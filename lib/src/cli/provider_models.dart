/// The model-pick helpers of [AgentCli]: the two-step `/model` TUI menu
/// (provider rows first, the chosen provider's models after), the
/// cross-provider model cache, and the `/model`-command switch paths.
/// Split out of `provider_commands.dart` to keep that file under the
/// repo's 2800-line size gate. Same library (a `part of`).
part of 'agent_cli.dart';

/// Model-pick helpers split out of `provider_commands.dart` (file-size
/// gate). Same library: the private extension members below are AgentCli's.
extension on AgentCli {
  // ------------------------------------------------------------- models

  // _allProvidersModelCache and _allProvidersCacheRefreshed are fields on
  // AgentCli (agent_cli.dart line 608-610); this part file accesses them
  // directly because it's the same library.

  bool get _modelCacheNeedsRefresh =>
      !_allProvidersCacheRefreshed && _modelCacheFuture == null;

  List<MenuItem> _buildModelMenu(String filter) {
    if (_modelCacheNeedsRefresh) {
      unawaited(_refreshAllProvidersModelCache());
    }
    // Two-step pick when several providers are available: the provider
    // list first, the chosen provider's models after. A single provider
    // goes straight to its models (the old flat behavior).
    final providers = _modelProviderNames();
    if (providers.length > 1) {
      return _providerMenuItems(providers, filter);
    }
    return _crossProviderModelMenuItems(_crossProviderCandidates(filter));
  }

  /// The distinct provider names behind the cross-provider candidates, in
  /// menu order: saved entries first, then env-keyed catalog providers,
  /// the active provider last.
  List<String> _modelProviderNames() {
    final seen = <String>{};
    return [
      for (final (provider, _) in _crossProviderCandidates(''))
        if (seen.add(provider)) provider,
    ];
  }

  /// The provider-step rows: one per provider, keyed `@<name>` (model rows
  /// key as `provider|model`, so the prefixes never collide). The filter
  /// matches the provider name OR any of its model ids — typing a model id
  /// lands on the one provider that serves it.
  List<MenuItem> _providerMenuItems(List<String> providers, String filter) {
    final lower = filter.toLowerCase();
    final currentProvider = _agent.state.model.provider;
    final active = _activeCustomName;
    return [
      for (final name in providers)
        if (_providerMatchesFilter(name, lower))
          MenuItem(
            key: '@$name',
            label: name,
            description:
                '${_providerModelCount(name)} model(s)'
                '${name == active || name == currentProvider ? ' · current' : ''}',
          ),
    ];
  }

  /// Whether [name] (or any of its model ids) matches the lowercase
  /// [filter]; an empty filter matches everything.
  bool _providerMatchesFilter(String name, String lower) {
    if (lower.isEmpty) return true;
    if (name.toLowerCase().contains(lower)) return true;
    return _crossProviderCandidates(
      '',
    ).any((e) => e.$1 == name && e.$2.toLowerCase().contains(lower));
  }

  /// The number of cached models for [name] (>= 1 — candidates always
  /// carry at least the entry's last-used model).
  int _providerModelCount(String name) =>
      _crossProviderCandidates('').where((e) => e.$1 == name).length;

  /// Step 2 of the two-step model pick: the chosen provider's model list
  /// in a generic picker (`modelProvider`), each row keyed
  /// `provider|model` — the selection routes back through
  /// [_tuiSelectModel]'s cross-provider switch.
  void _openProviderModelPicker(String name) {
    final currentModel = _agent.state.model;
    final models = [
      for (final entry in _crossProviderCandidates(''))
        if (entry.$1 == name) entry,
    ];
    if (models.isEmpty) return;
    _tuiController?.openPicker('modelProvider', 'Models — $name', [
      for (var i = 0; i < models.length; i++)
        MenuItem(
          key: '${models[i].$1}|${models[i].$2}',
          label:
              '${i + 1}) ${models[i].$2}'
              '${models[i].$2 == currentModel.id ? ' (current)' : ''}',
          description: visionMarker(models[i].$2),
        ),
    ]);
  }

  /// Builds MenuItem list from cross-provider candidates. Each entry is
  /// `provider/model-id` with a vision marker; the key encodes
  /// `providerName|modelId` for the selection handler.
  List<MenuItem> _crossProviderModelMenuItems(
    List<(String provider, String modelId)> entries,
  ) {
    if (entries.isEmpty) {
      return const [MenuItem(key: '', label: 'loading models...')];
    }
    final currentModel = _agent.state.model;
    return [
      for (var i = 0; i < entries.length; i++)
        _crossProviderMenuItem(entries[i], i, currentModel),
    ];
  }

  /// One cross-provider model row.
  MenuItem _crossProviderMenuItem(
    (String, String) entry,
    int index,
    dynamic currentModel,
  ) {
    final (provider, modelId) = entry;
    final isCurrent =
        provider == currentModel.provider && modelId == currentModel.id;
    return MenuItem(
      key: '$provider|$modelId',
      label:
          '${index + 1}) $provider/$modelId'
          '${isCurrent ? ' (current)' : ''}',
      description: visionMarker(modelId),
    );
  }

  Future<void> _tuiSelectModel(String key) async {
    // The provider step of the two-step model pick: `@<name>` rows open
    // that provider's model list.
    if (key.startsWith('@')) {
      _openProviderModelPicker(key.substring(1));
      return;
    }
    final pipe = key.indexOf('|');
    if (pipe < 0) return _handleModelCommand(key);
    await _switchCrossProviderModel(key, pipe);
  }

  /// Switches to the provider/model encoded as `provider|model`. A failing
  /// switch (key store, SSO mint, dead endpoint) must surface as a notice,
  /// never bubble into the picker command and take the TUI down.
  Future<void> _switchCrossProviderModel(String key, int pipe) async {
    final providerName = key.substring(0, pipe);
    final modelId = key.substring(pipe + 1);
    try {
      await _maybeSwitchToSavedEntry(providerName);
      if (!await _switchToEnvCatalogProvider(providerName, modelId)) {
        await _switchModel(modelId);
      }
    } on Object catch (e) {
      io.writeln('error: model switch to $providerName/$modelId failed: $e');
    }
  }

  /// Lands a cross-provider pick on an env-keyed CATALOG provider (no
  /// saved registry entry): switches to the provider's catalog endpoint
  /// (the key resolves env-first inside [_switchProvider]) with the
  /// picked model id applied by that same switch. Returns false when
  /// [providerName] is not such a provider or the pick is already served
  /// (it is the active provider or a saved entry) — the caller then runs
  /// the plain model switch. No second [_switchModel] after a catalog
  /// switch: it would print the switch twice and re-pin the roles chain
  /// on the new provider.
  Future<bool> _switchToEnvCatalogProvider(
    String providerName,
    String modelId,
  ) async {
    final spec = catalogProvider(providerName);
    if (spec == null) return false;
    if (providerName == _agent.state.model.provider &&
        _activeCustomName == null) {
      return false;
    }
    if (_activeCustomName == providerName) return false;
    await _switchProvider(spec, spec.defaultBaseUrl, modelId);
    return true;
  }

