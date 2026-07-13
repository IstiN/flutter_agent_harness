/// The low-level agent loop: stream the model, execute tool calls, append
/// results, re-invoke the model until stop.
///
/// Ported from pi-mono `packages/agent/src/agent-loop.ts`. Kept close to the
/// original control flow so future pi fixes port trivially. Deliberate
/// divergences from the TypeScript original:
///
/// - `AgentMessage` is our [Message] union directly; pi's custom-message
///   extension point and `convertToLlm`/`transformContext` arrive with the
///   stateful `Agent` (next phase). The context handed to the provider is the
///   loop's [Context] unchanged.
/// - Tools are not self-executing here: pi's `AgentTool.execute` is replaced
///   by an injected [ToolExecutor] callback, and the provider adapter is an
///   injected [StreamFunction], so the loop is fully unit-testable without
///   HTTP or a tool registry. Schema validation, argument preparation, and
///   per-tool `executionMode` overrides arrive with the tool registry.
/// - Hooks (`beforeToolCall`/`afterToolCall`/`shouldStopAfterTurn`/
///   `prepareNextTurn`) and steering/follow-up message queues are the next
///   card; the loop body marks where they slot into pi's `runLoop`.
/// - `AbortSignal` is [CancelToken]; cancellation is also checked *before*
///   each provider call and a synthetic aborted message is produced if the
///   token is already cancelled, instead of relying solely on the provider
///   returning an aborted error event.
/// - pi has no `maxTurns` in `AgentLoopConfig`; neither do we. Turns end when
///   the model stops calling tools, fails, or is aborted.
/// - pi does not consult `isContextOverflow` in the low-level loop (overflow
///   handling lives in the session/compaction layer); neither do we. The
///   upcoming hooks (`shouldStopAfterTurn`) are the extension point.
library;

import 'dart:async';

import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../exceptions.dart';
import '../model.dart';
import '../types.dart';

/// Provider adapter contract consumed by the agent loop.
///
/// Matches the shape of the provider adapters (`streamOpenAICompletions`,
/// `streamAnthropic`, `streamGoogle`): a model and a [Context] in, an
/// [AssistantMessageEventStream] out. The adapters' extra positional options
/// are adapted with a thin closure, e.g.
///
/// ```dart
/// (model, context, {cancelToken}) => streamOpenAICompletions(
///   model,
///   context,
///   OpenAICompletionsOptions(cancelToken: cancelToken),
/// )
/// ```
///
/// Contract (identical to the adapters'): never throw; all failures —
/// network, rate limiting, abort — arrive as an [ErrorEvent] on the returned
/// stream with [StopReason.error] or [StopReason.aborted]. The loop is
/// defensive anyway: a throw or a stream that closes without a terminal
/// event is converted into an error [AssistantMessage].
typedef StreamFunction =
    AssistantMessageEventStream Function(
      Model model,
      Context context, {
      CancelToken? cancelToken,
    });

/// How tool calls from a single assistant message are executed.
///
/// Ported from pi's `ToolExecutionMode`.
enum ToolExecutionMode {
  /// Each tool call is executed and finalized before the next one starts.
  sequential,

  /// Tool calls are preflighted sequentially, then executed concurrently.
  /// [ToolExecutionEndEvent]s are emitted in completion order, while
  /// tool-result message events are emitted in assistant source order after
  /// all calls settle.
  parallel,
}

/// Final or partial result produced by a tool execution.
///
/// Ported subset of pi's `AgentToolResult`: [content] is what goes back to
/// the model; `details`/`addedToolNames` arrive with the tool registry.
final class ToolExecutionResult {
  const ToolExecutionResult({required this.content, this.terminate = false});

  /// Convenience constructor for a plain-text result.
  factory ToolExecutionResult.text(String text, {bool terminate = false}) {
    return ToolExecutionResult(
      content: [TextContent(text: text)],
      terminate: terminate,
    );
  }

  /// Text or image content returned to the model.
  final List<ContentBlock> content;

  /// Hint that the agent should stop after the current tool batch.
  /// Early termination only happens when every finalized tool result in the
  /// batch sets this to `true` (pi semantics).
  final bool terminate;
}

/// Callback used by a tool executor to stream partial execution updates.
///
/// Scoped to a single tool call; updates emitted after the executor's future
/// settles are ignored by the loop (pi semantics).
typedef ToolUpdateCallback = void Function(ToolExecutionResult partialResult);

