/// Wires an [ApprovalManager] into an [Agent]'s `beforeToolCall` phase.
///
/// The approval check runs BEFORE any user-registered [BeforeToolCallHook]:
/// a denied call never reaches user hooks, and a hook can never accidentally
/// bypass approval. Composition preserves the existing hook — once approval
/// allows the call, the previously registered hook runs unchanged (the same
/// pattern [attachSecretRedactor] uses for its hooks).
library;

import '../agent/agent.dart';
import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../context.dart';
import 'approval.dart';

/// Composes the approval gate for [manager] onto [agent], preserving any
/// [BeforeToolCallHook] already registered (approval runs first).
///
/// A denied call becomes an error tool result carrying the denial reason, so
/// the model sees the refusal and can adapt (pi's blocked-tool semantics).
void attachApproval(Agent agent, ApprovalManager manager) {
  final existing = agent.beforeToolCall;
  agent.beforeToolCall = (hookContext, cancelToken) async {
    final outcome = await manager.authorize(
      toolName: hookContext.toolCall.name,
      tier: _tierFor(hookContext.context, hookContext.toolCall.name),
      arguments: hookContext.toolCall.arguments,
    );
    if (!outcome.allowed) {
      return BeforeToolCallResult(
        block: true,
        reason: outcome.reason ?? 'Tool call denied by approval policy',
      );
    }
    return existing?.call(hookContext, cancelToken);
  };
}

/// The tier of the tool named [toolName] in [context]: its declared
/// [AgentTool.tier], or [ApprovalTier.exec] — the safe default — for plain
/// [Tool] entries and anything else.
ApprovalTier _tierFor(Context context, String toolName) {
  for (final tool in context.tools ?? const <Tool>[]) {
    if (tool.name == toolName) {
      return tool is AgentTool ? tool.tier : ApprovalTier.exec;
    }
  }
  return ApprovalTier.exec;
}