  /// Lands a cross-provider model pick on its own endpoint: switches to
  /// [providerName]'s saved entry unless it is already the active one.
  Future<void> _maybeSwitchToSavedEntry(String providerName) async {
    final entry = config.customProviders?.find(providerName);
    if (entry != null && entry.name != _activeCustomName) {
      await _switchToSavedProvider(entry);
    }
  }

  /// Fetches model lists from ALL saved providers in the background and
  /// populates [_allProvidersModelCache]. Also keeps the legacy
  /// [_modelCache] (active provider only) in sync for context-window
  /// detection.
  Future<void> _refreshAllProvidersModelCache() async {
    if (_modelCacheFuture != null) return;
    final completer = Completer<void>();
    _modelCacheFuture = completer.future;
    try {
      await _fetchAllSavedProviderModels();
      // Also fetch the active catalog provider's live /models list (e.g.
      // OpenRouter) so the model picker is never empty just because the user
      // hasn't saved the provider as a custom entry.
      final activeProvider = _agent.state.model.provider;
      final activeSpec = catalogProvider(activeProvider);
      if (activeSpec != null &&
          !_allProvidersModelCache.containsKey(activeProvider)) {
        try {
          final ids = await _fetchProviderModelIds(
            activeSpec.name,
            _agent.state.model.baseUrl,
            _apiKey,
          );
          _allProvidersModelCache[activeProvider] = ids.isEmpty
              ? (_knownModels[activeProvider] ?? [_agent.state.model.id])
              : ids;
        } on Object {
          _allProvidersModelCache[activeProvider] =
              _knownModels[activeProvider] ?? [_agent.state.model.id];
        }
      }
      // Always include the active provider's fallback list.
      if (!_allProvidersModelCache.containsKey(activeProvider)) {
        _allProvidersModelCache[activeProvider] =
            _knownModels[activeProvider] ?? [_agent.state.model.id];
      }
      await _refreshEnvKeyedProviders(activeProvider);
      _allProvidersCacheRefreshed = true;
      _tuiController?.sendModelsRefresh();
    } finally {
      _modelCacheFuture = null;
      completer.complete();
    }
  }

  /// Fetches model lists for the env-keyed catalog providers (a key in the
  /// environment but no saved entry — the FA_PROVIDER_* / out-of-the-box
  /// path). Split out of [_refreshAllProvidersModelCache] to keep its
  /// cyclomatic complexity under the CRAP ratchet; behavior unchanged.
  Future<void> _refreshEnvKeyedProviders(String activeProvider) async {
    // Env-keyed catalog providers: a provider whose key sits in the
    // environment (ZAI_API_KEY, MINIMAX_API_KEY, ...) is usable out of
    // the box even without a saved registry entry — fetch its live
    // /models list so the picker shows the endpoint's realtime answer,
    // seeding from the remote catalog + the catalog default when the
    // endpoint won't talk to us. A provider with neither a live answer
    // nor seeds stays hidden (never listed with zero models).
    for (final spec in enabledProviders()) {
      if (spec.name == activeProvider ||
          _allProvidersModelCache.containsKey(spec.name)) {
        continue;
      }
      final envKey = _envKeyEntry(spec);
      if (envKey == null) continue;
      try {
        final ids = await _fetchProviderModelIds(
          spec.name,
          spec.defaultBaseUrl,
          envKey.$2,
        );
        if (ids.isNotEmpty) {
          _allProvidersModelCache[spec.name] = ids;
          continue;
        }
      } on Object {
        // Dead endpoint — the seeds below keep the provider listed.
      }
      final seeds = _envCatalogSeedModels(spec);
      if (seeds.isNotEmpty) _allProvidersModelCache[spec.name] = seeds;
    }
  }

  /// Fetches every saved provider's model list in parallel (no-op without a
  /// registry or entries).
  Future<void> _fetchAllSavedProviderModels() async {
    final registry = config.customProviders;
    if (registry == null || registry.entries.isEmpty) return;
    await Future.wait(registry.entries.map(_fetchProviderModels));
  }

  /// Fetches models for one saved provider entry and caches them.
  Future<void> _fetchProviderModels(CustomProviderEntry entry) async {
    try {
      final cookieOrKey = _providerEntryToken(entry);
      final ids = await _fetchIdsForProvider(entry, cookieOrKey);
      _allProvidersModelCache[entry.name] = ids.isEmpty ? [entry.modelId] : ids;
    } on Object {
      // Dead endpoint — use the entry's last-known model.
      _allProvidersModelCache[entry.name] = [entry.modelId];
    }
  }

  /// Resolves the API token for a saved provider entry.
  String _providerEntryToken(CustomProviderEntry entry) {
    final keyName = entry.keyName;
    final token = keyName != null ? config.secureKeys?.read(keyName) : null;
    return token ?? '';
  }

  /// Fetches model ids for a provider entry, dispatching on endpoint kind.
  Future<List<String>> _fetchIdsForProvider(
    CustomProviderEntry entry,
    String cookieOrKey,
  ) async {
    if (entry.baseUrl.contains('/code-assistant-api/')) {
      return fetchCodeMieModels(entry.baseUrl, cookieOrKey);
    }
    if (entry.spec.kind == 'dial') {
      return fetchDialModels(entry.baseUrl, cookieOrKey);
    }
    if (entry.spec.kind == 'copilot') {
      return _fetchCopilotModelsAndLimits(entry.baseUrl, apiKey: cookieOrKey);
    }
    return _fetchOpenAiShapeIds(entry, cookieOrKey);
  }

  /// The openai-completions branch of [_fetchIdsForProvider]. The
  /// dispatch checks the entry's `spec.api` (not `spec.kind`) because
  /// providers whose KIND is its own value (e.g. `minimax` — a
  /// first-class provider so `--provider minimax` and the parity
  /// guards treat it as such) still speak the openai-completions API
  /// and DO answer `/v1/models`. Other api dialects (anthropic,
  /// google, chatgpt-codex) have no /models endpoint here and answer
  /// an empty list.
  Future<List<String>> _fetchOpenAiShapeIds(
    CustomProviderEntry entry,
    String cookieOrKey,
  ) async {
    if (entry.spec.api != 'openai-completions') return const [];
    final fetch = config.modelsFetcher ?? _fetchOpenAiCompatibleModels;
    return fetch(entry.baseUrl, apiKey: cookieOrKey);
  }

