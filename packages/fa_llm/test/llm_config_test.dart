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

  group('fromEnvironment base URL normalization', () {
    String resolve(String provider, String baseUrl) =>
        LlmConfig.fromEnvironment(provider: provider, baseUrl: baseUrl).baseUrl;

    test('origin gains the versioned chat-completions route', () {
      expect(resolve('openai', 'http://127.0.0.1:8931'),
          'http://127.0.0.1:8931/v1/chat/completions');
      expect(resolve('openrouter', 'https://my-proxy.example'),
          'https://my-proxy.example/v1/chat/completions');
      expect(resolve('ollama', 'http://localhost:11434'),
          'http://localhost:11434/v1/chat/completions');
    });

    test('versioned base gains only the route', () {
      expect(resolve('openai', 'http://127.0.0.1:8931/v1'),
          'http://127.0.0.1:8931/v1/chat/completions');
      expect(resolve('ollama', 'http://localhost:11434/v1'),
          'http://localhost:11434/v1/chat/completions');
    });

    test('full endpoint passes through byte-identical', () {
      const openai = 'https://api.openai.com/v1/chat/completions';
      expect(resolve('openai', openai), openai);
      expect(resolve('openrouter', 'https://openrouter.ai/api/v1/chat/completions'),
          'https://openrouter.ai/api/v1/chat/completions');
      expect(resolve('ollama', 'http://localhost:11434/v1/chat/completions'),
          'http://localhost:11434/v1/chat/completions');
    });

    test('trailing slashes are dropped before the route is appended', () {
      expect(resolve('openai', 'http://127.0.0.1:8931/v1/'),
          'http://127.0.0.1:8931/v1/chat/completions');
    });

    test('empty override stays empty for the factory default fallback', () {
      expect(resolve('openai', ''), '');
    });
  });
}
