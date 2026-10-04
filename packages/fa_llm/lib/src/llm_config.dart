import 'llm_config_env.dart' if (dart.library.html) 'llm_config_env_stub.dart';

/// Configuration values for LLM providers.
///
/// Each value resolves in order: the matching explicit argument of
/// [LlmConfig.fromEnvironment], then the `{PROVIDER}_…` environment variable,
/// then the same name in a project-root `.env` file, then the built-in
/// default. `PROVIDER` is `OPENAI` (the default provider), `OPENROUTER`, or
/// `OLLAMA`; the variables are `{PROVIDER}_API_KEY`, `{PROVIDER}_MODEL`,
/// `{PROVIDER}_BASE_PATH`, `{PROVIDER}_BASE_URL`, `{PROVIDER}_MAX_TOKENS`,
/// `{PROVIDER}_CONTEXT_WINDOW`, `{PROVIDER}_TEMPERATURE`, and
/// `{PROVIDER}_MAX_TOKENS_PARAM_NAME`. `{PROVIDER}_BASE_PATH` wins over
/// `{PROVIDER}_BASE_URL` when both are set.
///
/// For the OpenAI-compatible providers (`openai`, `openrouter`, `ollama`) a
/// base URL — an explicit `baseUrl` argument or a `{PROVIDER}_BASE_PATH` /
/// `{PROVIDER}_BASE_URL` value — may be a bare origin
/// (`http://127.0.0.1:8931`) or a versioned base
/// (`http://127.0.0.1:8931/v1`); it is normalized to the full
/// chat-completions endpoint the providers POST to
/// (`…/v1/chat/completions`), so a local proxy can be pointed at with its
/// origin alone — a superset of the `OPENAI_BASE_URL` versioned-base
/// convention in the OpenAI SDKs. Anything else passes through verbatim: a
/// full endpoint, a custom gateway path, a URL carrying a query string. An
/// empty value is left empty (the provider factory then applies its
/// per-provider default endpoint), and the `copilot` provider speaks its own
/// dialect — its base URL is an API origin and is never rewritten.
class LlmConfig {
  final String providerName;
  final String apiKey;
  final String baseUrl;
  final String model;

  /// Maximum number of tokens the model is allowed to generate in a single
  /// response. This is the `max_tokens` / `max_completion_tokens` parameter.
  ///
  /// When `null` the limit is not sent to the provider, letting the model use
  /// its own default.
  final int? maxTokens;

  /// Total context-window size (input + output tokens). Defaults to 4096 for
  /// providers that do not expose a separate context length.
  final int contextWindow;

  final double temperature;
  final String maxTokensParamName;

  /// Copilot plan name ('individual' | 'business' | 'enterprise') for the
  /// `copilot` provider; ignored by other providers.
  final String? accountType;

  /// Named multi-account entry (e.g. `copilot-<login>`) selecting the
  /// secure-store key for the `copilot` provider.
  final String? entryName;

