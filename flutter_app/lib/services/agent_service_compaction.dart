// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of agent_service.dart: top-level helpers and the trailing compaction
// hooks / store-view classes live here so the main file stays under the
// 2800-line guard. Same library, so private members resolve.

part of 'agent_service.dart';

/// Configuration needed to talk to a provider.
final class AgentConfig {
  AgentConfig({
    required this.providerKind,
    required this.modelId,
    required this.baseUrl,
    required this.apiKey,
    this.systemPrompt,
    this.contextWindow = fallbackContextWindow,
    this.maxTokens = fallbackMaxTokens,
    this.supportsImages,
  });

  /// Provider adapter kind: `openai-completions`, `anthropic`, `google`,
  /// `webllm` (on-device, web — see `lib/webllm/`), `gemma` (on-device,
  /// iOS/Android — see `lib/gemma/`), or `transformers_js` (on-device, web —
  /// see `lib/transformers_js/`).
  final String providerKind;

  /// Model id passed to the provider.
  final String modelId;

  /// Provider base URL (e.g. OpenRouter `https://openrouter.ai/api/v1`).
  /// Empty for on-device providers.
  final String baseUrl;

  /// API key for the provider. Empty for on-device providers.
  final String apiKey;

  /// Optional system prompt override.
  final String? systemPrompt;

  /// Context window reported to the agent loop (drives overflow/compaction
  /// heuristics). Small for on-device models.
  final int contextWindow;

  /// Output-token cap reported to the agent loop.
  final int maxTokens;

  /// Whether the model accepts image input. When null (session restores,
  /// tests, programmatic configs) the vision heuristic
  /// [modelIdSuggestsVision] decides from [modelId]; the settings form
  /// passes the user's explicit checkbox value.
  final bool? supportsImages;

  /// A copy with a different model id — used when a persisted session
  /// records the model it was run with (CLI sessions carry it in their
  /// metadata): reopening the session must run THAT model, not the
  /// default chat model.
  AgentConfig withModelId(String id) => AgentConfig(
    providerKind: providerKind,
    modelId: id,
    baseUrl: baseUrl,
    apiKey: apiKey,
    systemPrompt: systemPrompt,
    contextWindow: contextWindow,
    maxTokens: maxTokens,
    supportsImages: supportsImages,
  );

  Model toModel() => Model(
    id: modelId,
    name: modelId,
    api: providerKind,
    provider: providerKind,
    baseUrl: baseUrl,
    contextWindow: contextWindow,
    maxTokens: maxTokens,
    // CodeMie authenticates via cookies: the stored apiKey is the full
    // cookie string, which rides in model.headers as a `cookie` entry. The
    // openai-completions adapter skips `Authorization: Bearer` when the key
    // is empty, so the cookie is the sole auth credential.
    headers: isCodeMieProvider(baseUrl) && apiKey.isNotEmpty
        ? {'cookie': apiKey}
        : null,
    input: [
      'text',
      if (supportsImages ?? modelIdSuggestsVision(modelId)) 'image',
    ],
  );
}

/// A UI-facing chat message: one of `user`, `assistant`, `thinking`,
/// `tool`, `system`. Alias of the shared fa_ui type — new code should use
/// [FaChatMessage] directly.
typedef FahChatMessage = FaChatMessage;

/// Whether [baseUrl] points at a CodeMie organization (SSO/cookie-based
/// auth). CodeMie providers authenticate via the full cookie string sent as
/// a `Cookie:` header (riding in [Model.headers]) instead of a Bearer key —

/// [AutoCompactorHooks] impl for the Flutter chat sheet. The chat list is
/// rebuilt from `state.messages` at the end of [AutoCompactor.run], so
/// hooks only need to drive per-pass UX (silent here — chat doesn't
/// surface each pass).
class _AutoCompactorFlutterHooks implements AutoCompactorHooks {
  const _AutoCompactorFlutterHooks();

  @override
  void onDelta(String delta) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}

  @override
  void onPass(AutoCompactorPass pass) {}

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens) {}

  @override
  void onBothRolesFailed(Object lastError) {
    // Surfaced via the next run's run-error stream; chat list keeps its
    // current view.
  }
}

/// A live [Map] view of the [TaskModelsStore]'s role overrides in
/// `roles:` config shape. Reads through on every access, so settings edits
/// resolve on the next `task` spawn without rebuilding the agent (used by
/// [_taskRolesResolver]).
final class _StoreBackedRolesMap
    with MapMixin<String, List<ModelRef>>
    implements Map<String, List<ModelRef>> {
  _StoreBackedRolesMap(this._store);

  final TaskModelsStore _store;

  @override
  List<ModelRef>? operator [](Object? key) {
    if (key is! String) return null;
    final config = _store.overrideFor(key);
    if (config == null) return null;
    return [
      ModelRef(
        provider: config.providerKind,
        modelId: config.modelId,
        apiKeyName: config.apiKeyName,
        baseUrl: config.baseUrl,
      ),
    ];
  }

  @override
  Iterable<String> get keys => _store.configuredRoles.toList(growable: false);

  @override
  void operator []=(String key, List<ModelRef> value) =>
      throw UnsupportedError('read-only');

  @override
  void clear() => throw UnsupportedError('read-only');

  @override
  List<ModelRef>? remove(Object? key) => throw UnsupportedError('read-only');
}
