/// The public entry surface of the agent loop: the replaying event stream
/// and the two `agentLoop*` entry points. Split out of `agent_loop.dart` to
/// keep it under the repo's 2800-line size gate (same library — a `part
/// of` — so the functions see the private `_drive`/`_runAgentLoop*` cores).
part of 'agent_loop.dart';

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
  CancelTokenSource? cancelTokenSource,
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
      cancelTokenSource: cancelTokenSource,
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
