/// The stateful [Agent]: owns the transcript, queues steering/follow-up
/// messages, and exposes lifecycle hooks on top of the low-level loop.
///
/// Ported from pi-mono `packages/agent/src/agent.ts`. Deliberate divergences
/// from the TypeScript original:
///
/// - `AbortSignal` is [CancelToken]; `agent.abort()` cancels the run's token.
/// - `continue()` is [Agent.continueRun] (`continue` is a Dart keyword).
/// - pi's `prepareNextTurn` / `prepareNextTurnWithContext` pair collapses
///   into a single [PrepareNextTurnHook], which always receives the turn
///   context (the no-context variant is a closure that ignores it).
/// - pi's `convertToLlm` is absent: our messages are already LLM-shaped.
/// - pi defaults `streamFn` to `streamSimple` and tools self-execute; here
///   [Agent.streamFunction] and [Agent.toolExecutor] are required, matching
///   the low-level loop's injection points. The tool registry (next card)
///   will provide a real executor.
/// - pi's `sessionId`, `thinkingLevel`/`thinkingBudgets`, `transport`,
///   `onPayload`/`onResponse`, `getApiKey`, and `maxRetryDelayMs` arrive with
///   the provider-options work they belong to.
library;

import 'dart:async';

import '../cancel_token.dart';
import '../context.dart';
import '../model.dart';
import '../types.dart';
import 'agent_loop.dart';

/// Controls how many queued messages are injected when the loop reaches a
/// queue drain point. Ported from pi's `QueueMode`.
enum QueueMode {
  /// Drain and inject every queued message at that point.
  all,

  /// Drain and inject only the oldest queued message, leaving the rest for
  /// later drain points.
  oneAtATime,
}

/// Listener for agent lifecycle events (pi's `Agent.subscribe` callback).
///
/// Listeners are awaited in subscription order and are included in the
/// current run's settlement: the agent does not become idle until all
/// awaited listeners for `agent_end` have finished. [cancelToken] is the
/// active run's token.
typedef AgentListener =
    FutureOr<void> Function(AgentEvent event, CancelToken cancelToken);

/// Public agent state. Ported from pi's `AgentState`.
///
/// Assigning [tools] or [messages] copies the provided top-level list.
/// The runtime fields ([isStreaming], [streamingMessage],
/// [pendingToolCalls], [errorMessage]) are read-only for consumers; the
/// owning [Agent] mutates them as it processes loop events.
final class AgentState {
  AgentState({
    this.systemPrompt = '',
    required this.model,
    List<Tool> tools = const [],
    List<Message> messages = const [],
  }) : _tools = List.of(tools),
       _messages = List.of(messages);

  /// System prompt sent with each model request.
  String systemPrompt;

  /// Active model used for future turns.
  Model model;

  List<Tool> _tools;
  List<Message> _messages;

  /// Tools available to the model. Assigning copies the list.
  List<Tool> get tools => List.unmodifiable(_tools);
  set tools(List<Tool> value) => _tools = List.of(value);

  /// Conversation transcript. Assigning copies the list.
  List<Message> get messages => List.unmodifiable(_messages);
  set messages(List<Message> value) => _messages = List.of(value);

  /// True while the agent is processing a prompt or continuation.
  ///
  /// Remains true until awaited `agent_end` listeners settle.
  bool get isStreaming => _isStreaming;
  bool _isStreaming = false;

  /// Partial assistant message for the current streamed response, if any.
  Message? get streamingMessage => _streamingMessage;
  Message? _streamingMessage;

  /// Tool call ids currently executing.
  Set<String> get pendingToolCalls => Set.unmodifiable(_pendingToolCalls);
  final _pendingToolCalls = <String>{};

  /// Error message from the most recent failed or aborted assistant turn.
  String? get errorMessage => _errorMessage;
  String? _errorMessage;
}

