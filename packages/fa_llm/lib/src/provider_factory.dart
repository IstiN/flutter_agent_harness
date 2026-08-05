import 'llm_config.dart';
import 'llm_provider.dart';
import 'openai_provider.dart';
import 'openrouter_provider.dart';

/// Factory for creating the default [LlmProvider] based on [LlmConfig].
///
/// The provider can be overridden by supplying a custom implementation
/// directly to [KbOrchestrator] or by registering it here.
class ProviderFactory {
  static LlmProvider create(LlmConfig config) {
    final baseUrl = _effectiveBaseUrl(config);
    switch (config.providerName) {
      case 'openrouter':
        return OpenRouterProvider(
          apiKey: config.apiKey,
          baseUrl: baseUrl,
          defaultModel: config.model,
          maxTokens: config.maxTokens,
          temperature: config.temperature,
          maxTokensParamName: config.maxTokensParamName,
        );
      case 'ollama':
        return OpenAiProvider(
          apiKey: config.apiKey,
          baseUrl: baseUrl,
          defaultModel: config.model,
          maxTokens: config.maxTokens,
          temperature: config.temperature,
          maxTokensParamName: config.maxTokensParamName,
        );
      case 'openai':
      default:
        return OpenAiProvider(
          apiKey: config.apiKey,
          baseUrl: baseUrl,
          defaultModel: config.model,
          maxTokens: config.maxTokens,
          temperature: config.temperature,
          maxTokensParamName: config.maxTokensParamName,
        );
    }
  }

  static String _effectiveBaseUrl(LlmConfig config) {
    if (config.baseUrl.isNotEmpty) return config.baseUrl;
    return switch (config.providerName) {
      'openrouter' => 'https://openrouter.ai/api/v1/chat/completions',
      'ollama' => 'http://localhost:11434/v1/chat/completions',
      _ => 'https://api.openai.com/v1/chat/completions',
    };
  }
}
