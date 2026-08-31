/// The low-level agent loop: stream the model, execute tool calls, append
/// results, re-invoke the model until stop.
///
/// Ported from pi-mono `packages/agent/src/agent-loop.ts`. Kept close to the
/// original control flow so future pi fixes port trivially. Deliberate
/// divergences from the TypeScript original:
///
/// - `AgentMessage` is our [Message] union directly; pi's custom-message
///   extension point and `convertToLlm` are absent because our messages are
///   already LLM-shaped. [TransformContextHook] (pi's `transformContext`) is
///   the only rewrite applied before each provider call.
/// - Tools are not self-executing here: pi's `AgentTool.execute` is replaced
///   by an injected [ToolExecutor] callback, and the provider adapter is an
///   injected [StreamFunction], so the loop is fully unit-testable without
///   HTTP or a tool registry. Schema validation and argument preparation
///   live in the tool registry's executor adapter; the per-tool
///   `executionMode` override is honored here when a [Context] tool is an
///   [AgentTool].
/// - Hooks (`beforeToolCall`/`afterToolCall`/`transformContext`/
///   `prepareNextTurn`) and steering/follow-up message queues are config
///   fields here, mirroring pi's `AgentLoopConfig`; the stateful `Agent`
///   (same directory) wires its queues and public hooks into them. pi's
///   `shouldStopAfterTurn` is not ported yet. pi's `convertToLlm` is absent:
///   our messages are already LLM-shaped.
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
import 'agent_tool.dart';

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

/// Per-call prompt-cache routing overrides, consulted by the provider
/// stream functions built with `providerStreamFunction`.
///
/// The [StreamFunction] contract has no options slot, so per-call routing
/// (pi's `sessionId`/`cacheRetention` stream options) travels in a zone:
/// [runWith] installs values for every provider call started inside its
/// body — including async work such as fallback-chain attempts, which run
/// in the zone they were created in. Adapters read [current] when a call
/// starts; a `null` field keeps the call's own defaults.
///
/// Used by compaction summarization, which forces `cacheRetention: 'none'`
/// plus a fresh routing session id so summaries never pollute the session's
/// prompt-cache accounting (pi's `callCompleteSimple`).
final class StreamCacheRouting {
  StreamCacheRouting._();

  static final Object _zoneKey = Object();

  /// The routing values active in the current zone, or `null` when no
  /// override is in effect (calls then use their built-in defaults).
  static ({String? sessionId, String? cacheRetention})? get current {
    final value = Zone.current[_zoneKey];
    return value is ({String? sessionId, String? cacheRetention})
        ? value
        : null;
  }

  /// Runs [body] with [sessionId]/[cacheRetention] overriding the cache
  /// routing of provider calls started inside it. An override is explicit:
  /// code that binds default routing values (the model-roles resolver)
  /// yields to an active override instead of replacing it.
  static T runWith<T>(
    T Function() body, {
    String? sessionId,
    String? cacheRetention,
  }) {
    return runZoned(
      body,
      zoneValues: {
        _zoneKey: (sessionId: sessionId, cacheRetention: cacheRetention),
      },
    );
  }
}

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

/// Sink receiving every event the loop emits (pi's `AgentEventSink`).
///
/// Awaiting the returned future delays the loop, which is how the stateful
/// `Agent` folds its listeners into the run's settlement.
typedef AgentEventSink = FutureOr<void> Function(AgentEvent event);

/// Context passed to [BeforeToolCallHook].
///
/// Ported from pi's `BeforeToolCallContext` (minus `args`, which arrives with
/// schema validation in the tool registry).
final class BeforeToolCallContext {
  const BeforeToolCallContext({
    required this.assistantMessage,
    required this.toolCall,
    required this.context,
  });

  /// The assistant message that requested the tool call.
  final AssistantMessage assistantMessage;

  /// The raw tool call block from [AssistantMessage.content].
  final ToolCall toolCall;

  /// The loop's context at the time the tool call is prepared.
  final Context context;
}

/// Result returned from [BeforeToolCallHook].
///
/// Returning `block: true` prevents the tool from executing; the loop emits
/// an error tool result with [reason] (or a default message) instead.
/// Ported from pi's `BeforeToolCallResult`.
final class BeforeToolCallResult {
  const BeforeToolCallResult({this.block = false, this.reason});

  /// Whether to block execution of the tool call.
  final bool block;

  /// Text of the error tool result emitted when [block] is true.
  final String? reason;
}

/// Called before a tool is executed (pi's `beforeToolCall`).
///
/// The hook receives the run's [CancelToken] and is responsible for honoring
/// it. A throw is converted into an error tool result (pi semantics).
typedef BeforeToolCallHook =
    FutureOr<BeforeToolCallResult?> Function(
      BeforeToolCallContext context,
      CancelToken? cancelToken,
    );

/// Context passed to [AfterToolCallHook].
///
/// Ported from pi's `AfterToolCallContext` (minus `args`/`details`).
final class AfterToolCallContext {
  const AfterToolCallContext({
    required this.assistantMessage,
    required this.toolCall,
    required this.result,
    required this.isError,
    required this.context,
  });

  /// The assistant message that requested the tool call.
  final AssistantMessage assistantMessage;

  /// The raw tool call block from [AssistantMessage.content].
  final ToolCall toolCall;

