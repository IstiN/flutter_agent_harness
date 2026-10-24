import 'package:flutter_agent_harness/src/model_roles/media_model_slots.dart';
import 'package:flutter_agent_harness/src/model_roles/models_config.dart';
import 'package:flutter_agent_harness/src/tools/generate_image.dart';
import 'package:test/test.dart';

void main() {
  test('dbg', () async {
    final cfg = ModelsConfig(slots: {
      'imageGeneration': MediaSlotModelConfig(
        providerKind: 'openai-completions',
        baseUrl: 'https://api.example.com/v1',
        modelId: 'MiniMax-M3',
        apiKeyName: 'MINIMAX_KEY',
      ),
    });
    print('override.apiKeyName=${cfg.slots['imageGeneration']?.apiKeyName} useMain=${cfg.slots['imageGeneration']?.useMainConnection}');
    final ep = await resolveImageGenerationEndpoint(
      cfg,
      mainBaseUrl: 'https://main.example/v1',
      mainModelId: 'main-model',
      mainApiKey: 'main-key',
      resolveKey: (name) async => name == 'MINIMAX_KEY' ? 'slot-key' : null,
    );
    print('EP: ${ep?.baseUrl} ${ep?.modelId} key=${ep?.apiKey}');
  });
}
