/// The provider/key management section of [AgentCli]: the `/provider` and
/// `/key` commands, the guided custom-provider flow glue, the TUI provider
/// picker, and the key-status helpers. Split out of `agent_cli.dart` to
/// keep that file under the repo's 2800-line size gate. Same library (a
/// `part of`), so the extension sees the class's private members.
part of 'agent_cli.dart';

/// Implementation members of [AgentCli] for provider and key management.
extension on AgentCli {
  /// Starts the guided custom-provider setup (or edit, when the `initial*`
  /// prefills and [editName] are set) without awaiting it: the REPL loop
  /// must keep reading lines so the flow's prompts can be answered
  /// (awaiting it here would deadlock the loop on the first question).
  void _startProviderFlow({
    String? initialType,
    String? initialBaseUrl,
    String? initialName,
    String? initialModelId,
    String? editName,
  }) {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    unawaited(
      runCustomProviderFlow(
        io,
        CustomProviderFlowConfig(
          askLine: _askLine,
          pickOption: _pickOption,
          fetchModels: _fetchModelsForFlow,
          applyResult: (setup) =>
              _applyCustomProviderSetup(setup, editName: editName),
          currentModelId: () => _agent.state.model.id,
          rolesActive: config.modelRolesResolver != null,
          deriveName: (baseUrl) =>
              config.customProviders?.deriveName(baseUrl) ?? 'custom',
          initialType: initialType,
          initialBaseUrl: initialBaseUrl,
          initialName: initialName,
          initialModelId: initialModelId,
          editName: editName,
        ),
      ).whenComplete(() {
        _providerFlowActive = false;
        // Leftover buffered lines are flow answers, not user prompts.
        _promptLineBuffer.clear();
      }),
    );
  }

  /// `/provider-edit`: the guided flow prefilled with the active provider —
  /// editing its registry entry when one is active, a plain session switch
  /// otherwise.
  void _startProviderEditFlow() {
    final entry = config.customProviders?.find(_activeCustomName ?? '');
    final model = _agent.state.model;
    final spec = catalogProvider(model.provider) ?? providerCatalog['openai']!;
    _startProviderFlow(
      initialType: entry?.apiType ?? spec.name,
      initialBaseUrl: model.baseUrl,
      initialName: entry?.name,
      initialModelId: model.id,
      editName: entry?.name,
    );
  }

  /// The flow's free-form questions are plain line prompts.
  Future<String?> _askLine(String question) => _promptLine(question);

  /// Reads one input line for a guided-flow prompt (printed inline).
  /// Resolves to `null` on cancel (Ctrl-C interrupt or input shutdown),
  /// which the flow maps to "setup cancelled". Answers buffered while no
  /// prompt was pending (piped input) are drained synchronously.
  Future<String?> _promptLine(String question) async {
    // Guided flows run sequentially (one command at a time); complete a
    // stray pending prompt defensively as cancelled.
    final stray = _pendingPromptAnswer;
    if (stray != null && !stray.isCompleted) stray.complete(null);
    // Assign before writing/checking: the input gate routes lines to this
    // completer from here on, so an answer arriving mid-setup can no
    // longer fall between the buffer check and the assignment (deadlock).
    final pending = Completer<String?>();
    _pendingPromptAnswer = pending;
    io.write(question);
    if (_promptLineBuffer.isNotEmpty) {
      final buffered = _promptLineBuffer.removeAt(0);
      // Piped lines are not echoed by the terminal; keep the transcript
      // readable like the interactively typed answers.
      io.writeln(buffered);
      pending.complete(buffered);
    }
    final interruptSub = io.interrupts.listen((_) {
      if (!pending.isCompleted) pending.complete(null);
    });
    final line = await pending.future;
    await interruptSub.cancel();
    if (identical(_pendingPromptAnswer, pending)) {
      _pendingPromptAnswer = null;
    }
    // The answer replaced the prompt line; keep output tidy.
    if (line != null) io.writeln('');
    return line;
  }

