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
      expect(resolve('openrouter', 'https://openrouter.ai/api/v1'),
          'https://openrouter.ai/api/v1/chat/completions');
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

    test('query-string endpoints pass through verbatim', () {
      const azure =
          'https://myres.openai.azure.com/openai/deployments/gpt-4o/'
          'chat/completions?api-version=2024-10-21';
      expect(resolve('openai', azure), azure);
    });

    test('custom gateway paths pass through verbatim', () {
      expect(resolve('openai', 'https://gw.example/corp-route'),
          'https://gw.example/corp-route');
      expect(resolve('ollama', 'https://gw.example/corp-route'),
          'https://gw.example/corp-route');
    });

    test('copilot base URLs are never rewritten', () {
      expect(resolve('copilot', 'https://api.githubcopilot.com'),
          'https://api.githubcopilot.com');
      expect(resolve('copilot', 'https://copilot.corp.example.com/v1'),
          'https://copilot.corp.example.com/v1');
    });

    test('empty override stays empty for the factory default fallback', () {
      expect(resolve('openai', ''), '');
    });
  });

  group('fromEnvironment env and .env resolution', () {
    test('BASE_PATH wins over BASE_URL and is normalized', () {
      final config = LlmConfig.fromEnvironment(
        environmentOverride: {
          'OPENAI_BASE_PATH': 'http://127.0.0.1:8931/v1',
          'OPENAI_BASE_URL': 'http://127.0.0.1:8931',
        },
      );
      expect(config.baseUrl, 'http://127.0.0.1:8931/v1/chat/completions');
    });

    test('environment beats .env', () {
      final config = LlmConfig.fromEnvironment(
        environmentOverride: {'OPENAI_MODEL': 'from-env'},
        dotEnvOverride: {'OPENAI_MODEL': 'from-dotenv'},
      );
      expect(config.model, 'from-env');
    });

    test('.env supplies values the environment lacks', () {
      final config = LlmConfig.fromEnvironment(
        environmentOverride: {},
        dotEnvOverride: {'OPENAI_MODEL': 'from-dotenv'},
      );
      expect(config.model, 'from-dotenv');
    });
  });
}
