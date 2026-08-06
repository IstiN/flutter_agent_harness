import 'package:fa_llm/src/llm_config.dart';
import 'package:fa_llm/src/openai_provider.dart';
import 'package:fa_llm/src/openrouter_provider.dart';
import 'package:fa_llm/src/provider_factory.dart';
import 'package:test/test.dart';

void main() {
  const baseConfig = LlmConfig(
    providerName: 'openai',
    apiKey: 'key',
    baseUrl: '',
    model: 'gpt-4',
  );

  test('creates OpenAiProvider for openai provider', () {
    final provider = ProviderFactory.create(baseConfig) as OpenAiProvider;
    expect(provider.baseUrl, 'https://api.openai.com/v1/chat/completions');
  });

  test('creates OpenRouterProvider for openrouter provider', () {
    final provider =
        ProviderFactory.create(baseConfig.copyWith(providerName: 'openrouter'))
            as OpenRouterProvider;
    expect(provider.baseUrl, 'https://openrouter.ai/api/v1/chat/completions');
  });

  test('creates OpenAiProvider with ollama base url for ollama provider', () {
    final provider =
        ProviderFactory.create(baseConfig.copyWith(providerName: 'ollama'))
            as OpenAiProvider;
    expect(provider.baseUrl, 'http://localhost:11434/v1/chat/completions');
  });

  test('honors explicit base url', () {
    final provider =
        ProviderFactory.create(
              baseConfig.copyWith(
                baseUrl: 'https://custom.example.com/v1/chat/completions',
              ),
            )
            as OpenAiProvider;
    expect(provider.baseUrl, 'https://custom.example.com/v1/chat/completions');
  });
}