  /// Returns cross-provider model candidates as `(providerName, modelId)`
  /// pairs, optionally filtered by a lowercase substring match on either
  /// the provider name or the model id. The active provider is always
  /// included, even when the registry has other saved providers.
  List<(String, String)> _crossProviderCandidates([String filter = '']) {
    final registryEntries = _collectRegistryCandidates();
    final envCatalogEntries = _envKeyedCatalogCandidates();
    final activeEntries = _activeProviderFallback();
    final seen = <String>{};
    final entries = <(String, String)>[
      for (final e in [
        ...registryEntries,
        ...envCatalogEntries,
        ...activeEntries,
      ])
        if (seen.add('${e.$1}|${e.$2}')) e,
    ];
    return _filterCandidates(entries, filter);
  }

  /// The catalog providers usable right now through an environment key
  /// but with no saved registry entry that is not the active provider —
  /// both are covered by the other candidate sources. This is what makes
  /// an out-of-the-box provider (key set, nothing saved) visible in the
  /// `/model` picker: the realtime `/models` cache when the fetch
  /// answered, the remote-catalog seeds otherwise.
  List<(String, String)> _envKeyedCatalogCandidates() {
    final activeProvider = _agent.state.model.provider;
    final savedNames = {
      for (final entry
          in config.customProviders?.entries ?? const <CustomProviderEntry>[])
        entry.name,
    };
    return [
      for (final spec in enabledProviders())
        if (spec.name != activeProvider &&
            !savedNames.contains(spec.name) &&
            _envKeyEntry(spec) != null)
          for (final modelId
              in _allProvidersModelCache[spec.name] ??
                  _envCatalogSeedModels(spec))
            (spec.name, modelId),
    ];
  }

  /// The offline seed ids for a catalog provider: the remote catalog's
  /// chat fallback (deduped). Empty when the catalog ships nothing — such
  /// a provider is never listed with zero models. No local default id is
  /// merged: providers carry no default model by design.
  List<String> _envCatalogSeedModels(ProviderSpec spec) {
    final merged = <String>[
      ...remoteCatalogEnrichment.chatFallbackFor(spec.name),
    ];
    final seen = <String>{};
    return [
      for (final id in merged)
        if (id.isNotEmpty && seen.add(id)) id,
    ];
  }

  /// Collects `(provider, model)` pairs from all saved custom providers.
  /// When the live fetch for a saved entry is empty (no key, dead
  /// endpoint) the picker still has to show *something* — the catalog
  /// seed list is the data-driven fallback. The saved entry's
  /// `modelId` is the last-resort seed when both the live fetch and
  /// the catalog are empty for that provider.
  List<(String, String)> _collectRegistryCandidates() {
    final registry = config.customProviders;
    if (registry == null) return const [];
    return [
      for (final entry in registry.entries)
        for (final modelId in _registryEntryModels(entry))
          (entry.name, modelId),
    ];
  }

  /// The model ids used for one saved provider entry. Three sources,
  /// deduped in priority order:
  /// 1. Live-fetched ids from `_allProvidersModelCache` (the endpoint's
  ///    `/v1/models` answer when it was willing to talk to us — even
  ///    if the answer came back as a single-id last-resort seed).
  /// 2. The bundled remote-catalog seed list for the entry's
  ///    providerKind — fills gaps the live fetch couldn't answer
  ///    (401, network down, providers whose /v1/models isn't paginated
  ///    like `minimax` without a key).
  /// 3. The entry's last-known `modelId` — always present as a
  ///    last-resort seed so the picker never collapses to nothing.
  List<String> _registryEntryModels(dynamic entry) {
    final cached = _allProvidersModelCache[entry.name] ?? const <String>[];
    final providerKind = _providerKindForEntry(entry);
    final seed = remoteCatalogEnrichment.chatFallbackFor(providerKind);
    final merged = <String>[
      for (final id in cached)
        if (id.isNotEmpty) id,
      for (final id in seed)
        if (id.isNotEmpty) id,
      if (entry.modelId.isNotEmpty) entry.modelId,
    ];
    final seen = <String>{};
    final unique = <String>[
      for (final id in merged)
        if (seen.add(id)) id,
    ];
    return unique;
  }

  /// The providerKind of a saved entry — `apiType` (the registry field
  /// the `provider` column maps to) is what catalogProvider() expects.
  String? _providerKindForEntry(dynamic entry) {
    try {
      return entry.apiType as String?;
    } on Object {
      return null;
    }
  }

  /// Fallback candidates from the active provider's known models. The
  /// priority chain is:
  /// 1. The cross-provider cache (preloaded / fetched models).
  /// 2. The legacy active-provider cache (refreshed by `/v1/models`).
  /// 3. The bundled `_knownModels` list (hardcoded, kept for providers
  ///    that don't ship a remote catalog entry yet).
  /// 4. The remote catalog's `contextWindows` keys — data-driven from
  ///    `fa1.dev/models-catalog.json` (NOT hardcoded).
  /// 5. The active model's id — the saved entry's last-used model.
  List<(String, String)> _activeProviderFallback() {
    final activeProvider = _agent.state.model.provider;
    final activeName = _activeCustomName ?? activeProvider;
    final List<String> known;
    if (_allProvidersModelCache[activeName] != null) {
      known = _allProvidersModelCache[activeName]!;
    } else if (_modelCache.isNotEmpty) {
      known = _modelCache;
    } else {
      final hardcoded = _knownModels[activeProvider];
      final catalogSeeds = remoteCatalogEnrichment.chatFallbackFor(
        activeProvider,
      );
      if (hardcoded != null) {
        known = hardcoded;
      } else if (catalogSeeds.isNotEmpty) {
        known = catalogSeeds;
      } else {
        known = [_agent.state.model.id];
      }
    }
    return [for (final modelId in known) (activeProvider, modelId)];
  }

  /// Filters candidates by a lowercase substring, or returns all if empty.
  List<(String, String)> _filterCandidates(
    List<(String, String)> entries,
    String filter,
  ) {
    if (filter.isEmpty) return entries;
    final lower = filter.toLowerCase();
    return entries
        .where(
          (e) =>
              e.$1.toLowerCase().contains(lower) ||
              e.$2.toLowerCase().contains(lower),
        )
        .toList();
  }

