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

/// The in-chat compaction-failure notice lead (gh-1077 AC2): names WHERE
/// to fix the summarizer — the app's Quick-model slot IS the `smol` role.
/// The IT suite asserts this string; change both together.
const String appCompactionFailureNoticeLead =
    'Context compaction failed — nothing was summarized and no history '
    'was lost. Fix the summarizer in Settings → Task models → Quick '
    'model (or check the main connection key/quota).';

/// The full in-chat notice: the lead plus the underlying error.
String appCompactionFailureNotice(Object error) =>
    '$appCompactionFailureNoticeLead\n$error';

/// [AutoCompactorHooks] impl for the Flutter chat sheet. The chat list is
/// rebuilt from `state.messages` at the end of the run, so per-pass UX
/// stays silent; FAILURES are recorded and surfaced after the rebuild as
/// an in-chat system notice (gh-1077 AC2 — a failed compaction used to be
/// a silent per-turn no-op until the provider hard-overflowed).
class _AutoCompactorFlutterHooks implements AutoCompactorHooks {
  _AutoCompactorFlutterHooks(this.failures);

  /// Errors recorded via [onBothRolesFailed] — one entry per exhausted
  /// summarizer ladder. `_maybeAutoCompact` turns the last one into the
  /// chat notice once the transcript rebuild is done.
  final List<Object> failures;

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
  void onBothRolesFailed(Object lastError) => failures.add(lastError);
}