  const LlmConfig({
    required this.providerName,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    this.maxTokens,
    int? contextWindow,
    this.temperature = -1,
    this.maxTokensParamName = 'max_completion_tokens',
    this.accountType,
    this.entryName,
  }) : contextWindow = contextWindow ?? 4096;
  factory LlmConfig.fromEnvironment({
    String provider = 'openai',
    String? apiKey,
    String? baseUrl,
    String? model,
    int? maxTokens,
    double? temperature,
    String? maxTokensParamName,
    Map<String, String>? environmentOverride,
    Map<String, String>? dotEnvOverride,
  }) {
    final env = environmentOverride ?? systemEnvironment;
    final dotEnv = dotEnvOverride ?? loadDotEnvValues();
    final resolvedProvider = provider.toLowerCase();

    String providerPrefix(String key) {
      switch (resolvedProvider) {
        case 'openrouter':
          return 'OPENROUTER';
        case 'ollama':
          return 'OLLAMA';
        case 'openai':
        default:
          return 'OPENAI';
      }
    }

    String? envKey(String key) {
      final prefix = providerPrefix(key);
      final envValue =
          env['${prefix}_$key'] ?? env['${prefix}_${key.toUpperCase()}'];
      if (envValue != null && envValue.isNotEmpty) return envValue;

      final dotEnvValue =
          dotEnv['${prefix}_$key'] ?? dotEnv['${prefix}_${key.toUpperCase()}'];
      if (dotEnvValue != null && dotEnvValue.isNotEmpty) return dotEnvValue;

      return null;
    }

    String defaultBaseUrl() {
      switch (resolvedProvider) {
        case 'openrouter':
          return 'https://openrouter.ai/api/v1/chat/completions';
        case 'ollama':
          return 'https://ollama.com/v1/chat/completions';
        case 'openai':
        default:
          return 'https://api.openai.com/v1/chat/completions';
      }
    }

    // For the OpenAI-compatible dialects a bare origin or versioned base is
    // an alias for the full endpoint; anything else — a full endpoint, a
    // custom gateway path, a URL with a query string — passes through
    // verbatim. copilot's base is an API origin in its own dialect and is
    // never rewritten.
    String fullEndpoint(String url) {
      final uri = Uri.tryParse(url);
      if (uri == null || uri.hasQuery || uri.hasFragment) return url;
      final base = url.replaceAll(RegExp(r'/+$'), '');
      if (base.endsWith('/chat/completions')) return base;
      if (base.endsWith('/v1')) return '$base/chat/completions';
      if (uri.path.isEmpty || uri.path == '/') {
        return '$base/v1/chat/completions';
      }
      return url;
    }

    var resolvedBaseUrl =
        baseUrl ??
        envKey('BASE_PATH') ??
        envKey('BASE_URL') ??
        defaultBaseUrl();
    // Empty is left empty: the provider factory maps it to the provider's
    // default endpoint.
    if (resolvedProvider != 'copilot' && resolvedBaseUrl.isNotEmpty) {
      resolvedBaseUrl = fullEndpoint(resolvedBaseUrl);
    }

    return LlmConfig(
      providerName: resolvedProvider,
      apiKey: apiKey ?? envKey('API_KEY') ?? '',
      baseUrl: resolvedBaseUrl,
      model: model ?? envKey('MODEL') ?? '',
      maxTokens: maxTokens ?? int.tryParse(envKey('MAX_TOKENS') ?? ''),
      contextWindow: int.tryParse(envKey('CONTEXT_WINDOW') ?? ''),
      temperature:
          temperature ?? double.tryParse(envKey('TEMPERATURE') ?? '') ?? -1,
      maxTokensParamName:
          maxTokensParamName ??
          (envKey('MAX_TOKENS_PARAM_NAME')?.isNotEmpty == true
              ? envKey('MAX_TOKENS_PARAM_NAME')!
              : 'max_completion_tokens'),
    );
  }

  bool get isConfigured => apiKey.isNotEmpty && model.isNotEmpty;

  LlmConfig copyWith({
    String? providerName,
    String? apiKey,
    String? baseUrl,
    String? model,
    int? maxTokens,
    int? contextWindow,
    double? temperature,
    String? maxTokensParamName,
    String? accountType,
    String? entryName,
  }) {
    // crap:ignore: hand-rolled copyWith boilerplate (the idiomatic Dart shape every immutable config type here shares); codegen is the real fix — gh-1106.
    return LlmConfig(
      providerName: providerName ?? this.providerName,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      maxTokens: maxTokens ?? this.maxTokens,
      contextWindow: contextWindow ?? this.contextWindow,
      temperature: temperature ?? this.temperature,
      maxTokensParamName: maxTokensParamName ?? this.maxTokensParamName,
      accountType: accountType ?? this.accountType,
      entryName: entryName ?? this.entryName,
    );
  }
}
