/// CLI user preferences: last model, provider, base URL, mode, approval
/// policy, prompt overrides, and (optionally) model roles with fallback
/// chains.
///
/// Stored in `~/.fah/config.yaml` so the terminal REPL remembers choices
/// between runs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../exceptions.dart';
import '../model_roles/model_roles.dart';
import '../prompts/prompt_overrides.dart';
import '../ttsr/ttsr.dart';

/// Persisted CLI configuration.
final class CliConfig {
  CliConfig({
    this.providerKind = 'openai-completions',
    this.modelId = 'openai/gpt-4o-mini',
    this.baseUrl = 'https://openrouter.ai/api/v1',
    this.mode = 'code',
    this.approvalMode = 'yolo',
    this.allowedTools = const [],
    this.promptOverrides = const {},
    this.modelRoles,
    this.ttsr,
  });

  factory CliConfig.fromYaml(YamlMap map) {
    return CliConfig(
      providerKind: map['provider'] as String? ?? 'openai-completions',
      modelId: map['model'] as String? ?? 'openai/gpt-4o-mini',
      baseUrl: map['baseUrl'] as String? ?? 'https://openrouter.ai/api/v1',
      mode: map['mode'] as String? ?? 'code',
      approvalMode: map['approvalMode'] as String? ?? 'yolo',
      allowedTools: switch (map['allowedTools']) {
        final YamlList list => [for (final entry in list) '$entry'],
        _ => const [],
      },
      // The prompts section is parsed strictly: unknown prompt names throw
      // [ConfigException] instead of silently doing nothing.
      promptOverrides: parsePromptOverrideMap(map['prompts']),
      // The roles section is parsed strictly: schema errors throw
      // [ConfigException] instead of silently resetting to defaults.
      modelRoles: map['roles'] == null && map['modelOverrides'] == null
          ? null
          : ModelRolesConfig.fromYaml(map),
      // The ttsr section is parsed strictly too (bad rules must surface).
      ttsr: map['ttsr'] == null
          ? null
          : TtsrConfig.fromYaml(map['ttsr'], sourcePath: '~/.fah/config.yaml'),
    );
  }

  final String providerKind;
  final String modelId;
  final String baseUrl;
  final String mode;

  /// Approval mode label (`always-ask`, `write`, `yolo`); parsed with
  /// `approvalModeFromLabel` from `lib/src/approval/`.
  final String approvalMode;

  /// Tools the user always-allowed (via `/allow` or an "approve always"
  /// prompt answer), persisted across runs.
  final List<String> allowedTools;

  /// Raw prompt overrides from the `prompts:` yaml section: prompt name →
  /// file path or inline text (validated by [parsePromptOverrideMap]). The
  /// executable resolves it into a `PromptOverrides` via
  /// `resolvePromptOverrides` (file reads live in `lib/io.dart`); an empty
  /// map keeps the built-in prompts.
  final Map<String, String> promptOverrides;

  /// Optional model roles: role → fallback chains, path-scoped overrides,
  /// and the retry policy (`roles:` / `modelOverrides:` / `retry:` yaml
  /// sections). `null` keeps the legacy single provider/model behavior.
  final ModelRolesConfig? modelRoles;

  /// Optional TTSR stream rules (`ttsr:` yaml section). `null` disables
  /// stream-rule monitoring.
  final TtsrConfig? ttsr;

  String toYaml() {
    final buffer = StringBuffer()
      ..write('provider: $providerKind\n')
      ..write('model: $modelId\n')
      ..write('baseUrl: $baseUrl\n')
      ..write('mode: $mode\n')
      ..write('approvalMode: $approvalMode\n');
    if (allowedTools.isEmpty) {
      buffer.write('allowedTools: []\n');
    } else {
      buffer.write('allowedTools:\n');
      for (final tool in allowedTools) {
        buffer.write('  - $tool\n');
      }
    }
    if (promptOverrides.isNotEmpty) {
      // JSON-quoted values are valid yaml scalars and keep inline multi-line
      // prompt text round-trippable (same convention as the ttsr section).
      buffer.write('prompts:\n');
      for (final entry in promptOverrides.entries) {
        buffer.write('  ${entry.key}: ${jsonEncode(entry.value)}\n');
      }
    }
    final roles = modelRoles;
    if (roles != null) buffer.write(roles.toYaml());
    final ttsrConfig = ttsr;
    if (ttsrConfig != null) buffer.write(ttsrConfig.toYaml());
    return buffer.toString();
  }
}

/// Returns the user's home directory, or `null` if it cannot be determined.
String? homeDirectory() {
  if (Platform.isWindows) {
    return Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  }
  return Platform.environment['HOME'];
}

/// Loads [CliConfig] from `~/.fah/config.yaml`.
///
/// Returns defaults when the file is missing or unreadable. A syntactically
/// valid file whose model-roles section is invalid throws [ConfigException]
/// (bad roles must surface, never silently vanish).
CliConfig loadCliConfig(String homeDir) {
  final file = File('$homeDir/.fah/config.yaml');
  if (!file.existsSync()) return CliConfig();
  try {
    final content = file.readAsStringSync();
    final doc = loadYaml(content);
    if (doc is YamlMap) return CliConfig.fromYaml(doc);
  } on ConfigException {
    rethrow;
  } on Object {
    // Ignore corrupt config and fall back to defaults.
  }
  return CliConfig();
}

/// Saves [CliConfig] to `~/.fah/config.yaml`.
Future<void> saveCliConfig(String homeDir, CliConfig config) async {
  final dir = Directory('$homeDir/.fah');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final file = File('${dir.path}/config.yaml');
  await file.writeAsString(config.toYaml());
}
