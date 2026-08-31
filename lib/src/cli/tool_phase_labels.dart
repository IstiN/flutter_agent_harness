/// Busy-row phase labels for tool execution.
///
/// A long tool call (a full test gate, a big build) used to sit under a
/// stale `Compacting context…` label left by the pre-flight compaction and
/// read as a compaction hang — the "working but doing nothing" wedge.
/// Wiring these hooks makes the busy row name the tool that is actually
/// executing and fall back to the plain `Working…` row between calls.
///
/// Split out of `agent_cli.dart` (2800-line gate) and kept host-agnostic:
/// the CLI passes its TUI controller's `setBusyPhase`, tests pass a list
/// sink, a null [onPhase] disables labeling entirely.
library;

import '../agent/agent.dart';

/// Composes busy-phase labels onto [agent]'s tool hooks.
///
/// `beforeToolCall` relabels the busy row to `Running <tool>…` — but only
/// when the call is allowed through (a denial result with `block: true`
/// never relabels, so a rejected call stays invisible). `afterToolCall`
/// clears the phase again. Previously registered hooks are preserved:
/// approval (attached earlier) runs first, the phase label is set after
/// the prior hook allows the call, and a prior `afterToolCall` runs after
/// the phase clears.
void attachToolPhaseLabels(Agent agent, void Function(String phase)? onPhase) {
  if (onPhase == null) return;
  final priorBefore = agent.beforeToolCall;
  agent.beforeToolCall = (context, cancelToken) async {
    final result = await priorBefore?.call(context, cancelToken);
    if (result?.block != true) {
      onPhase('Running ${context.toolCall.name}…');
    }
    return result;
  };
  final priorAfter = agent.afterToolCall;
  agent.afterToolCall = (context, cancelToken) async {
    onPhase('');
    return priorAfter?.call(context, cancelToken);
  };
}
