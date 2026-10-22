import 'package:flutter_agent_harness/src/config/config_service.dart';

void main() {
  const incident = '''
provider: copilot
model: gemini-4-argon
models:
  overrides:
    "copilot":
      "gemini-4-argon":
        contextWindow: 204800
''';
  final edited = removeYamlPath(incident, [
    'models',
    'overrides',
    'copilot',
    'gemini-4-argon',
    'contextWindow',
  ]);
  print('--- edited ---');
  print(edited);
  print('--- end ---');
}
