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
import '../providers/aiin_auth.dart';
import '../providers/chatgpt_codex.dart';
import '../providers/chatgpt_oauth.dart';
import '../providers/codemie_sso.dart';
import '../providers/copilot.dart';
import '../providers/copilot_oauth.dart';
import '../providers/transient_retry_stream.dart';
import '../providers/dial.dart';
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
    this.visible = true,
  });

  /// Canonical provider name (e.g. `openrouter`, `anthropic`).
  final String name;

  /// Adapter kind consumed by [providerStreamFunction]:
  /// `openai-completions`, `anthropic`, `google`, `dial`, or
  /// `chatgpt-codex`.
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

  /// Whether this provider shows in the CLI/app provider pickers.
  final bool visible;
}

/// The built-in provider table.
///
/// **Build-time provider filtering:** the `FA_PROVIDERS` dart-define
/// restricts the binary to a subset of providers —
/// `dart compile exe -DFA_PROVIDERS=dial,codemie` builds a CLI that offers
/// ONLY those (plus saved custom openai-like endpoints; `custom` is always
/// available). Unset or `all` keeps every provider. The [ProviderSpec] map
/// itself stays complete (adapters, tests, config parsing unchanged); the
/// filter applies at every user-facing surface: the catalog lookups
/// ([catalogProvider]), the CLI pickers, `/provider` status, the model
/// pickers, and key-name collection.
const providerCatalog = <String, ProviderSpec>{
  'aiin': ProviderSpec(
    name: 'aiin',
    // Own kind (the minimax/zai pattern) so `--provider aiin` and the parity
    // guards treat AIIN as a first-class provider; chat is OpenAI-compatible,
    // so providerStreamFunction routes it to the OpenAI completions adapter.
    kind: 'aiin',
    api: 'openai-completions',
    defaultBaseUrl: '$aiinApiBaseUrl/v1',
    apiKeyEnvNames: ['AIIN_API_KEY'],
    contextWindow: 200000,
    maxTokens: 16384,
  ),
  'openrouter': ProviderSpec(
    name: 'openrouter',
    kind: 'openai-completions',
    api: 'openai-completions',
    defaultBaseUrl: 'https://openrouter.ai/api/v1',
    apiKeyEnvNames: ['OPENROUTER_API_KEY', 'OPENAI_API_KEY'],
    contextWindow: 200000,
    maxTokens: 16384,
  ),
  'kimi': ProviderSpec(
    name: 'kimi',
    kind: 'openai-completions',
    api: 'openai-completions',
    defaultBaseUrl: 'https://api.kimi.com/coding/v1',
    apiKeyEnvNames: ['KIMI_API_KEY', 'OPENAI_API_KEY'],
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

  'copilot': ProviderSpec(
    name: 'copilot',
    kind: 'copilot',
    api: 'openai-completions',
    defaultBaseUrl: copilotIndividualBaseUrl,
    apiKeyEnvNames: ['COPILOT_GITHUB_TOKEN'],
    contextWindow: 1000000,
    maxTokens: 32768,
  ),
  'codemie': ProviderSpec(
    name: 'codemie',
    kind: 'openai-completions',
    api: 'openai-completions',
    defaultBaseUrl: '$defaultCodeMieBaseUrl/code-assistant-api/v1',
    apiKeyEnvNames: ['CODEMIE_API_KEY'],
    contextWindow: 200000,
    maxTokens: 16384,
  ),
  'dial': ProviderSpec(
    name: 'dial',
    kind: 'dial',
    api: 'openai-completions',
    defaultBaseUrl: 'https://ai-proxy.lab.epam.com',
    apiKeyEnvNames: ['DIAL_API_KEY'],
    contextWindow: 200000,
    maxTokens: 16384,
  ),
  'minimax': ProviderSpec(
    name: 'minimax',
    // Chat is OpenAI-compatible (MiniMax-M3 works via the OpenAI completions
    // adapter, including vision); image generation uses a separate dialect
    // handled in generate_image.dart (detected by the baseUrl marker). The
    // kind is its own so `--provider minimax` and the parity guards treat it
    // as a first-class provider; providerStreamFunction routes it to the
    // OpenAI completions adapter.
    kind: 'minimax',
    api: 'openai-completions',
    defaultBaseUrl: 'https://api.minimax.io/v1',
    apiKeyEnvNames: ['MINIMAX_API_KEY'],
    contextWindow: 200000,
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
  'zai': ProviderSpec(
    name: 'zai',
    // Own kind (the minimax pattern) so `--provider zai` and the parity
    // guards treat Z.AI as a first-class provider; chat is OpenAI-
    // compatible, so providerStreamFunction routes it to the OpenAI
    // completions adapter.
    kind: 'zai',
    api: 'openai-completions',
    // The CODING plan endpoint — the plain /api/paas/v4 root serves a
    // different, non-agentic model set.
    defaultBaseUrl: 'https://api.z.ai/api/coding/paas/v4',
    apiKeyEnvNames: ['ZAI_API_KEY', 'Z_AI_API_KEY'],
    contextWindow: 200000,
    maxTokens: 16384,
    // glm-5.3 (the coding endpoint's flagship) is text-only; the per-id
    // vision heuristic covers the `...v` variants when one is selected.
    input: ['text'],
  ),
};

/// The `FA_PROVIDERS` dart-define value: a comma-separated allowlist of
/// provider names, `all`/empty for everything. Compile-time constant so
/// filtered-out adapters still tree-shake out of a `dart compile` build.
/// Set via the CI/build system: the native-binaries workflow passes it as
/// `-DFA_PROVIDERS=...` on the compile step.
const _faProvidersDefine = String.fromEnvironment('FA_PROVIDERS');

/// The runtime `FA_PROVIDERS` environment variable, resolved by the host
/// (bin/fah.dart or the app wiring) and injected once at startup. The
/// compile-time define WINS over this runtime value when both are set.
/// Unset (`null`) on hosts without a concept of process env (web).
String? providerFilterEnvOverride;

/// Whether [name] survives the provider filter (see [providerCatalog]).
/// `true` for every name without a filter.
///
/// Filter precedence: the `FA_PROVIDERS` dart-define first (immutable,
/// tree-shakable), then the runtime env override ([providerFilterEnvOverride],
/// set from the process environment by the host at startup). Values: an
/// empty/`all`/`*` value keeps every provider; anything else is a
/// comma-separated name allowlist.
bool providerEnabledInBuild(String name) {
  final define = _faProvidersDefine.isNotEmpty
      ? _faProvidersDefine
      : (providerFilterEnvOverride ?? '');
  if (define.isEmpty || define == 'all' || define == '*') return true;
  final allowed = define
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty);
  return allowed.contains(name.trim().toLowerCase());
}

/// The build-enabled subset of the catalog (insertion order preserved).
/// Without `FA_PROVIDERS` this is the whole table; `visible: false`
/// entries are excluded regardless of the filter.
List<ProviderSpec> enabledProviders() => [
  for (final spec in providerCatalog.values)
    if (spec.visible && providerEnabledInBuild(spec.name)) spec,
];

/// The build-enabled provider names (`enabledProviders` in name form).
List<String> enabledProviderNames() => [
  for (final spec in enabledProviders()) spec.name,
];

/// Resolves [name] against the [providerCatalog], honoring the build-time
/// provider filter (`FA_PROVIDERS` — filtered names resolve to null and the
/// error paths list only the enabled providers).
///
/// The legacy CLI kind `openai-completions` is accepted as an alias for
/// `openrouter` (its historical default endpoint).
ProviderSpec? catalogProvider(String name) {
  final normalized = name.trim().toLowerCase();
  if (normalized == 'openai-completions' &&
      providerEnabledInBuild('openrouter')) {
    return providerCatalog['openrouter'];
  }
  final spec = providerCatalog[normalized];
  if (spec == null || !providerEnabledInBuild(spec.name)) return null;
  return spec;
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

/// Providers carry NO default model: a model is always an explicit choice
/// (`--model`, a saved switch, a roles chain, or a picker's live `/models`
/// list). Silent defaults chose paid flagships over free tiers behind the
/// user's back (zai's `glm-5.3` vs `glm-5.3-flash` — real spend nobody
/// ordered), so the mechanism was removed, not re-seeded.
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
    'aiin' => providerCatalog['aiin']!,
    'anthropic' => providerCatalog['anthropic']!,
    'google' => providerCatalog['google']!,
    'dial' => providerCatalog['dial']!,
    'minimax' => providerCatalog['minimax']!,
    'zai' => providerCatalog['zai']!,
    'copilot' => providerCatalog['copilot']!,
    'openai-completions' || 'openrouter' =>
      baseUrl == null
          ? providerCatalog['openrouter']!
          : providerCatalog['openai']!,
    _ => throw ConfigException('unknown provider: $providerKind'),
  };

  final id = modelId;
  if (id == null) {
    // No provider has a default model — the choice is always explicit.
    throw ConfigException('provider "$providerKind" requires --model <id>');
  }
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
/// (`openai-completions`, `minimax`, `zai`, `anthropic`, `google`, `dial`,
/// `chatgpt-codex`, `copilot`)
/// with a static [apiKey]. Throws [ConfigException] for unknown kinds.
///
/// [sessionId] (resolved lazily per call) is the prompt-cache affinity key
/// threaded to adapters that support one (OpenAI `prompt_cache_key`,
/// OpenRouter `x-session-id`); [cacheRetention] sets the adapters' cache
/// retention (`short`/`long`/`none`, adapter default when null). Both are
/// defaults: an active [StreamCacheRouting] override (the compaction
/// bypass) wins per call. [dialApiVersion] is the DIAL `api-version` query
/// parameter (the `dial` kind only; omitted when null).
StreamFunction providerStreamFunction(
  String kind,
  String apiKey, {
  String? Function()? sessionId,
  String? cacheRetention,
  String? dialApiVersion,
  bool? dialCacheMarkersSupported,
  ChatGptCredentialsPersist? onChatGptCredentialsRefreshed,
}) {
  if (kind != 'openai-completions' &&
      kind != 'anthropic' &&
      kind != 'google' &&
      kind != 'dial' &&
      kind != 'minimax' &&
      kind != 'zai' &&
      kind != 'aiin' &&
      kind != 'chatgpt-codex' &&
      kind != 'copilot') {
    throw ConfigException('Unknown provider kind: $kind');
  }
  // ignore: implicit_call_tearoffs
  final inner = _CatalogStreamFunction(
    kind,
    apiKey,
    sessionId,
    cacheRetention,
    dialApiVersion,
    dialCacheMarkersSupported,
    onChatGptCredentialsRefreshed,
  );
  // Every provider call (chat turns, compaction summaries, memory
  // extraction, media) rides the transient-network retry: a Wi-Fi switch
  // mid-turn dies with "Connection reset by peer" — sleep, replay.
  return transientRetryStreamFunction(inner.call);
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
    this._dialApiVersion,
    this._dialCacheMarkersSupported,
    this._onChatGptCredentialsRefreshed,
  );

  final String _kind;
  final String _apiKey;
  final String? Function()? _sessionId;
  final String? _cacheRetention;
  final String? _dialApiVersion;
  final bool? _dialCacheMarkersSupported;
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
      'openai-completions' || 'minimax' || 'zai' || 'aiin' => streamOpenAICompletions(
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
      'dial' => streamDial(
        model,
        context,
        DialOptions(
          apiKey: _apiKey,
          apiVersion: _dialApiVersion,
          cancelToken: cancelToken,
          sessionId: effectiveSessionId,
          cacheRetention: effectiveRetention,
          cacheMarkersSupported: _dialCacheMarkersSupported,
        ),
      ),
      'copilot' => streamCopilot(
        model,
        context,
        CopilotOptions(
          githubToken: _apiKey,
          cancelToken: cancelToken,
          sessionId: effectiveSessionId,
          cacheRetention: effectiveRetention,
        ),
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
