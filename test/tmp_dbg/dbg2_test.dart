import 'package:flutter_agent_harness/src/model_roles/media_model_slots.dart';
import 'package:test/test.dart';

void main() {
  test('dbg2', () {
    const o = MediaSlotModelConfig(
      providerKind: 'openai-completions',
      baseUrl: 'https://api.example.com/v1',
      modelId: 'MiniMax-M3',
      apiKeyName: 'MINIMAX_KEY',
    );
    print('keyName=${o.apiKeyName} kind=${o.providerKind} url=${o.baseUrl} model=${o.modelId}');
  });
}