  /// refreshes the TUI picker if it is currently open. Failures are swallowed
  /// so the UI keeps working with the hardcoded fallback list. When the
  /// payload reports the active model's real context window, the model is
  /// corrected (roles mode keeps the chain's configured window instead).
  Future<void> _refreshModelCache() async {
    if (_modelCacheFuture != null) return _modelCacheFuture!;
    final completer = Completer<void>();
    _modelCacheFuture = completer.future;
    try {
      final model = _agent.state.model;
      if (model.api == 'openai-completions') {
        final ids = await _fetchActiveProviderModels(model);
        if (ids.isNotEmpty) {
          _modelCache = ids;
          _tuiController?.sendModelsRefresh();
          // Endpoint-reported limits are authoritative EXCEPT where the
          // roles chain pins explicit values: roles mode used to skip the
          // detection entirely, so a chain entry riding the catalog
          // default (e.g. the copilot 1M default for a 256k kimi model)
          // never learned the real window and the compaction thresholds
          // silently ran against the wrong number.
          final pinned = _rolesPinnedLimits(model);
          if (!pinned.window) _applyDetectedContextWindow(model);
          if (!pinned.cap) _applyDetectedMaxTokens(model);
        }
      }
    } on Object {
      // Swallowed: the cache keeps the fallback list; the UI still works.
      // (Tests inject [AgentCliConfig.modelsFetcher] for deterministic lists;
      // a dead endpoint returning HTML instead of JSON is the normal case.)
    } finally {
      _modelCacheFuture = null;
      completer.complete();
    }
  }

  /// Fetches the active provider's model ids through the shared dispatch
  /// ([_fetchProviderModelIds]): CodeMie `/llm_models`, DIAL deployments,
  /// everything else OpenAI `/models`.
  Future<List<String>> _fetchActiveProviderModels(Model model) {
    return _fetchProviderModelIds(model.provider, model.baseUrl, _apiKey);
  }

  /// Whether the roles chain pins explicit limits for [model]: a chain
  /// entry with a `contextWindow`/`maxTokens` in the `roles:` config means
  /// the user set them deliberately and the endpoint-reported values must
  /// not override them. Entries riding the catalog defaults (the common
  /// case) report both flags false, so detection applies.
  ({bool window, bool cap}) _rolesPinnedLimits(Model model) {
    final resolver = config.modelRolesResolver;
    if (resolver == null) return (window: false, cap: false);
    final refs = resolver.config.chainFor(
      defaultModelRole,
      cwd: resolver.cwd,
      homeDir: resolver.homeDir,
    );
    if (refs == null) return (window: false, cap: false);
    for (final ref in refs) {
      if (ref.modelId != model.id) continue;
      return (
        window: ref.contextWindow != null,
        cap: ref.maxTokens != null,
      );
    }
    return (window: false, cap: false);
  }

  /// Applies the endpoint-reported context window for [model] when it
  /// differs from the carried one (called from [_refreshModelCache];
  /// [_rolesPinnedLimits] keeps user-pinned `roles:` limits winning).
  void _applyDetectedContextWindow(Model model) {
    final detected = _modelContextWindows[model.id];
    if (detected != null && detected != model.contextWindow) {
      _replaceModelLimits(contextWindow: detected);
      io.writeln(_style.dim('model context window: $detected (from endpoint)'));
    }
  }

  /// Applies the endpoint-reported max-tokens cap for [model] when it
  /// differs from the carried one (see [_applyDetectedContextWindow]).
  void _applyDetectedMaxTokens(Model model) {
    final detectedCap = _modelMaxTokens[model.id];
    if (detectedCap != null && detectedCap != model.maxTokens) {
      _replaceModelLimits(maxTokens: detectedCap);
      io.writeln(_style.dim('model max tokens: $detectedCap (from endpoint)'));
    }
  }

  /// [fetchDialModelsInfo] wrapper for [_refreshModelCache]: records the
  /// `features.cache` deployment set (drives [DialOptions.cacheMarkersSupported])
  /// and the endpoint-reported limits (context window / max output from
  /// `limits`, the MAXIMUM values — never the `defaults`), and answers the
  /// plain id list. [apiKey] overrides the session key (the settings flows
  /// resolve the TARGET provider's key, not the active connection's).
  Future<List<String>> _fetchDialModelsAndFeatures(
    String baseUrl, {
    String? apiKey,
  }) async {
    final (ids, cacheSupported, windows, maxTokens) = await fetchDialModelsInfo(
      baseUrl,
      apiKey ?? _apiKey,
      client: config.modelsHttpClient,
    );
    if (cacheSupported.isNotEmpty) _dialCacheModels = cacheSupported;
    if (windows.isNotEmpty) _modelContextWindows = windows;
    if (maxTokens.isNotEmpty) _modelMaxTokens = maxTokens;
    return ids;
  }

  /// [fetchModelsForEndpoint] wrapper routing Copilot to its dialect (the
  /// GitHub key is exchanged for the short-lived Copilot token first — a
  /// raw Bearer GET would 401): records the endpoint-reported limits
  /// (context window / max output from `capabilities.limits`) and answers
  /// the plain id list.
  Future<List<String>> _fetchCopilotModelsAndLimits(
    String baseUrl, {
    String? apiKey,
  }) async {
    final (ids, windows, maxTokens) = await fetchModelsForEndpoint(
      baseUrl,
      apiKey: apiKey ?? _apiKey,
      provider: 'copilot',
      client: config.modelsHttpClient,
    );
    if (windows.isNotEmpty) _modelContextWindows = windows;
    if (maxTokens.isNotEmpty) _modelMaxTokens = maxTokens;
    return ids;
  }

  Future<List<String>> _fetchOpenAiCompatibleModels(
    String baseUrl, {
    required String apiKey,
  }) async {
    final normalized = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$normalized/models');
    final headers = <String, String>{'Accept': 'application/json'};
    if (apiKey.isNotEmpty) headers['Authorization'] = 'Bearer $apiKey';
    try {
      final response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return const [];
      final (ids, windows, maxTokens) = parseModelsResponse(response.body);
      _modelContextWindows = windows;
      _modelMaxTokens = maxTokens;
      return ids;
    } on Object {
      return const [];
    }
  }

  /// Lists the known models for the active provider, optionally filtered by
  /// [filter]. The output is numbered so `/model N` can pick one. For
  /// OpenAI-compatible endpoints the list is fetched live from `/v1/models`
  /// and cached.
  Future<void> _listModels(String filter) async {
    if (_modelCacheNeedsRefresh) {
      await _refreshAllProvidersModelCache();
    }
    final entries = _crossProviderCandidates(filter);
    if (entries.isEmpty) return io.writeln('no models available');
    io.writeln('models (provider/model):');
    _printNumberedModels(entries);
    io.writeln('use /model <n> or /model <provider>/<id> to switch');
  }