  /// The executed tool result before any overrides are applied.
  final ToolExecutionResult result;

  /// Whether the executed result is currently treated as an error.
  final bool isError;

  /// The loop's context at the time the tool call is finalized.
  final Context context;
}

/// Partial override returned from [AfterToolCallHook].
///
/// Merge semantics are field-by-field (pi semantics, no deep merge): each
/// provided field replaces the corresponding value of the executed result;
/// omitted fields keep their original values.
final class AfterToolCallResult {
  const AfterToolCallResult({this.content, this.isError, this.terminate});

  /// Replaces the tool result content in full.
  final List<ContentBlock>? content;

  /// Replaces the error flag.
  final bool? isError;

  /// Replaces the early-termination hint.
  final bool? terminate;
}

/// Called after a tool finishes executing, before `tool_execution_end` and
/// the tool-result message events are emitted (pi's `afterToolCall`).
///
/// A throw turns the result into an error tool result (pi semantics).
typedef AfterToolCallHook =
    FutureOr<AfterToolCallResult?> Function(
      AfterToolCallContext context,
      CancelToken? cancelToken,
    );

/// Context passed to [PrepareNextTurnHook] after a turn fully completes.
///
/// Ported from pi's `PrepareNextTurnContext`.
final class NextTurnContext {
  const NextTurnContext({
    required this.message,
    required this.toolResults,
    required this.context,
    required this.newMessages,
  });

  /// The assistant message that completed the turn.
  final AssistantMessage message;

  /// Tool results produced this turn, in assistant source order.
  final List<ToolResultMessage> toolResults;

  /// The loop's context after the turn's messages have been appended.
  final Context context;

  /// The messages this run will return if it exits now (prompts included for
  /// [agentLoop]/[runAgentLoop], excluded for continuations).
  final List<Message> newMessages;
}

/// Replacement runtime state used by the loop before another provider
/// request. Ported subset of pi's `AgentLoopTurnUpdate` (no `thinkingLevel`:
/// reasoning levels are not ported yet).
final class AgentLoopTurnUpdate {
  const AgentLoopTurnUpdate({this.context, this.model});

  /// Context for the next provider request. `null` keeps the current one.
  final Context? context;

  /// Model for the next provider request. `null` keeps the current one.
  final Model? model;
}

/// Called after `turn_end` and before the loop decides whether another
/// provider request should start (pi's `prepareNextTurn`).
///
/// Return an [AgentLoopTurnUpdate] to replace the context and/or model for
/// the next turn in this run; return `null` to keep the current ones.
typedef PrepareNextTurnHook =
    FutureOr<AgentLoopTurnUpdate?> Function(NextTurnContext context);

/// Rewrites the message list sent to the provider before each call (pi's
/// `transformContext`). The transcript itself is never modified.
///
/// Contract (pi): must not throw; return a safe fallback instead. A throw
/// propagates out of the loop and fails the run.
typedef TransformContextHook =
    FutureOr<List<Message>> Function(
      List<Message> messages,
      CancelToken? cancelToken,
    );

/// Returns queued messages to inject into the conversation.
///
/// Used for steering (polled after each turn, and once before the first) and
/// follow-ups (polled when the run would otherwise stop). Contract (pi):
/// must not throw; return an empty list when nothing is queued.
typedef QueuedMessagesSource = FutureOr<List<Message>> Function();

/// Configuration for one agent loop run.
///
/// Ported subset of pi's `AgentLoopConfig`. `convertToLlm`,
/// `shouldStopAfterTurn`, `getApiKey`, and the provider-option fields are not
/// ported (see the library doc).
final class AgentLoopConfig {
  const AgentLoopConfig({
    required this.model,
    this.toolExecution = ToolExecutionMode.parallel,
    this.beforeToolCall,
    this.afterToolCall,
    this.transformContext,
    this.prepareNextTurn,
    this.getSteeringMessages,
    this.getFollowUpMessages,
    this.steeringNotifications,
    this.hasPendingSteering,
    this.maxEmptyRetries = 1,
    this.maxSteeringTurns = 20,
  });

  /// The model to call each turn.
  final Model model;

  /// How tool calls within one assistant message are executed.
  /// Default: [ToolExecutionMode.parallel] (pi default).
  final ToolExecutionMode toolExecution;

  /// Called before each tool execution; can block it.
  final BeforeToolCallHook? beforeToolCall;

  /// Called after each tool execution; can override the result.
  final AfterToolCallHook? afterToolCall;

  /// Rewrites the message list sent to the provider before each call.
  final TransformContextHook? transformContext;

  /// Adjusts context/model between turns.
  final PrepareNextTurnHook? prepareNextTurn;

  /// Steering messages to inject at the next turn boundary.
  final QueuedMessagesSource? getSteeringMessages;

  /// Follow-up messages to process after the run would otherwise stop.
  final QueuedMessagesSource? getFollowUpMessages;

  /// Fires when a steering message arrives mid-run (the in-process queue).
  /// The tool-call phase turns the first arrival into a soft-yield request
  /// (see [currentYieldToken]): yield-aware long-running tools (bash, task)
  /// finish the tool call early WITHOUT stopping the underlying work, so the
  /// user message is delivered at the next step boundary instead of waiting
  /// for the whole tool call.
  final Stream<void>? steeringNotifications;

