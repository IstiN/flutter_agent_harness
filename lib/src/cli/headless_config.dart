/// The headless run-lifecycle config and drain policy (gh-1459).
///
/// `fa -p` (headless print mode) must not exit while background jobs it
/// was told to await are still running: after the final answer the run
/// drains live subagent AND background shell jobs — wait for the settles,
/// let the settle notices steer fresh reaction turns, and loop until
/// nothing is active — under ONE wall-clock ceiling
/// (`headless: shellJobDrainMs`, default 30 minutes). Past the ceiling the
/// pre-gh-1459 detach-with-summary applies: an infinite watch-loop job
/// must never hang headless forever.
library;

import '../exceptions.dart';

/// Default wall-clock ceiling for the headless background-job drain
/// (`headless: shellJobDrainMs`, gh-1459): 30 minutes.
const defaultShellJobDrainMs = 30 * 60 * 1000;

/// The `headless:` yaml section (gh-1459): knobs of the headless
/// (`fa -p`) run lifecycle. Parsed strictly like `waiting:`/`jobs:` — a
/// bad schema throws at boot; negative values are rejected.
final class HeadlessConfig {
  const HeadlessConfig({this.shellJobDrainMs = defaultShellJobDrainMs});

  /// How long a headless run may keep draining live background jobs
  /// (subagents + shell jobs) after the final answer before it detaches
  /// with the waiting summary (gh-1459). `0` disables the drain entirely —
  /// the pre-gh-1459 detach-immediately behavior.
  final int shellJobDrainMs;

  factory HeadlessConfig.fromYaml(Object? node) {
    if (node == null) return const HeadlessConfig();
    if (node is! Map) {
      throw ConfigException('headless must be a map, got: $node');
    }
    for (final key in node.keys) {
      if (!{'shellJobDrainMs'}.contains('$key')) {
        throw ConfigException('unknown "headless" key: $key');
      }
    }
    final value = node['shellJobDrainMs'];
    if (value != null) {
      if (value is! int) {
        throw ConfigException('"headless.shellJobDrainMs" must be an integer');
      }
      if (value < 0) {
        throw ConfigException(
          '"headless.shellJobDrainMs" must be >= 0 (0 disables the drain)',
        );
      }
    }
    return HeadlessConfig(
      shellJobDrainMs: value as int? ?? defaultShellJobDrainMs,
    );
  }

  String toYaml() => 'headless:\n'
      '  shellJobDrainMs: $shellJobDrainMs\n';
}

/// What one round of the headless background-job drain does right now
/// (gh-1459). Pure — unit-tested directly.
enum HeadlessDrainAction {
  /// Active jobs exist and the ceiling still has budget: keep draining.
  drain,

  /// Nothing active: the run may exit.
  exit,

  /// The wall-clock ceiling is spent (or disabled): detach with the
  /// waiting summary — the documented degradation, never a hang.
  detach,
}

/// The drain decision for one round (gh-1459): active jobs keep draining
/// while the ceiling has budget; nothing active exits; a spent ceiling
/// detaches. Pure — unit-tested directly.
HeadlessDrainAction headlessJobDrainAction({
  required bool hasActiveJobs,
  required DateTime now,
  required DateTime deadline,
}) {
  if (!hasActiveJobs) return HeadlessDrainAction.exit;
  if (!now.isBefore(deadline)) return HeadlessDrainAction.detach;
  return HeadlessDrainAction.drain;
}
