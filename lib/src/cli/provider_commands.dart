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

  /// `/provider-edit`: asks Edit/Delete first, then either runs the guided
  /// edit flow (prefilled with the active provider) or deletes it with
  /// confirmation. Catalog providers can only be edited (no registry entry).
  void _startProviderEditFlow() {
    final entry = config.customProviders?.find(_activeCustomName ?? '');
    if (entry != null) {
      _providerEditOrDelete(entry);
      return;
    }
    // Catalog provider: no registry entry to delete — just edit.
    _startProviderEditWizard(entry);
  }

  /// The Edit/Delete picker for a custom provider entry.
  Future<void> _providerEditOrDelete(CustomProviderEntry entry) async {
    io.writeln('provider ${entry.name} (${entry.baseUrl})');
    final choice = await _pickOption('action', [
      ('edit', 'Edit provider', 'change base URL, name, key, or model'),
      ('delete', 'Delete provider', 'remove from the registry'),
    ]);
    if (choice == null) return;
    if (choice == 'delete') {
      await _deleteProviderWithConfirmation(entry);
      return;
    }
    _startProviderEditWizard(entry);
  }

  /// The edit wizard (prefilled from the entry or active provider).
  void _startProviderEditWizard(CustomProviderEntry? entry) {
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

  /// Deletes [entry] after a y/N confirmation.
  Future<void> _deleteProviderWithConfirmation(
    CustomProviderEntry entry,
  ) async {
    io.writeln(
      'Delete provider ${entry.name} (${entry.baseUrl}, model: ${entry.modelId})?',
    );
    final answer = await _pickOption('confirm delete', [
      ('y', 'Yes, delete', 'remove from the registry'),
      ('n', 'No, cancel', 'keep the provider'),
    ]);
    if (answer != 'y') {
      io.writeln('delete cancelled');
      return;
    }
    final registry = config.customProviders;
    if (registry == null) return;
    registry.entries.removeWhere((e) => e.name == entry.name);
    // Clear the active custom name if the deleted provider was active.
    if (_activeCustomName == entry.name) {
      _activeCustomName = null;
    }
    io.writeln('deleted provider ${entry.name}');
  }

  /// The flow's free-form questions: a TUI text prompt when the controller
  /// is up (masked input for secrets), a plain line prompt otherwise.
  Future<String?> _askLine(String question, {bool secret = false}) async {
    final tui = _tuiController;
    if (_useTui && tui != null) {
      final defaultValue = _extractDefault(question);
      final spec = TextPromptSpec(
        question: question,
        defaultValue: defaultValue,
        secret: secret,
      );
      final result = await tui.openPrompt(spec);
      if (result == null || result is TuiPromptCancelled) return null;
      if (result is TextPromptAnswer) return result.value;
      return null;
    }
    return _promptLine(question);
  }

  /// Parses a `(empty = X):` or `(empty keeps 'X'):` hint from [question],
  /// returning `X` so the TUI prompt can show it as the default value, or
  /// null when no default hint is present.
  String? _extractDefault(String question) {
    final match = RegExp(r'\(empty\s*=\s*(.+?)\)').firstMatch(question);
    if (match != null) return match.group(1)!.trim();
    final keeps = RegExp(r"\(empty\s*keeps\s*'(.+?)'\)").firstMatch(question);
    if (keeps != null) return keeps.group(1)!.trim();
    return null;
  }

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
      return _pickOptionTui(controller, title, options, initialKey: initialKey);
    }
    _printFlowOptions(title, options, initialKey);
    return _promptOptionNumber(options);
  }

  /// The line-mode option list of [_pickOption]: the numbered options with
  /// descriptions and a `(current)` marker on [initialKey].
  void _printFlowOptions(
    String title,
    List<FlowOption> options,
    String? initialKey,
  ) {
    io.writeln(title);
    for (var i = 0; i < options.length; i++) {
      final (key, label, description) = options[i];
      final desc = description.isNotEmpty ? ' — $description' : '';
      final current = key == initialKey ? ' (current)' : '';
      io.writeln('  ${i + 1}) $label$desc$current');
    }
  }

  /// The line-mode answer loop of [_pickOption]: re-prompts until a valid
  /// 1-based number arrives; null on cancel.
  Future<String?> _promptOptionNumber(List<FlowOption> options) async {
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

  /// The TUI variant of [_pickOption]: opens the menu on the controller
  /// and resolves with the picked key (or null on cancel). A stray pending
  /// picker answer is completed defensively as cancelled.
  Future<String?> _pickOptionTui(
    FaTuiController controller,
    String title,
    List<FlowOption> options, {
    String? initialKey,
  }) {
    final pending = _replaceWizardPickerAnswer();
    controller.openPicker('wizard:$title', title, [
      for (final (key, label, description) in options)
        MenuItem(key: key, label: label, description: description),
    ], initialKey: initialKey);
    return pending.future;
  }

  /// Installs a fresh wizard-picker answer completer; a stray pending one is
  /// completed defensively as cancelled.
  Completer<String?> _replaceWizardPickerAnswer() {
    final stray = _wizardPickerAnswer;
    if (stray?.isCompleted == false) stray!.complete(null);
    final pending = Completer<String?>();
    _wizardPickerAnswer = pending;
    return pending;
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
    final token = setup.token;
    final keyName = await _persistSetupKey(setup, editName);
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

  /// The key-name/persistence step of [_applyCustomProviderSetup]: returns
  /// the secure-store key name the entry should carry, or null when no key
  /// persists (keyless, session-only, or a failed/unavailable store).
  /// Without a fresh token the edit keeps the entry's existing key name.
  Future<String?> _persistSetupKey(
    CustomProviderSetup setup,
    String? editName,
  ) async {
    final registry = config.customProviders;
    final token = setup.token;
    if (token == null) {
      return editName != null ? registry?.find(editName)?.keyName : null;
    }
    final keyName = _setupKeyName(setup, editName);
    final keys = config.secureKeys;
    if (keys != null && keys.available) {
      await keys.save(keyName, token);
      config.onSecretStored?.call(keyName, token);
      return keyName;
    }
    // No secure store OR the write failed (locked/managed keychain):
    // the key still applies to this session via the switch below, but
    // cannot persist with the entry.
    io.writeln(
      'could not save the key to the secure store (unavailable, locked, '
      'or managed) — it applies to this session only and is not saved '
      'with the provider',
    );
    return null;
  }

  /// The secure-store key name a setup entry should carry: a same-name edit
  /// keeps the entry's existing store name (stable key slot); a new entry
  /// (or a rename) gets a NAME-scoped one, so several accounts on the same
  /// endpoint keep separate keys instead of overwriting one host-scoped
  /// entry.
  String _setupKeyName(CustomProviderSetup setup, String? editName) {
    final keyName = _reusedSetupEntry(setup, editName)?.keyName;
    return keyName ??
        CustomProviderRegistry.keyNameFor(
          setup.baseUrl,
          providerName: setup.name,
        );
  }

  /// The saved entry whose store key a setup edit reuses: only a same-name
  /// edit of an existing entry (a rename is a new key slot).
  CustomProviderEntry? _reusedSetupEntry(
    CustomProviderSetup setup,
    String? editName,
  ) {
    if (editName == null || setup.name != editName) return null;
    return config.customProviders?.find(editName);
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
    final items = <MenuItem>[
      ..._savedProviderItems(),
      ..._catalogProviderItems(),
      const MenuItem(
        key: 'custom',
        label: '+ Add provider',
        description: 'guided setup: api type, url, key, model',
      ),
    ];
    _tuiController?.openPicker('provider', 'Select provider', items);
  }

  /// The picker's saved-custom-provider entries (registry order), each
  /// marked `(current)` when it is the active one.
  Iterable<MenuItem> _savedProviderItems() {
    final registry = config.customProviders;
    if (registry == null) return const [];
    return [for (final entry in registry.entries) _savedProviderItem(entry)];
  }

  /// One picker entry for a saved custom provider, marked `(current)` when
  /// it is the active one.
  MenuItem _savedProviderItem(CustomProviderEntry entry) => MenuItem(
    key: 'saved:${entry.name}',
    label: entry.name,
    description:
        '${entry.baseUrl} · ${entry.modelId}'
        '${entry.name == _activeCustomName ? ' (current)' : ''}',
  );

  /// The picker's catalog presets; the active provider is marked
  /// `(current)` unless a saved custom provider is active instead.
  Iterable<MenuItem> _catalogProviderItems() {
    final current = _agent.state.model.provider;
    final activeName = _activeCustomName;
    return [
      for (final spec in providerCatalog.values)
        _catalogProviderItem(
          spec,
          isCurrent: activeName == null && spec.name == current,
        ),
    ];
  }

  /// One picker entry for a catalog preset.
  MenuItem _catalogProviderItem(ProviderSpec spec, {required bool isCurrent}) =>
      MenuItem(
        key: spec.name,
        label: spec.name,
        description:
            '${spec.defaultBaseUrl}'
            '${isCurrent ? ' (current)' : ''}',
      );

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
    if (_startCustomProviderArg(args)) return;
    if (_startOpenRouterOAuthArg(args)) return;
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
    await _switchToCatalogProvider(args);
  }

  /// The `/provider custom` branch of [_handleProviderCommand]: starts the
  /// guided setup. Returns true when the command targeted the custom flow
  /// (handled — setup started or the usage error printed).
  bool _startCustomProviderArg(List<String> args) {
    if (args.first != 'custom') return false;
    if (args.length > 1) {
      io.writeln('usage: /provider custom');
      return true;
    }
    _startProviderFlow();
    return true;
  }

  Future<OpenRouterOAuthKey> _defaultOpenRouterExchange({
    required String code,
    required String codeVerifier,
    String? label,
  }) => exchangeOpenRouterCode(code, codeVerifier: codeVerifier, label: label);

  /// The `/provider openrouter oauth [headless]` branch: authenticates the
  /// user with OpenRouter via PKCE and stores the resulting API key.
  /// Returns true when the command targeted the OAuth flow.
  bool _startOpenRouterOAuthArg(List<String> args) {
    if (args.first != 'openrouter') return false;
    if (args.length < 2 || args[1] != 'oauth') {
      return false;
    }
    final headless = args.length > 2 && args[2] == 'headless';
    if (args.length > 3 || (args.length == 3 && !headless)) {
      io.writeln('usage: /provider openrouter oauth [headless]');
      return true;
    }
    unawaited(_handleOpenRouterOAuthCommand(headless: headless));
    return true;
  }

  /// Runs the OpenRouter OAuth flow and saves the resulting key.
  ///
  /// When [headless] is true, prints a URL the user opens manually and prompts
  /// for the authorization code OpenRouter displays. Otherwise starts a local
  /// HTTP server, opens the browser, captures the callback, and exchanges the
  /// code automatically.
  ///
  /// [exchangeFn] is injectable for tests; production uses [exchangeOpenRouterCode].
  Future<void> _handleOpenRouterOAuthCommand({required bool headless}) async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      await _runOpenRouterOAuthCommand(headless: headless);
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
  }

  Future<void> _runOpenRouterOAuthCommand({required bool headless}) async {
    final spec = providerCatalog['openrouter'];
    if (spec == null) {
      io.writeln('OpenRouter provider not found in catalog');
      return;
    }

    final exchangeFn =
        config.openRouterOAuthExchangeFn ?? _defaultOpenRouterExchange;

    OpenRouterOAuthKey? key;
    if (headless) {
      key = await _runOpenRouterHeadlessOAuth(exchangeFn: exchangeFn);
    } else {
      key = await runOpenRouterOAuthCliFlow(
        onStatus: io.writeln,
        exchangeFn: exchangeFn,
      );
    }

    if (key == null) return;

    await _applyOpenRouterOAuthKey(spec, key);
  }

  /// Headless OAuth: show the URL, ask the user to paste the code, exchange it.
  Future<OpenRouterOAuthKey?> _runOpenRouterHeadlessOAuth({
    required Future<OpenRouterOAuthKey> Function({
      required String code,
      required String codeVerifier,
      String? label,
    })
    exchangeFn,
  }) async {
    final verifier = generateOpenRouterCodeVerifier();
    final challenge = generateOpenRouterCodeChallenge(verifier);
    final authUrl = buildOpenRouterAuthUrl(
      codeChallenge: challenge,
      keyLabel: openRouterDefaultKeyLabel,
    );

    io.writeln(
      'OpenRouter OAuth (headless): open this URL in a browser, authorize, '
      'then paste the code shown on screen:',
    );
    io.writeln(authUrl.toString());

    final code = await _askLine('authorization code: ');
    if (code == null || code.trim().isEmpty) {
      io.writeln('OpenRouter OAuth cancelled');
      return null;
    }
    io.writeln('authorization code received, exchanging for API key...');

    try {
      return await exchangeFn(
        code: code.trim(),
        codeVerifier: verifier,
        label: openRouterDefaultKeyLabel,
      );
    } on ConfigException catch (e) {
      io.writeln('OpenRouter OAuth failed: ${e.message}');
      return null;
    }
  }

  /// Saves an OAuth-derived OpenRouter key and switches to OpenRouter.
  Future<void> _applyOpenRouterOAuthKey(
    ProviderSpec spec,
    OpenRouterOAuthKey key,
  ) async {
    io.writeln('OpenRouter authorized');
    final keyName = spec.apiKeyEnvNames.first;
    await _storeProviderToken(
      spec,
      spec.defaultBaseUrl,
      key.key,
      keyName: keyName,
    );
    // already active (not just any openai-completions endpoint).
    final isOpenRouterActive =
        _activeCustomName == null &&
        _agent.state.model.provider == spec.name &&
        _agent.state.model.baseUrl == spec.defaultBaseUrl;
    if (isOpenRouterActive) {
      _apiKey = key.key;
      _explicitToken = true;
      _streamFunction = providerStreamFunction(
        spec.kind,
        key.key,
        sessionId: () => _session?.cachedId,
      );
      _agent.streamFunction = _streamFunction;
      io.writeln('OpenRouter key updated for current session');
    } else {
      // Switch to OpenRouter so the key is immediately usable.
      await _switchProvider(
        spec,
        spec.defaultBaseUrl,
        _agent.state.model.id,
        token: key.key,
        tokenKeyName: keyName,
      );
    }
    if (key.settingsUrl != null) {
      io.writeln('key settings: ${key.settingsUrl}');
    }
  }

  /// The catalog-switch branch of [_handleProviderCommand]: resolves the
  /// provider name against the catalog and switches with the optional
  /// endpoint/token args.
  Future<void> _switchToCatalogProvider(List<String> args) async {
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
    _streamFunction = providerStreamFunction(
      spec.kind,
      key,
      sessionId: () => _session?.cachedId,
    );
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
    if (args.isEmpty) {
      _printKeyStatus();
      return;
    }
    switch (args.first) {
      case 'set':
        await _handleKeySet(args);
      case 'delete':
        await _handleKeyDelete(args);
      default:
        io.writeln('usage: /key [set <NAME> <value> | delete <NAME>]');
    }
  }

  /// `/key delete <NAME>`: validates the name and removes it from the
  /// secure store.
  Future<void> _handleKeyDelete(List<String> args) async {
    final keys = config.secureKeys;
    if (args.length != 2) {
      io.writeln('usage: /key delete <NAME>');
      return;
    }
    if (!_keyNamePattern.hasMatch(args[1])) {
      io.writeln('invalid key name: ${args[1]} (use [A-Za-z0-9_]+)');
      return;
    }
    if (keys == null || !keys.available) {
      io.writeln('secure storage unavailable on this host');
      return;
    }
    await keys.delete(args[1]);
    io.writeln('removed ${args[1]} from ${keys.label}');
  }

  /// `/key set <NAME> [<value>]`: validates the name, writes the value to
  /// the secure store, and picks the key up immediately when it serves the
  /// active provider (roles mode applies it on the next start). The explicit
  /// 3-arg form (`/key set NAME value`) takes the value verbatim from the
  /// command line (scriptable, visible in scrollback); with fewer args the
  /// value is prompted — through the TUI prompt zone (masked) when available,
  /// or a plain line prompt otherwise.
  Future<void> _handleKeySet(List<String> args) async {
    final keys = config.secureKeys;
    final storeAvailable = keys != null && keys.available;
    // Explicit 3-arg form stays scriptable (value verbatim from the line).
    if (args.length == 3) {
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
      _applySavedKeyToActiveProvider(args[1], args[2]);
      return;
    }
    if (args.length > 3) {
      io.writeln('usage: /key set <NAME> [<value>]');
      return;
    }
    // 0-1 value args after `set`: interactive (TUI) or prompted (line mode).
    final name = args.length == 2 ? args[1] : null;
    final tui = _tuiController;
    if (_useTui && tui != null) {
      await _handleKeySetInteractive(tui: tui, name: name);
      return;
    }
    // Line mode: bare `/key set` cannot prompt for the name interactively.
    if (name == null) {
      io.writeln('usage: /key set <NAME> [<value>]');
      return;
    }
    if (!_keyNamePattern.hasMatch(name)) {
      io.writeln('invalid key name: $name (use [A-Za-z0-9_]+)');
      return;
    }
    if (!storeAvailable) {
      io.writeln(
        'secure storage unavailable on this host — '
        'set $name in the environment instead',
      );
      return;
    }
    // Line mode with name only: prompt for the value through a
    // fire-and-forget flow so the REPL keeps reading lines (same pattern
    // as the provider wizard — _promptLine blocks on the next input line).
    _providerFlowActive = true;
    unawaited(() async {
      try {
        final value = await _promptLine('value for $name: ');
        if (value == null || value.isEmpty) {
          io.writeln('cancelled');
          return;
        }
        if (!await keys.save(name, value)) {
          io.writeln(
            'could not save $name to ${keys.label}: the write failed '
            '(locked or managed keychain?) — '
            'set $name in the environment instead',
          );
          return;
        }
        config.onSecretStored?.call(name, value);
        io.writeln('saved $name to ${keys.label}');
        _applySavedKeyToActiveProvider(name, value);
      } finally {
        _providerFlowActive = false;
        _promptLineBuffer.clear();
      }
    }());
  }

  /// The TUI interactive variant of [_handleKeySet]: prompts for the key
  /// name (when [name] is null) and a masked value through the TUI prompt
  /// zone, then saves. Cancelling either prompt (Esc) aborts silently.
  Future<void> _handleKeySetInteractive({
    required FaTuiController tui,
    String? name,
  }) async {
    final keys = config.secureKeys;
    if (keys == null || !keys.available) {
      io.writeln('secure storage unavailable on this host');
      return;
    }
    // Step 1: name (if not provided on the command line).
    var keyName = name;
    if (keyName == null) {
      final nameSpec = TextPromptSpec(
        header: 'Key',
        question: 'Key name (UPPER_SNAKE or [A-Za-z0-9_]+):',
      );
      final nameResult = await tui.openPrompt(nameSpec);
      if (nameResult == null || nameResult is! TextPromptAnswer) return;
      keyName = nameResult.value.trim();
    }
    if (!_keyNamePattern.hasMatch(keyName)) {
      io.writeln('invalid key name: $keyName');
      return;
    }
    // Step 2: value (masked so it never appears in the terminal).
    final valueSpec = TextPromptSpec(
      header: 'Key',
      question: 'Value for $keyName:',
      secret: true,
    );
    final valueResult = await tui.openPrompt(valueSpec);
    if (valueResult == null || valueResult is! TextPromptAnswer) return;
    final value = valueResult.value;
    if (value.isEmpty) {
      io.writeln('cancelled');
      return;
    }
    if (!await keys.save(keyName, value)) {
      io.writeln('could not save $keyName');
      return;
    }
    config.onSecretStored?.call(keyName, value);
    io.writeln('saved $keyName to ${keys.label}');
    _applySavedKeyToActiveProvider(keyName, value);
  }

  /// The tail of [_handleKeySet]: picks the freshly saved key up
  /// immediately when it serves the active provider (roles mode applies it
  /// on the next start).
  void _applySavedKeyToActiveProvider(String name, String value) {
    final spec = catalogProvider(_providerKind);
    if (config.modelRolesResolver != null) {
      io.writeln('  takes effect on the next start (roles mode)');
    } else if (spec != null && spec.apiKeyEnvNames.contains(name)) {
      _apiKey = value;
      _explicitToken = false;
      _streamFunction = providerStreamFunction(
        spec.kind,
        value,
        sessionId: () => _session?.cachedId,
      );
      _agent.streamFunction = _streamFunction;
      io.writeln('  active provider key updated');
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
    _printSavedProviders();
    io.writeln('supported providers:');
    for (final spec in providerCatalog.values) {
      io.writeln('  ${spec.name} — ${spec.defaultBaseUrl}');
    }
    io.writeln(
      'use /provider <name> [baseUrl] [token] to switch, '
      'or /provider custom for a guided setup',
    );
  }

  /// The saved-custom-provider section of [_printProviderStatus], each
  /// entry marked `(current)` when active. Nothing prints without entries.
  void _printSavedProviders() {
    final registry = config.customProviders;
    if (registry == null || registry.entries.isEmpty) return;
    io.writeln('saved providers:');
    for (final entry in registry.entries) {
      final current = entry.name == _activeCustomName ? ' (current)' : '';
      io.writeln(
        '  ${entry.name} — ${entry.baseUrl} · ${entry.modelId}$current',
      );
    }
  }

  /// Resolves the API key for [spec] at [baseUrl], in order:
  /// 1. a genuine ENVIRONMENT value of the catalog env names (it differs
  ///    from the store's entry, so it came from the actual environment) —
  ///    the ecosystem convention stays first;
  /// 2. the endpoint-scoped secure-store entry (`FA_KEY_<HOST>` — what
  ///    `/provider` and the custom-provider wizard write);
  /// 3. legacy env-name store entries, written by older versions.
  /// Null when the host exposes no values (tests, web) or nothing is set.
  /// Resolves the API key for [spec] at [baseUrl]. For the spec's DEFAULT
  /// hosted endpoint: env value → host-scoped store key → legacy env-name
  /// store key (documented order). For ANY OTHER endpoint: only the
  /// endpoint-scoped store keys (the active custom entry's key name, then
  /// the host-scoped one) — the spec's env names (`OPENROUTER_API_KEY` &
  /// friends) describe the default endpoint and must never hijack a custom
  /// one (the user's OpenRouter key silently serving api.aiin.by).
  String? _providerKeyFor(ProviderSpec spec, String baseUrl) {
    if (baseUrl == spec.defaultBaseUrl) {
      return _defaultEndpointKey(spec, baseUrl);
    }
    return _customEndpointKey(baseUrl);
  }

  /// Key resolution for the spec's DEFAULT hosted endpoint: env value →
  /// host-scoped store key → legacy env-name store key (documented order).
  String? _defaultEndpointKey(ProviderSpec spec, String baseUrl) {
    final env = _envKeyEntry(spec);
    if (env != null) return env.$2;
    final keys = config.secureKeys;
    if (keys == null) return null;
    return _storedDefaultEndpointKey(spec, baseUrl, keys);
  }

  /// The first catalog env name holding a genuine environment value (one
  /// that differs from the store's entry, so it came from the actual
  /// environment) as a (name, value) pair, or null.
  (String, String)? _envKeyEntry(ProviderSpec spec) {
    final read = config.envVarValue;
    final keys = config.secureKeys;
    for (final name in spec.apiKeyEnvNames) {
      final value = read?.call(name);
      if (value != null && value.isNotEmpty && value != keys?.read(name)) {
        return (name, value);
      }
    }
    return null;
  }

  /// The stored key for the spec's default endpoint: the endpoint-scoped
  /// entry (`FA_KEY_<HOST>`), then the legacy env-name entries.
  String? _storedDefaultEndpointKey(
    ProviderSpec spec,
    String baseUrl,
    SecureKeyCache keys,
  ) {
    final scoped = keys.read(CustomProviderRegistry.keyNameFor(baseUrl));
    if (scoped != null && scoped.isNotEmpty) return scoped;
    for (final name in spec.apiKeyEnvNames) {
      final value = keys.read(name);
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// Key resolution for ANY OTHER endpoint: only the endpoint-scoped store
  /// keys (the active custom entry's key name, then the host-scoped one) —
  /// the spec's env names (`OPENROUTER_API_KEY` & friends) describe the
  /// default endpoint and must never hijack a custom one (the user's
  /// OpenRouter key silently serving api.aiin.by).
  String? _customEndpointKey(String baseUrl) {
    final keys = config.secureKeys;
    if (keys == null) return null;
    final entryKey = _activeCustomKeyName();
    if (entryKey != null) {
      final entryValue = _nonEmptyStoredKey(keys, entryKey);
      if (entryValue != null) return entryValue;
    }
    return _nonEmptyStoredKey(keys, CustomProviderRegistry.keyNameFor(baseUrl));
  }

  /// The stored value for [name] when it is set and non-empty, else null.
  String? _nonEmptyStoredKey(SecureKeyCache keys, String name) {
    final value = keys.read(name);
    if (value == null || value.isEmpty) return null;
    return value;
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
    if (baseUrl == spec.defaultBaseUrl) {
      return _defaultEndpointKeyLine(spec, baseUrl);
    }
    return _customEndpointKeyLine(baseUrl);
  }

  /// The default-endpoint branch of [_providerKeyLine]: env var name →
  /// endpoint-scoped store entry → legacy env-name store entry, else a
  /// warning that the hosted endpoint has no key.
  String _defaultEndpointKeyLine(ProviderSpec spec, String baseUrl) {
    final keys = config.secureKeys;
    final env = _envKeyEntry(spec);
    if (env != null) return 'key: ${env.$1}';
    if (keys != null) {
      final scopedName = CustomProviderRegistry.keyNameFor(baseUrl);
      if (keys.read(scopedName) != null) {
        return 'key: $scopedName (${keys.label ?? 'secure store'})';
      }
      final legacyName = _legacyStoredKeyName(spec, keys);
      if (legacyName != null) {
        return 'key: $legacyName (${keys.label ?? 'secure store'})';
      }
    }
    return 'key: no key found (want ${spec.apiKeyEnvNames.first})';
  }

  /// The first catalog env name present in the secure store (a legacy
  /// env-name entry), or null.
  String? _legacyStoredKeyName(ProviderSpec spec, SecureKeyCache keys) {
    for (final name in spec.apiKeyEnvNames) {
      if (keys.read(name) != null) return name;
    }
    return null;
  }

  /// The custom-endpoint branch of [_providerKeyLine]: a custom endpoint
  /// never shows the spec's env names as its key (see [_providerKeyFor]) —
  /// only the endpoint-scoped store keys count; a keyless note otherwise
  /// (local servers may legitimately run without a key).
  String _customEndpointKeyLine(String baseUrl) {
    final keys = config.secureKeys;
    if (keys != null) {
      final entryKey = _activeCustomKeyName();
      if (entryKey != null && keys.read(entryKey) != null) {
        return 'key: $entryKey (${keys.label ?? 'secure store'})';
      }
      final scopedName = CustomProviderRegistry.keyNameFor(baseUrl);
      if (keys.read(scopedName) != null) {
        return 'key: $scopedName (${keys.label ?? 'secure store'})';
      }
    }
    return 'key: none (keyless endpoint)';
  }

  // ------------------------------------------------------------- models

  /// Whether the model list still needs its background fetch: no cached
  /// models yet and no fetch already in flight.
  bool get _modelCacheNeedsRefresh =>
      _modelCache.isEmpty && _modelCacheFuture == null;

  List<MenuItem> _buildModelMenu(String filter) {
    // If we have no cached models yet, kick off a background fetch and show a
    // loading placeholder. The picker will refresh automatically when the list
    // arrives.
    if (_modelCacheNeedsRefresh) {
      unawaited(_refreshModelCache());
    }
    return _modelMenuItems(_modelCandidates(filter));
  }

  /// The picker items of [_buildModelMenu]: a loading placeholder while the
  /// candidate list is empty, else the numbered model entries.
  List<MenuItem> _modelMenuItems(List<String> models) {
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
            _applyDetectedContextWindow(model);
            _applyDetectedMaxTokens(model);
          }
        }
      }
    } finally {
      _modelCacheFuture = null;
      completer.complete();
    }
  }

  /// Applies the endpoint-reported context window for [model] when it
  /// differs from the carried one (called from [_refreshModelCache], which
  /// skips both detections in roles mode — the chain's configured limits
  /// win there).
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
    final lastList = _lastModelList ?? _listModelsForMenu();
    if (number < 1 || number > lastList.length) {
      io.writeln('invalid selection: $number (1-${lastList.length})');
      return true;
    }
    await _switchModel(lastList[number - 1]);
    return true;
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
      _streamFunction = providerStreamFunction(
        spec.kind,
        key,
        sessionId: () => _session?.cachedId,
      );
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
  /// roles yaml `contextWindow:`/`maxTokens:`). Bare in TUI mode opens an
  /// interactive two-step picker (field → preset/custom value).
  Future<void> _handleModelEdit(String rest) async {
    final args = rest
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (args.isEmpty) {
      if (_useTui && _tuiController != null) {
        await _modelEditInteractive();
      } else {
        _printModelLimits();
      }
      return;
    }
    _applyModelEditArg(args);
  }

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
  Future<void> _modelEditInteractive() async {
    final tui = _tuiController!;
    final current = _agent.state.model;

    // Step 1: pick field.
    final fieldSpec = AskPromptSpec(
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
    );
    final fieldResult = await tui.openPrompt(fieldSpec);
    if (fieldResult == null || fieldResult is! AskPromptAnswer) return;
    final fieldLabel = fieldResult.value.selected.first;
    final isContext = fieldLabel.contains('Context');

    // Step 2: pick preset (or Custom → free-text).
    final presets = isContext
        ? [4096, 8192, 16384, 32768, 65536, 131072, 204800, 1048576]
        : [4096, 8192, 16384, 32768, 65536];
    final presetSpec = AskPromptSpec(
      header: 'Model Edit',
      question: '${isContext ? 'Context window' : 'Max tokens'} size:',
      index: 0,
      total: 1,
      options: [
        for (final p in presets) AskOption(label: _formatTokenPreset(p)),
        const AskOption(
          label: 'Custom…',
          description: 'Enter a number manually',
        ),
      ],
    );
    final presetResult = await tui.openPrompt(presetSpec);
    if (presetResult == null || presetResult is! AskPromptAnswer) return;
    final picked = presetResult.value.selected.first;

    int value;
    if (picked == 'Custom…') {
      // Step 3: free-text number entry.
      final textSpec = TextPromptSpec(
        header: 'Model Edit',
        question: 'Enter value (tokens):',
      );
      final textResult = await tui.openPrompt(textSpec);
      if (textResult == null || textResult is! TextPromptAnswer) return;
      value = int.tryParse(textResult.value.trim()) ?? 0;
      if (value <= 0) {
        io.writeln('invalid value');
        return;
      }
    } else {
      value = _parseTokenPreset(picked);
    }

    _replaceModelLimits(
      contextWindow: isContext ? value : null,
      maxTokens: isContext ? null : value,
    );
    io.writeln('${isContext ? 'context window' : 'max tokens'} set to $value');
  }

  /// Formats a token count as a compact preset label (`4K`, `16K`, `1M`).
  String _formatTokenPreset(int tokens) {
    if (tokens >= 1048576 && tokens % 1048576 == 0) {
      return '${tokens ~/ 1048576}M';
    }
    if (tokens >= 1024 && tokens % 1024 == 0) {
      return '${tokens ~/ 1024}K';
    }
    return '$tokens';
  }

  /// Parses a compact preset label (`4K`, `16K`, `1M`) back to tokens.
  int _parseTokenPreset(String label) {
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