  /// Probes for externally pending steering (e.g. the messaging inbox)
  /// WITHOUT draining it — polled on a slow timer during the tool-call
  /// phase as a second yield trigger. Null when the host has no external
  /// steering source.
  final Future<bool> Function()? hasPendingSteering;

  /// How many times a degenerate EMPTY completion (stopReason `stop`, no
  /// tool calls, no text — some providers answer like this under load) is
  /// retried with the same context before the turn accepts it. Default: 1
  /// (one automatic retry — a blank answer never ends a run on the first
  /// try).
  final int maxEmptyRetries;

  /// How many steering batches may extend ONE run (mid-run user input or
  /// external mail). Without a cap, a self-sustaining agent chatter loop
  /// (every inbound message steers a reply that triggers the next
  /// inbound) extends the run forever — the spinner never stops and
  /// typed input queues behind an endless turn. Once the cap is reached
  /// the run settles; undelivered steering stays queued and is picked up
  /// by the next run (whose own wake caps apply). Default: 20.
  final int maxSteeringTurns;

  /// Returns a copy with [model] replaced (used by [prepareNextTurn]).
  AgentLoopConfig copyWith({Model? model}) {
    return AgentLoopConfig(
      model: model ?? this.model,
      toolExecution: toolExecution,
      beforeToolCall: beforeToolCall,
      afterToolCall: afterToolCall,
      transformContext: transformContext,
      prepareNextTurn: prepareNextTurn,
      getSteeringMessages: getSteeringMessages,
      getFollowUpMessages: getFollowUpMessages,
      steeringNotifications: steeringNotifications,
      hasPendingSteering: hasPendingSteering,
      maxEmptyRetries: maxEmptyRetries,
      maxSteeringTurns: maxSteeringTurns,
    );
  }
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

/// The agent is fully idle: the run AND every queued follow-up have drained
/// and all awaited listeners for the run's events (including `agent_end`)
/// have settled (pi's `agent_settled`).
///
/// Emitted only by the stateful `Agent` (in agent.dart), after the last
/// [AgentEndEvent] of a run and before [Agent.waitForIdle] resolves — the
/// low-level loop never emits it, so [AgentEventStream] still completes on
/// [AgentEndEvent].
final class AgentSettledEvent extends AgentEvent {
  const AgentSettledEvent();
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
    runAgentLoop(
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
    throw const ConfigException('Cannot continue from message role: assistant');
  }

