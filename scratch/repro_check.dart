import 'package:yaml/yaml.dart';
import 'package:flutter_agent_harness/src/config/config_service.dart';

void main() {
  // The file shape AFTER the contextWindow write + host persist
  // (ModelCapabilityOverrides.toYaml renders jsonEncode'd keys).
  const source = '''
provider: copilot
model: gemini-4-argon
models:
  overrides:
    "copilot":
      "gemini-4-argon":
        contextWindow: 204800
''';
  final edited = upsertYamlPath(
    source,
    ['models', 'overrides', 'copilot', 'gemini-4-argon', 'maxTokens'],
    ['65536'],
  );
  print('--- edited ---');
  print(edited);
  print('--- loadYaml ---');
  try {
    final doc = loadYaml(edited);
    print('parsed ok');
  } on Object catch (e) {
    print('THROWS: ${e.runtimeType}: $e');
  }
}