/// Executes a single tool call and returns its result.
///
/// Throw to signal failure — the loop converts the error into an error tool
/// result (pi's "throw on failure instead of encoding errors in `content`").
/// [cancelToken] should abort in-flight work promptly; [onUpdate] streams
/// partial results.
typedef ToolExecutor =
    Future<ToolExecutionResult> Function(
      ToolCall toolCall,
      CancelToken? cancelToken,
      ToolUpdateCallback? onUpdate,
    );

/// Configuration for one agent loop run.
///
/// Ported subset of pi's `AgentLoopConfig`. Hooks and steering/follow-up
/// queues are intentionally absent — they arrive with the stateful `Agent`
/// in the next phase and slot into the marked extension points in the loop
/// body.
final class AgentLoopConfig {
  const AgentLoopConfig({
    required this.model,
    this.toolExecution = ToolExecutionMode.parallel,
  });

  /// The model to call each turn.
  final Model model;

  /// How tool calls within one assistant message are executed.
  /// Default: [ToolExecutionMode.parallel] (pi default).
  final ToolExecutionMode toolExecution;
}

/// Events emitted by the agent loop.
///
/// Ported from pi's `AgentEvent` union as a sealed class hierarchy. A turn is
/// one assistant response plus any tool calls/results it triggers. Partial
/// snapshots follow the partial-first invariant: every [MessageUpdateEvent]
/// carries the live partial [AssistantMessage].
sealed class AgentEvent {
  const AgentEvent();
}

/// The loop started processing a prompt or continuation.
final class AgentStartEvent extends AgentEvent {
  const AgentStartEvent();
}

/// The loop finished. Always the last event; carries every message produced
/// by this run (prompts included for [agentLoop], excluded for
/// [agentLoopContinue]).
final class AgentEndEvent extends AgentEvent {
  const AgentEndEvent(this.messages);

  /// Messages produced by this run, in order.
  final List<Message> messages;
}

/// A new turn (assistant response + tool calls) started.
final class TurnStartEvent extends AgentEvent {
  const TurnStartEvent();
}

/// A turn finished: the assistant message completed and its tool calls (if
/// any) produced [toolResults].
final class TurnEndEvent extends AgentEvent {
  const TurnEndEvent({required this.message, required this.toolResults});

  /// The completed assistant message of this turn.
  final AssistantMessage message;

  /// Tool results produced this turn, in assistant source order.
  final List<ToolResultMessage> toolResults;
}

/// A message entered the transcript: a prompt, a (partial) assistant
/// message, or a tool result.
final class MessageStartEvent extends AgentEvent {
  const MessageStartEvent(this.message);

  /// The message. For assistant messages this is the first partial snapshot.
  final Message message;
}

/// The streamed assistant message advanced. Only emitted for assistant
/// messages; [message] is the live partial snapshot carried by
/// [assistantMessageEvent].
final class MessageUpdateEvent extends AgentEvent {
  const MessageUpdateEvent({
    required this.message,
    required this.assistantMessageEvent,
  });

  /// The live partial assistant message.
  final AssistantMessage message;

  /// The underlying provider event that produced this update.
  final AssistantMessageEvent assistantMessageEvent;
}

/// A message is complete: the final assistant message, a prompt, or a tool
/// result.
final class MessageEndEvent extends AgentEvent {
  const MessageEndEvent(this.message);

  /// The final message.
  final Message message;
}

/// Execution of a tool call started.
final class ToolExecutionStartEvent extends AgentEvent {
  const ToolExecutionStartEvent({
    required this.toolCallId,
    required this.toolName,
    required this.args,
  });

  /// The [ToolCall.id] being executed.
  final String toolCallId;

  /// The tool's name.
  final String toolName;

  /// The parsed tool call arguments.
  final Map<String, dynamic> args;
}

/// A tool reported a partial execution result.
final class ToolExecutionUpdateEvent extends AgentEvent {
  const ToolExecutionUpdateEvent({
    required this.toolCallId,
    required this.toolName,
    required this.args,
    required this.partialResult,
  });

  /// The [ToolCall.id] being executed.
  final String toolCallId;

  /// The tool's name.
  final String toolName;

  /// The parsed tool call arguments.
  final Map<String, dynamic> args;

  /// The partial result.
  final ToolExecutionResult partialResult;
}

/// Execution of a tool call finished (successfully or with an error result).
final class ToolExecutionEndEvent extends AgentEvent {
  const ToolExecutionEndEvent({
    required this.toolCallId,
    required this.toolName,
    required this.result,
    required this.isError,
  });

