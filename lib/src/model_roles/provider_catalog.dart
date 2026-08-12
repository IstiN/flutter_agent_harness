/// The provider catalog: the small static table mapping provider names to
/// their adapter kind, default base URL, API-key env names, and model
/// defaults.
///
/// Shared by the model-roles resolver (which builds chain entries from
/// config) and the `fah` executable (which builds its legacy single model
/// from CLI flags), so provider defaults live in exactly one place.
library;

import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../exceptions.dart';
import '../model.dart';
import '../providers/anthropic.dart';
import '../providers/chatgpt_codex.dart';
import '../providers/chatgpt_oauth.dart';
import '../providers/google.dart';
import '../providers/openai_completions.dart';

/// Static description of a supported provider.
final class ProviderSpec {
  /// Creates a provider spec.
  const ProviderSpec({
    required this.name,
    required this.kind,
    required this.api,
    required this.defaultBaseUrl,
    required this.apiKeyEnvNames,
    required this.contextWindow,
    required this.maxTokens,
    this.reasoning = true,
    this.input = const ['text', 'image'],
  });

  /// Canonical provider name (e.g. `openrouter`, `anthropic`).
  final String name;

  /// Adapter kind consumed by [providerStreamFunction]:
  /// `openai-completions`, `anthropic`, or `google`.
  final String kind;

  /// The API dialect recorded on built models (e.g. `anthropic-messages`).
  final String api;

  /// Default API base URL.
  final String defaultBaseUrl;

  /// API-key base names, in preference order. The first present in the
  /// secrets store wins; rotation stacks `_2`, `_3`, ... suffixes on the
  /// chosen base name.
  final List<String> apiKeyEnvNames;

  /// Default total context window in tokens.
  final int contextWindow;

  /// Default maximum output tokens.
  final int maxTokens;

  /// Whether models on this provider default to reasoning output.
  final bool reasoning;

  /// Default input modalities.
  final List<String> input;
}

/// The built-in provider table.
const providerCatalog = <String, ProviderSpec>{
  'openrouter': ProviderSpec(
    name: 'openrouter',
    kind: 'openai-completions',
    api: 'openai-completions',
    defaultBaseUrl: 'https://openrouter.ai/api/v1',
    apiKeyEnvNames: ['OPENROUTER_API_KEY', 'OPENAI_API_KEY'],
    contextWindow: 200000,
    maxTokens: 16384,
  ),
  'openai': ProviderSpec(
    name: 'openai',
    kind: 'openai-completions',
    api: 'openai-completions',
    defaultBaseUrl: 'https://api.openai.com/v1',
    apiKeyEnvNames: ['OPENAI_API_KEY'],
    contextWindow: 200000,
    maxTokens: 16384,
  ),
  'chatgpt': ProviderSpec(
    name: 'chatgpt',
    kind: 'chatgpt-codex',
    api: 'responses',
    defaultBaseUrl: chatGptCodexBaseUrl,
    apiKeyEnvNames: ['CHATGPT_OAUTH_CREDENTIALS'],
    contextWindow: 128000,
    maxTokens: 16384,
  ),
  'anthropic': ProviderSpec(
    name: 'anthropic',
    kind: 'anthropic',
    api: 'anthropic-messages',
    defaultBaseUrl: 'https://api.anthropic.com',
    apiKeyEnvNames: ['ANTHROPIC_API_KEY'],
    contextWindow: 200000,
    maxTokens: 16384,
  ),
  'google': ProviderSpec(
    name: 'google',
    kind: 'google',
    api: 'google-generative-ai',
    defaultBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    apiKeyEnvNames: ['GOOGLE_API_KEY'],
    contextWindow: 1000000,
    maxTokens: 16384,
  ),
};

/// Resolves [name] against the [providerCatalog].
///
/// The legacy CLI kind `openai-completions` is accepted as an alias for
/// `openrouter` (its historical default endpoint).
ProviderSpec? catalogProvider(String name) {
  final normalized = name.trim().toLowerCase();
  if (normalized == 'openai-completions') return providerCatalog['openrouter'];
  return providerCatalog[normalized];
}

/// Builds a [Model] for [provider]/[modelId] with catalog defaults, overrid-
/// able per reference (see `ModelRef`).
///
/// Throws [ConfigException] for unknown providers.
Model buildCatalogModel(
  String provider,
  String modelId, {
  String? baseUrl,
  int? contextWindow,
  int? maxTokens,
}) {
  final spec = catalogProvider(provider);
  if (spec == null) {
    throw ConfigException(
      'unknown provider "$provider" — supported providers: '
      '${providerCatalog.keys.join(', ')}',
    );
  }
  return Model(
    id: modelId,
    name: modelId,
    api: spec.api,
    provider: spec.name,
    baseUrl: baseUrl ?? spec.defaultBaseUrl,
    reasoning: spec.reasoning,
    input: spec.input,
    contextWindow: contextWindow ?? spec.contextWindow,
    maxTokens: maxTokens ?? spec.maxTokens,
  );
}