  /// The flow's multiple-choice questions: a TUI menu when the controller
  /// is up (answer arrives via `_tuiPickerSelected` / cancel via
  /// `_tuiPickerCancelled`), a numbered list plus line prompt otherwise.
  Future<String?> _pickOption(
    String title,
    List<FlowOption> options, {
    String? initialKey,
  }) async {
    final controller = _tuiController;
    if (_useTui && controller != null) {
      final stray = _wizardPickerAnswer;
      if (stray != null && !stray.isCompleted) stray.complete(null);
      final pending = Completer<String?>();
      _wizardPickerAnswer = pending;
      controller.openPicker('wizard:$title', title, [
        for (final (key, label, description) in options)
          MenuItem(key: key, label: label, description: description),
      ], initialKey: initialKey);
      return pending.future;
    }
    io.writeln(title);
    for (var i = 0; i < options.length; i++) {
      final (key, label, description) = options[i];
      final desc = description.isNotEmpty ? ' — $description' : '';
      final current = key == initialKey ? ' (current)' : '';
      io.writeln('  ${i + 1}) $label$desc$current');
    }
    for (;;) {
      final answer = await _promptLine('type a number: ');
      if (answer == null) return null;
      final number = int.tryParse(answer.trim());
      if (number != null && number >= 1 && number <= options.length) {
        return options[number - 1].$1;
      }
      io.writeln(
        'invalid selection: ${answer.trim()} '
        '(1-${options.length}, Ctrl-C to cancel)',
      );
    }
  }

  /// The flow's `/models` fetch with the same key resolution the provider
  /// switch uses (explicit token, else env → endpoint-scoped → legacy store).
  Future<List<String>> _fetchModelsForFlow(
    ProviderSpec spec,
    String baseUrl, {
    String? token,
  }) {
    final key = token ?? _providerKeyFor(spec, baseUrl) ?? '';
    final fetch = config.modelsFetcher ?? _fetchOpenAiCompatibleModels;
    return fetch(baseUrl, apiKey: key);
  }

  /// Applies a completed wizard: writes/updates the registry entry (and the
  /// secure-store key under the entry's own key name), then switches the
  /// provider. In edit mode ([editName]) the entry keeps its name and its
  /// existing key when no new token was typed.
  Future<void> _applyCustomProviderSetup(
    CustomProviderSetup setup, {
    String? editName,
  }) async {
    final registry = config.customProviders;
    final modelId = setup.modelId.isNotEmpty
        ? setup.modelId
        : _agent.state.model.id;
    String? keyName;
    final token = setup.token;
    if (token != null) {
      // A same-name edit keeps the entry's existing store name (stable key
      // slot); a new entry (or a rename) gets a NAME-scoped one, so several
      // accounts on the same endpoint keep separate keys instead of
      // overwriting one host-scoped entry.
      final existing = editName != null ? registry?.find(editName) : null;
      keyName =
          existing != null && existing.keyName != null && setup.name == editName
          ? existing.keyName!
          : CustomProviderRegistry.keyNameFor(
              setup.baseUrl,
              providerName: setup.name,
            );
      final keys = config.secureKeys;
      if (keys != null && keys.available) {
        await keys.save(keyName, token);
        config.onSecretStored?.call(keyName, token);
      } else {
        // No secure store OR the write failed (locked/managed keychain):
        // the key still applies to this session via the switch below, but
        // cannot persist with the entry.
        keyName = null;
        io.writeln(
          'could not save the key to the secure store (unavailable, locked, '
          'or managed) — it applies to this session only and is not saved '
          'with the provider',
        );
      }
    } else if (editName != null) {
      keyName = registry?.find(editName)?.keyName;
    }
    CustomProviderEntry? entry;
    if (registry != null) {
      // Renaming on edit: drop the old entry so the new name replaces it.
      if (editName != null && setup.name != editName) {
        registry.entries.removeWhere((e) => e.name == editName);
        io.writeln('renamed provider $editName to ${setup.name}');
      }
      entry = CustomProviderEntry(
        name: setup.name,
        apiType: setup.spec.name,
        baseUrl: setup.baseUrl,
        modelId: modelId,
        keyName: keyName,
      );
      registry.add(entry);
      _activeCustomName = entry.name;
      if (editName == null) {
        io.writeln('saved provider ${entry.name} (listed first in /provider)');
      }
    }
    // The key for the switch: the freshly typed token, else the entry's
    // stored key, else the env resolution inside _switchProvider.
    final stored = entry?.keyName;
    final switchToken =
        token ?? (stored != null ? config.secureKeys?.read(stored) : null);
    await _switchProvider(
      setup.spec,
      setup.baseUrl,
      modelId,
      token: switchToken,
      tokenKeyName: keyName,
    );
  }

