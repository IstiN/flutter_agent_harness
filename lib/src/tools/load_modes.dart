/// Agent load modes (issue #680): the essential/discoverable tool-load
/// presets, after oh-my-pi's `essential-tools.ts` model — a curated base
/// set loads into the schema at boot, everything else stays discoverable
/// (hidden from the schema, mountable on demand through the availability
/// gate).
///
/// The `pi` entry is DATA-ONLY on this lane (issue #680 owns the shared
/// taxonomy; issue #679 owns pi's behavior: `--pi`/`FA_PI_MODE`, the bare
/// prompt profile and its parity gate). Both presets live here so the
/// settings switch (`agent.mode: default|pi|omp`) and the coexistence
/// tests have one source of truth.
///
/// `defaultMode` is no preset at all: every present tool loads exactly as
/// before this feature (byte-identical behavior — REG).
///
/// Pure Dart: no `dart:io`.
library;

/// The tool-load preset the harness boots with.
enum AgentLoadMode {
  /// No preset: today's behavior, every present tool in the schema.
  defaultMode,

  /// The pi preset (issue #679): 4-tool base, discovery off. Data-only
  /// here — pi's prompt/flag surface lives on the #679 lane.
  pi,

  /// The omp preset (issue #680, after oh-my-pi's essential set): the
  /// base loads into the schema; everything else is discoverable.
  omp,
}

extension AgentLoadModeLabel on AgentLoadMode {
  /// The yaml/CLI label: `agent.mode: <label>`, `FA_AGENT_MODE=<label>`.
  String get label => switch (this) {
    AgentLoadMode.defaultMode => 'default',
    AgentLoadMode.pi => 'pi',
    AgentLoadMode.omp => 'omp',
  };
}

/// Parses a `default|pi|omp` label (config `agent.mode`, `FA_AGENT_MODE`).
/// Returns null for null/empty (no intent); an unknown label is the
/// caller's error to report (ConfigException at boot).
AgentLoadMode? agentLoadModeFromLabel(String? label) {
  if (label == null || label.isEmpty) return null;
  for (final mode in AgentLoadMode.values) {
    if (mode.label == label) return mode;
  }
  return null;
}

/// Every valid label, for error messages and the settings picker.
const agentLoadModeLabels = ['default', 'pi', 'omp'];

/// The availability ids each non-default preset keeps ESSENTIAL (always
/// in the schema, pinned). Everything else known becomes discoverable.
///
/// - pi (#679): read/write/edit/bash — the minimal file+shell base.
/// - omp (#680): the card's draft set. fa has no `glob` tool — `ls` is
///   the file-discovery id in this harness's taxonomy, so the card's
///   `glob` maps to `ls`. `memory` stays discoverable (the owner's
///   deferred call: the hello gate favors the leaner base).
const essentialToolIdsByLoadMode = <AgentLoadMode, Set<String>>{
  AgentLoadMode.pi: {'read', 'write', 'edit', 'bash'},
  AgentLoadMode.omp: {'read', 'write', 'edit', 'bash', 'ls', 'task', 'ask'},
};

/// Resolves the load mode for this boot: flag > env > config (issue #680
/// AC3 precedence). [flagOmp] is `--omp`; [envMode] the raw `FA_AGENT_MODE`
/// value; [configMode] the raw `agent.mode` yaml value.
///
/// Throws [ArgumentError] naming the source when an env/config label is
/// not one of [agentLoadModeLabels] — a typo must never silently boot the
/// default mode.
AgentLoadMode resolveAgentLoadMode({
  bool flagOmp = false,
  String? envMode,
  String? configMode,
}) {
  if (flagOmp) return AgentLoadMode.omp;
  final fromEnv = agentLoadModeFromLabel(envMode);
  if (envMode != null && envMode.isNotEmpty && fromEnv == null) {
    throw ArgumentError.value(
      envMode,
      'FA_AGENT_MODE',
      'unknown load mode (expected one of: ${agentLoadModeLabels.join(', ')})',
    );
  }
  if (fromEnv != null) return fromEnv;
  final fromConfig = agentLoadModeFromLabel(configMode);
  if (configMode != null && configMode.isNotEmpty && fromConfig == null) {
    throw ArgumentError.value(
      configMode,
      'agent.mode',
      'unknown load mode (expected one of: ${agentLoadModeLabels.join(', ')})',
    );
  }
  return fromConfig ?? AgentLoadMode.defaultMode;
}
