// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The app-side read of the sections of `~/.fah/config.yaml` the Flutter
/// host honors (issue #1078): `roles:`, `tools:`, `ttsr:`, `redact:`,
/// `providerTimeouts:`, and `agent.mode`.
///
/// ONE parsing layer shared by both hosts: every section goes through the
/// SAME strict core parser the CLI boot runs ([ModelRolesConfig.fromYaml],
/// [ToolsConfig.fromYaml], [TtsrConfig.fromYaml], [RedactionConfig.fromYaml],
/// [parseProviderTimeouts], [agentLoadModeValidationError]) — the app never
/// re-implements a schema. The difference is policy, not parsing: the CLI
/// treats a bad section as a hard boot failure, the app treats it as a
/// named warning plus the default (AC7 — a bad yaml file must never brick
/// the boot). AC7's scope is DESKTOP-only by construction: the yaml
/// pipeline exists where a user home exists (macOS/Windows/Linux); on
/// Android/iOS [desktopHomeDir] is null and the whole read is a silent
/// no-op — the app stores keep their UI-chosen values (there is no
/// `~/.fah` in a mobile sandbox to mis-parse).
///
/// Scope mirrors the CLI reads exactly: `roles:`/`ttsr:`/`redact:`/
/// `providerTimeouts:`/`agent.mode` are USER-scope (`~/.fah/config.yaml`);
/// `tools:` is the live scope stack (user global + project, the app has no
/// session-scope file); `ttsr:` additionally merges project `.fah/rules.yaml`
/// rules project-first (the CLI `_resolveTtsr` merge). Project
/// `.fah/config.yaml` sections beyond `tools:` are NOT read — the CLI does
/// not read them either.
///
/// Pure Dart: no `dart:io` (file reading belongs to the host loader).
library;

import 'package:yaml/yaml.dart';

import '../cli/cli_config.dart' show parseProviderTimeouts;
import '../exceptions.dart';
import '../model_roles/model_roles.dart';
import '../providers/provider_common.dart';
import '../redact/redaction_types.dart';
import '../tools/availability.dart';
import '../tools/load_modes.dart';
import '../ttsr/ttsr.dart';

/// The parsed config sections the Flutter app applies (issue #1078).
///
/// Absent sections are null/empty; a present-but-invalid section carries a
/// [warnings] entry naming file + section and reads as absent (defaults).
final class AppFahSections {
  /// Creates the resolved sections.
  const AppFahSections({
    this.userDoc,
    this.roles,
    this.ttsr,
    this.userTools = const ToolsConfig(),
    this.projectTools = const ToolsConfig(),
    this.redact,
    this.providerTimeouts,
    this.loadMode = AgentLoadMode.defaultMode,
    this.mcpConfigured = false,
    this.warnings = const [],
  });

  /// The `roles:` section (`roles:`/`modelOverrides:`/`retry:`), or null.
  final ModelRolesConfig? roles;

  /// The merged `ttsr:` config: user `~/.fah/config.yaml` settings + rules
  /// with project `.fah/rules.yaml` rules registered FIRST (name clashes:
  /// project wins — the manager dedupes first-wins), or null.
  final TtsrConfig? ttsr;

  /// The user-scope `tools:` section (the stack's global scope).
  final ToolsConfig userTools;

  /// The project-scope `tools:` section of `<project>/.fah/config.yaml`.
  final ToolsConfig projectTools;

  /// The `redact:` section, or null (defaults).
  final RedactionConfig? redact;

  /// The `providerTimeouts:` overrides, or null (defaults).
  final ProviderTimeoutsOverride? providerTimeouts;

  /// The resolved tool-load preset: `FA_AGENT_MODE` env > `agent.mode`
  /// config (the app has no `--omp` flag; the CLI's flag rung is its own).
  final AgentLoadMode loadMode;

  /// Whether a user `mcp:` section exists. The app does not consume it yet
  /// (CLI-only transport, inventory #2) — the loader surfaces a dead-config
  /// warning so the setting stops being silently ignored.
  final bool mcpConfigured;

  /// One line per skipped/malformed section: names the file + section
  /// (AC7). The host logs these once at boot.
  final List<String> warnings;

  /// The raw user doc (exposed for the parity guard to compare parser
  /// inputs); null when the file was absent/unreadable/malformed.
  final Object? userDoc;
}