  /// The numbered `(provider, model)` rows of the `/models` listing plus the
  /// `_lastModelList` snapshot powering `/model <n>`.
  void _printNumberedModels(List<(String, String)> entries) {
    for (var i = 0; i < entries.length; i++) {
      io.writeln('  ${i + 1}) ${entries[i].$1}/${entries[i].$2}');
    }
    _lastModelList = [for (final e in entries) '${e.$1}/${e.$2}'];
  }

  /// Returns the full list of known model ids for the active provider.
  List<String> _listModelsForMenu() => _modelCandidates('');

  /// Returns known model ids for the ACTIVE provider only (used by
  /// `/model <id>` line-mode switches and the number picker). The TUI
  /// picker uses [_crossProviderCandidates] instead for cross-provider.
  List<String> _modelCandidates([String filter = '']) {
    final provider = _agent.state.model.provider;
    final activeName = _activeCustomName ?? provider;
    final all =
        _allProvidersModelCache[activeName] ??
        (_modelCache.isNotEmpty
            ? _modelCache
            : (_knownModels[provider] ?? [_agent.state.model.id]));
    if (filter.isEmpty) return all.toList();
    final lower = filter.toLowerCase();
    return all.where((id) => id.toLowerCase().contains(lower)).toList();
  }

  /// `/models [filter]` | `config` | `set <slot> <model> [baseUrl]` |
  /// `remove <slot>` — a bare or filtered invocation lists the endpoint's
  /// models; the `config`/`set`/`remove` subcommands show and manage the
  /// media slot overrides of the `models:` config section (persisted by the
  /// host).
  Future<void> _handleModelsCommand(String rest) async {
    final trimmed = rest.trim();
    final split = trimmed.indexOf(RegExp(r'\s'));
    final head = split < 0 ? trimmed : trimmed.substring(0, split);
    final tail = split < 0 ? '' : trimmed.substring(split + 1).trim();
    switch (head) {
      case 'config':
        _printModelsConfig();
      case 'set':
        _setModelsSlot(tail);
      case 'remove':
        _removeModelsSlot(tail);
      default:
        await _listModels(trimmed);
    }
  }

  /// `/models config`: the effective models configuration — the main
  /// connection, every media slot (override or main-connection fallback),
  /// and the custom model definitions `/model <name>` can switch to.
  void _printModelsConfig() {
    final models = config.modelsConfig;
    final current = _agent.state.model;
    io.writeln(
      'main connection: ${current.id} '
      '(${current.provider} @ ${current.baseUrl})',
    );
    io.writeln('media slots (no override = main connection):');
    for (final slot in mediaModelSlotIds) {
      final override = models?.slots[slot];
      if (override == null) {
        io.writeln('  $slot: main connection');
      } else {
        final key = override.apiKeyName == null
            ? ''
            : ' · key: ${override.apiKeyName}';
        io.writeln(
          '  $slot: ${override.modelId} @ ${override.baseUrl} '
          '(${override.providerKind})$key',
        );
      }
    }
    final custom = models?.custom ?? const <String, CustomModelDefinition>{};
    if (custom.isEmpty) {
      io.writeln(
        'custom models: none (define under models.custom in '
        '~/.fah/config.yaml)',
      );
    } else {
      io.writeln('custom models (switch with /model <name>):');
      for (final entry in custom.entries) {
        final def = entry.value;
        io.writeln(
          '  ${entry.key}: ${def.model} (${def.provider} @ ${def.baseUrl})',
        );
      }
    }
    io.writeln(
      _style.dim('persisted in the models: section of ~/.fah/config.yaml'),
    );
  }

