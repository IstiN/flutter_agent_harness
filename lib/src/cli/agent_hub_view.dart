/// Plain-text rendering for the agents hub (issue #277): one line per tree
/// row with the live metrics, the footer aggregate line, and the compact
/// duration label both use.
///
/// Pure Dart, no ANSI — the TUI frame layer (agent_hub_tui.dart) adds
/// highlighting; the line-mode surfaces reuse these strings verbatim.
library;

import '../trajectory/formatters.dart' show formatTokens;
import 'agent_hub_projection.dart';

/// Compact elapsed label: `42s`, `1m12s`, `1h02m` (never fractional).
String hubDuration(Duration d) {
  final seconds = d.inSeconds < 0 ? 0 : d.inSeconds;
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m${(seconds % 60).toStringAsFixed(0).padLeft(2, '0')}s';
  return '${minutes ~/ 60}h${(minutes % 60).toStringAsFixed(0).padLeft(2, '0')}m';
}


/// One tree row: indent · status icon · name id · status · metrics.
/// Known metrics only — an unknown metric renders `—` and stays out of the
/// way; a row with no metrics at all skips the metrics segment entirely.
String hubAgentRow(HubRow row) {
  final agent = row.agent;
  final indent = '  ' * (row.depth + 1);
  final connector = row.depth > 0 ? '└ ' : '';
  final metrics = <String>[
    if (agent.tokens != null) '${formatTokens(agent.tokens)} tok',
    if (agent.requests != null) '${agent.requests} req',
    if (agent.toolCalls != null) '${agent.toolCalls} tools',
    if (agent.costUsd != null) '\$${agent.costUsd!.toStringAsFixed(4)}',
    if (agent.contextPercent != null)
      'ctx ${agent.contextPercent!.toStringAsFixed(0)}%',
  ];
  final head =
      '$indent$connector${hubStatusIcon(agent.status)} '
      '${agent.name} (${agent.agentType}) · ${agent.status.name}';
  if (metrics.isEmpty) return head;
  return '$head · ${metrics.join(' · ')}';
}

/// The footer line: Σ tokens · Σ cost · N running · fleet size. The cost
/// segment appears only when some agent reported one (E1: aggregates are
/// over the whole fleet regardless of what is visible).
String hubFooterLine(HubFooter footer) {
  final segments = <String>[
    'Σ ${formatTokens(footer.tokens)} tok',
    if (footer.cost > 0) 'Σ \$${footer.cost.toStringAsFixed(4)}',
    '${footer.running} running',
    '${footer.agents} agents',
  ];
  return segments.join(' · ');
}

