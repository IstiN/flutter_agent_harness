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
/// Since GOAL #28 (issue #2416) `defaultMode` is the owner's partition:
/// twelve essential tool NAMES (the keep-12, [essentialToolNamesByLoadMode])
/// load into the schema, everything else defers to the `others` discovery
/// surface, and the four capability-bound media/decide tools stay
/// conditional on their capability ([conditionalCapabilityToolNames]).
///
/// Pure Dart: no `dart:io`.
library;

/// The tool-load preset the harness boots with.
enum AgentLoadMode {
  /// No preset: today's behavior, every present tool in the schema.
  defaultMode,

  /// The pi preset (issue #679): 4-tool base, discovery off — pi-mono's
  /// exact benchmark shape (no `discover_tools` meta tool; that surface
  /// is omp's). Data-only here — pi's prompt/flag surface lives on the
  /// #679 lane.
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

/// Validates one `agent.mode` value (issue #680): null when [value] is a
/// legal [agentLoadModeLabels] label, else the error text. The single
/// source shared by the boot parser (`cli_config.dart`) and the settings
/// validator (`config_service.dart`) — both throw it as a
/// ConfigException, so the rule cannot drift between the two parsers.
String? agentLoadModeValidationError(Object? value) {
  if (value is String && agentLoadModeLabels.contains(value)) return null;
  return '"agent.mode" must be one of: ${agentLoadModeLabels.join(', ')}';
}

/// Whether a preset ships the `others` discovery surface (issue #2416,
/// replacing #680's `discover_tools`): the default partition and omp
/// demote non-essential tools and discover them back through `others`;
/// pi is pi-mono's exact benchmark shape (issue #679) — 4 tools,
/// discovery off, no discovery surface.
const discoveryEnabledByLoadMode = <AgentLoadMode, bool>{
  AgentLoadMode.defaultMode: true,
  AgentLoadMode.pi: false,
  AgentLoadMode.omp: true,
};

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

/// The default partition's ESSENTIAL tool NAMES (GOAL #28, issue #2416 —
/// the owner's keep-12, pinned 2026-11-25). Name-level, not id-level: the
/// `memory` id splits (`memory_add` + `memory_search` stay loaded,
/// `memory_list`/`memory_delete` defer) and `reply` (a `task`-family
/// member) stays loaded so subagents deliver natively. Pinned — no scope
/// can demote them; `off` still disables (`tools: {id: off}`), and
/// `tools: {id: on}` is the standing mount that keeps any family loaded.
const essentialToolNamesByLoadMode = <AgentLoadMode, Set<String>>{
  AgentLoadMode.defaultMode: {
    'read',
    'write',
    'edit',
    'ls',
    'bash',
    'bash_job',
    'lsp',
    'web_search',
    'web_fetch',
    'memory_add',
    'memory_search',
    'reply',
  },
};

/// The capability-conditional tool NAMES (GOAL #28): present in the
/// manifest iff the host's capability for them exists, absent
/// (unregistered, with the reason in /tools) otherwise — call-time
/// refusal replaced by capability-conditional registration.
///
/// - `inspect_image` — a vision model is configured (gh-1984 live sync).
/// - `generate_image` / `generate_video` — the `models.slots.
///   imageGeneration`/`videoGeneration` slot resolves (or the explicit
///   `useMainConnection` opt-in).
/// - `decide` — the main connection's provider is OpenRouter.
/// - `transcribe_audio` — already capability-bound (transcription slot);
///   unchanged, listed here so the partition never defers it.
const conditionalCapabilityToolNames = <String>{
  'inspect_image',
  'generate_image',
  'generate_video',
  'decide',
  'transcribe_audio',
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