/// A live [Map] view of the [TaskModelsStore]'s role overrides in
/// `roles:` config shape. Reads through on every access, so settings edits
/// resolve on the next `task` spawn without rebuilding the agent (used by
/// [_taskRolesResolver]).
///
/// Public (gh-1077): this IS the documented app-stores → roles mapping —
/// one [ModelRef] per configured role — and the AC5 parity test drives it
/// against the CLI's roles config over the same inputs.
final class StoreBackedRolesMap
    with MapMixin<String, List<ModelRef>>
    implements Map<String, List<ModelRef>> {
  /// [fallback] carries the yaml `roles:` chains (issue #1078): a store
  /// miss reads through to it (E1 — the explicit app-UI store wins, yaml
  /// fills the gaps). The store is null when no TaskModelsStore was
  /// wired (yaml-only services).
  StoreBackedRolesMap(this._store, {Map<String, List<ModelRef>>? fallback})
    // ignore: prefer_initializing_formals
    : _fallback = fallback;

  final TaskModelsStore? _store;
  final Map<String, List<ModelRef>>? _fallback;
  @override
  List<ModelRef>? operator [](Object? key) {
    if (key is! String) return null;
    final config = _store?.overrideFor(key);
    if (config != null) {
      return [
        ModelRef(
          provider: config.providerKind,
          modelId: config.modelId,
          apiKeyName: config.apiKeyName,
          baseUrl: config.baseUrl,
        ),
      ];
    }
    return _fallback?[key];
  }

  @override
  Iterable<String> get keys => {
    ...?_store?.configuredRoles,
    ...?_fallback?.keys,
  }.toList(growable: false);

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
  /// Compaction thresholds for the active model (gh-1077): resolved by the
  /// SHARED host wiring the CLI also computes through — the effective
  /// window under the owner cap (`agent.contextWindowCap`, applied by
  /// [resolveCompactionHostWiring] via [effectiveContextWindow]), scaled by
  /// [CompactionSettings.forWindow] to the conversation window (the model's
  /// context window minus the system-prompt overhead). pi's fixed defaults
  /// exceed the whole window of an on-device model, so the same settings
  /// cannot serve hosted 128k models and 8k WebLLM presets.
  CompactionSettings get compactionSettings => _compactionWiring.settings;

  /// The host wiring for the live agent (gh-1077). The smol summarizer is
  /// resolved lazily by [_maybeAutoCompact] — a broken smol chain must not
  /// fail the pre-run gate — so it is not part of this getter. Exposed for
  /// the parity/window tests; [_conversationWindow] rides inside it.
  @visibleForTesting
  CompactionHostWiring get compactionWiringForTest => _compactionWiring;

  /// The window left for the conversation after [_systemOverheadTokens]
  /// and the owner cap; `0` when the prompt alone exhausts the model
  /// window (compaction then has nothing sensible to plan against).
  @visibleForTesting
  int get conversationWindowForTest => _compactionWiring.conversationWindow;

  CompactionHostWiring get _compactionWiring => resolveCompactionHostWiring(
    mainModel: _agent.state.model,
    contextWindowCap: _contextWindowCap,
    systemOverheadTokens: _systemOverheadTokens,
  );

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
  /// fallback + transient retry. This wrapper resolves the host wiring
  /// (gh-1077: the same shared resolution the CLI computes through),
  /// builds the per-host smol/main summarizers, and surfaces failures
  /// in-chat instead of silently no-oping.
  Future<bool> _maybeAutoCompact() async {
    final wiring = _compactionWiring;
    if (_session == null || !wiring.enabled) return false;
    final conversationWindow = wiring.conversationWindow;
    if (conversationWindow <= 0) return false;
    final settings = wiring.settings;
    // The same request-size basis as the loop's over-window guard and the
    // CLI's compaction gate: transcript estimate PLUS the system-prompt /
    // tool-schema overhead when no provider-usage anchor prices them in —
    // the threshold must trip on what the next request actually carries.
    final transcriptTokens = estimateRequestTokens(
      _agent.state.messages,
      systemPrompt: _agent.state.systemPrompt,
      tools: _agent.state.tools,
    );
    if (!shouldCompact(transcriptTokens, conversationWindow, settings)) {
      return false;
    }
    // The whole transcript fits in the kept region: compaction could not
    // drop anything. (A single oversized message can still overflow the
    // engine — that surfaces as a readable run error, not a compaction
    // loop.)
    if (transcriptTokens <= settings.keepRecentTokens) return false;

    // smol resolved AFTER the gate (CLI parity): a broken smol chain must
    // not turn every prompt into a compaction failure — only an actual
    // compaction run can, and that surfaces as the in-chat notice.
    final smolSlot = _resolveCompactionSmol();

    final failures = <Object>[];
    try {
      await AutoCompactorFactory(
        session: _session!,
        state: _agent.state,
        window: conversationWindow,
        settings: settings,
        sources: AutoCompactorSources(
          smolStream: smolSlot?.stream,
          smolModel: smolSlot?.model,
          mainStream: _agent.streamFunction,
          mainModel: _agent.state.model,
        ),
        hooks: _AutoCompactorFlutterHooks(failures),
        prompts: const CompactionPrompts(),
        // The engine rides the same config chain as the CLI (issue #148
        // D8, default flip #287): project .fah/config.yaml < ~/.fah/
        // config.yaml, default structured. Resolved per compaction so
        // edits apply without a restart (the Settings picker relies on
        // this — a flip takes effect at the NEXT compaction).
        engine:
            loadAppCompactionEngine(env.sessionCwd) ??
            CompactionEngine.structured,
      ).run();
    } on Object catch (error) {
      // A throwing run (unresolvable summarizer chain, engine crash) is a
      // compaction failure like any other: the session stays intact
      // (failure-safe append — nothing is ever lost) and the user learns
      // why instead of watching silent no-ops.
      failures.add(error);
    }

    // The AutoCompactor replaces `state.messages` on success; mirror
    // that into the chat list so the UI reflects the new transcript.
    _persistedCount = _agent.state.messages.length;
    messages
      ..clear()
      ..addAll(_agent.state.messages.map(_toChatMessage));
    // Surface the failure AFTER the rebuild so the notice is not wiped
    // (gh-1077 AC2): an in-chat system note naming where to fix the
    // summarizer, plus the debug log for post-mortems.
    if (failures.isNotEmpty) {
      final error = failures.last;
      AppLog.i('compaction', 'auto-compaction failed: $error');
      messages.add(
        FahChatMessage(
          role: 'system',
          content: appCompactionFailureNotice(error),
        ),
      );
    }
    // Extensions may not call the protected notifyListeners — _notify is
    // the class's own one-line wrapper, in scope via the same library.
    _notify();
    // Success signal for the over-window guard's auto-continuation: the
    // transcript actually shrank (same basis as the gate above).
    final afterTokens = estimateRequestTokens(
      _agent.state.messages,
      systemPrompt: _agent.state.systemPrompt,
      tools: _agent.state.tools,
    );
    return afterTokens < transcriptTokens;
  }

  /// ONE synchronous compaction for the loop's over-window guard (the
  /// issue #387 analogue, gh-1077 AC4): the guard calls this when a
  /// request is about to be refused as over-window. Returns the relieved
  /// transcript to retry with, or `null` when compaction freed nothing —
  /// the loop then surfaces its verbatim guard error. The guard bounds
  /// this to ONE attempt per response; there is no loop here either.
  Future<List<Message>?> _relieveOverWindow(List<Message> overWindow) async {
    if (_session == null) return null;
    overWindowReliefCountForTest++;
    final systemPrompt = _agent.state.systemPrompt;
    final tools = _agent.state.tools;
    final beforeTokens = estimateRequestTokens(
      overWindow,
      systemPrompt: systemPrompt,
      tools: tools,
    );
    AppLog.i('compaction', 'over-window relief start tokens=$beforeTokens');
    await _maybeAutoCompact();
    final after = _agent.state.messages.toList();
    final afterTokens = estimateRequestTokens(
      after,
      systemPrompt: systemPrompt,
      tools: tools,
    );
    if (afterTokens >= beforeTokens) {
      AppLog.i('compaction', 'over-window relief no-op');
      return null;
    }
    AppLog.i(
      'compaction',
      'over-window relief done tokens=$afterTokens (was $beforeTokens)',
    );
    return after;
  }

  /// The compaction summarizer slot (gh-1077 fix contract 1): the `smol`
  /// role resolved through the SAME [ModelRolesResolver] semantics the CLI
  /// uses — chain resolution, key rotation, the retry policy, and the
  /// main-model fallback as last resort — over the app's store-backed
  /// roles map ([StoreBackedRolesMap]). When the resolver cannot serve the
  /// store override (a provider kind the roles catalog does not know, e.g.
  /// an on-device engine), the legacy direct-store build applies; `null` =
  /// the main stream summarizes.
  HarnessLlmSlot? _resolveCompactionSmol() {
    final resolver = _taskRolesResolver;
    if (resolver != null) {
      try {
        final role = resolver.resolveRole(smolModelRole);
        if (role != null) return role;
      } on Object catch (error) {
        // A configured chain with no usable entry (missing key, unknown
        // provider): never throw out of the compaction path — fall through
        // to the legacy build; a total failure still lands in the notice.
        AppLog.i('compaction', 'smol role unresolved: $error');
      }
    }
    return _legacySmolSlotFromStore();
  }

  /// The pre-gh-1077 smol build: one Model over the store override's
  /// provider kind + endpoint, keyed by the named secret (else the main
  /// connection's key). Kept for provider kinds the roles catalog cannot
  /// resolve (on-device engines).
  HarnessLlmSlot? _legacySmolSlotFromStore() {
    final smolConfig = _taskModelsStore?.overrideFor(TaskRole.smol);
    if (smolConfig == null || smolConfig.modelId.isEmpty) return null;
    var apiKey = _activeApiKey;
    final keyName = smolConfig.apiKeyName;
    if (keyName != null && keyName.isNotEmpty) {
      final resolved = _secretsEnv != null
          ? _secretsEnv.secretsSnapshot()[keyName]
          : null;
      if (resolved != null && resolved.isNotEmpty) apiKey = resolved;
    }
    final model = Model(
      id: smolConfig.modelId,
      name: smolConfig.modelId,
      api: _agent.state.model.api,
      provider: _agent.state.model.provider,
      baseUrl: smolConfig.baseUrl,
      contextWindow: _agent.state.model.contextWindow,
      maxTokens: _agent.state.model.maxTokens,
      input: _agent.state.model.input,
    );
    return (
      model: model,
      stream: providerStreamFunction(smolConfig.providerKind, apiKey),
    );
  }
}
