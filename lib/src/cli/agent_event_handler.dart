import '../agent/agent_loop.dart';
import '../trajectory/trajectory_record.dart' show TrajectoryRequestDetail;
import '../types.dart';

/// Routes an [AgentEvent] to the appropriate UI callback.
///
/// Pulled out of [AgentCli] so the switch complexity can be unit-tested
/// without spinning up a full CLI instance.
Future<void> handleAgentEvent(
  AgentEvent event, {
  required void Function(Message message, {required bool start})
  onMessageLifecycle,
  required void Function(AssistantMessageEvent) onMessageUpdate,
  required void Function(String toolName, Map<String, dynamic> args)
  onToolExecutionStart,
  required void Function(
    String toolName,
    ToolExecutionResult result, {
    required bool isError,
  })
  onToolExecutionEnd,
  required void Function(AssistantMessage message) onTurnEnd,
  Future<void> Function(TrajectoryRequestDetail detail)? onModelRequest,
}) async {
  switch (event) {
    case MessageStartEvent(:final message) || MessageEndEvent(:final message):
      onMessageLifecycle(message, start: event is MessageStartEvent);
    case MessageUpdateEvent(:final assistantMessageEvent):
      onMessageUpdate(assistantMessageEvent);
    case ToolExecutionStartEvent(:final toolName, :final args):
      onToolExecutionStart(toolName, args);
    case ToolExecutionEndEvent(:final toolName, :final result, :final isError):
      onToolExecutionEnd(toolName, result, isError: isError);
    case TurnEndEvent(:final message):
      onTurnEnd(message);
    case ModelRequestEvent(:final detail):
      await onModelRequest?.call(detail);
    default:
  }
}