  /// The [ToolCall.id] that was executed.
  final String toolCallId;

  /// The tool's name.
  final String toolName;

  /// The final result.
  final ToolExecutionResult result;

  /// Whether the result is an error (unknown tool, executor threw, blocked,
  /// aborted, or truncated arguments).
  final bool isError;
}

/// The event stream returned by [agentLoop] and [agentLoopContinue].
///
/// Completes on [AgentEndEvent]; [EventStream.result] then yields the
/// messages produced by the run.
class AgentEventStream extends EventStream<AgentEvent, List<Message>> {
  AgentEventStream()
    : super(
        isComplete: (event) => event is AgentEndEvent,
        extractResult: (event) => (event as AgentEndEvent).messages,
      );
}

/// Starts an agent loop with new prompt messages.
///
/// The prompts are appended to [context] and announced with
/// [MessageStartEvent]/[MessageEndEvent]; the loop then streams the model,
/// executes tool calls via [toolExecutor], and re-invokes the model until it
/// stops calling tools, fails, or [cancelToken] is cancelled. Provider
/// failures never throw (errors-as-events): they end the loop with an
/// assistant message whose [AssistantMessage.stopReason] is
/// [StopReason.error] or [StopReason.aborted].
///
/// The returned [AgentEventStream] replays all events to a late listener and
/// its [EventStream.result] resolves with the messages produced by the run.
///
/// [context] is copied defensively; the loop mutates only its own copy.
AgentEventStream agentLoop({
  required List<Message> prompts,
  required Context context,
  required AgentLoopConfig config,
  required StreamFunction streamFunction,
  required ToolExecutor toolExecutor,
  CancelToken? cancelToken,
}) {
  final stream = AgentEventStream();
  _drive(
    stream,
    _runAgentLoop(
      prompts: prompts,
      context: context,
      config: config,
      emit: stream.push,
      streamFunction: streamFunction,
      toolExecutor: toolExecutor,
      cancelToken: cancelToken,
    ),
  );
  return stream;
}

/// Continues an agent loop from [context] without adding a new message.
///
/// Used for retries — the context already ends with a user or tool-result
/// message the model can respond to. Throws [ConfigException] synchronously
/// if [context] has no messages or ends with an assistant message (pi
/// validation).
AgentEventStream agentLoopContinue({
  required Context context,
  required AgentLoopConfig config,
  required StreamFunction streamFunction,
  required ToolExecutor toolExecutor,
  CancelToken? cancelToken,
}) {
  if (context.messages.isEmpty) {
    throw const ConfigException('Cannot continue: no messages in context');
  }
  if (context.messages.last.role == 'assistant') {
    throw const ConfigException(
      'Cannot continue from message role: assistant',
    );
  }

  final stream = AgentEventStream();
  _drive(
    stream,
    _runAgentLoop(
      prompts: const [],
      context: context,
      config: config,
      emit: stream.push,
      streamFunction: streamFunction,
      toolExecutor: toolExecutor,
      cancelToken: cancelToken,
    ),
  );
  return stream;
}

void _drive(AgentEventStream stream, Future<void> run) {
  unawaited(
    run
        .then((_) => stream.end())
        // The loop converts provider/tool failures into events, so reaching
        // here means a loop bug; still close the stream rather than hang.
        .catchError((Object _) => stream.end()),
  );
}

