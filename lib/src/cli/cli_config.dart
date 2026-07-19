/// CLI user preferences: last model, provider, base URL, mode, and approval
/// policy.
///
/// Stored in `~/.fah/config.yaml` so the terminal REPL remembers choices
/// between runs.
library;

import 'dart:io';

import 'package:yaml/yaml.dart';

/// Persisted CLI configuration.
final class CliConfig {
  CliConfig({
    this.providerKind = 'openai-completions',
    this.modelId = 'openai/gpt-4o-mini',
    this.baseUrl = 'https://openrouter.ai/api/v1',
    this.mode = 'code',
    this.approvalMode = 'yolo',
    this.allowedTools = const [],
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
/// Returns defaults when the file is missing or unreadable.
CliConfig loadCliConfig(String homeDir) {
  final file = File('$homeDir/.fah/config.yaml');
  if (!file.existsSync()) return CliConfig();
  try {
    final content = file.readAsStringSync();
    final doc = loadYaml(content);
    if (doc is YamlMap) return CliConfig.fromYaml(doc);
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