  /// `/models set <slot> <model> [baseUrl]`: pins one media slot to a model.
  /// The base URL defaults to the main connection's endpoint; the provider
  /// kind is always `openai-completions` (the media tools' wire format).
  void _setModelsSlot(String args) {
    final parts = args
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length < 2 || parts.length > 3) {
      io.writeln('usage: /models set <slot> <model> [baseUrl]');
      return;
    }
    final slot = parts[0];
    if (!mediaModelSlotIds.contains(slot)) {
      io.writeln(
        'unknown slot: $slot (slots: ${mediaModelSlotIds.join(', ')})',
      );
      return;
    }
    final models = config.modelsConfig;
    if (models == null) {
      io.writeln('models config is unavailable on this host');
      return;
    }
    final baseUrl = parts.length == 3 ? parts[2] : _agent.state.model.baseUrl;
    models.setSlotOverride(
      slot,
      MediaSlotModelConfig(
        providerKind: 'openai-completions',
        baseUrl: baseUrl,
        modelId: parts[1],
      ),
    );
    io.writeln('slot $slot → ${parts[1]} @ $baseUrl (openai-completions)');
    config.onModelsConfigChanged?.call();
  }

  /// `/models remove <slot>`: drops a media slot override, returning the
  /// slot to the main-connection fallback.
  void _removeModelsSlot(String slot) {
    if (slot.isEmpty) {
      io.writeln('usage: /models remove <slot>');
      return;
    }
    if (!mediaModelSlotIds.contains(slot)) {
      io.writeln(
        'unknown slot: $slot (slots: ${mediaModelSlotIds.join(', ')})',
      );
      return;
    }
    final models = config.modelsConfig;
    if (models == null) {
      io.writeln('models config is unavailable on this host');
      return;
    }
    if (!models.removeSlotOverride(slot)) {
      io.writeln('no override for slot $slot');
      return;
    }
    io.writeln('slot $slot → main connection');
    config.onModelsConfigChanged?.call();
  }

  Future<void> _handleModelCommand(String rest) async {
    final trimmed = rest.trim();
    if (trimmed == '?') {
      await _listModels('');
      return;
    }
    if (trimmed.isEmpty) {
      // Bare `/model` in TUI mode opens the interactive picker; in line mode
      // it prints the active model and the roles overview.
      final controller = _tuiController;
      if (controller != null) {
        controller.openModelMenu();
        return;
      }
      await _switchModel('');
      return;
    }
    if (await _switchModelByNumber(trimmed)) return;
    // A custom model definition from the models: config section resolves
    // before plain model ids (its provider/endpoint/token limits come from
    // the definition, not the current connection).
    final custom = config.modelsConfig?.custom[trimmed];
    if (custom != null) {
      await _switchToCustomModel(trimmed, custom);
      return;
    }
    await _switchModel(trimmed);
  }

  /// The `/model N` branch of [_handleModelCommand]: resolves a 1-based
  /// number against the last listed models. Returns true when [trimmed] was
  /// a number (handled — valid pick or invalid-selection message).
  Future<bool> _switchModelByNumber(String trimmed) async {
    final number = int.tryParse(trimmed);
    if (number == null) return false;
    await _switchModelOrReport(number, _lastModelList ?? _listModelsForMenu());
    return true;
  }

  /// Switches to list entry [number] (1-based) or reports the range error.
  Future<void> _switchModelOrReport(int number, List<String> list) async {
    if (number >= 1 && number <= list.length) {
      await _switchModel(list[number - 1]);
    } else {
      io.writeln('invalid selection: $number (1-${list.length})');
    }
  }

  /// `/model <name>` where [name] is a custom model definition from the
  /// `models:` config section: switches provider, endpoint, and model in one
  /// step. Roles mode pins the default chain; legacy mode rebuilds the
  /// stream function like `/provider` (key resolves from the catalog env
  /// names / secure store — never from the config file).
  Future<void> _switchToCustomModel(
    String name,
    CustomModelDefinition def,
  ) async {
    // fromYaml validates the provider against the catalog.
    final spec = catalogProvider(def.provider)!;
    final rolesResolver = config.modelRolesResolver;
    if (rolesResolver != null) {
      rolesResolver.setDefaultChain([
        ModelRef(
          provider: spec.name,
          modelId: def.model,
          baseUrl: def.baseUrl,
          contextWindow: def.contextWindow,
          maxTokens: def.maxTokens,
          // Keep the endpoint's scoped key on the pin (see _switchProvider).
          apiKeyName:
              _rolesKeyNameFor(spec.name, def.baseUrl) ??
              _scopedKeyNameForNonDefault(spec.name, def.baseUrl),
        ),
      ]);
      rolesResolver.applyToAgent(_agent);
      _streamFunction = _agent.streamFunction;
      // Same invariant as _switchProvider: the session key field must name
      // THIS endpoint's key, or a later /model switch re-seeds the pinned
      // chain with the stale startup key.
      _apiKey = _providerKeyFor(spec, def.baseUrl) ?? '';
    } else {
      final key = _providerKeyFor(spec, def.baseUrl) ?? '';
      _providerKind = spec.kind;
      _apiKey = key;
      _explicitToken = false;
      _streamFunction = _catalogStreamFunction(spec.kind, key);
      _agent.streamFunction = _streamFunction;
      final built = buildCatalogModel(
        spec.name,
        def.model,
        baseUrl: def.baseUrl,
        contextWindow: def.contextWindow,
        maxTokens: def.maxTokens,
      );
      final modalities = def.input;
      _agent.state.model = modalities == null
          ? built
          : Model(
              id: built.id,
              name: built.name,
              api: built.api,
              provider: built.provider,
              baseUrl: built.baseUrl,
              reasoning: built.reasoning,
              input: modalities,
              cost: built.cost,
              contextWindow: built.contextWindow,
              maxTokens: built.maxTokens,
              headers: built.headers,
              compat: built.compat,
            );
    }
    _activeCustomName = null;
    // The cached model list belongs to the previous provider/endpoint.
    _modelCache = const [];
    _modelContextWindows = const {};
    _modelMaxTokens = const {};
    _lastModelList = null;
    unawaited(_refreshModelCache());
    await _session?.appendModelChange(provider: spec.name, modelId: def.model);
    io.writeln('switched model to $name (${def.model} @ ${def.baseUrl})');
    if (rolesResolver == null) {
      io.writeln('  ${_providerKeyLine(spec, def.baseUrl, explicit: false)}');
    }
    await config.onModelChanged?.call(_agent.state.model);
  }

  /// Compact post-switch note: the role models that did NOT move with the
  /// main one, so the user can go adjust them (/settings → Agent models)
  /// when the combination no longer makes sense (a free main model paired
  /// with a paid smol summarizer, a flash main with a flagship subagent).
  void _printRoleModelsNote() {
    final resolver = config.modelRolesResolver;
    if (resolver == null) {
      io.writeln(
        _style.dim(
          '  note: smol/subagent/memory roles inherit the main model — '
          'pin them via /settings → Agent models',
        ),
      );
      return;
    }
    String label(String role) {
      final chain = resolver.config.chainFor(
        role,
        cwd: resolver.cwd,
        homeDir: resolver.homeDir,
      );
      if (chain == null) return 'inherits main';
      return chain.map((ref) => ref.modelId).join(' → ');
    }

    io.writeln(
      _style.dim(
        '  note: role models unchanged — smol (compaction): '
        '${label(smolModelRole)} · subagent: ${label("subagent")} · '
        'memory: ${label("memory")} — /settings → Agent models to adjust',
      ),
    );
  }

  Future<void> _switchModel(String modelId) async {
    final current = _agent.state.model;
    final rolesResolver = config.modelRolesResolver;
    if (modelId.isEmpty) {
      io.writeln('model: ${current.id} (${current.api})');
      if (rolesResolver != null) io.writeln(rolesResolver.describeRoles());
      return;
    }
    // An endpoint-reported window/cap beats the carried one (the catalog
    // defaults) when the id is known to /models.
    final window = _modelContextWindows[modelId] ?? current.contextWindow;
    final cap = _modelMaxTokens[modelId] ?? current.maxTokens;
    // Cookie-header auth (CodeMie SSO) can never ride a roles chain — the
    // chain stream would send the cookie as Bearer. Keep the direct model
    // set (the cookie stays in model.headers), mirroring
    // [_switchCodeMieProvider]'s resolver bypass.
    final cookieAuth = current.headers?.containsKey('cookie') ?? false;
    if (rolesResolver != null && !cookieAuth) {
      // Roles mode: pin the default role to the requested model id on the
      // current provider (a single-entry chain for this session). The
      // endpoint's scoped key name rides along (see _switchProvider).
      final pinnedKeyName =
          _rolesKeyNameFor(current.provider, current.baseUrl) ??
          _scopedKeyNameForNonDefault(current.provider, current.baseUrl);
      // Seed the resolver with the session's LIVE key material under the
      // pinned name BEFORE resolving the chain: saved-entry keys (CodeMie
      // JWT, typed custom keys) live in the secure store / session, never
      // in the resolver's startup snapshot — an unseeded pin resolves
      // nothing and chainFor throws "no usable chain entry: set
      // OPENAI_API_KEY", which aborts the switch and leaves the status
      // line on the old model.
      if (pinnedKeyName != null) {
        if (_apiKey.isNotEmpty) {
          rolesResolver.addSecret(pinnedKeyName, _apiKey);
        } else {
          _seedEnvKeyStack(rolesResolver, pinnedKeyName);
        }
      }
      rolesResolver.setDefaultChain([
        ModelRef(
          provider: current.provider,
          modelId: modelId,
          baseUrl: current.baseUrl,
          contextWindow: window,
          maxTokens: cap,
          apiKeyName: pinnedKeyName,
        ),
      ]);
      rolesResolver.applyToAgent(_agent);
      _streamFunction = _agent.streamFunction;
      await _session?.appendModelChange(
        provider: current.provider,
        modelId: modelId,
      );
      io.writeln('switched model to $modelId');
      _printRoleModelsNote();
      // _recordCustomModel persists via its own onModelChanged (the
      // per-provider model memory write must survive restarts even when
      // nothing else changed).
      await _recordCustomModel(modelId);
      return;
    }
    _agent.state.model = Model(
      id: modelId,
      name: modelId,
      api: current.api,
      provider: current.provider,
      baseUrl: current.baseUrl,
      reasoning: current.reasoning,
      // The endpoint exposes no modality metadata — recompute from the
      // shared vision heuristic instead of carrying the previous model's
      // modalities (a text-only pick would otherwise keep claiming image
      // support, and vice versa).
      input: inputModalitiesFor(modelId),
      cost: current.cost,
      contextWindow: window,
      maxTokens: cap,
      headers: current.headers,
      compat: current.compat,
    );
    await _session?.appendModelChange(
      provider: current.provider,
      modelId: modelId,
    );
    io.writeln('switched model to $modelId');
    _printRoleModelsNote();
    // _recordCustomModel ALWAYS notifies the host (not just with an active
    // custom entry) — the single onModelChanged fire for this switch.
    await _recordCustomModel(modelId);
  }

  /// `/model-edit [contextWindow|maxTokens <n>]`: shows or overrides the
  /// active model's token limits for this session (persist per chain via
  /// roles yaml `contextWindow:`/`maxTokens:`). Bare in TUI mode opens an
  /// interactive two-step picker (field → preset/custom value).
  Future<void> _handleModelEdit(String rest) async {
    final args = _splitCommandArgs(rest);
    if (args.isNotEmpty) return _applyModelEditArg(args);
    await _showModelEditDefault();
  }

  /// Bare `/model-edit`: the TUI two-step picker, or the line-mode limits.
  Future<void> _showModelEditDefault() async {
    if (_useTui && _tuiController != null) {
      await _modelEditInteractive();
    } else {
      _printModelLimits();
    }
  }

  /// Splits a command's rest into non-empty whitespace-separated tokens.
  List<String> _splitCommandArgs(String rest) => rest
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();

  /// Bare `/model-edit`: the active model's token limits and the setter
  /// usage hint.
  void _printModelLimits() {
    final current = _agent.state.model;
    io.writeln(
      'model ${current.id}: contextWindow ${current.contextWindow} · '
      'maxTokens ${current.maxTokens}',
    );
    io.writeln(
      _style.dim('set with /model-edit <contextWindow|maxTokens> <n>'),
    );
  }

  /// Bare `/model-edit` in TUI mode: a two-step interactive picker —
  /// (1) which field to edit (context window or max output tokens),
  /// (2) a standard preset list plus a "Custom…" free-text entry. The
  /// picked value is applied via [_replaceModelLimits]. Cancelling either
  /// step aborts without changes.
  /// `/model-edit` TUI interactive: delegates to the pure [interactiveModelEdit]
  /// with the live controller + model.
  Future<void> _modelEditInteractive() => interactiveModelEdit(
    current: _agent.state.model,
    prompt: _tuiController!.openPrompt,
    onResult: io.writeln,
    onApply: _replaceModelLimitsFromEdit,
  );

  /// Adapts [interactiveModelEdit]'s apply callback to [_replaceModelLimits].
  void _replaceModelLimitsFromEdit({
    required bool isContext,
    required int value,
  }) {
    _replaceModelLimits(
      contextWindow: isContext ? value : null,
      maxTokens: isContext ? null : value,
    );
  }

  /// `/model-edit <contextWindow|maxTokens> <n>`: validates the value and
  /// applies the override.
  void _applyModelEditArg(List<String> args) {
    final value = args.length == 2 ? int.tryParse(args[1]) : null;
    if (args.length != 2 || value == null || value <= 0) {
      io.writeln('usage: /model-edit <contextWindow|maxTokens> <n>');
      return;
    }
    _applyModelLimitEdit(args[0], value);
  }

  /// Applies a validated `/model-edit` limit override by field name.
  void _applyModelLimitEdit(String field, int value) {
    switch (field) {
      case 'contextWindow':
        _replaceModelLimits(contextWindow: value);
        io.writeln('model context window set to $value');
      case 'maxTokens':
        _replaceModelLimits(maxTokens: value);
        io.writeln('model max tokens set to $value');
      default:
        io.writeln('usage: /model-edit <contextWindow|maxTokens> <n>');
    }
  }

  /// Rebuilds the active model with new token limits, preserving every other
  /// field (endpoint detection and `/model-edit`).
  void _replaceModelLimits({int? contextWindow, int? maxTokens}) {
    final current = _agent.state.model;
    _agent.state.model = Model(
      id: current.id,
      name: current.name,
      api: current.api,
      provider: current.provider,
      baseUrl: current.baseUrl,
      reasoning: current.reasoning,
      input: current.input,
      cost: current.cost,
      contextWindow: contextWindow ?? current.contextWindow,
      maxTokens: maxTokens ?? current.maxTokens,
      headers: current.headers,
      compat: current.compat,
    );
    unawaited(config.onModelChanged?.call(_agent.state.model));
  }
}

