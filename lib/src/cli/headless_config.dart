/// The headless run-lifecycle config and drain policy (gh-1459).
///
/// `fa -p` (headless print mode) must not exit while background jobs it
/// was told to await are still running: after the final answer the run
/// drains live subagent AND background shell jobs — wait for the settles,
/// let the settle notices steer fresh reaction turns, and loop until
/// nothing is active — under ONE wall-clock ceiling
/// (`headless: shellJobDrainMs`, default 30 minutes). Past the ceiling the
/// pre-gh-1459 detach-with-summary applies: an infinite watch-loop job
/// must never hang headless forever. While the drain waits, an interim
/// liveness notice (gh-1459 ask #4 — `headless: shellJobQuietMs`, default
/// 5 minutes; elapsed + log tail + the bash_job escape hatch) keeps the
/// model able to wait, inspect, or kill instead of blocking blindly to
/// the ceiling.
library;

import '../exceptions.dart';

/// Default wall-clock ceiling for the headless background-job drain
/// (`headless: shellJobDrainMs`, gh-1459): 30 minutes.
const defaultShellJobDrainMs = 30 * 60 * 1000;

/// Default liveness-steer cadence for the headless drain
/// (`headless: shellJobQuietMs`, gh-1459 ask #4): every 5 minutes of a
/// still-running awaited shell job, ONE compact system-notice is steered
/// into a fresh turn (elapsed + log tail + the bash_job escape hatch) so
/// the model can keep waiting, inspect, or kill — never a passive block
/// to the ceiling. `0` disables the steers.
const defaultShellJobQuietMs = 5 * 60 * 1000;

/// The `headless:` yaml section (gh-1459): knobs of the headless
/// (`fa -p`) run lifecycle. Parsed strictly like `waiting:`/`jobs:` — a
/// bad schema throws at boot; negative values are rejected.
final class HeadlessConfig {
  const HeadlessConfig({
    this.shellJobDrainMs = defaultShellJobDrainMs,
    this.shellJobQuietMs = defaultShellJobQuietMs,
  });

  /// How long a headless run may keep draining live background jobs
  /// (subagents + shell jobs) after the final answer before it detaches
  /// with the waiting summary (gh-1459). `0` disables the drain entirely —
  /// the pre-gh-1459 detach-immediately behavior.
  final int shellJobDrainMs;

  /// The interim liveness cadence of the drain (gh-1459 ask #4): every
  /// `shellJobQuietMs` of a still-running awaited shell job, one compact
  /// system-notice is steered into a fresh turn. `0` disables the steers
  /// (the drain still waits, silently, to the ceiling).
  final int shellJobQuietMs;

  factory HeadlessConfig.fromYaml(Object? node) {
    if (node == null) return const HeadlessConfig();
    if (node is! Map) {
      throw ConfigException('headless must be a map, got: $node');
    }
    for (final key in node.keys) {
      if (!{'shellJobDrainMs', 'shellJobQuietMs'}.contains('$key')) {
        throw ConfigException('unknown "headless" key: $key');
      }
    }
    final drainMs = _nonNegativeInt(node, 'shellJobDrainMs');
    final quietMs = _nonNegativeInt(node, 'shellJobQuietMs');
    return HeadlessConfig(
      shellJobDrainMs: drainMs ?? defaultShellJobDrainMs,
      shellJobQuietMs: quietMs ?? defaultShellJobQuietMs,
    );
  }

  static int? _nonNegativeInt(Map node, String key) {
    final value = node[key];
    if (value == null) return null;
    if (value is! int) {
      throw ConfigException('"headless.$key" must be an integer');
    }
    if (value < 0) {
      throw ConfigException('"headless.$key" must be >= 0 (0 disables it)');
    }
    return value;
  }

  String toYaml() =>
      'headless:\n'
      '  shellJobDrainMs: $shellJobDrainMs\n'
      '  shellJobQuietMs: $shellJobQuietMs\n';
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

/// What the drain's liveness leg does for one still-running awaited shell
/// job right now (gh-1459 ask #4). Pure — unit-tested directly.
enum HeadlessLivenessAction {
  /// A new quiet threshold was crossed and the model has not probed the
  /// job since the last consumption point: steer ONE notice now.
  steer,

  /// A threshold crossed but the model probed the job (its own
  /// `bash_job status/output`) since the last consumption point: skip
  /// this crossing — it is consumed, so the next steer waits for the
  /// NEXT threshold (never a per-timer retry of the same one).
  skip,

  /// No new threshold crossed yet (or liveness disabled): keep waiting.
  wait,
}

/// The liveness decision for one still-running job (gh-1459 ask #4):
/// [elapsedMs] measured from the job's start, bucketed by [quietMs];
/// [lastConsumedBucket] is the last bucket already steered or skipped;
/// [probedSinceLastConsumption] is whether the model probed the job
/// after that consumption. Pure — unit-tested directly.
HeadlessLivenessAction headlessJobLivenessAction({
  required int elapsedMs,
  required int quietMs,
  required int lastConsumedBucket,
  required bool probedSinceLastConsumption,
}) {
  if (quietMs <= 0) return HeadlessLivenessAction.wait;
  final bucket = elapsedMs ~/ quietMs;
  if (bucket == 0 || bucket <= lastConsumedBucket) {
    return HeadlessLivenessAction.wait;
  }
  if (probedSinceLastConsumption) return HeadlessLivenessAction.skip;
  return HeadlessLivenessAction.steer;
}

/// The elapsed clause of the liveness notice (gh-1459 ask #4): "12m"
/// from the first minute up, "45s" below it. Pure — unit-tested directly.
String headlessLivenessElapsedText(Duration elapsed) =>
    elapsed.inMinutes >= 1 ? '${elapsed.inMinutes}m' : '${elapsed.inSeconds}s';