  /// Switches to a saved registry entry (picker or typed `/provider <name>`):
  /// restores its last-used model and marks it active.
  Future<void> _switchToSavedProvider(CustomProviderEntry entry) async {
    final keyName = entry.keyName;
    final token = keyName != null ? config.secureKeys?.read(keyName) : null;
    _activeCustomName = entry.name;
    await _switchProvider(
      entry.spec,
      entry.baseUrl,
      entry.modelId,
      token: token,
      tokenKeyName: keyName,
    );
  }

  /// Per-provider model memory: while a saved custom provider is active, a
  /// `/model` switch rewrites the entry's last-used model (the host persists
  /// it with the usual config save).
  void _recordCustomModel(String modelId) {
    final active = _activeCustomName;
    if (active == null) return;
    config.customProviders?.updateModel(active, modelId);
  }

  /// The TUI provider picker (bare `/provider`): saved custom providers
  /// first, then the catalog presets, then the `+ Add provider` wizard
  /// entry last. A saved selection restores the entry's last-used model.
  void _openProviderPicker() {
    final registry = config.customProviders;
    final current = _agent.state.model.provider;
    final activeName = _activeCustomName;
    final items = <MenuItem>[
      if (registry != null)
        for (final entry in registry.entries)
          MenuItem(
            key: 'saved:${entry.name}',
            label: entry.name,
            description:
                '${entry.baseUrl} · ${entry.modelId}'
                '${entry.name == activeName ? ' (current)' : ''}',
          ),
      for (final spec in providerCatalog.values)
        MenuItem(
          key: spec.name,
          label: spec.name,
          description:
              '${spec.defaultBaseUrl}'
              '${spec.name == current && activeName == null ? ' (current)' : ''}',
        ),
      const MenuItem(
        key: 'custom',
        label: '+ Add provider',
        description: 'guided setup: api type, url, key, model',
      ),
    ];
    _tuiController?.openPicker('provider', 'Select provider', items);
  }

  /// `/provider [name] [baseUrl] [token] | custom` — shows the active
  /// provider, endpoint, and key status plus the supported catalog; switches
  /// the provider/endpoint at runtime; or starts the guided custom-provider
  /// setup (`custom`, see provider_flow.dart). A saved provider name
  /// (registry) restores its last-used model. Without an explicit token the
  /// key resolves from the provider's catalog env names; a custom endpoint
  /// may run keyless (local servers). The executable persists
  /// provider/model/baseUrl but never the key itself.
  Future<void> _handleProviderCommand(String rest) async {
    final args = rest
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (args.isEmpty) {
      _printProviderStatus();
      return;
    }
    if (args.first == 'custom') {
      if (args.length > 1) {
        io.writeln('usage: /provider custom');
        return;
      }
      _startProviderFlow();
      return;
    }
    if (args.length > 3) {
      io.writeln('usage: /provider <name> [baseUrl] [token]');
      return;
    }
    // A saved custom provider name resolves before the catalog (registry
    // names can never collide with catalog names by construction).
    final saved = args.length == 1
        ? config.customProviders?.find(args[0])
        : null;
    if (saved != null) {
      await _switchToSavedProvider(saved);
      return;
    }
    final spec = catalogProvider(args[0]);
    if (spec == null) {
      io.writeln(
        'unknown provider: ${args[0]} — supported providers: '
        '${providerCatalog.keys.join(', ')}',
      );
      return;
    }
    _activeCustomName = null;
    final baseUrl = args.length > 1 ? args[1] : spec.defaultBaseUrl;
    final token = args.length > 2 ? args[2] : null;
    await _switchProvider(spec, baseUrl, _agent.state.model.id, token: token);
  }

