import 'package:http/http.dart' as http;

import 'copilot/copilot_endpoints.dart';
import 'copilot/copilot_provider.dart';
import 'copilot/copilot_token.dart';
import 'copilot/copilot_token_manager.dart';
import 'copilot/copilot_token_store.dart';
import 'llm_config.dart';
import 'llm_provider.dart';
import 'openai_provider.dart';
import 'openrouter_provider.dart';

/// Factory for creating the default [LlmProvider] based on [LlmConfig].
///
/// The provider can be overridden by supplying a custom implementation
/// directly to [KbOrchestrator] or by registering it here.
class ProviderFactory {
  static LlmProvider create(
    LlmConfig config, {
    CopilotTokenStore? tokenStore,
    String? entryName,
    http.Client? client,
  }) {
    final baseUrl = _effectiveBaseUrl(config);
    switch (config.providerName) {
      case 'copilot':
        return _createCopilot(
          config,
          tokenStore: tokenStore,
          entryName: entryName,
          client: client,
        );
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

  /// `copilot` branch: apiKey is the GitHub token; [entryName] selects the
  /// secure-store key at the host layer; the manager owns exchange/refresh.
  static LlmProvider _createCopilot(
    LlmConfig config, {
    CopilotTokenStore? tokenStore,
    String? entryName,
    http.Client? client,
  }) {
    final store = tokenStore ?? MemoryCopilotTokenStore();
    final entry = entryName ?? config.entryName ?? 'copilot';
    final manager = CopilotTokenManager(
      exchange: () async {
        final githubToken = await store.read(entry) ?? config.apiKey;
        return fetchCopilotToken(githubToken: githubToken, client: client);
      },
    );
    return CopilotProvider(
      token: manager.get,
      refresh: manager.getAgain,
      baseUrl: copilotBaseUrl(
        accountType: copilotAccountTypeFromName(config.accountType),
        baseUrlOverride: config.baseUrl.isEmpty ? null : config.baseUrl,
      ),
      defaultModel: config.model,
      maxTokens: config.maxTokens,
      client: client,
    );
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
