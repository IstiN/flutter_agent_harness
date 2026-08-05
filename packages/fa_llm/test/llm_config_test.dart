import 'package:fa_llm/src/llm_config.dart';
import 'package:test/test.dart';

void main() {
  test('isConfigured returns true only when apiKey and model are set', () {
    final configured = LlmConfig(
      providerName: 'openai',
      apiKey: 'secret',
      baseUrl: 'https://api.openai.com',
      model: 'gpt-4',
    );
    expect(configured.isConfigured, isTrue);

    final noKey = configured.copyWith(apiKey: '');
    expect(noKey.isConfigured, isFalse);

    final noModel = configured.copyWith(model: '');
    expect(noModel.isConfigured, isFalse);
  });
}