  /// Applies a provider/endpoint switch: rebuilds the model and stream
  /// (roles mode pins the default chain instead), records the change, and
  /// prints the confirmation. [modelId] replaces the active id (the typed
  /// command keeps it, the custom flow lets the user pick); [token] is an
  /// explicit session key — persisted to the secure store under
  /// [tokenKeyName] (default: the spec's primary env name), never to the
  /// config file. Without [token] the key resolves from the provider's
  /// catalog env names.
  Future<void> _switchProvider(
    ProviderSpec spec,
    String baseUrl,
    String modelId, {
    String? token,
    String? tokenKeyName,
  }) async {
    final modelLine = modelId == _agent.state.model.id
        ? '  model unchanged: $modelId — use /model to change'
        : '  model: $modelId';
    final rolesResolver = config.modelRolesResolver;
    if (rolesResolver != null) {
      // Roles mode: pin the default role to the new provider/endpoint (a
      // single-entry chain for this session), mirroring `/model <id>`.
      // Keys resolve through the resolver's secrets snapshot, so an explicit
      // token cannot be threaded through.
      if (token != null) {
        io.writeln(
          'explicit tokens are not supported while model roles are active; '
          'set ${spec.apiKeyEnvNames.first} in the environment instead',
        );
        return;
      }
      try {
        rolesResolver.setDefaultChain([
          ModelRef(provider: spec.name, modelId: modelId, baseUrl: baseUrl),
        ]);
        rolesResolver.applyToAgent(_agent);
      } on ConfigException catch (error) {
        io.writeln('cannot switch provider: ${error.message}');
        return;
      }
      _streamFunction = _agent.streamFunction;
      _modelCache = const [];
      _modelContextWindows = const {};
      _modelMaxTokens = const {};
      _lastModelList = null;
      await _session?.appendModelChange(provider: spec.name, modelId: modelId);
      io.writeln('switched provider to ${spec.name} (endpoint: $baseUrl)');
      io.writeln(modelLine);
      config.onModelChanged?.call(_agent.state.model);
      return;
    }
    final key = token ?? _providerKeyFor(spec, baseUrl) ?? '';
    _providerKind = spec.kind;
    _apiKey = key;
    _explicitToken = token != null;
    _streamFunction = providerStreamFunction(spec.kind, key);
    _agent.streamFunction = _streamFunction;
    _agent.state.model = buildCatalogModel(
      spec.name,
      modelId,
      baseUrl: baseUrl,
    );
    // The cached model list belongs to the previous provider/endpoint.
    _modelCache = const [];
    _modelContextWindows = const {};
    _modelMaxTokens = const {};
    _lastModelList = null;
    unawaited(_refreshModelCache());
    await _session?.appendModelChange(provider: spec.name, modelId: modelId);
    var keyLine = _providerKeyLine(spec, baseUrl, explicit: token != null);
    if (token != null) {
      final savedTo = await _storeProviderToken(
        spec,
        baseUrl,
        token,
        keyName: tokenKeyName,
      );
      if (savedTo != null) {
        final storeName =
            tokenKeyName ?? CustomProviderRegistry.keyNameFor(baseUrl);
        keyLine =
            'key: provided (saved to $savedTo; '
            'remove with /key delete $storeName)';
      }
    }
    io.writeln('switched provider to ${spec.name} (${spec.api})');
    io.writeln('  endpoint: $baseUrl');
    io.writeln('  $keyLine');
    io.writeln(modelLine);
    config.onProviderChanged?.call(_providerKind, _apiKey);
  }

  /// Persists an explicit `/provider` token in the platform secure store
  /// so future starts resolve it without env vars. Returns the store label
  /// on success, null when secure storage is unavailable (the token then
  /// stays session-only). The entry name is [keyName] (registry entries use
  /// their own), defaulting to the endpoint-scoped name for [baseUrl] —
  /// NOT the spec's shared env name, so a key for one endpoint can never be
  /// picked up by another (the stale-OPENAI_API_KEY-on-kimi footgun).
  Future<String?> _storeProviderToken(
    ProviderSpec spec,
    String baseUrl,
    String token, {
    String? keyName,
  }) async {
    final keys = config.secureKeys;
    if (keys == null || !keys.available) return null;
    final name = keyName ?? CustomProviderRegistry.keyNameFor(baseUrl);
    if (await keys.save(name, token)) {
      config.onSecretStored?.call(name, token);
      return keys.label;
    }
    io.writeln(
      'note: could not save the key to ${keys.label} (locked or managed '
      'keychain?) — it applies to this session only',
    );
    return null;
  }

  static final _keyNamePattern = RegExp(r'^[A-Za-z0-9_]+$');