/// Port of pi's `runAgentLoop` + `runLoop`.
Future<void> _runAgentLoop({
  required List<Message> prompts,
  required Context context,
  required AgentLoopConfig config,
  required void Function(AgentEvent) emit,
  required StreamFunction streamFunction,
  required ToolExecutor toolExecutor,
  CancelToken? cancelToken,
}) async {
  final newMessages = <Message>[...prompts];
  final currentContext = Context(
    systemPrompt: context.systemPrompt,
    messages: [...context.messages, ...prompts],
    tools: context.tools,
  );

  emit(const AgentStartEvent());
  emit(const TurnStartEvent());
  for (final prompt in prompts) {
    emit(MessageStartEvent(prompt));
    emit(MessageEndEvent(prompt));
  }

  var firstTurn = true;
  var hasMoreToolCalls = true;
  // pi's inner loop is `while (hasMoreToolCalls || pendingMessages.isNotEmpty)`;
  // pending steering/follow-up messages arrive with the next card.
  while (hasMoreToolCalls) {
    if (firstTurn) {
      firstTurn = false;
    } else {
      emit(const TurnStartEvent());
    }
    // Extension point: pi injects pending steering messages here.

    final message = await _streamAssistantResponse(
      currentContext,
      config,
      emit,
      streamFunction,
      cancelToken,
    );
    newMessages.add(message);

    if (message.stopReason == StopReason.error ||
        message.stopReason == StopReason.aborted) {
      emit(TurnEndEvent(message: message, toolResults: const []));
      emit(AgentEndEvent(List.unmodifiable(newMessages)));
      return;
    }

    final toolCalls = message.content.whereType<ToolCall>().toList();

    final toolResults = <ToolResultMessage>[];
    hasMoreToolCalls = false;
    if (toolCalls.isNotEmpty) {
      // A "length" stop means the output was cut off by the token limit, so
      // every tool call in the message may carry truncated arguments. Fail
      // them all instead of executing potentially borked calls.
      final batch = message.stopReason == StopReason.length
          ? await _failToolCallsFromTruncatedMessage(toolCalls, emit)
          : await _executeToolCalls(
              currentContext,
              toolCalls,
              config,
              toolExecutor,
              cancelToken,
              emit,
            );
      toolResults.addAll(batch.messages);
      hasMoreToolCalls = !batch.terminate;

      for (final result in toolResults) {
        currentContext.messages.add(result);
        newMessages.add(result);
      }
    }

    emit(
      TurnEndEvent(message: message, toolResults: List.unmodifiable(toolResults)),
    );
    // Extension point: pi calls prepareNextTurn / shouldStopAfterTurn here,
    // then drains steering and follow-up queues to decide whether to loop.
  }

  emit(AgentEndEvent(List.unmodifiable(newMessages)));
}

/// Streams one assistant response from the provider, emitting message
/// lifecycle events and keeping the partial message in [context.messages]
/// up to date (partial-first). Port of pi's `streamAssistantResponse`.
Future<AssistantMessage> _streamAssistantResponse(
  Context context,
  AgentLoopConfig config,
  void Function(AgentEvent) emit,
  StreamFunction streamFunction,
  CancelToken? cancelToken,
) async {
  // Hardening over pi: short-circuit an already-cancelled token instead of
  // relying on the provider to surface the abort as an error event.
  if (cancelToken != null && cancelToken.isCancelled) {
    return _finishWithoutStream(
      context,
      emit,
      _terminalMessage(config.model, StopReason.aborted, 'Operation aborted'),
    );
  }

  AssistantMessageEventStream response;
  try {
    response = streamFunction(
      config.model,
      context,
      cancelToken: cancelToken,
    );
  } catch (error) {
    return _finishWithoutStream(
      context,
      emit,
      _terminalMessage(config.model, StopReason.error, '$error'),
    );
  }

  AssistantMessage? partialMessage;
  var addedPartial = false;

  await for (final event in response) {
    switch (event) {
      case StartEvent(:final partial):
        partialMessage = partial;
        context.messages.add(partial);
        addedPartial = true;
        emit(MessageStartEvent(partial));
      case DoneEvent() || ErrorEvent():
        return _finishStreamed(context, emit, addedPartial, event);
      default:
        if (partialMessage != null) {
          partialMessage = event.partial;
          context.messages[context.messages.length - 1] = event.partial;
          emit(
            MessageUpdateEvent(
              message: event.partial,
              assistantMessageEvent: event,
            ),
          );
        }
    }
  }

  // The provider stream closed without a terminal event (provider bug).
  const errorText = 'Provider stream ended without a terminal event';
  final base = partialMessage ?? _terminalMessage(config.model, StopReason.error, errorText);
  return _finishWithoutStream(
    context,
    emit,
    base.copyWith(stopReason: StopReason.error, errorMessage: errorText),
    replaceLast: addedPartial,
  );
}

AssistantMessage _finishStreamed(
  Context context,
  void Function(AgentEvent) emit,
  bool addedPartial,
  AssistantMessageEvent terminalEvent,
) {
  final finalMessage = terminalEvent.partial;
  if (addedPartial) {
    context.messages[context.messages.length - 1] = finalMessage;
  } else {
    context.messages.add(finalMessage);
    emit(MessageStartEvent(finalMessage));
  }
  emit(MessageEndEvent(finalMessage));
  return finalMessage;
}