/// Known model ids shown by `/models` and the `/model` picker. Maps the
/// provider name stored on the active [Model] to a short, useful subset.
///
/// TDD note: providers whose chat endpoint actually serves a `/v1/models`
/// response (MiniMax, OpenAI, OpenRouter, Google, Anthropic) are NOT
/// listed here — `/v1/models` is the source of truth. The list below is
/// a LAST-RESORT offline fallback only — picked when the live endpoint
/// fetch fails AND the remote catalog hasn't shipped an entry for that
/// provider. If you're adding a provider here because `/models` is
/// empty in the UI, first try `/v1/models` against the real endpoint
/// with the right auth — adding here is a temporary band-aid.
const _knownModels = <String, List<String>>{
  'openrouter': [
    'anthropic/claude-sonnet-4',
    'openai/gpt-4o-mini',
    'google/gemini-2.5-pro',
    'anthropic/claude-opus-4',
    'openai/gpt-4.1-mini',
  ],
  'kimi': ['k3', 'kimi-for-coding', 'kimi-for-coding-highspeed', 'k3-256k'],
  'anthropic': ['claude-sonnet-4-5', 'claude-opus-4', 'claude-haiku-4'],
  'google': ['gemini-2.5-pro', 'gemini-2.0-flash'],
  'openai': ['gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini'],
};