  /// `/key [set <NAME> <value> | delete <NAME>]` — manages API keys in the
  /// platform secure store (macOS Keychain, Secret Service, Windows
  /// Credential Locker). Bare `/key` lists, per known key name, where the
  /// active value comes from (env, keychain, or not set) — never values.
  Future<void> _handleKeyCommand(String rest) async {
    final args = rest
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    final keys = config.secureKeys;
    if (args.isEmpty) {
      _printKeyStatus();
      return;
    }
    final storeAvailable = keys != null && keys.available;
    switch (args.first) {
      case 'set':
        if (args.length != 3) {
          io.writeln('usage: /key set <NAME> <value>');
          return;
        }
        if (!_keyNamePattern.hasMatch(args[1])) {
          io.writeln('invalid key name: ${args[1]} (use [A-Za-z0-9_]+)');
          return;
        }
        if (!storeAvailable) {
          io.writeln(
            'secure storage unavailable on this host — '
            'set ${args[1]} in the environment instead',
          );
          return;
        }
        if (!await keys.save(args[1], args[2])) {
          io.writeln(
            'could not save ${args[1]} to ${keys.label}: the write failed '
            '(locked or managed keychain?) — '
            'set ${args[1]} in the environment instead',
          );
          return;
        }
        config.onSecretStored?.call(args[1], args[2]);
        io.writeln('saved ${args[1]} to ${keys.label}');
        // When the stored key serves the active provider, pick it up
        // immediately. Roles mode resolves keys from the resolver's startup
        // snapshot, so there it takes effect on the next start.
        final spec = catalogProvider(_providerKind);
        if (config.modelRolesResolver != null) {
          io.writeln('  takes effect on the next start (roles mode)');
        } else if (spec != null && spec.apiKeyEnvNames.contains(args[1])) {
          _apiKey = args[2];
          _explicitToken = false;
          _streamFunction = providerStreamFunction(spec.kind, args[2]);
          _agent.streamFunction = _streamFunction;
          io.writeln('  active provider key updated');
        }
      case 'delete':
        if (args.length != 2) {
          io.writeln('usage: /key delete <NAME>');
          return;
        }
        if (!_keyNamePattern.hasMatch(args[1])) {
          io.writeln('invalid key name: ${args[1]} (use [A-Za-z0-9_]+)');
          return;
        }
        if (!storeAvailable) {
          io.writeln('secure storage unavailable on this host');
          return;
        }
        await keys.delete(args[1]);
        io.writeln('removed ${args[1]} from ${keys.label}');
      default:
        io.writeln('usage: /key [set <NAME> <value> | delete <NAME>]');
    }
  }

  /// Bare `/key`: for every known key name (the provider catalog's env names
  /// plus names present in the secure-store snapshot), where the active
  /// value comes from — `env`, the store label, or `not set`.
  void _printKeyStatus() {
    final keys = config.secureKeys;
    final names = <String>{
      for (final spec in providerCatalog.values) ...spec.apiKeyEnvNames,
      ...?keys?.names,
    }.toList()..sort();
    for (final name in names) {
      final inEnv = config.envVarIsSet?.call(name) ?? false;
      final inStore = keys != null && keys.read(name) != null;
      final source = inEnv
          ? 'env'
          : inStore
          ? keys.label ?? 'keychain'
          : 'not set';
      io.writeln('  $name: $source');
    }
    if (keys == null || !keys.available) {
      io.writeln(
        'secure storage unavailable on this host — keys resolve from the '
        'environment only',
      );
    } else {
      io.writeln(
        'secure storage: ${keys.label} '
        '(/key set <NAME> <value>, /key delete <NAME>)',
      );
    }
  }

  /// Bare `/provider` in line mode: the active provider/endpoint/key status
  /// plus saved custom providers and the catalog with default endpoints.
  void _printProviderStatus() {
    final model = _agent.state.model;
    io.writeln('provider: ${model.provider} (${model.api})');
    io.writeln('  endpoint: ${model.baseUrl}');
    final keyStatus = _keyStatusLine(model);
    if (keyStatus != null) io.writeln('  $keyStatus');
    final registry = config.customProviders;
    if (registry != null && registry.entries.isNotEmpty) {
      io.writeln('saved providers:');
      for (final entry in registry.entries) {
        final current = entry.name == _activeCustomName ? ' (current)' : '';
        io.writeln(
          '  ${entry.name} — ${entry.baseUrl} · ${entry.modelId}$current',
        );
      }
    }
    io.writeln('supported providers:');
    for (final spec in providerCatalog.values) {
      io.writeln('  ${spec.name} — ${spec.defaultBaseUrl}');
    }
    io.writeln(
      'use /provider <name> [baseUrl] [token] to switch, '
      'or /provider custom for a guided setup',
    );
  }