/// Appends (or replaces the partial with) [message] and emits its lifecycle
/// events, for paths where no provider events flowed.
AssistantMessage _finishWithoutStream(
  Context context,
  void Function(AgentEvent) emit,
  AssistantMessage message, {
  bool replaceLast = false,
}) {
  if (replaceLast) {
    context.messages[context.messages.length - 1] = message;
  } else {
    context.messages.add(message);
    emit(MessageStartEvent(message));
  }
  emit(MessageEndEvent(message));
  return message;
}

AssistantMessage _terminalMessage(
  Model model,
  StopReason stopReason,
  String errorMessage,
) {
  return AssistantMessage(
    content: const [],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.now(),
  );
}

/// Fails all tool calls from an assistant message that was truncated by the
/// output token limit. Streamed tool-call arguments are finalized with a
/// best-effort JSON salvage parser, so a truncated message can yield tool
/// calls whose arguments parse but are silently incomplete. None of them are
/// safe to execute; report each as an error so the model can re-issue them.
///
/// Port of pi's `failToolCallsFromTruncatedMessage`.
Future<_ExecutedToolCallBatch> _failToolCallsFromTruncatedMessage(
  List<ToolCall> toolCalls,
  void Function(AgentEvent) emit,
) async {
  final messages = <ToolResultMessage>[];
  for (final toolCall in toolCalls) {
    emit(
      ToolExecutionStartEvent(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        args: toolCall.arguments,
      ),
    );
    final finalized = _FinalizedToolCall(
      toolCall,
      _errorToolResult(
        'Tool call "${toolCall.name}" was not executed: the response hit '
        'the output token limit, so its arguments may be truncated. '
        'Re-issue the tool call with complete arguments.',
      ),
      true,
    );
    _emitToolExecutionEnd(finalized, emit);
    messages.add(_emitToolResultMessage(finalized, emit));
  }
  return _ExecutedToolCallBatch(messages, terminate: false);
}

/// Executes the tool calls of one assistant message. Port of pi's
/// `executeToolCalls`, minus the per-tool `executionMode` override (that
/// lives on pi's `AgentTool`, which arrives with the tool registry).
Future<_ExecutedToolCallBatch> _executeToolCalls(
  Context context,
  List<ToolCall> toolCalls,
  AgentLoopConfig config,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  void Function(AgentEvent) emit,
) {
  return config.toolExecution == ToolExecutionMode.sequential
      ? _executeToolCallsSequential(
          context,
          toolCalls,
          toolExecutor,
          cancelToken,
          emit,
        )
      : _executeToolCallsParallel(
          context,
          toolCalls,
          toolExecutor,
          cancelToken,
          emit,
        );
}

Future<_ExecutedToolCallBatch> _executeToolCallsSequential(
  Context context,
  List<ToolCall> toolCalls,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  void Function(AgentEvent) emit,
) async {
  final finalizedCalls = <_FinalizedToolCall>[];
  final messages = <ToolResultMessage>[];

  for (final toolCall in toolCalls) {
    emit(
      ToolExecutionStartEvent(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        args: toolCall.arguments,
      ),
    );

    final finalized = switch (_prepareToolCall(context, toolCall, cancelToken)) {
      _ImmediateToolCall(:final result, :final isError) => _FinalizedToolCall(
        toolCall,
        result,
        isError,
      ),
      _PreparedToolCall() => await _executePreparedToolCall(
        toolCall,
        toolExecutor,
        cancelToken,
        emit,
      ),
    };

    _emitToolExecutionEnd(finalized, emit);
    finalizedCalls.add(finalized);
    messages.add(_emitToolResultMessage(finalized, emit));

    if (cancelToken != null && cancelToken.isCancelled) break;
  }

  return _ExecutedToolCallBatch(
    messages,
    terminate: _shouldTerminateToolBatch(finalizedCalls),
  );
}

Future<_ExecutedToolCallBatch> _executeToolCallsParallel(
  Context context,
  List<ToolCall> toolCalls,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  void Function(AgentEvent) emit,
) async {
  // One entry per started tool call, in assistant source order.
  final pending = <Future<_FinalizedToolCall>>[];

  for (final toolCall in toolCalls) {
    emit(
      ToolExecutionStartEvent(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        args: toolCall.arguments,
      ),
    );

    switch (_prepareToolCall(context, toolCall, cancelToken)) {
      case _ImmediateToolCall(:final result, :final isError):
        final finalized = _FinalizedToolCall(toolCall, result, isError);
        _emitToolExecutionEnd(finalized, emit);
        pending.add(Future.value(finalized));
      case _PreparedToolCall():
        // Executes concurrently; tool_execution_end is emitted in completion
        // order as each call settles.
        pending.add(
          _executePreparedToolCall(toolCall, toolExecutor, cancelToken, emit)
              .then((finalized) {
                _emitToolExecutionEnd(finalized, emit);
                return finalized;
              }),
        );
    }

    if (cancelToken != null && cancelToken.isCancelled) break;
  }

  final finalizedCalls = await Future.wait(pending);
  final messages = <ToolResultMessage>[];
  for (final finalized in finalizedCalls) {
    messages.add(_emitToolResultMessage(finalized, emit));
  }

  return _ExecutedToolCallBatch(
    messages,
    terminate: _shouldTerminateToolBatch(finalizedCalls),
  );
}

