import 'openai_provider.dart';

/// OpenRouter provider.
///
/// OpenRouter exposes an OpenAI-compatible chat completions endpoint but
/// requires extra identification headers (`HTTP-Referer` and `X-Title`).
class OpenRouterProvider extends OpenAiProvider {
  OpenRouterProvider({
    required super.apiKey,
    super.baseUrl = 'https://openrouter.ai/api/v1/chat/completions',
    required super.defaultModel,
    super.maxTokens,
    super.temperature,
    super.maxTokensParamName,
    super.client,
    String referer = 'https://github.com/IstiN/flutter_agent_memory',
    String appTitle = 'flutter_agent_memory',
  }) : super(customHeaders: {'HTTP-Referer': referer, 'X-Title': appTitle});
}