  /// Resolves the API key for [spec] at [baseUrl], in order:
  /// 1. a genuine ENVIRONMENT value of the catalog env names (it differs
  ///    from the store's entry, so it came from the actual environment) —
  ///    the ecosystem convention stays first;
  /// 2. the endpoint-scoped secure-store entry (`FA_KEY_<HOST>` — what
  ///    `/provider` and the custom-provider wizard write);
  /// 3. legacy env-name store entries, written by older versions.
  /// Null when the host exposes no values (tests, web) or nothing is set.
  String? _providerKeyFor(ProviderSpec spec, String baseUrl) {
    final read = config.envVarValue;
    final keys = config.secureKeys;
    for (final name in spec.apiKeyEnvNames) {
      final value = read?.call(name);
      if (value != null && value.isNotEmpty && value != keys?.read(name)) {
        return value;
      }
    }
    if (keys != null) {
      final scoped = keys.read(CustomProviderRegistry.keyNameFor(baseUrl));
      if (scoped != null && scoped.isNotEmpty) return scoped;
      for (final name in spec.apiKeyEnvNames) {
        final value = keys.read(name);
        if (value != null && value.isNotEmpty) return value;
      }
    }
    return null;
  }

  /// The `/provider` confirmation's key line: the source of the resolved
  /// key (env var name, endpoint-scoped or legacy store entry, or
  /// "provided" for an explicit token — never the value), a keyless note
  /// for a custom endpoint (local servers may legitimately run without a
  /// key), or a warning when a hosted endpoint has no key.
  String _providerKeyLine(
    ProviderSpec spec,
    String baseUrl, {
    required bool explicit,
  }) {
    if (explicit) return 'key: provided';
    final read = config.envVarValue;
    final keys = config.secureKeys;
    for (final name in spec.apiKeyEnvNames) {
      final value = read?.call(name);
      if (value != null && value.isNotEmpty && value != keys?.read(name)) {
        return 'key: $name';
      }
    }
    if (keys != null) {
      final scopedName = CustomProviderRegistry.keyNameFor(baseUrl);
      if (keys.read(scopedName) != null) {
        return 'key: $scopedName (${keys.label ?? 'secure store'})';
      }
      for (final name in spec.apiKeyEnvNames) {
        if (keys.read(name) != null) {
          return 'key: $name (${keys.label ?? 'secure store'})';
        }
      }
    }
    if (baseUrl != spec.defaultBaseUrl) return 'key: none (keyless endpoint)';
    return 'key: no key found (want ${spec.apiKeyEnvNames.first})';
  }

  // ------------------------------------------------------------- models

  List<MenuItem> _buildModelMenu(String filter) {
    // If we have no cached models yet, kick off a background fetch and show a
    // loading placeholder. The picker will refresh automatically when the list
    // arrives.
    if (_modelCache.isEmpty && _modelCacheFuture == null) {
      unawaited(_refreshModelCache());
    }
    final models = _modelCandidates(filter);
    if (models.isEmpty) {
      return const [MenuItem(key: '', label: 'loading models...')];
    }
    return [
      for (var i = 0; i < models.length; i++)
        MenuItem(key: models[i], label: '${i + 1}) ${models[i]}'),
    ];
  }

  Future<void> _tuiSelectModel(String modelId) async {
    await _handleModelCommand(modelId);
  }