/// Port of pi's `prepareToolCall`, reduced to the pieces available without a
/// tool registry: existence check against [Context.tools] and the abort
/// check. Schema validation and argument preparation arrive later.
_ToolCallPreparation _prepareToolCall(
  Context context,
  ToolCall toolCall,
  CancelToken? cancelToken,
) {
  if (_findTool(context, toolCall.name) == null) {
    return _ImmediateToolCall(
      _errorToolResult('Tool ${toolCall.name} not found'),
      true,
    );
  }
  if (cancelToken != null && cancelToken.isCancelled) {
    return _ImmediateToolCall(_errorToolResult('Operation aborted'), true);
  }
  return _PreparedToolCall();
}

Tool? _findTool(Context context, String name) {
  for (final tool in context.tools ?? const <Tool>[]) {
    if (tool.name == name) return tool;
  }
  return null;
}

/// Port of pi's `executePreparedToolCall`: run the executor, relay partial
/// updates, convert a throw into an error result.
Future<_FinalizedToolCall> _executePreparedToolCall(
  ToolCall toolCall,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  void Function(AgentEvent) emit,
) async {
  var acceptingUpdates = true;
  try {
    final result = await toolExecutor(toolCall, cancelToken, (partialResult) {
      if (!acceptingUpdates) return;
      emit(
        ToolExecutionUpdateEvent(
          toolCallId: toolCall.id,
          toolName: toolCall.name,
          args: toolCall.arguments,
          partialResult: partialResult,
        ),
      );
    });
    acceptingUpdates = false;
    return _FinalizedToolCall(toolCall, result, false);
  } catch (error) {
    return _FinalizedToolCall(toolCall, _errorToolResult('$error'), true);
  } finally {
    acceptingUpdates = false;
  }
}

bool _shouldTerminateToolBatch(List<_FinalizedToolCall> finalizedCalls) {
  return finalizedCalls.isNotEmpty &&
      finalizedCalls.every((finalized) => finalized.result.terminate);
}

ToolExecutionResult _errorToolResult(String message) {
  return ToolExecutionResult(content: [TextContent(text: message)]);
}

void _emitToolExecutionEnd(
  _FinalizedToolCall finalized,
  void Function(AgentEvent) emit,
) {
  emit(
    ToolExecutionEndEvent(
      toolCallId: finalized.toolCall.id,
      toolName: finalized.toolCall.name,
      result: finalized.result,
      isError: finalized.isError,
    ),
  );
}

ToolResultMessage _emitToolResultMessage(
  _FinalizedToolCall finalized,
  void Function(AgentEvent) emit,
) {
  final message = ToolResultMessage(
    toolCallId: finalized.toolCall.id,
    toolName: finalized.toolCall.name,
    content: finalized.result.content,
    isError: finalized.isError,
    timestamp: DateTime.now(),
  );
  emit(MessageStartEvent(message));
  emit(MessageEndEvent(message));
  return message;
}

final class _ExecutedToolCallBatch {
  const _ExecutedToolCallBatch(this.messages, {required this.terminate});

  final List<ToolResultMessage> messages;
  final bool terminate;
}

sealed class _ToolCallPreparation {
  const _ToolCallPreparation();
}

/// The tool call resolved to a result without executing (unknown tool,
/// aborted).
final class _ImmediateToolCall extends _ToolCallPreparation {
  const _ImmediateToolCall(this.result, this.isError);

  final ToolExecutionResult result;
  final bool isError;
}

/// The tool call is cleared to execute.
final class _PreparedToolCall extends _ToolCallPreparation {
  const _PreparedToolCall();
}

final class _FinalizedToolCall {
  const _FinalizedToolCall(this.toolCall, this.result, this.isError);

  final ToolCall toolCall;
  final ToolExecutionResult result;
  final bool isError;
}