/// Builds the legacy single [Model] the `fah` executable runs when no roles
/// are configured (`--provider`/`--model`/`--base-url` flags).
///
/// Historical behavior preserved: `openai-completions` with a custom
/// [baseUrl] reports provider `openai` instead of `openrouter`.
Model buildCliDefaultModel(
  String providerKind, {
  String? modelId,
  String? baseUrl,
}) {
  final spec = switch (providerKind) {
    'anthropic' => providerCatalog['anthropic']!,
    'google' => providerCatalog['google']!,
    'openai-completions' || 'openrouter' =>
      baseUrl == null
          ? providerCatalog['openrouter']!
          : providerCatalog['openai']!,
    _ => throw ConfigException('unknown provider: $providerKind'),
  };
  const defaultIds = {
    'anthropic': 'claude-sonnet-4-5',
    'google': 'gemini-2.5-pro',
    'openai-completions': 'anthropic/claude-sonnet-4',
  };
  final id = modelId ?? defaultIds[spec.kind]!;
  return Model(
    id: id,
    name: id,
    api: spec.api,
    provider: spec.name,
    baseUrl: baseUrl ?? spec.defaultBaseUrl,
    reasoning: spec.reasoning,
    input: spec.input,
    contextWindow: spec.contextWindow,
    maxTokens: spec.maxTokens,
  );
}

/// Builds the [StreamFunction] for a provider adapter [kind]
/// (`openai-completions`, `anthropic`, `google`) with a static [apiKey].
/// Throws [ConfigException] for unknown kinds.
///
/// [sessionId] (resolved lazily per call) is the prompt-cache affinity key
/// threaded to adapters that support one (OpenAI `prompt_cache_key`,
/// OpenRouter `x-session-id`); [cacheRetention] sets the adapters' cache
/// retention (`short`/`long`/`none`, adapter default when null). Both are
/// defaults: an active [StreamCacheRouting] override (the compaction
/// bypass) wins per call.
StreamFunction providerStreamFunction(
  String kind,
  String apiKey, {
  String? Function()? sessionId,
  String? cacheRetention,
  ChatGptCredentialsPersist? onChatGptCredentialsRefreshed,
}) {
  if (kind != 'openai-completions' &&
      kind != 'anthropic' &&
      kind != 'google' &&
      kind != 'chatgpt-codex') {
    throw ConfigException('Unknown provider kind: $kind');
  }
  // ignore: implicit_call_tearoffs
  return _CatalogStreamFunction(
    kind,
    apiKey,
    sessionId,
    cacheRetention,
    onChatGptCredentialsRefreshed,
  );
}

/// The [providerStreamFunction] product: resolves the cache routing at call
/// time — an active [StreamCacheRouting] override first, then the factory
/// defaults — and builds the adapter options for one call.
final class _CatalogStreamFunction {
  const _CatalogStreamFunction(
    this._kind,
    this._apiKey,
    this._sessionId,
    this._cacheRetention,
    this._onChatGptCredentialsRefreshed,
  );

  final String _kind;
  final String _apiKey;
  final String? Function()? _sessionId;
  final String? _cacheRetention;
  final ChatGptCredentialsPersist? _onChatGptCredentialsRefreshed;

  /// The [StreamFunction] entry point.
  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final routing = StreamCacheRouting.current;
    final effectiveSessionId = routing?.sessionId ?? _sessionId?.call();
    final effectiveRetention = routing?.cacheRetention ?? _cacheRetention;
    return switch (_kind) {
      'openai-completions' => streamOpenAICompletions(
        model,
        context,
        OpenAICompletionsOptions(
          apiKey: _apiKey,
          cancelToken: cancelToken,
          sessionId: effectiveSessionId,
          cacheRetention: effectiveRetention,
        ),
      ),
      'anthropic' => streamAnthropic(
        model,
        context,
        AnthropicOptions(
          apiKey: _apiKey,
          cancelToken: cancelToken,
          cacheRetention: effectiveRetention,
        ),
      ),
      'google' => streamGoogle(
        model,
        context,
        GoogleOptions(apiKey: _apiKey, cancelToken: cancelToken),
      ),
      'chatgpt-codex' => streamChatGptCodex(
        model,
        context,
        credentials: _apiKey,
        onCredentialsRefreshed: _onChatGptCredentialsRefreshed,
        cancelToken: cancelToken,
      ),
      // Validated by providerStreamFunction; unreachable.
      _ => throw ConfigException('Unknown provider kind: $_kind'),
    };
  }
}
