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
/// the mobile boot).
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
  YamlMap? user;
  if (userDoc is YamlMap) user = userDoc;

  // roles: — user scope, the CLI's exact parse (whole-doc: it reads
  // roles:/modelOverrides:/retry:).
  ModelRolesConfig? roles;
  if (user != null &&
      (user['roles'] != null ||
          user['modelOverrides'] != null ||
          user['retry'] != null)) {
    try {
      roles = ModelRolesConfig.fromYaml(user);
    } on ConfigException catch (error) {
      warnings.add('invalid roles section in $userSource: ${error.message}');
    }
  }

  // tools: — both scopes parse independently; the caller stacks them
  // (global < project < runtime) in the live resolution.
  final userTools = _parseTools(user?['tools'], userSource, warnings);
  final projectTools = _parseTools(
    projectDoc is YamlMap ? projectDoc['tools'] : null,
    projectSource,
    warnings,
  );

  // ttsr: — user settings + rules, project .fah/rules.yaml rules first
  // (the CLI _resolveTtsr merge: project rules win name clashes).
  TtsrConfig? ttsr;
  TtsrConfig? userTtsr;
  if (user?['ttsr'] != null) {
    try {
      userTtsr = TtsrConfig.fromYaml(
        user!['ttsr'],
        sourcePath: userSource,
        warnings: warnings,
      );
    } on ConfigException catch (error) {
      warnings.add('invalid ttsr section in $userSource: ${error.message}');
    }
  }
  List<TtsrRule>? projectRules;
  if (projectRulesDoc != null) {
    try {
      projectRules = TtsrConfig.rulesFromYaml(
        projectRulesDoc,
        sourcePath: projectRulesSource,
        warnings: warnings,
      );
    } on ConfigException catch (error) {
      warnings.add(
        'invalid ttsr rules in $projectRulesSource: ${error.message}',
      );
    }
  }
  if (userTtsr != null || (projectRules != null && projectRules.isNotEmpty)) {
    ttsr = TtsrConfig(
      settings: userTtsr?.settings ?? TtsrSettings.defaultSettings,
      rules: [...?projectRules, ...?userTtsr?.rules],
    );
  }

  // redact: — tolerant parse (invalid values already fall back to defaults
  // inside RedactionConfig.fromYaml); a structural failure warns.
  RedactionConfig? redact;
  if (user?['redact'] != null) {
    final node = user!['redact'];
    if (node is Map<dynamic, dynamic>) {
      try {
        redact = RedactionConfig.fromYaml(node);
      } on Object catch (error) {
        warnings.add('invalid redact section in $userSource: $error');
      }
    } else {
      redact = RedactionConfig.fromYaml(null);
      warnings.add('invalid redact section in $userSource: expected a map');
    }
  }

  // providerTimeouts: — the CLI's own strict parser.
  ProviderTimeoutsOverride? providerTimeouts;
  if (user?['providerTimeouts'] != null) {
    try {
      providerTimeouts = parseProviderTimeouts(user!['providerTimeouts']);
    } on ConfigException catch (error) {
      warnings.add(
        'invalid providerTimeouts section in $userSource: ${error.message}',
      );
    }
  }

  // agent.mode — env first (the app has no --omp flag), then the config
  // value. The shared validator names the offending source (AC7).
  final configMode = _agentModeOf(user);
  var loadMode = AgentLoadMode.defaultMode;
  for (final (source, value) in [('FA_AGENT_MODE', envMode), (
    'agent.mode',
    configMode,
  )]) {
    if (value == null || value.isEmpty) continue;
    final invalid = agentLoadModeValidationError(value);
    if (invalid != null) {
      final origin = source == 'FA_AGENT_MODE' ? 'environment' : userSource;
      warnings.add('invalid $source in $origin: $invalid');
      continue;
    }
    loadMode = agentLoadModeFromLabel(value)!;
    break; // first accepted intent wins: env overrides the config label
  }

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

/// The raw `agent.mode` label, or null.
String? _agentModeOf(YamlMap? user) {
  final agent = user?['agent'];
  if (agent is! YamlMap) return null;
  final mode = agent['mode'];
  return mode is String ? mode : null;
}
