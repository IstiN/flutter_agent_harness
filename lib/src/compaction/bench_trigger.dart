/// The bench-profile auto-compaction trigger (gh-1604 items 2+3).
///
/// Long bench trials (30-minute MIPS-class tasks) never trip the
/// window-minus-reserve default: the context grows monotonically, every
/// later request re-reads the accreted stream, and a single trial burned
/// 11.2M input tokens. The bench env knob
/// (`FAH_COMPACT_TRIGGER_TOKENS`) lowers the auto-compaction trigger to
/// an ABSOLUTE context size — summarization fires as soon as the
/// estimated context crosses it, keeping the task text + a rolling
/// summary, so the per-request context stays bounded for the whole run.
///
/// Pure Dart: the env map is injected (the CLI passes
/// `Platform.environment`, tests pass their own), no dart:io.
library;

import 'dart:math';

import 'compaction.dart';

/// The env var a bench/unattended run sets to bound the context: the
/// auto-compaction trigger becomes this many estimated tokens instead of
/// the window-minus-reserve default. Unset/blank/invalid = the default
/// behavior, byte-identical.
const benchCompactionTriggerEnvVar = 'FAH_COMPACT_TRIGGER_TOKENS';

/// The [benchCompactionTriggerEnvVar] value from [env] as a positive
/// integer, trimmed; null when unset, blank, or not a positive integer
/// (junk never breaks a boot — the default behavior applies). Pure.
int? benchCompactionTriggerTokens(Map<String, String> env) {
  final value = env[benchCompactionTriggerEnvVar]?.trim();
  if (value == null || value.isEmpty) return null;
  final parsed = int.tryParse(value);
  return (parsed != null && parsed > 0) ? parsed : null;
}

/// Applies [triggerTokens] as the compaction firing point to [base] for a
/// model whose (effective) context window is [window].
///
/// The trigger of [CompactionSettings] is `window - reserveTokens`
/// ([shouldCompact]); reaching trigger [triggerTokens] therefore raises
/// the reserve to `window - triggerTokens`. Two guards keep the pass
/// sane:
///
/// - the kept recent region never exceeds half the trigger — a pass
///   always frees tokens, never reshuffles the same budget;
/// - a trigger at/above the settings' own default threshold is a no-op
///   (the bench knob can only LOWER the trigger, never raise it). A
///   trigger at/above the window clamps to `window`, which always
///   satisfies this guard — it is the same no-op, never a "fire at the
///   window" outcome.
///
/// Pure; returns [base] unchanged when the trigger changes nothing.
CompactionSettings withCompactionTriggerTokens(
  CompactionSettings base, {
  required int window,
  required int triggerTokens,
}) {
  if (!base.enabled) return base;
  final clamped = triggerTokens.clamp(1, window);
  final defaultTrigger = window - base.reserveTokens;
  if (clamped >= defaultTrigger) return base;
  // max<int>(…): a trigger of 1 makes `clamped ~/ 2` 0, and `int.clamp`
  // throws when the lower limit exceeds the upper — a parse-valid env
  // value must degrade, never kill the run (gh-1604 rework). The explicit
  // type argument keeps the static type int under clamp's `num` context.
  final keep = base.keepRecentTokens.clamp(1, max<int>(1, clamped ~/ 2));
  return CompactionSettings(
    enabled: true,
    reserveTokens: window - clamped,
    keepRecentTokens: keep,
  );
}

/// Composes [benchCompactionTriggerTokens] over [base]: the settings the
/// host's compaction gate should use for this run. The env-unset case
/// returns [base] IDENTICALLY (same instance) so unset runs stay
/// byte-for-byte legacy. Pure.
CompactionSettings resolveBenchCompactionSettings(
  CompactionSettings base, {
  required int window,
  required Map<String, String> env,
}) {
  final trigger = benchCompactionTriggerTokens(env);
  if (trigger == null) return base;
  return withCompactionTriggerTokens(
    base,
    window: window,
    triggerTokens: trigger,
  );
}