/// Placeholder model mirroring pi's `DEFAULT_MODEL`, used when the caller
/// does not configure one.
const _defaultModel = Model(
  id: 'unknown',
  name: 'unknown',
  api: 'unknown',
  provider: 'unknown',
  baseUrl: '',
  contextWindow: 0,
  maxTokens: 0,
);

/// A FIFO of pending [Message]s with pi's drain semantics.
final class _PendingMessageQueue {
  _PendingMessageQueue(this.mode);

  /// How many messages [drain] returns.
  QueueMode mode;

  final _messages = <Message>[];

  void enqueue(Message message) => _messages.add(message);

  bool hasItems() => _messages.isNotEmpty;

  List<Message> drain() {
    if (mode == QueueMode.all) {
      final drained = List.of(_messages);
      _messages.clear();
      return drained;
    }
    if (_messages.isEmpty) return const [];
    return [_messages.removeAt(0)];
  }

  void clear() => _messages.clear();
}

final class _ActiveRun {
  _ActiveRun(this.source);

  final CancelTokenSource source;
  final completer = Completer<void>();
}

/// Stateful wrapper around the low-level agent loop.
///
/// `Agent` owns the current transcript, emits lifecycle events, executes
/// tools, and exposes queueing APIs for steering and follow-up messages.
/// Port of pi's `Agent`.
class Agent {
  /// Creates an agent. See the library doc for the pi mapping.
  Agent({
    Model? model,
    String? systemPrompt,
    List<Tool>? tools,
    List<Message>? messages,
    required this.streamFunction,
    required this.toolExecutor,
    this.beforeToolCall,
    this.afterToolCall,
    this.transformContext,
    this.prepareNextTurn,
    QueueMode steeringMode = QueueMode.oneAtATime,
    QueueMode followUpMode = QueueMode.oneAtATime,
    this.toolExecution = ToolExecutionMode.parallel,
  }) : _state = AgentState(
         model: model ?? _defaultModel,
         systemPrompt: systemPrompt ?? '',
         tools: tools ?? const [],
         messages: messages ?? const [],
       ),
       _steeringQueue = _PendingMessageQueue(steeringMode),
       _followUpQueue = _PendingMessageQueue(followUpMode);

  final AgentState _state;
  final _listeners = <AgentListener>{};
  final _PendingMessageQueue _steeringQueue;
  final _PendingMessageQueue _followUpQueue;
  _ActiveRun? _activeRun;

  /// Provider adapter used for every model call. See [StreamFunction].
  StreamFunction streamFunction;

  /// Executes tool calls requested by the model. See [ToolExecutor].
  ToolExecutor toolExecutor;

  /// Called before a tool is executed; can block it. See [BeforeToolCallHook].
  BeforeToolCallHook? beforeToolCall;

  /// Called after a tool finishes; can override the result.
  /// See [AfterToolCallHook].
  AfterToolCallHook? afterToolCall;

  /// Rewrites the message list sent to the provider before each call.
  /// See [TransformContextHook].
  TransformContextHook? transformContext;

  /// Adjusts context/model between turns. See [PrepareNextTurnHook].
  PrepareNextTurnHook? prepareNextTurn;

  /// Tool execution strategy for assistant messages that contain multiple
  /// tool calls.
  ToolExecutionMode toolExecution;

  /// Current agent state.
  AgentState get state => _state;

  /// Controls how queued steering messages are drained.
  QueueMode get steeringMode => _steeringQueue.mode;
  set steeringMode(QueueMode mode) => _steeringQueue.mode = mode;

  /// Controls how queued follow-up messages are drained.
  QueueMode get followUpMode => _followUpQueue.mode;
  set followUpMode(QueueMode mode) => _followUpQueue.mode = mode;