/// Parses the already-loaded yaml documents into [AppFahSections].
///
/// Every section parse is isolated: a malformed section records a warning
/// naming its file + section and falls back to the default, never poisoning
/// the other sections (AC7). Throws nothing.
AppFahSections parseAppConfigSections({
  Object? userDoc,
  Object? projectDoc,
  Object? projectRulesDoc,
  String userSource = '~/.fah/config.yaml',
  String projectSource = '.fah/config.yaml',
  String projectRulesSource = '.fah/rules.yaml',
  String? envMode,
}) {
  final warnings = <String>[];
  final user = _coerceScopeDoc(userDoc, userSource, warnings);
  final project = _coerceScopeDoc(projectDoc, projectSource, warnings);
  final roles = _parseRolesSection(user, userSource, warnings);
  // tools: — both scopes parse independently; the caller stacks them
  // (global < project < runtime) in the live resolution.
  final userTools = _parseTools(user?['tools'], userSource, warnings);
  final projectTools = _parseTools(
    project?['tools'],
    projectSource,
    warnings,
  );
  final ttsr = _parseTtsrSection(
    user,
    userSource,
    projectRulesDoc,
    projectRulesSource,
    warnings,
  );
  final redact = _parseRedactSection(user, userSource, warnings);
  final providerTimeouts = _parseTimeoutsSection(user, userSource, warnings);
  final loadMode = _resolveLoadMode(envMode, user, userSource, warnings);
  // Inventory #2 interim: `mcp:` stays CLI-only on mobile — say so instead
  // of silently ignoring it.
  final mcpConfigured = user?['mcp'] != null;
  if (mcpConfigured) {
    warnings.add(
      'mcp section in $userSource is not consumed by the app yet '
      '(MCP servers connect through the CLI harness)',
    );
  }
  return AppFahSections(
    roles: roles,
    ttsr: ttsr,
    userTools: userTools,
    projectTools: projectTools,
    redact: redact,
    providerTimeouts: providerTimeouts,
    loadMode: loadMode,
    mcpConfigured: mcpConfigured,
    warnings: warnings,
    userDoc: userDoc,
  );
}

/// One scope's yaml document: the map itself, a named warning for any
/// other node, null for absence (AC7 — the warning names the file).
YamlMap? _coerceScopeDoc(Object? doc, String source, List<String> warnings) {
  if (doc is YamlMap) return doc;
  if (doc != null) warnings.add('invalid config in $source: expected a map');
  return null;
}

/// The `roles:` section — user scope, the CLI's exact parse (whole-doc:
/// it reads roles:/modelOverrides:/retry:) behind the CLI's exact trigger.
ModelRolesConfig? _parseRolesSection(
  YamlMap? user,
  String userSource,
  List<String> warnings,
) {
  if (user == null || !_shipsRolesSection(user)) return null;
  try {
    return ModelRolesConfig.fromYaml(user);
  } on ConfigException catch (error) {
    warnings.add('invalid roles section in $userSource: ${error.message}');
    return null;
  }
}

/// The CLI's exact roles trigger (cli_config.dart: roles ||
/// modelOverrides). A `retry:`-only doc is a silent no-op on the CLI —
/// the retry policy only rides a roles parse — so it stays one here
/// (parity over convenience).
bool _shipsRolesSection(YamlMap? user) =>
    user != null &&
    (user['roles'] != null || user['modelOverrides'] != null);

/// The `ttsr:` section: user settings + rules, project `.fah/rules.yaml`
/// rules first (the CLI _resolveTtsr merge: project rules win name
/// clashes). Null when neither scope ships anything.
TtsrConfig? _parseTtsrSection(
  YamlMap? user,
  String userSource,
  Object? projectRulesDoc,
  String projectRulesSource,
  List<String> warnings,
) {
  final userTtsr = _parseUserTtsr(user, userSource, warnings);
  final projectRules = _parseProjectTtsrRules(
    projectRulesDoc,
    projectRulesSource,
    warnings,
  );
  if (userTtsr == null && _isAbsent(projectRules)) return null;
  return TtsrConfig(
    settings: userTtsr?.settings ?? TtsrSettings.defaultSettings,
    rules: [...?projectRules, ...?userTtsr?.rules],
  );
}

/// The user `ttsr:` section, or null (absent or structurally dead).
TtsrConfig? _parseUserTtsr(
  YamlMap? user,
  String userSource,
  List<String> warnings,
) {
  if (user?['ttsr'] == null) return null;
  try {
    return TtsrConfig.fromYaml(
      user!['ttsr'],
      sourcePath: userSource,
      warnings: warnings,
    );
  } on ConfigException catch (error) {
    warnings.add('invalid ttsr section in $userSource: ${error.message}');
    return null;
  }
}

/// The project `.fah/rules.yaml` rules, or null (absent or dead).
List<TtsrRule>? _parseProjectTtsrRules(
  Object? projectRulesDoc,
  String projectRulesSource,
  List<String> warnings,
) {
  if (projectRulesDoc == null) return null;
  try {
    return TtsrConfig.rulesFromYaml(
      projectRulesDoc,
      sourcePath: projectRulesSource,
      warnings: warnings,
    );
  } on ConfigException catch (error) {
    warnings.add(
      'invalid ttsr rules in $projectRulesSource: ${error.message}',
    );
    return null;
  }
}