  /// Fetches the model list from an OpenAI-compatible `/models` endpoint and
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
        final fetch = config.modelsFetcher ?? _fetchOpenAiCompatibleModels;
        final ids = await fetch(model.baseUrl, apiKey: _apiKey);
        if (ids.isNotEmpty) {
          _modelCache = ids;
          _tuiController?.sendModelsRefresh();
          if (config.modelRolesResolver == null) {
            final detected = _modelContextWindows[model.id];
            if (detected != null && detected != model.contextWindow) {
              _replaceModelLimits(contextWindow: detected);
              io.writeln(
                _style.dim('model context window: $detected (from endpoint)'),
              );
            }
            final detectedCap = _modelMaxTokens[model.id];
            if (detectedCap != null && detectedCap != model.maxTokens) {
              _replaceModelLimits(maxTokens: detectedCap);
              io.writeln(
                _style.dim('model max tokens: $detectedCap (from endpoint)'),
              );
            }
          }
        }
      }
    } finally {
      _modelCacheFuture = null;
      completer.complete();
    }
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
    if (_modelCache.isEmpty && _modelCacheFuture == null) {
      await _refreshModelCache();
    }
    final candidates = _modelCandidates(filter);
    if (candidates.isEmpty) {
      io.writeln('no known models for provider ${_agent.state.model.provider}');
      return;
    }
    io.writeln('models for ${_agent.state.model.provider}:');
    for (var i = 0; i < candidates.length; i++) {
      io.writeln('  ${i + 1}) ${candidates[i]}');
    }
    _lastModelList = candidates;
    io.writeln('use /model <n> or /model <id> to switch');
  }

  /// Returns the full list of known model ids for the active provider.
  List<String> _listModelsForMenu() => _modelCandidates('');

  /// Returns known model ids for the active provider, filtered by an optional
  /// lowercase substring. Prefers the live cache fetched from the provider's
  /// `/models` endpoint; falls back to the hardcoded subset when the cache is
  /// empty or the fetch has not completed yet.
  List<String> _modelCandidates([String filter = '']) {
    final provider = _agent.state.model.provider;
    final all = _modelCache.isNotEmpty
        ? _modelCache
        : (_knownModels[provider] ?? const <String>[]);
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
    final number = int.tryParse(trimmed);
    final lastList = _lastModelList ?? _listModelsForMenu();
    if (number != null) {
      if (number < 1 || number > lastList.length) {
        io.writeln('invalid selection: $number (1-${lastList.length})');
        return;
      }
      await _switchModel(lastList[number - 1]);
      return;
    }
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
        ),
      ]);
      rolesResolver.applyToAgent(_agent);
      _streamFunction = _agent.streamFunction;
    } else {
      final key = _providerKeyFor(spec, def.baseUrl) ?? '';
      _providerKind = spec.kind;
      _apiKey = key;
      _explicitToken = false;
      _streamFunction = providerStreamFunction(spec.kind, key);
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
    config.onModelChanged?.call(_agent.state.model);
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
    if (rolesResolver != null) {
      // Roles mode: pin the default role to the requested model id on the
      // current provider (a single-entry chain for this session).
      rolesResolver.setDefaultChain([
        ModelRef(
          provider: current.provider,
          modelId: modelId,
          baseUrl: current.baseUrl,
          contextWindow: window,
          maxTokens: cap,
        ),
      ]);
      rolesResolver.applyToAgent(_agent);
      _streamFunction = _agent.streamFunction;
      await _session?.appendModelChange(
        provider: current.provider,
        modelId: modelId,
      );
      io.writeln('switched model to $modelId');
      _recordCustomModel(modelId);
      config.onModelChanged?.call(_agent.state.model);
      return;
    }
    _agent.state.model = Model(
      id: modelId,
      name: modelId,
      api: current.api,
      provider: current.provider,
      baseUrl: current.baseUrl,
      reasoning: current.reasoning,
      input: current.input,
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
    _recordCustomModel(modelId);
    config.onModelChanged?.call(_agent.state.model);
  }

  /// `/model-edit [contextWindow|maxTokens <n>]`: shows or overrides the
  /// active model's token limits for this session (persist per chain via
  /// roles yaml `contextWindow:`/`maxTokens:`).
  void _handleModelEdit(String rest) {
    final current = _agent.state.model;
    final args = rest
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (args.isEmpty) {
      io.writeln(
        'model ${current.id}: contextWindow ${current.contextWindow} · '
        'maxTokens ${current.maxTokens}',
      );
      io.writeln(
        _style.dim('set with /model-edit <contextWindow|maxTokens> <n>'),
      );
      return;
    }
    final value = args.length == 2 ? int.tryParse(args[1]) : null;
    if (args.length != 2 || value == null || value <= 0) {
      io.writeln('usage: /model-edit <contextWindow|maxTokens> <n>');
      return;
    }
    switch (args[0]) {
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
    config.onModelChanged?.call(_agent.state.model);
  }
}

/// Known model ids shown by `/models` and the `/model` picker. Maps the
/// provider name stored on the active [Model] to a short, useful subset.
const _knownModels = <String, List<String>>{
  'openrouter': [
    'anthropic/claude-sonnet-4',
    'openai/gpt-4o-mini',
    'google/gemini-2.5-pro',
    'anthropic/claude-opus-4',
    'openai/gpt-4.1-mini',
  ],
  'anthropic': ['claude-sonnet-4-5', 'claude-opus-4', 'claude-haiku-4'],
  'google': ['gemini-2.5-pro', 'gemini-2.0-flash'],
  'openai': ['gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini'],
};