  final stream = AgentEventStream();
  _drive(
    stream,
    runAgentLoopContinue(
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

/// Starts an agent loop with new prompt messages, delivering events to
/// [emit] and resolving with the messages produced by the run.
///
/// This is the emit-based core beneath [agentLoop] (pi's `runAgentLoop`);
/// use it when events must be awaited as part of the run (the stateful
/// `Agent` does this for its listeners). Unlike [agentLoop], exceptions
/// from [emit] or a [TransformContextHook] propagate to the caller instead
/// of being swallowed into a closed stream.
Future<List<Message>> runAgentLoop({
  required List<Message> prompts,
  required Context context,
  required AgentLoopConfig config,
  required StreamFunction streamFunction,
  required ToolExecutor toolExecutor,
  required AgentEventSink emit,
  CancelToken? cancelToken,
}) {
  return _runAgentLoop(
    prompts: prompts,
    context: context,
    config: config,
    emit: emit,
    streamFunction: streamFunction,
    toolExecutor: toolExecutor,
    cancelToken: cancelToken,
  );
}

/// Continues an agent loop from [context], delivering events to [emit].
///
/// Emit-based core beneath [agentLoopContinue] (pi's `runAgentLoopContinue`).
/// Throws [ConfigException] synchronously if [context] has no messages or
/// ends with an assistant message (pi validation).
Future<List<Message>> runAgentLoopContinue({
  required Context context,
  required AgentLoopConfig config,
  required StreamFunction streamFunction,
  required ToolExecutor toolExecutor,
  required AgentEventSink emit,
  CancelToken? cancelToken,
}) {
  if (context.messages.isEmpty) {
    throw const ConfigException('Cannot continue: no messages in context');
  }
  if (context.messages.last.role == 'assistant') {
    throw const ConfigException('Cannot continue from message role: assistant');
  }

  return _runAgentLoop(
    prompts: const [],
    context: context,
    config: config,
    emit: emit,
    streamFunction: streamFunction,
    toolExecutor: toolExecutor,
    cancelToken: cancelToken,
  );
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
Future<List<Message>> _runAgentLoop({
  required List<Message> prompts,
  required Context context,
  required AgentLoopConfig config,
  required AgentEventSink emit,
  required StreamFunction streamFunction,
  required ToolExecutor toolExecutor,
  CancelToken? cancelToken,
}) async {
  final newMessages = <Message>[...prompts];
  var currentContext = Context(
    systemPrompt: context.systemPrompt,
    messages: [...context.messages, ...prompts],
    tools: context.tools,
  );
  var currentConfig = config;

  await _emitRunStart(prompts, emit);

  var firstTurn = true;
  // Steering-extension cap: a self-sustaining chatter loop (every inbound
  // message steers a reply that triggers the next inbound) must not keep
  // the run alive forever. Undelivered steering stays queued; the next
  // run picks it up under its own wake caps.
  var steeringExtensions = 0;
  Future<List<Message>> pollSteering(AgentLoopConfig config) async {
    if (steeringExtensions >= config.maxSteeringTurns) {
      return const <Message>[];
    }
    final messages = await _steeringMessages(config);
    if (messages.isNotEmpty) steeringExtensions++;
    return messages;
  }

  // Check for steering messages at start (user may have typed while waiting).
  var pendingMessages = await pollSteering(currentConfig);

  // Outer loop: continues when queued follow-up messages arrive after the
  // agent would stop. Inner loop: tool calls and steering messages.
  while (true) {
    var hasMoreToolCalls = true;
    while (hasMoreToolCalls || pendingMessages.isNotEmpty) {
      await _emitTurnStart(firstTurn, emit);
      firstTurn = false;

      // Inject queued messages before the next assistant response.
      await _injectPendingMessages(
        pendingMessages,
        emit,
        currentContext,
        newMessages,
      );
      pendingMessages = const [];

      var message = await _streamAssistantResponse(
        currentContext,
        currentConfig,
        emit,
        streamFunction,
        cancelToken,
      );
      message = await _retryDegenerateEmpty(
        message,
        currentContext,
        currentConfig,
        emit,
        streamFunction,
        cancelToken,
      );
      newMessages.add(message);

      final terminal = await _terminalRunMessages(message, newMessages, emit);
      if (terminal != null) return terminal;

      final toolPhase = await _runToolCallPhase(
        currentContext,
        message,
        currentConfig,
        toolExecutor,
        cancelToken,
        emit,
        newMessages,
      );
      final toolResults = toolPhase.results;
      hasMoreToolCalls = toolPhase.hasMore;

      final turnResults = List<ToolResultMessage>.unmodifiable(toolResults);
      await emit(TurnEndEvent(message: message, toolResults: turnResults));
      final turnUpdate = await currentConfig.prepareNextTurn?.call(
        NextTurnContext(
          message: message,
          toolResults: turnResults,
          context: currentContext,
          newMessages: List.unmodifiable(newMessages),
        ),
      );
      (currentContext, currentConfig) = _applyTurnUpdate(
        currentContext,
        currentConfig,
        turnUpdate,
      );

      pendingMessages = await pollSteering(currentConfig);
    }

    // Agent would stop here. Check for follow-up messages.
    final followUpMessages =
        await currentConfig.getFollowUpMessages?.call() ?? const <Message>[];
    if (followUpMessages.isNotEmpty) {
      // Set as pending so the inner loop processes them.
      pendingMessages = followUpMessages;
      continue;
    }

    break;
  }

  await emit(AgentEndEvent(List.unmodifiable(newMessages)));
  return newMessages;
}

/// Emits the run-start sequence: `agent_start`, the first `turn_start`, and
/// the lifecycle events of every prompt message.
Future<void> _emitRunStart(List<Message> prompts, AgentEventSink emit) async {
  await emit(const AgentStartEvent());
  await emit(const TurnStartEvent());
  for (final prompt in prompts) {
    await emit(MessageStartEvent(prompt));
    await emit(MessageEndEvent(prompt));
  }
}

/// Emits `turn_start` for every turn after the first (the first turn's start
/// was already emitted by [_emitRunStart]).
Future<void> _emitTurnStart(bool firstTurn, AgentEventSink emit) async {
  if (!firstTurn) await emit(const TurnStartEvent());
}

/// Ends the run when the assistant [message] failed or was aborted, emitting
/// the closing `turn_end`/`agent_end` and returning the run's messages.
/// Returns `null` for a healthy message so the turn continues.
Future<List<Message>?> _terminalRunMessages(
  AssistantMessage message,
  List<Message> newMessages,
  AgentEventSink emit,
) async {
  if (message.stopReason != StopReason.error &&
      message.stopReason != StopReason.aborted) {
    return null;
  }
  await emit(TurnEndEvent(message: message, toolResults: const []));
  await emit(AgentEndEvent(List.unmodifiable(newMessages)));
  return newMessages;
}

/// Applies a [PrepareNextTurnHook]'s [turnUpdate]: replaces the context
/// and/or model for the next turn; `null` keeps the current ones.
(Context, AgentLoopConfig) _applyTurnUpdate(
  Context currentContext,
  AgentLoopConfig currentConfig,
  AgentLoopTurnUpdate? turnUpdate,
) {
  if (turnUpdate == null) return (currentContext, currentConfig);
  if (turnUpdate.context != null) currentContext = turnUpdate.context!;
  if (turnUpdate.model != null) {
    currentConfig = currentConfig.copyWith(model: turnUpdate.model);
  }
  return (currentContext, currentConfig);
}

/// Emits and appends the queued steering/follow-up [pendingMessages] before
/// the next assistant response.
Future<void> _injectPendingMessages(
  List<Message> pendingMessages,
  AgentEventSink emit,
  Context currentContext,
  List<Message> newMessages,
) async {
  for (final message in pendingMessages) {
    await emit(MessageStartEvent(message));
    await emit(MessageEndEvent(message));
    currentContext.messages.add(message);
    newMessages.add(message);
  }
}

/// Executes the assistant [message]'s tool calls (or fails them all when the
/// message was truncated by the token limit), appending the results to the
/// context and [newMessages]. Returns the results and whether tool turns
/// continue.
Future<({List<ToolResultMessage> results, bool hasMore})> _runToolCallPhase(
  Context currentContext,
  AssistantMessage message,
  AgentLoopConfig currentConfig,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  AgentEventSink emit,
  List<Message> newMessages,
) {
  // The soft-yield token for this phase (see [currentYieldToken]): the first
  // steering arrival — in-process queue notification or the external probe's
  // slow poll — asks yield-aware long-running tools to finish early WITHOUT
  // stopping their work, so the user's message is delivered at the upcoming
  // step boundary instead of after the whole tool call.
  final yieldSource = CancelTokenSource();
  final notificationSub = currentConfig.steeringNotifications?.listen((_) {
    yieldSource.cancel('steering message arrived');
  });
  Timer? probeTimer;
  final probe = currentConfig.hasPendingSteering;
  if (probe != null) {
    probeTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        if (await probe()) {
          yieldSource.cancel('external steering message pending');
        }
      } on Object {
        // A probe failure must never break the tool phase.
      }
    });
  }
  return runZoned(
    () => _executeToolCallPhase(
      currentContext,
      message,
      currentConfig,
      toolExecutor,
      cancelToken,
      emit,
      newMessages,
    ),
    zoneValues: {yieldTokenZoneKey: yieldSource.token},
  ).whenComplete(() async {
    await notificationSub?.cancel();
    probeTimer?.cancel();
  });
}

Future<({List<ToolResultMessage> results, bool hasMore})> _executeToolCallPhase(
  Context currentContext,
  AssistantMessage message,
  AgentLoopConfig currentConfig,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  AgentEventSink emit,
  List<Message> newMessages,
) async {
  final toolCalls = message.content.whereType<ToolCall>().toList();

  final toolResults = <ToolResultMessage>[];
  var hasMoreToolCalls = false;
  if (toolCalls.isNotEmpty) {
    // A "length" stop means the output was cut off by the token limit, so
    // every tool call in the message may carry truncated arguments. Fail
    // them all instead of executing potentially borked calls.
    final batch = message.stopReason == StopReason.length
        ? await _failToolCallsFromTruncatedMessage(toolCalls, emit)
        : await _executeToolCalls(
            currentContext,
            message,
            toolCalls,
            currentConfig,
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
  return (results: toolResults, hasMore: hasMoreToolCalls);
}

Future<List<Message>> _steeringMessages(AgentLoopConfig config) async {
  return await config.getSteeringMessages?.call() ?? const <Message>[];
}

/// A completion is degenerate-empty when the model stopped normally
/// (`stop`) but produced no tool calls and no non-whitespace text — a
/// known provider failure mode under load (the answer is simply blank).
bool _isDegenerateEmpty(AssistantMessage message) {
  if (message.stopReason != StopReason.stop) return false;
  for (final block in message.content) {
    if (block is ToolCall) return false;
    if (block is TextContent && block.text.trim().isNotEmpty) return false;
  }
  return true;
}

/// Retries a degenerate-empty completion with the same context (bounded by
/// `config.maxEmptyRetries`; a blank answer never ends a run on the first
/// try). The retried messages stay in the transcript (truthful record) and
/// the eventual real answer follows them.
Future<AssistantMessage> _retryDegenerateEmpty(
  AssistantMessage message,
  Context context,
  AgentLoopConfig config,
  AgentEventSink emit,
  StreamFunction streamFunction,
  CancelToken? cancelToken,
) async {
  var retries = 0;
  var current = message;
  while (_isDegenerateEmpty(current) &&
      retries < config.maxEmptyRetries &&
      !(cancelToken?.isCancelled ?? false)) {
    retries++;
    current = await _streamAssistantResponse(
      context,
      config,
      emit,
      streamFunction,
      cancelToken,
    );
  }
  return current;
}

/// Streams one assistant response from the provider, emitting message
/// lifecycle events and keeping the partial message in [context.messages]
/// up to date (partial-first). Port of pi's `streamAssistantResponse`.
Future<AssistantMessage> _streamAssistantResponse(
  Context context,
  AgentLoopConfig config,
  AgentEventSink emit,
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

  final requestContext = await _buildRequestContext(
    context,
    config,
    cancelToken,
  );

  AssistantMessageEventStream response;
  try {
    response = streamFunction(
      config.model,
      requestContext,
      cancelToken: cancelToken,
    );
  } catch (error) {
    return _finishWithoutStream(
      context,
      emit,
      _terminalMessage(config.model, StopReason.error, '$error'),
    );
  }

  final streamed = await _consumeResponseStream(response, context, emit);
  if (streamed.finished != null) return streamed.finished!;

  // The provider stream closed without a terminal event (provider bug).
  const errorText = 'Provider stream ended without a terminal event';
  final base =
      streamed.partial ??
      _terminalMessage(config.model, StopReason.error, errorText);
  return _finishWithoutStream(
    context,
    emit,
    base.copyWith(stopReason: StopReason.error, errorMessage: errorText),
    replaceLast: streamed.addedPartial,
  );
}

/// Applies the request-payload rewrites before a provider call: the
/// `transformContext` hook and the orphaned-tool-call repair. Only the
/// request payload is rewritten, never the transcript.
Future<Context> _buildRequestContext(
  Context context,
  AgentLoopConfig config,
  CancelToken? cancelToken,
) async {
  // pi applies transformContext (then convertToLlm) before each provider
  // call; only the request payload is rewritten, never the transcript.
  var requestContext = context;
  final transformContext = config.transformContext;
  if (transformContext != null) {
    requestContext = Context(
      systemPrompt: context.systemPrompt,
      messages: await transformContext(List.of(context.messages), cancelToken),
      tools: context.tools,
    );
  }
  // Orphaned tool calls (aborted run, restored session, compaction cut)
  // make providers hard-400; repair the payload, never the transcript.
  final repaired = repairOrphanedToolCalls(requestContext.messages);
  if (!identical(repaired, requestContext.messages)) {
    requestContext = Context(
      systemPrompt: requestContext.systemPrompt,
      messages: repaired,
      tools: requestContext.tools,
    );
  }
  return requestContext;
}

/// Consumes the provider [response] stream, emitting message lifecycle
/// events and keeping the partial message in [context.messages] up to date
/// (partial-first). On a terminal event the finished message is returned in
/// `finished`; when the stream closes without one, `finished` is `null` and
/// `partial`/`addedPartial` describe the last partial snapshot.
Future<
  ({AssistantMessage? finished, AssistantMessage? partial, bool addedPartial})
>
_consumeResponseStream(
  AssistantMessageEventStream response,
  Context context,
  AgentEventSink emit,
) async {
  AssistantMessage? partialMessage;
  var addedPartial = false;

  await for (final event in response) {
    switch (event) {
      case StartEvent(:final partial):
        partialMessage = partial;
        context.messages.add(partial);
        addedPartial = true;
        await emit(MessageStartEvent(partial));
      case DoneEvent() || ErrorEvent():
        return (
          finished: await _finishStreamed(context, emit, addedPartial, event),
          partial: partialMessage,
          addedPartial: addedPartial,
        );
      default:
        if (partialMessage != null) {
          partialMessage = event.partial;
          context.messages[context.messages.length - 1] = event.partial;
          await emit(
            MessageUpdateEvent(
              message: event.partial,
              assistantMessageEvent: event,
            ),
          );
        }
    }
  }

  return (finished: null, partial: partialMessage, addedPartial: addedPartial);
}

Future<AssistantMessage> _finishStreamed(
  Context context,
  AgentEventSink emit,
  bool addedPartial,
  AssistantMessageEvent terminalEvent,
) async {
  final finalMessage = terminalEvent.partial;
  if (addedPartial) {
    context.messages[context.messages.length - 1] = finalMessage;
  } else {
    context.messages.add(finalMessage);
    await emit(MessageStartEvent(finalMessage));
  }
  await emit(MessageEndEvent(finalMessage));
  return finalMessage;
}

/// Appends (or replaces the partial with) [message] and emits its lifecycle
/// events, for paths where no provider events flowed.
Future<AssistantMessage> _finishWithoutStream(
  Context context,
  AgentEventSink emit,
  AssistantMessage message, {
  bool replaceLast = false,
}) async {
  if (replaceLast) {
    context.messages[context.messages.length - 1] = message;
  } else {
    context.messages.add(message);
    await emit(MessageStartEvent(message));
  }
  await emit(MessageEndEvent(message));
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

/// Repairs orphaned tool calls in a request payload: every [ToolCall] in an
/// assistant message must be answered by a [ToolResultMessage], or providers
/// hard-reject the whole context (OpenAI 400: "an assistant message with
/// 'tool_calls' must be followed by tool messages..."). Aborted runs,
/// restored sessions and compaction cuts can all leave calls without
/// results. Rather than dropping them (which erases what the run was doing),
/// a synthetic interrupted result is injected right after the assistant
/// message. The transcript itself is never modified — the repair applies to
/// the outbound request only. Returns [messages] untouched (same instance)
/// when nothing is missing.
List<Message> repairOrphanedToolCalls(List<Message> messages) {
  final answered = <String>{
    for (final message in messages)
      if (message is ToolResultMessage) message.toolCallId,
  };
  List<Message>? repaired;
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    repaired?.add(message);
    if (message is! AssistantMessage) continue;
    final missing = message.content.whereType<ToolCall>().where(
      (call) => !answered.contains(call.id),
    );
    for (final call in missing) {
      (repaired ??= [...messages.sublist(0, i + 1)]).add(
        ToolResultMessage(
          toolCallId: call.id,
          toolName: call.name,
          content: [
            TextContent(
              text:
                  'Tool call "${call.name}" did not produce a result: the '
                  'run was interrupted before the tool finished. Re-issue '
                  'the tool call if it is still needed.',
            ),
          ],
          isError: true,
          timestamp: DateTime.now(),
        ),
      );
    }
  }
  return repaired ?? messages;
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
  AgentEventSink emit,
) async {
  final messages = <ToolResultMessage>[];
  for (final toolCall in toolCalls) {
    await emit(
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
    await _emitToolExecutionEnd(finalized, emit);
    messages.add(await _emitToolResultMessage(finalized, emit));
  }
  return _ExecutedToolCallBatch(messages, terminate: false);
}

/// Executes the tool calls of one assistant message. Port of pi's
/// `executeToolCalls`, including the per-tool `executionMode` override: if
/// any called tool is an [AgentTool] with
/// [AgentTool.executionMode] == [ToolExecutionMode.sequential], the whole
/// batch runs sequentially (pi semantics).
Future<_ExecutedToolCallBatch> _executeToolCalls(
  Context context,
  AssistantMessage assistantMessage,
  List<ToolCall> toolCalls,
  AgentLoopConfig config,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  AgentEventSink emit,
) {
  final hasSequentialToolCall = toolCalls.any((toolCall) {
    final tool = _findTool(context, toolCall.name);
    return tool is AgentTool &&
        tool.executionMode == ToolExecutionMode.sequential;
  });
  return config.toolExecution == ToolExecutionMode.sequential ||
          hasSequentialToolCall
      ? _executeToolCallsSequential(
          context,
          assistantMessage,
          toolCalls,
          config,
          toolExecutor,
          cancelToken,
          emit,
        )
      : _executeToolCallsParallel(
          context,
          assistantMessage,
          toolCalls,
          config,
          toolExecutor,
          cancelToken,
          emit,
        );
}

Future<_ExecutedToolCallBatch> _executeToolCallsSequential(
  Context context,
  AssistantMessage assistantMessage,
  List<ToolCall> toolCalls,
  AgentLoopConfig config,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  AgentEventSink emit,
) async {
  final finalizedCalls = <_FinalizedToolCall>[];
  final messages = <ToolResultMessage>[];

  for (final toolCall in toolCalls) {
    await emit(
      ToolExecutionStartEvent(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        args: toolCall.arguments,
      ),
    );

    final finalized = switch (await _prepareToolCall(
      context,
      assistantMessage,
      toolCall,
      config,
      cancelToken,
    )) {
      _ImmediateToolCall(:final result, :final isError) => _FinalizedToolCall(
        toolCall,
        result,
        isError,
      ),
      _PreparedToolCall() => await _finalizeExecutedToolCall(
        context,
        assistantMessage,
        toolCall,
        await _executePreparedToolCall(
          toolCall,
          toolExecutor,
          cancelToken,
          emit,
        ),
        config,
        cancelToken,
      ),
    };

    await _emitToolExecutionEnd(finalized, emit);
    finalizedCalls.add(finalized);
    messages.add(await _emitToolResultMessage(finalized, emit));

    if (cancelToken != null && cancelToken.isCancelled) break;
  }

  return _ExecutedToolCallBatch(
    messages,
    terminate: _shouldTerminateToolBatch(finalizedCalls),
  );
}

Future<_ExecutedToolCallBatch> _executeToolCallsParallel(
  Context context,
  AssistantMessage assistantMessage,
  List<ToolCall> toolCalls,
  AgentLoopConfig config,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  AgentEventSink emit,
) async {
  // One entry per started tool call, in assistant source order.
  final pending = <Future<_FinalizedToolCall>>[];

  for (final toolCall in toolCalls) {
    await emit(
      ToolExecutionStartEvent(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        args: toolCall.arguments,
      ),
    );

    switch (await _prepareToolCall(
      context,
      assistantMessage,
      toolCall,
      config,
      cancelToken,
    )) {
      case _ImmediateToolCall(:final result, :final isError):
        final finalized = _FinalizedToolCall(toolCall, result, isError);
        await _emitToolExecutionEnd(finalized, emit);
        pending.add(Future.value(finalized));
      case _PreparedToolCall():
        // Executes concurrently; tool_execution_end is emitted in completion
        // order as each call settles.
        pending.add(() async {
          final executed = await _executePreparedToolCall(
            toolCall,
            toolExecutor,
            cancelToken,
            emit,
          );
          final finalized = await _finalizeExecutedToolCall(
            context,
            assistantMessage,
            toolCall,
            executed,
            config,
            cancelToken,
          );
          await _emitToolExecutionEnd(finalized, emit);
          return finalized;
        }());
    }

    if (cancelToken != null && cancelToken.isCancelled) break;
  }

  final finalizedCalls = await Future.wait(pending);
  final messages = <ToolResultMessage>[];
  for (final finalized in finalizedCalls) {
    messages.add(await _emitToolResultMessage(finalized, emit));
  }

  return _ExecutedToolCallBatch(
    messages,
    terminate: _shouldTerminateToolBatch(finalizedCalls),
  );
}

/// Port of pi's `prepareToolCall`, reduced to the pieces available without a
/// tool registry: existence check against [Context.tools], the
/// `beforeToolCall` hook, and the abort checks. Schema validation and
/// argument preparation arrive with the tool registry.
Future<_ToolCallPreparation> _prepareToolCall(
  Context context,
  AssistantMessage assistantMessage,
  ToolCall toolCall,
  AgentLoopConfig config,
  CancelToken? cancelToken,
) async {
  if (_findTool(context, toolCall.name) == null) {
    return _ImmediateToolCall(
      _errorToolResult('Tool ${toolCall.name} not found'),
      true,
    );
  }

  try {
    return await _runBeforeToolCallHook(
      context,
      assistantMessage,
      toolCall,
      config,
      cancelToken,
    );
  } catch (error) {
    return _ImmediateToolCall(_errorToolResult('$error'), true);
  }
}

/// Runs the `beforeToolCall` hook (when configured) with the abort checks.
/// A throw propagates to [_prepareToolCall], which converts it into an error
/// tool result (pi semantics).
Future<_ToolCallPreparation> _runBeforeToolCallHook(
  Context context,
  AssistantMessage assistantMessage,
  ToolCall toolCall,
  AgentLoopConfig config,
  CancelToken? cancelToken,
) async {
  final beforeToolCall = config.beforeToolCall;
  if (beforeToolCall != null) {
    final beforeResult = await beforeToolCall(
      BeforeToolCallContext(
        assistantMessage: assistantMessage,
        toolCall: toolCall,
        context: context,
      ),
      cancelToken,
    );
    final abortedAfterHook = _abortIfCancelled(cancelToken);
    if (abortedAfterHook != null) return abortedAfterHook;
    if (beforeResult != null && beforeResult.block) {
      return _ImmediateToolCall(
        _errorToolResult(beforeResult.reason ?? 'Tool execution was blocked'),
        true,
      );
    }
  }
  final aborted = _abortIfCancelled(cancelToken);
  if (aborted != null) return aborted;
  return _PreparedToolCall();
}

/// The abort check shared by the tool-call preparation paths: an immediate
/// error result when [cancelToken] is already cancelled, `null` otherwise.
_ToolCallPreparation? _abortIfCancelled(CancelToken? cancelToken) {
  if (cancelToken != null && cancelToken.isCancelled) {
    return _ImmediateToolCall(_errorToolResult('Operation aborted'), true);
  }
  return null;
}

Tool? _findTool(Context context, String name) {
  for (final tool in context.tools ?? const <Tool>[]) {
    if (tool.name == name) return tool;
  }
  return null;
}

/// Port of pi's `executePreparedToolCall`: run the executor, relay partial
/// updates, convert a throw into an error result.
Future<_ExecutedToolCallOutcome> _executePreparedToolCall(
  ToolCall toolCall,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  AgentEventSink emit,
) async {
  final updateEvents = <Future<void>>[];
  var acceptingUpdates = true;
  try {
    final result = await toolExecutor(toolCall, cancelToken, (partialResult) {
      if (!acceptingUpdates) return;
      updateEvents.add(
        Future<void>(
          () => emit(
            ToolExecutionUpdateEvent(
              toolCallId: toolCall.id,
              toolName: toolCall.name,
              args: toolCall.arguments,
              partialResult: partialResult,
            ),
          ),
        ),
      );
    });
    acceptingUpdates = false;
    await Future.wait(updateEvents);
    return _ExecutedToolCallOutcome(result, false);
  } catch (error) {
    acceptingUpdates = false;
    await Future.wait(updateEvents);
    return _ExecutedToolCallOutcome(_errorToolResult('$error'), true);
  }
}

/// Port of pi's `finalizeExecutedToolCall`: apply the `afterToolCall` hook's
/// field-by-field overrides; a throwing hook turns the result into an error.
Future<_FinalizedToolCall> _finalizeExecutedToolCall(
  Context context,
  AssistantMessage assistantMessage,
  ToolCall toolCall,
  _ExecutedToolCallOutcome executed,
  AgentLoopConfig config,
  CancelToken? cancelToken,
) async {
  var result = executed.result;
  var isError = executed.isError;

  final afterToolCall = config.afterToolCall;
  if (afterToolCall != null) {
    try {
      final afterResult = await afterToolCall(
        AfterToolCallContext(
          assistantMessage: assistantMessage,
          toolCall: toolCall,
          result: result,
          isError: isError,
          context: context,
        ),
        cancelToken,
      );
      if (afterResult != null) {
        result = ToolExecutionResult(
          content: afterResult.content ?? result.content,
          terminate: afterResult.terminate ?? result.terminate,
        );
        isError = afterResult.isError ?? isError;
      }
    } catch (error) {
      result = _errorToolResult('$error');
      isError = true;
    }
  }

  return _FinalizedToolCall(toolCall, result, isError);
}

bool _shouldTerminateToolBatch(List<_FinalizedToolCall> finalizedCalls) {
  return finalizedCalls.isNotEmpty &&
      finalizedCalls.every((finalized) => finalized.result.terminate);
}

ToolExecutionResult _errorToolResult(String message) {
  return ToolExecutionResult(content: [TextContent(text: message)]);
}

Future<void> _emitToolExecutionEnd(
  _FinalizedToolCall finalized,
  AgentEventSink emit,
) async {
  await emit(
    ToolExecutionEndEvent(
      toolCallId: finalized.toolCall.id,
      toolName: finalized.toolCall.name,
      result: finalized.result,
      isError: finalized.isError,
    ),
  );
}

Future<ToolResultMessage> _emitToolResultMessage(
  _FinalizedToolCall finalized,
  AgentEventSink emit,
) async {
  final message = ToolResultMessage(
    toolCallId: finalized.toolCall.id,
    toolName: finalized.toolCall.name,
    content: finalized.result.content,
    isError: finalized.isError,
    timestamp: DateTime.now(),
  );
  await emit(MessageStartEvent(message));
  await emit(MessageEndEvent(message));
  return message;
}

final class _ExecutedToolCallBatch {
  const _ExecutedToolCallBatch(this.messages, {required this.terminate});

  final List<ToolResultMessage> messages;
  final bool terminate;
}

final class _ExecutedToolCallOutcome {
  const _ExecutedToolCallOutcome(this.result, this.isError);

  final ToolExecutionResult result;
  final bool isError;
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