/// Null-or-empty: an absent project rules layer.
bool _isAbsent(List<TtsrRule>? rules) => rules == null || rules.isEmpty;

/// The `redact:` section — tolerant parse (invalid values fall back to
/// defaults inside [RedactionConfig.fromYaml]); a non-map node or a
/// structural failure (bad allowlist regex) warns and falls back.
RedactionConfig? _parseRedactSection(
  YamlMap? user,
  String userSource,
  List<String> warnings,
) {
  final node = user?['redact'];
  if (node == null) return null;
  if (node is! Map<dynamic, dynamic>) {
    warnings.add('invalid redact section in $userSource: expected a map');
    return RedactionConfig.fromYaml(null);
  }
  return _redactConfigOf(node, userSource, warnings);
}

/// The parsed `redact:` map, or null when even the tolerant parse fails.
RedactionConfig? _redactConfigOf(
  Map<dynamic, dynamic> node,
  String userSource,
  List<String> warnings,
) {
  try {
    return RedactionConfig.fromYaml(node);
  } on Object catch (error) {
    warnings.add('invalid redact section in $userSource: $error');
    return null;
  }
}

/// The `providerTimeouts:` section — the CLI's own strict parser.
ProviderTimeoutsOverride? _parseTimeoutsSection(
  YamlMap? user,
  String userSource,
  List<String> warnings,
) {
  if (user?['providerTimeouts'] == null) return null;
  try {
    return parseProviderTimeouts(user!['providerTimeouts']);
  } on ConfigException catch (error) {
    warnings.add(
      'invalid providerTimeouts section in $userSource: ${error.message}',
    );
    return null;
  }
}

/// agent.mode — env first (the app has no --omp flag), then the config
/// value. The shared validator names the offending source (AC7).
AgentLoadMode _resolveLoadMode(
  String? envMode,
  YamlMap? user,
  String userSource,
  List<String> warnings,
) {
  final env = _modeLabelIntent(
    'FA_AGENT_MODE',
    envMode,
    'environment',
    warnings,
  );
  if (env != null) return agentLoadModeFromLabel(env)!;
  final config = _modeLabelIntent(
    'agent.mode',
    _agentModeOf(user, userSource, warnings),
    userSource,
    warnings,
  );
  if (config != null) return agentLoadModeFromLabel(config)!;
  return AgentLoadMode.defaultMode;
}

/// A present, non-empty mode label — null means "no intent from here".
String? _modeLabelIntent(
  String source,
  String? value,
  String origin,
  List<String> warnings,
) {
  if (value == null || value.isEmpty) return null;
  return _validModeLabel(source, value, origin, warnings);
}

/// The label, or a named AC7 warning + null when the CLI validator
/// rejects it (the app degrades instead of failing boot).
String? _validModeLabel(
  String source,
  String value,
  String origin,
  List<String> warnings,
) {
  final invalid = agentLoadModeValidationError(value);
  if (invalid != null) {
    warnings.add('invalid $source in $origin: $invalid');
    return null;
  }
  return value;
}

/// One scope's `tools:` parse with the named warning on a bad section.
ToolsConfig _parseTools(Object? node, String source, List<String> warnings) {
  if (node == null) return const ToolsConfig();
  try {
    return ToolsConfig.fromYaml(node);
  } on ConfigException catch (error) {
    warnings.add('invalid tools section in $source: ${error.message}');
    return const ToolsConfig();
  }
}

/// The raw `agent.mode` label, or null — with an AC7 warning when the
/// node or the label is malformed (the CLI's [resolveAgentLoadMode]
/// errors on any non-empty non-label value; the app degrades to the
/// warning + default instead of failing boot).
String? _agentModeOf(YamlMap? user, String source, List<String> warnings) {
  final agent = user?['agent'];
  if (agent == null) return null;
  return _agentModeLeaf(agent, source, warnings);
}

/// The `mode:` leaf of a present `agent:` section.
String? _agentModeLeaf(Object? agent, String source, List<String> warnings) {
  if (agent is! YamlMap) {
    warnings.add('invalid agent section in $source: expected a map');
    return null;
  }
  final mode = agent['mode'];
  if (mode == null) return null;
  return _modeLabelOrWarn(mode, source, warnings);
}

/// The raw label, or the AC7 warning when the CLI's label set rejects it.
String? _modeLabelOrWarn(Object? mode, String source, List<String> warnings) {
  if (mode is String) return mode;
  warnings.add(
    'invalid agent.mode in $source: expected one of '
    '${agentLoadModeLabels.join('|')}',
  );
  return null;
}