/// Formats a token count as a compact preset label (`4K`, `16K`, `1M`).
String formatTokenPreset(int tokens) {
  if (tokens >= 1048576 && tokens % 1048576 == 0) {
    return '${tokens ~/ 1048576}M';
  }
  if (tokens >= 1024 && tokens % 1024 == 0) {
    return '${tokens ~/ 1024}K';
  }
  return '$tokens';
}

/// Parses a compact preset label (`4K`, `16K`, `1M`) back to tokens.
int parseTokenPreset(String label) {
  final trimmed = label.trim();
  final match = RegExp(
    r'^(\d+)([KM])?$',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (match == null) return int.tryParse(trimmed) ?? 0;
  final base = int.parse(match.group(1)!);
  final suffix = match.group(2)?.toUpperCase();
  return switch (suffix) {
    'K' => base * 1024,
    'M' => base * 1048576,
    _ => base,
  };
}

/// Parses a `(empty = X):` or `(empty keeps 'X'):` hint from [question],
/// returning `X` so the TUI prompt can show it as the default value, or
/// null when no default hint is present.
String? extractDefaultValue(String question) {
  final match = RegExp(r'\(empty\s*=\s*(.+?)\)').firstMatch(question);
  if (match != null) return match.group(1)!.trim();
  final keeps = RegExp(r"\(empty\s*keeps\s*'(.+?)'\)").firstMatch(question);
  if (keeps != null) return keeps.group(1)!.trim();
  return null;
}

/// Testable core of the TUI key-set flow: prompts for name (when [name] is
/// null) and a masked value through [prompt], validates, saves to [keys],
/// and reports the outcome through [onResult]. The freshly saved key is
/// handed to [onSaved] for immediate provider pickup.
Future<void> interactiveKeySet({
  required String? name,
  required SecureKeyCache keys,
  required void Function(String name, String value)? onSecretStored,
  required Future<TuiPromptAnswer?> Function(TuiPromptSpec) prompt,
  required void Function(String message) onResult,
  required void Function(String name, String value) onSaved,
}) async {
  final keyNamePattern = RegExp(r'^[A-Za-z0-9_]+$');
  final keyName = await promptTextTui(
    prompt,
    name,
    header: 'Key',
    question: 'Key name (UPPER_SNAKE or [A-Za-z0-9_]+):',
  );
  if (keyName == null) return;
  if (!keyNamePattern.hasMatch(keyName)) {
    onResult('invalid key name: $keyName');
    return;
  }
  final value = await promptTextTui(
    prompt,
    null,
    header: 'Key',
    question: 'Value for $keyName:',
    secret: true,
  );
  if (value == null || value.isEmpty) {
    onResult('cancelled');
    return;
  }
  if (!await keys.save(keyName, value)) {
    onResult('could not save $keyName');
    return;
  }
  onSecretStored?.call(keyName, value);
  onResult('saved $keyName to ${keys.label}');
  onSaved(keyName, value);
}

/// Opens a [TextPromptSpec] through [prompt] and returns the trimmed text
/// answer. Returns [initial] as-is when provided (no prompt needed), or
/// null on cancel/unexpected result.
Future<String?> promptTextTui(
  Future<TuiPromptAnswer?> Function(TuiPromptSpec) prompt,
  String? initial, {
  required String header,
  required String question,
  bool secret = false,
}) async {
  if (initial != null) return initial;
  final result = await prompt(
    TextPromptSpec(header: header, question: question, secret: secret),
  );
  if (result == null || result is! TextPromptAnswer) return null;
  return result.value.trim();
}

/// Testable core of the TUI model-edit flow. Prompts for field (context
/// window vs max tokens), then a preset or custom value, and calls [onApply]
/// with the result. Reports messages through [onResult].
Future<void> interactiveModelEdit({
  required Model current,
  required Future<TuiPromptAnswer?> Function(TuiPromptSpec) prompt,
  required void Function(String message) onResult,
  required void Function({required bool isContext, required int value}) onApply,
}) async {
  final isContext = await pickModelEditField(prompt, current);
  if (isContext == null) return;

  final value = await pickModelEditValue(prompt, isContext, onResult);
  if (value == null) return;

  onApply(isContext: isContext, value: value);
  onResult('${isContext ? 'context window' : 'max tokens'} set to $value');
}

/// Step 1: picks which field to edit (null on cancel).
Future<bool?> pickModelEditField(
  Future<TuiPromptAnswer?> Function(TuiPromptSpec) prompt,
  Model current,
) async {
  final result = await prompt(
    AskPromptSpec(
      header: 'Model Edit',
      question: 'Which limit to edit?',
      index: 0,
      total: 1,
      options: [
        AskOption(
          label: 'Context Window',
          description: 'Current: ${current.contextWindow}',
        ),
        AskOption(
          label: 'Max Output Tokens',
          description: 'Current: ${current.maxTokens}',
        ),
      ],
    ),
  );
  if (result == null || result is! AskPromptAnswer) return null;
  return result.value.selected.first.contains('Context');
}

/// Step 2: picks a preset value or enters a custom one (null on cancel).
Future<int?> pickModelEditValue(
  Future<TuiPromptAnswer?> Function(TuiPromptSpec) prompt,
  bool isContext,
  void Function(String message) onResult,
) async {
  final presets = isContext
      ? [4096, 8192, 16384, 32768, 65536, 131072, 204800, 1048576]
      : [4096, 8192, 16384, 32768, 65536];
  final result = await prompt(
    AskPromptSpec(
      header: 'Model Edit',
      question: '${isContext ? 'Context window' : 'Max tokens'} size:',
      index: 0,
      total: 1,
      options: [
        for (final p in presets) AskOption(label: formatTokenPreset(p)),
        const AskOption(
          label: 'Custom…',
          description: 'Enter a number manually',
        ),
      ],
    ),
  );
  if (result == null || result is! AskPromptAnswer) return null;
  final picked = result.value.selected.first;
  if (picked != 'Custom…') return parseTokenPreset(picked);
  return _pickCustomTokenValue(prompt, onResult);
}

Future<int?> _pickCustomTokenValue(
  Future<TuiPromptAnswer?> Function(TuiPromptSpec) prompt,
  void Function(String message) onResult,
) async {
  final textResult = await prompt(
    const TextPromptSpec(
      header: 'Model Edit',
      question: 'Enter value (tokens):',
    ),
  );
  if (textResult == null || textResult is! TextPromptAnswer) return null;
  final value = int.tryParse(textResult.value.trim()) ?? 0;
  if (value <= 0) {
    onResult('invalid value');
    return null;
  }
  return value;
}