  /// Subscribe to agent lifecycle events. Returns an unsubscribe function.
  ///
  /// Listener futures are awaited in subscription order and included in the
  /// current run's settlement. `agent_end` is the final emitted event for a
  /// run, but the agent does not become idle until all awaited listeners for
  /// that event have settled (pi semantics).
  void Function() subscribe(AgentListener listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Queue a message to be injected after the current assistant turn
  /// finishes.
  void steer(Message message) => _steeringQueue.enqueue(message);

  /// Queue a message to run only after the agent would otherwise stop.
  void followUp(Message message) => _followUpQueue.enqueue(message);

  /// Remove all queued steering messages.
  void clearSteeringQueue() => _steeringQueue.clear();

  /// Remove all queued follow-up messages.
  void clearFollowUpQueue() => _followUpQueue.clear();

  /// Remove all queued steering and follow-up messages.
  void clearAllQueues() {
    clearSteeringQueue();
    clearFollowUpQueue();
  }

  /// Returns true when either queue still contains pending messages.
  bool hasQueuedMessages() {
    return _steeringQueue.hasItems() || _followUpQueue.hasItems();
  }

  /// Active cancel token for the current run, if any.
  CancelToken? get cancelToken => _activeRun?.source.token;

  /// Abort the current run, if one is active.
  void abort() => _activeRun?.source.cancel();

  /// Resolves when the current run and all awaited event listeners have
  /// finished (after `agent_end` listeners settle).
  Future<void> waitForIdle() {
    return _activeRun?.completer.future ?? Future<void>.value();
  }

  /// Clear transcript state, runtime state, and queued messages.
  void reset() {
    _state._messages = [];
    _state._isStreaming = false;
    _state._streamingMessage = null;
    _state._pendingToolCalls.clear();
    _state._errorMessage = null;
    clearAllQueues();
  }

  /// Start a new prompt from plain text.
  Future<void> prompt(String text) {
    return promptMessages([UserMessage.text(text)]);
  }

  /// Start a new prompt from a single message.
  Future<void> promptMessage(Message message) {
    return promptMessages([message]);
  }

  /// Start a new prompt from a batch of messages.
  Future<void> promptMessages(List<Message> messages) {
    if (_activeRun != null) {
      throw StateError(
        'Agent is already processing a prompt. Use steer() or followUp() to '
        'queue messages, or wait for completion.',
      );
    }
    return _runPromptMessages(messages);
  }

  /// Continue from the current transcript. The last message must be a user
  /// or tool-result message, unless queued steering/follow-up messages can
  /// start a fresh prompt run (pi's `continue()`).
  Future<void> continueRun() async {
    if (_activeRun != null) {
      throw StateError(
        'Agent is already processing. Wait for completion before continuing.',
      );
    }

    final messages = _state._messages;
    if (messages.isEmpty) {
      throw StateError('No messages to continue from');
    }

    if (messages.last.role == 'assistant') {
      final queuedSteering = _steeringQueue.drain();
      if (queuedSteering.isNotEmpty) {
        await _runPromptMessages(queuedSteering, skipInitialSteeringPoll: true);
        return;
      }

      final queuedFollowUps = _followUpQueue.drain();
      if (queuedFollowUps.isNotEmpty) {
        await _runPromptMessages(queuedFollowUps);
        return;
      }

      throw StateError('Cannot continue from message role: assistant');
    }

    await _runContinuation();
  }

  Future<void> _runPromptMessages(
    List<Message> messages, {
    bool skipInitialSteeringPoll = false,
  }) {
    return _runWithLifecycle((token) {
      return runAgentLoop(
        prompts: messages,
        context: _createContextSnapshot(),
        config: _createLoopConfig(
          skipInitialSteeringPoll: skipInitialSteeringPoll,
        ),
        emit: _processEvent,
        streamFunction: streamFunction,
        toolExecutor: toolExecutor,
        cancelToken: token,
      );
    });
  }

  Future<void> _runContinuation() {
    return _runWithLifecycle((token) {
      return runAgentLoopContinue(
        context: _createContextSnapshot(),
        config: _createLoopConfig(),
        emit: _processEvent,
        streamFunction: streamFunction,
        toolExecutor: toolExecutor,
        cancelToken: token,
      );
    });
  }

  Context _createContextSnapshot() {
    return Context(
      systemPrompt: _state.systemPrompt.isEmpty ? null : _state.systemPrompt,
      messages: List.of(_state._messages),
      tools: List.of(_state._tools),
    );
  }

  AgentLoopConfig _createLoopConfig({bool skipInitialSteeringPoll = false}) {
    var skip = skipInitialSteeringPoll;
    return AgentLoopConfig(
      model: _state.model,
      toolExecution: toolExecution,
      beforeToolCall: beforeToolCall,
      afterToolCall: afterToolCall,
      transformContext: transformContext,
      prepareNextTurn: prepareNextTurn == null
          ? null
          : (context) => prepareNextTurn?.call(context),
      getSteeringMessages: () {
        if (skip) {
          skip = false;
          return const <Message>[];
        }
        return _steeringQueue.drain();
      },
      getFollowUpMessages: _followUpQueue.drain,
    );
  }

  Future<void> _runWithLifecycle(
    Future<void> Function(CancelToken token) executor,
  ) async {
    if (_activeRun != null) {
      throw StateError('Agent is already processing.');
    }

    final run = _ActiveRun(CancelTokenSource());
    _activeRun = run;
    _state._isStreaming = true;
    _state._streamingMessage = null;
    _state._errorMessage = null;

    try {
      await executor(run.source.token);
    } catch (error) {
      await _handleRunFailure(error, run.source.token.isCancelled);
    } finally {
      _finishRun();
    }
  }

  /// Converts an unexpected loop failure (e.g. a throwing
  /// [TransformContextHook]) into a normal event sequence ending the run,
  /// exactly like pi's `handleRunFailure`.
  Future<void> _handleRunFailure(Object error, bool aborted) async {
    final failureMessage = AssistantMessage(
      content: const [TextContent(text: '')],
      api: _state.model.api,
      provider: _state.model.provider,
      model: _state.model.id,
      usage: Usage.zero,
      stopReason: aborted ? StopReason.aborted : StopReason.error,
      errorMessage: '$error',
      timestamp: DateTime.now(),
    );
    await _processEvent(MessageStartEvent(failureMessage));
    await _processEvent(MessageEndEvent(failureMessage));
    await _processEvent(
      TurnEndEvent(message: failureMessage, toolResults: const []),
    );
    await _processEvent(AgentEndEvent([failureMessage]));
  }

  void _finishRun() {
    _state._isStreaming = false;
    _state._streamingMessage = null;
    _state._pendingToolCalls.clear();
    _activeRun?.completer.complete();
    _activeRun = null;
  }

  /// Reduce internal state for a loop event, then await listeners.
  ///
  /// `agent_end` only means no further loop events will be emitted. The run
  /// is considered idle later, after all awaited listeners for `agent_end`
  /// finish and [_finishRun] clears runtime-owned state (pi semantics).
  Future<void> _processEvent(AgentEvent event) async {
    switch (event) {
      case MessageStartEvent(:final message):
        _state._streamingMessage = message;
      case MessageUpdateEvent(:final message):
        _state._streamingMessage = message;
      case MessageEndEvent(:final message):
        _state._streamingMessage = null;
        _state._messages.add(message);
      case ToolExecutionStartEvent(:final toolCallId):
        _state._pendingToolCalls.add(toolCallId);
      case ToolExecutionEndEvent(:final toolCallId):
        _state._pendingToolCalls.remove(toolCallId);
      case TurnEndEvent(:final message):
        if (message case AssistantMessage(:final errorMessage?)) {
          _state._errorMessage = errorMessage;
        }
      case AgentEndEvent():
        _state._streamingMessage = null;
      default:
        break;
    }

    final token = _activeRun?.source.token;
    if (token == null) {
      throw StateError('Agent listener invoked outside active run');
    }
    for (final listener in List.of(_listeners)) {
      await listener(event, token);
    }
  }
}
