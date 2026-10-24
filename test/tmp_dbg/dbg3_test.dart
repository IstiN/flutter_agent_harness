import 'package:flutter_agent_harness/src/model_roles/media_model_slots.dart';
import 'package:flutter_agent_harness/src/model_roles/models_config.dart';
import 'package:flutter_agent_harness/src/tools/generate_image.dart';
import 'package:test/test.dart';

void main() {
  test('dbg3', () async {
    final cfg = ModelsConfig(slots: {
      'imageGeneration': MediaSlotModelConfig(
        providerKind: 'openai-completions',
        baseUrl: 'https://api.example.com/v1',
        modelId: 'MiniMax-M3',
        apiKeyName: 'MINIMAX_KEY',
      ),
    });
    final override = cfg.slots['imageGeneration']!;
    final resolved = await resolveKeyTrace(override.apiKeyName);
    print('resolved="$resolved"');
  });
}

Future<String?> resolveKeyTrace(String? name) async {
  print('resolveKey called with "$name"');
  return name == 'MINIMAX_KEY' ? 'slot-key' : null;
}
