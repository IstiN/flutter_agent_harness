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

/// The compaction window sizing + the auto-compact trigger — extension on
/// [AgentService] living in this part to keep the main file under the
/// 2800-line guard (same library, so private members resolve).
extension CompactionWindowSizing on AgentService {
  /// Compaction thresholds for the active model, scaled by
  /// [CompactionSettings.forWindow] to the conversation window (the model's
  /// context window minus the system-prompt overhead). pi's fixed defaults
  /// exceed the whole window of an on-device model, so the same settings
  /// cannot serve hosted 128k models and 8k WebLLM presets.
  CompactionSettings get compactionSettings =>
      CompactionSettings.forWindow(_conversationWindow);

  /// The window left for the conversation after [_systemOverheadTokens];
  /// `0` when the prompt alone exhausts the model window (compaction then
  /// has nothing sensible to plan against).
  int get _conversationWindow {
    final window = _agent.state.model.contextWindow - _systemOverheadTokens;
    return window > 0 ? window : 0;
  }

  /// Estimated tokens the provider counts against the context window on top
  /// of the transcript: the rendered system prompt plus — for the chat-only
  /// on-device backends (WebLLM, transformers.js), whose stream functions
  /// run through the prompt-tools wrapper — the tool instructions appended
  /// to that prompt. The wrapper's instruction block outweighs the base
  /// system prompt several times over, so ignoring it would size compaction
  /// against a window the engine does not actually have.
  int get _systemOverheadTokens {
    var system = _agent.state.systemPrompt;
    if (_providerKind == webLlmProviderKind ||
        _providerKind == transformersJsProviderKind) {
      system = '$system\n\n${promptToolInstructions(_agent.state.tools)}';
    }
    return estimateTokens(UserMessage.text(system));
  }

  /// Auto-compaction after each completed run (CLI parity): the shared
  /// [AutoCompactor] in core drives the multi-pass loop + smol→main
  /// fallback + transient retry. This wrapper only builds the per-host
  /// smol/main summarizers and the [AutoCompactorHooks] that mirrors the
  /// compacted transcript into the chat list.
  Future<bool> _maybeAutoCompact() async {
    final conversationWindow = _conversationWindow;
    if (_session == null || conversationWindow <= 0) return false;
    final settings = compactionSettings;
    final transcriptTokens = estimateContextTokens(
      _agent.state.messages,
    ).tokens;
    if (!shouldCompact(transcriptTokens, conversationWindow, settings)) {
      return false;
    }
    // The whole transcript fits in the kept region: compaction could not
    // drop anything. (A single oversized message can still overflow the
    // engine — that surfaces as a readable run error, not a compaction
    // loop.)
    if (transcriptTokens <= settings.keepRecentTokens) return false;

    // Resolve the smol summarizer from the task-models store, or fall
    // back to the main stream. The harness core doesn't know about
    // TaskModelsStore — only the host does.
    final smolConfig = _taskModelsStore?.overrideFor(TaskRole.smol);
    StreamFunction? smolStream;
    Model? smolModel;
    if (smolConfig != null && smolConfig.modelId.isNotEmpty) {
      var apiKey = _activeApiKey;
      final keyName = smolConfig.apiKeyName;
      if (keyName != null && keyName.isNotEmpty) {
        final resolved = _secretsEnv != null
            ? _secretsEnv.secretsSnapshot()[keyName]
            : null;
        if (resolved != null && resolved.isNotEmpty) apiKey = resolved;
      }
      smolModel = Model(
        id: smolConfig.modelId,
        name: smolConfig.modelId,
        api: _agent.state.model.api,
        provider: _agent.state.model.provider,
        baseUrl: smolConfig.baseUrl,
        contextWindow: _agent.state.model.contextWindow,
        maxTokens: _agent.state.model.maxTokens,
        input: _agent.state.model.input,
      );
      smolStream = providerStreamFunction(smolConfig.providerKind, apiKey);
    }

    await AutoCompactorFactory(
      session: _session!,
      state: _agent.state,
      window: conversationWindow,
      settings: settings,
      sources: AutoCompactorSources(
        smolStream: smolStream,
        smolModel: smolModel,
        mainStream: _agent.streamFunction,
        mainModel: _agent.state.model,
      ),
      hooks: const _AutoCompactorFlutterHooks(),
      prompts: const CompactionPrompts(),
      // The engine rides the same config chain as the CLI (issue #148
      // D8): project .fah/config.yaml < ~/.fah/config.yaml, default
      // classic. Resolved per compaction so edits apply without a
      // restart.
      engine:
          loadAppCompactionEngine(env.sessionCwd) ?? CompactionEngine.classic,
    ).run();

    // The AutoCompactor replaces `state.messages` on success; mirror
    // that into the chat list so the UI reflects the new transcript.
    _persistedCount = _agent.state.messages.length;
    messages
      ..clear()
      ..addAll(_agent.state.messages.map(AgentService._toChatMessage));
    // Extensions may not call the protected notifyListeners — _notify is
    // the class's own one-line wrapper, in scope via the same library.
    _notify();
    // Success signal for the over-window guard's auto-continuation: the
    // transcript actually shrank.
    final afterTokens = estimateContextTokens(_agent.state.messages).tokens;
    return afterTokens < transcriptTokens;
  }
}
