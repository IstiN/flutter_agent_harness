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
    ({String label, Future<String?> Function() run})? reauth,
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
          reauth: reauth,
        ),
      ).whenComplete(() {
        _providerFlowActive = false;
        // Leftover buffered lines are flow answers, not user prompts.
        _promptLineBuffer.clear();
      }),
    );
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

  /// The edit wizard (prefilled from the entry when editing one, else from
  /// the active provider). The entry's own baseUrl/modelId/name MUST win
  /// over the live model — otherwise editing a non-active entry shows the
  /// wrong defaults (a kimi-active session editing the codemie entry would
  /// pre-fill Kimi's URL and model into the codemie wizard).
  void _startProviderEditWizard(CustomProviderEntry? entry) {
    final model = _agent.state.model;
    final spec = entry != null
        ? entry.spec
        : (catalogProvider(model.provider) ?? providerCatalog['openai']!);
    _startProviderFlow(
      initialType: entry?.apiType ?? spec.name,
      initialBaseUrl: entry?.baseUrl ?? model.baseUrl,
      initialName: entry?.name,
      initialModelId: entry?.modelId ?? model.id,
      editName: entry?.name,
      reauth: _editReauthOption(entry),
    );
  }

  /// The browser re-authorization choice for the edit wizard's key step:
  /// the same sign-in choice the connect flow offers, so the user can
  /// renew an expired credential without losing the entry. OpenRouter and
  /// CodeMie (any auth method — SSO entries as well as legacy entries
  /// whose `authMethod` was never recorded) get the picker; every other
  /// entry edits the key manually.
  ({String label, Future<String?> Function() run})? _editReauthOption(
    CustomProviderEntry? entry,
  ) {
    if (entry == null) return null;
    final orSpec = providerCatalog['openrouter'];
    if (orSpec != null &&
        (entry.apiType == 'openrouter' ||
            entry.baseUrl == orSpec.defaultBaseUrl)) {
      return (
        label: 'Browser OAuth (openrouter.ai)',
        run: _mintOpenRouterOAuthKey,
      );
    }
    // CodeMie: detected by the `/code-assistant-api/` URL marker — works
    // for legacy entries whose `authMethod` was never recorded too. The
    // picker still offers "Enter a new API key" for users who want to
    // paste a fresh cookie/JWT instead of opening the browser.
    if (entry.baseUrl.contains('/code-assistant-api/')) {
      return (label: 'Browser SSO (CodeMie)', run: _mintCodeMieSsoCookie);
    }
    return null;
  }

  /// Runs the browser OpenRouter OAuth flow and returns only the minted
  /// key: the edit wizard's own apply path persists it under the entry's
  /// key slot and switches, so the connect-time [_applyOpenRouterOAuthKey]
  /// (which stores + switches immediately) does not fit here.
  Future<String?> _mintOpenRouterOAuthKey() async {
    final exchangeFn =
        config.openRouterOAuthExchangeFn ?? _defaultOpenRouterExchange;
    final key = await runOpenRouterOAuthCliFlow(
      onStatus: io.writeln,
      exchangeFn: exchangeFn,
    );
    return key?.key;
  }

  /// Runs the CodeMie SSO login and returns only the freshly minted cookie
  /// string. Mirrors [_mintOpenRouterOAuthKey]: the edit wizard's own apply
  /// path persists it under the entry's key slot and switches, so the
  /// connect-time [_applyCodeMieSsoCredentials] (which also saves a
  /// registry entry and asks for a name) does not fit here.
  Future<String?> _mintCodeMieSsoCookie() async {
    final authenticate =
        config.codeMieSsoAuthenticateFn ??
        (url, onStatus) =>
            runCodeMieSsoCliFlow(codeMieUrl: url, onStatus: onStatus);
    final creds = await authenticate(defaultCodeMieBaseUrl, io.writeln);
    if (creds == null) return null;
    final cookie = creds.authToken;
    if (cookie.isEmpty) {
      io.writeln('CodeMie SSO carried no cookies — aborted');
      return null;
    }
    return cookie;
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
    if (answer != 'y') return io.writeln('delete cancelled');
    removeProvider(entry);
  }

  /// The flow's `/models` fetch with the same key resolution the provider
  /// switch uses (explicit token, else env → endpoint-scoped → legacy store).
  /// Failures answer an empty list: the flow falls back to manual entry.
  Future<List<String>> _fetchModelsForFlow(
    ProviderSpec spec,
    String baseUrl, {
    String? token,
  }) async {
    final key = token ?? _providerKeyFor(spec, baseUrl) ?? '';
    try {
      return await _fetchProviderModelIds(spec.name, baseUrl, key);
    } on Object {
      return const [];
    }
  }

  /// The shared model-list dispatch for the settings flows and the cache
  /// refresh: CodeMie endpoints list `/llm_models`, DIAL serves deployments
  /// (recording the reported limits), everything else is an OpenAI-compatible
  /// `/models` ([AgentCliConfig.modelsFetcher] override included). Without
  /// this a DIAL/CodeMie pick dropped the user into manual model entry.
  Future<List<String>> _fetchProviderModelIds(
    String providerName,
    String baseUrl,
    String key,
  ) async {
    if (baseUrl.contains('/code-assistant-api/')) {
      return fetchCodeMieModels(baseUrl, key, client: config.modelsHttpClient);
    }
    if (providerName == 'dial') {
      return _fetchDialModelsAndFeatures(baseUrl, apiKey: key);
    }
    final fetch = config.modelsFetcher ?? _fetchOpenAiCompatibleModels;
    return fetch(baseUrl, apiKey: key);
  }

  /// Applies a completed wizard: writes/updates the registry entry (and the
  /// secure-store key under the entry's own key name), then switches the
  /// provider. In edit mode ([editName]) the entry keeps its name and
  /// its existing key when no new token was typed.
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
    // Edit mode keeps the existing entry's auth method (SSO/JWT routing
    // is the more precise signal than key format — set explicitly by the
    // connect flows). New entries default to api-key.
    final existingEntry = (editName != null && registry != null)
        ? registry.find(editName)
        : null;
    final entry = await _recordSetupEntry(
      setup,
      registry,
      modelId: modelId,
      keyName: keyName,
      editName: editName,
      existingEntry: existingEntry,
    );
    // The key for the switch: the freshly typed token, else the entry's
    // stored key, else the env resolution inside _switchProvider.
    final stored0 = entry?.keyName;
    final switchToken =
        token ?? (stored0 != null ? config.secureKeys?.read(stored0) : null);
    await _switchSetupEntry(
      setup,
      entry,
      modelId: modelId,
      keyName: keyName,
      switchToken: switchToken,
    );
  }

  /// The switch step of [_applyCustomProviderSetup]: CodeMie endpoints route
  /// through the cookie/JWT-specific helpers (the generic switch would send
  /// a cookie as `Authorization: Bearer`, which CodeMie rejects); everything
  /// else takes the regular switch.
  Future<void> _switchSetupEntry(
    CustomProviderSetup setup,
    CustomProviderEntry? entry, {
    required String modelId,
    required String? keyName,
    required String? switchToken,
  }) async {
    final stored = entry?.keyName;
    final isCodeMie = setup.baseUrl.contains('/code-assistant-api/');
    if (!isCodeMie || switchToken == null) {
      await _switchProvider(
        setup.spec,
        setup.baseUrl,
        modelId,
        token: switchToken,
        tokenKeyName: keyName,
      );
      return;
    }
    // For legacy entries whose `authMethod` was never recorded (defaults
    // to apiKey) we fall back to key-format detection — a JWT-shaped
    // value is a JWT, everything else is treated as a SSO cookie.
    final authMethod = entry?.authMethod ?? CustomProviderAuthMethod.apiKey;
    final looksJwt = isCodeMieJwtToken(switchToken);
    final asSso = authMethod == CustomProviderAuthMethod.sso || !looksJwt;
    if (asSso) {
      await _switchCodeMieProvider(
        setup.spec,
        setup.baseUrl,
        modelId,
        switchToken,
        stored ?? '',
      );
      return;
    }
    await _switchCodeMieJwtProvider(
      setup.spec,
      setup.baseUrl,
      modelId,
      switchToken,
      stored ?? '',
    );
  }

  /// The registry step of [_applyCustomProviderSetup]: writes (or renames
  /// on edit) the entry and returns it, or null without a registry.
  Future<CustomProviderEntry?> _recordSetupEntry(
    CustomProviderSetup setup,
    CustomProviderRegistry? registry, {
    required String modelId,
    required String? keyName,
    required String? editName,
    required CustomProviderEntry? existingEntry,
  }) async {
    if (registry == null) return null;
    // Renaming on edit: drop the old entry so the new name replaces it.
    if (editName != null && setup.name != editName) {
      registry.entries.removeWhere((e) => e.name == editName);
      io.writeln('renamed provider $editName to ${setup.name}');
    }
    final entry = CustomProviderEntry(
      name: setup.name,
      apiType: setup.spec.name,
      baseUrl: setup.baseUrl,
      modelId: modelId,
      keyName: keyName,
      authMethod: existingEntry?.authMethod ?? CustomProviderAuthMethod.apiKey,
    );
    registry.add(entry);
    _activeCustomName = entry.name;
    if (editName == null) {
      io.writeln('saved provider ${entry.name} (listed first in /provider)');
    }
    return entry;
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
  /// restores its last-used model and marks it active. CodeMie endpoints
  /// (detected by the `/code-assistant-api/` URL marker) are routed to
  /// [_switchToSavedCodeMieProvider], which distinguishes SSO cookie auth from
  /// JWT Bearer auth; other entries use the regular provider switch.
  Future<void> _switchToSavedProvider(CustomProviderEntry entry) async {
    if (entry.baseUrl.contains('/code-assistant-api/')) {
      await _switchToSavedCodeMieProvider(entry);
      return;
    }
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
    config.onModelChanged?.call(_agent.state.model);
  }

  /// The TUI provider picker (bare `/provider`): saved custom providers
  /// first, then the catalog presets, then the `+ Add provider` wizard
  /// entry last. A saved selection restores the entry's last-used model.
  /// The TUI provider picker (bare `/provider`): saved providers only,
  /// plus `+ Add provider` as the last entry. Selecting a saved provider
  /// opens its Edit/Delete sub-picker; selecting add opens the preset
  /// picker. No catalog presets shown — they are only reachable from the
  /// add flow.
  void _openProviderPicker() {
    final items = <MenuItem>[
      ..._savedProviderItems(),
      const MenuItem(
        key: 'add',
        label: '+ Add provider',
        description: 'openrouter, chatgpt, codemie, openai, ...',
      ),
    ];
    _tuiController?.openPicker('provider', 'Providers', items);
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
    if (_dispatchProviderSubcommand(args)) return;
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
      try {
        await _switchToSavedProvider(saved);
      } on Object catch (error) {
        io.writeln('provider switch failed: $error');
      }
      return;
    }
    try {
      await _switchToCatalogProvider(args);
    } on Object catch (error) {
      io.writeln('provider switch failed: $error');
    }
  }

  /// Dispatches the subcommand forms of `/provider` (custom, openrouter
  /// oauth, chatgpt oauth, codemie sso, dial setup). Returns true when one
  /// handled it.
  bool _dispatchProviderSubcommand(List<String> args) {
    if (_startCustomProviderArg(args)) return true;
    if (_startOpenRouterArg(args)) return true;
    if (_startChatGptOAuthArg(args)) return true;
    if (_startCodeMieArg(args)) return true;
    if (_startDialSetupArg(args)) return true;
    if (_startKimiArg(args)) return true;
    return false;
  }

  /// The `/provider dial setup [baseUrl]` branch: the guided DIAL flow (the
  /// same one the `+ Add provider → DIAL` preset opens). Returns true when
  /// the command targeted the flow.
  bool _startDialSetupArg(List<String> args) {
    if (args.length < 2 || args[0] != 'dial' || args[1] != 'setup') {
      return false;
    }
    if (args.length > 2) {
      io.writeln('usage: /provider dial setup');
      return true;
    }
    unawaited(_startDialProviderSetup());
    return true;
  }

  /// The `/provider kimi` branch: switches to the catalog Kimi provider
  /// (Moonshot API). A saved custom provider named `kimi` from older builds
  /// is intentionally bypassed — the catalog entry has the correct endpoint
  /// and env-key name.
  bool _startKimiArg(List<String> args) {
    if (args.first != 'kimi') return false;
    if (args.length > 2) {
      io.writeln('usage: /provider kimi [baseUrl]');
      return true;
    }
    final baseUrl = args.length == 2 ? args[1] : null;
    unawaited(_handleKimiCommand(baseUrl: baseUrl));
    return true;
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

  /// The `/provider openrouter ...` dispatcher. Supports:
  ///
  /// - `/provider openrouter` (no args) — asks whether to use OAuth or an API key.
  /// - `/provider openrouter oauth [headless]` — browser OAuth flow.
  /// - `/provider openrouter <baseUrl> [token]` — API-key flow.
  ///
  /// Returns true when the command targeted OpenRouter.
  bool _startOpenRouterArg(List<String> args) {
    if (args.first != 'openrouter') return false;

    // Explicit OAuth subcommand.
    if (args.length >= 2 && args[1] == 'oauth') {
      final headless = args.length > 2 && args[2] == 'headless';
      if (args.length > 3 || (args.length == 3 && !headless)) {
        io.writeln('usage: /provider openrouter oauth [headless]');
        return true;
      }
      unawaited(_handleOpenRouterOAuthCommand(headless: headless));
      return true;
    }

    // No args: show the OAuth vs API-key picker.
    if (args.length == 1) {
      unawaited(_handleOpenRouterAuthMethodChoice());
      return true;
    }

    // API-key form: let the catalog switch handle <baseUrl> [token].
    return false;
  }

  /// Prompts the user to pick OpenRouter OAuth or API-key auth, then runs the
  /// chosen flow. A key that already resolves for the default endpoint
  /// (environment value, endpoint-scoped store entry, or legacy env-name
  /// store entry — the same chain startup uses) is offered first: opening a
  /// fresh session and running `/provider openrouter` must not force a
  /// re-auth when a stored key works. The sub-flows manage
  /// [_providerFlowActive] themselves, so this picker releases the gate
  /// before handing off.
  Future<void> _handleOpenRouterAuthMethodChoice() async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      final spec = providerCatalog['openrouter'];
      final storedKey = spec == null
          ? null
          : _providerKeyFor(spec, spec.defaultBaseUrl);
      final choices = [
        if (storedKey != null)
          (
            'stored',
            'Use stored key',
            'already saved — no need to authorize again',
          ),
        ('oauth', 'Browser OAuth', 'authorize via openrouter.ai'),
        ('key', 'API key', 'paste your OpenRouter API key'),
      ];
      final choice = await _pickOption('OpenRouter sign-in method', choices);
      if (choice == null) {
        io.writeln('OpenRouter setup cancelled');
        return;
      }
      // Release the flow gate so the sub-flow can take its own lock.
      _providerFlowActive = false;
      switch (choice) {
        case 'stored':
          // A catalog switch: the previously-active custom entry must stop
          // receiving `/model` memory updates.
          _activeCustomName = null;
          await _switchProvider(
            spec!,
            spec.defaultBaseUrl,
            _agent.state.model.id,
          );
        case 'oauth':
          await _handleOpenRouterOAuthCommand(headless: false);
        default:
          await _runOpenRouterApiKeyFlow();
      }
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
  }

  /// The API-key branch of the OpenRouter auth-method picker: asks for an API
  /// key and switches to the default OpenRouter endpoint with it. On a first
  /// connect (no saved entry for the endpoint yet) the key becomes a saved
  /// named entry — the same shape the OAuth connect and the custom wizard
  /// produce, with the provider-name step every add flow offers.
  Future<void> _runOpenRouterApiKeyFlow() async {
    final spec = providerCatalog['openrouter'];
    if (spec == null) {
      io.writeln('OpenRouter provider not found in catalog');
      return;
    }
    final key = await _askLine('OpenRouter API key: ', secret: true);
    if (key == null || key.trim().isEmpty) {
      io.writeln('OpenRouter setup cancelled');
      return;
    }
    final registry = config.customProviders;
    final existing = registry != null
        ? _entryForBaseUrl(registry, spec.defaultBaseUrl)
        : null;
    if (registry == null || existing != null) {
      // No registry to hold an entry — or an entry already serves the
      // endpoint (re-keying keeps its name and model memory): the plain
      // catalog switch stores the key under the endpoint-scoped slot.
      // `/model` memory continues on that entry when it exists; without
      // one this is a plain catalog switch (no entry to record into).
      _activeCustomName = existing?.name;
      await _switchProvider(
        spec,
        spec.defaultBaseUrl,
        _agent.state.model.id,
        token: key.trim(),
      );
      return;
    }
    final name = await _askConnectProviderName(
      registry.deriveName(spec.defaultBaseUrl),
      sameBaseUrl: spec.defaultBaseUrl,
    );
    if (name == null) {
      io.writeln('OpenRouter setup cancelled');
      return;
    }
    await _applyCustomProviderSetup(
      CustomProviderSetup(
        spec: spec,
        baseUrl: spec.defaultBaseUrl,
        name: name,
        modelId: _agent.state.model.id,
        token: key.trim(),
      ),
    );
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

  /// Saves an OAuth-derived OpenRouter key and switches to OpenRouter. The
  /// org is also saved as a registry entry — a connected provider must show
  /// in the `/provider` picker and survive restarts like every other one
  /// (CodeMie/dial already do); without the entry the key was only stored
  /// and OpenRouter stayed invisible in the list.
  ///
  /// The key persists under the ENDPOINT-SCOPED store name
  /// (`FA_KEY_OPENROUTER_AI`), the same slot the registry entry references
  /// and the first store slot startup resolution reads. Storing under the
  /// spec's env name (`OPENROUTER_API_KEY`, the legacy fallback) kept a
  /// stale scoped entry from an older manual paste SHADOWING the fresh
  /// OAuth key in every new session — the new window resolved the old,
  /// often revoked, key and looked "logged out".
  Future<void> _applyOpenRouterOAuthKey(
    ProviderSpec spec,
    OpenRouterOAuthKey key,
  ) async {
    io.writeln('OpenRouter authorized');
    final keyName = CustomProviderRegistry.keyNameFor(spec.defaultBaseUrl);
    await _storeProviderToken(
      spec,
      spec.defaultBaseUrl,
      key.key,
      keyName: keyName,
    );
    // An explicit connect ALWAYS asks for the display name — Enter keeps
    // the existing entry for a same-account key refresh, a new name creates
    // a separate entry for a second account. The key is already minted and
    // stored above, so a cancel keeps the host-derived default.
    final registry = config.customProviders;
    String? name;
    if (registry != null) {
      name = await _askConnectProviderName(
        _codeMieHostName(spec.defaultBaseUrl),
        sameBaseUrl: spec.defaultBaseUrl,
      );
    }
    _saveCatalogConnectEntry(spec, name: name);
    // already active (not just any openai-completions endpoint).
    final isOpenRouterActive =
        _activeCustomName == null &&
        _agent.state.model.provider == spec.name &&
        _agent.state.model.baseUrl == spec.defaultBaseUrl;
    if (isOpenRouterActive) {
      _apiKey = key.key;
      _explicitToken = true;
      _streamFunction = _catalogStreamFunction(spec.kind, key.key);
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

  /// Saves a connected catalog provider (OAuth/SSO flows) as a registry
  /// entry, so it appears in the `/provider` picker and `/provider <name>`
  /// restores it. Idempotent — re-connect keeps the entry (and its model
  /// memory); the lookup is by base URL so a renamed entry is not
  /// duplicated. [name] is the display name chosen at connect time; without
  /// it the existing entry's name (else the endpoint host) is kept.
  void _saveCatalogConnectEntry(ProviderSpec spec, {String? name}) {
    final registry = config.customProviders;
    if (registry == null) return;
    final existing = _entryForBaseUrl(registry, spec.defaultBaseUrl);
    final entryName =
        name ?? existing?.name ?? _codeMieHostName(spec.defaultBaseUrl);
    registry.add(
      CustomProviderEntry(
        name: entryName,
        apiType: spec.name,
        baseUrl: spec.defaultBaseUrl,
        modelId: existing?.modelId ?? _agent.state.model.id,
        keyName: CustomProviderRegistry.keyNameFor(spec.defaultBaseUrl),
      ),
    );
    _activeCustomName = entryName;
  }

  /// The `/provider chatgpt oauth [headless]` branch: authenticates the
  /// user with their ChatGPT account via PKCE (the Codex CLI client id) and
  /// stores the resulting OAuth credentials — access + refresh tokens as
  /// one JSON blob — under CHATGPT_OAUTH_CREDENTIALS. Returns true when the
  /// command targeted the OAuth flow.
  bool _startChatGptOAuthArg(List<String> args) {
    if (args.first != 'chatgpt') return false;
    if (args.length < 2 || args[1] != 'oauth') {
      return false;
    }
    final headless = args.length > 2 && args[2] == 'headless';
    if (args.length > 3 || (args.length == 3 && !headless)) {
      io.writeln('usage: /provider chatgpt oauth [headless]');
      return true;
    }
    unawaited(_handleChatGptOAuthCommand(headless: headless));
    return true;
  }

  /// Runs the ChatGPT OAuth flow and saves the resulting credentials.
  Future<void> _handleChatGptOAuthCommand({required bool headless}) async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      await _runChatGptOAuthCommand(headless: headless);
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
  }

  Future<void> _runChatGptOAuthCommand({required bool headless}) async {
    final spec = providerCatalog['chatgpt']!;

    final exchangeFn = config.chatGptOAuthExchangeFn ?? _defaultChatGptExchange;

    ChatGptOAuthCredentials? credentials;
    if (headless) {
      credentials = await _runChatGptHeadlessOAuth(exchangeFn: exchangeFn);
    } else {
      credentials = await runChatGptOAuthCliFlow(
        onStatus: io.writeln,
        exchangeFn: exchangeFn,
      );
    }

    if (credentials == null) return;

    await _applyChatGptOAuthCredentials(spec, credentials);
  }

  Future<ChatGptOAuthCredentials> _defaultChatGptExchange({
    required String code,
    required String redirectUri,
    required String verifier,
  }) => exchangeChatGptAuthorizationCode(
    code: code,
    redirectUri: redirectUri,
    codeVerifier: verifier,
  );

  /// Headless ChatGPT OAuth: no localhost server — the user opens the URL,
  /// authorizes, and pastes the FULL redirect URL they land on (it carries
  /// the code and state as query parameters).
  Future<ChatGptOAuthCredentials?> _runChatGptHeadlessOAuth({
    required Future<ChatGptOAuthCredentials> Function({
      required String code,
      required String redirectUri,
      required String verifier,
    })
    exchangeFn,
  }) async {
    final verifier = generateChatGptPkceVerifier();
    final state = generateChatGptState();
    const redirectUri = 'http://127.0.0.1:1455/auth/callback';
    final authUrl = buildChatGptAuthorizeUrl(
      redirectUri: redirectUri,
      codeChallenge: generateChatGptPkceChallenge(verifier),
      state: state,
    );

    io.writeln(
      'ChatGPT OAuth (headless): open this URL in a browser, authorize, '
      'then paste the FULL redirect URL you land on '
      '(it starts with $redirectUri):',
    );
    io.writeln(authUrl.toString());

    final pasted = await _askLine('redirect URL: ');
    if (pasted == null || pasted.trim().isEmpty) {
      io.writeln('ChatGPT OAuth cancelled');
      return null;
    }
    final uri = Uri.tryParse(pasted.trim());
    final code = uri?.queryParameters['code'];
    final callbackState = uri?.queryParameters['state'];
    if (code == null || code.isEmpty || callbackState != state) {
      io.writeln(
        'invalid redirect URL (missing code or bad state) — '
        'ChatGPT OAuth aborted',
      );
      return null;
    }

    try {
      return await exchangeFn(
        code: code,
        redirectUri: redirectUri,
        verifier: verifier,
      );
    } on ConfigException catch (e) {
      io.writeln('ChatGPT OAuth failed: ${e.message}');
      return null;
    }
  }

  /// Saves OAuth-derived ChatGPT credentials and switches to the Codex
  /// backend so the session is usable at once. The account also lands in
  /// the provider registry (name prompt included) like every other
  /// connected provider — without the entry it never showed in `/provider`.
  Future<void> _applyChatGptOAuthCredentials(
    ProviderSpec spec,
    ChatGptOAuthCredentials credentials,
  ) async {
    io.writeln('ChatGPT authorized');
    final encoded = credentials.encode();
    final keyName = spec.apiKeyEnvNames.first;
    await _storeProviderToken(
      spec,
      spec.defaultBaseUrl,
      encoded,
      keyName: keyName,
    );
    final registry = config.customProviders;
    String? name;
    if (registry != null) {
      final fallback =
          _entryForBaseUrl(registry, spec.defaultBaseUrl)?.name ??
          _codeMieHostName(spec.defaultBaseUrl);
      // A cancel keeps the fallback — the OAuth credentials are already
      // minted and stored.
      name =
          await _askConnectProviderName(
            fallback,
            sameBaseUrl: spec.defaultBaseUrl,
          ) ??
          fallback;
      registry.add(
        CustomProviderEntry(
          name: name,
          apiType: spec.name,
          baseUrl: spec.defaultBaseUrl,
          modelId: _agent.state.model.id,
          keyName: keyName,
        ),
      );
      _activeCustomName = name;
      io.writeln('saved provider $name (listed first in /provider)');
    }
    await _switchProvider(
      spec,
      spec.defaultBaseUrl,
      _agent.state.model.id,
      token: encoded,
      tokenKeyName: keyName,
    );
  }

  /// Persists refreshed ChatGPT OAuth credentials: the access token rotates
  /// on refresh, so the fresh blob replaces the stored one (and the live
  /// session key) — the next start resolves it like the initial grant.
  Future<void> _persistChatGptCredentials(String encoded) async {
    _apiKey = encoded;
    final spec = providerCatalog['chatgpt']!;
    await _storeProviderToken(
      spec,
      spec.defaultBaseUrl,
      encoded,
      keyName: spec.apiKeyEnvNames.first,
    );
  }

  /// [providerStreamFunction] with the CLI's session id and — for the
  /// ChatGPT Codex provider — the credentials-persist callback wired. The
  /// DIAL kind additionally picks up the optional `DIAL_API_VERSION`
  /// environment value as its `api-version` query parameter and gates the
  /// manual cache markers on the endpoint-reported `features.cache` set
  /// (unknown models keep the optimistic marker + fallback).
  StreamFunction _catalogStreamFunction(String kind, String key) =>
      providerStreamFunction(
        kind,
        key,
        sessionId: () => _session?.cachedId,
        dialApiVersion: kind == 'dial'
            ? config.envVarValue?.call('DIAL_API_VERSION')
            : null,
        dialCacheMarkersSupported: kind == 'dial' ? _dialCacheFlag : null,
        onChatGptCredentialsRefreshed: kind == 'chatgpt-codex'
            ? _persistChatGptCredentials
            : null,
      );

  /// The active model's manual-cache support for the dial adapter: true /
  /// false when the models fetch reported the flag, null while unknown.
  bool? get _dialCacheFlag {
    if (_dialCacheModels.isEmpty) return null;
    return _dialCacheModels.contains(_agent.state.model.id);
  }

  /// Runs the CodeMie SSO flow and applies the resulting credentials.
  /// [offerName] is true only for the explicit add flows (typed command,
  /// auth-method picker): the automatic re-authorizations (startup, saved
  /// entry switch, mid-stream expiry) keep the existing entry's name — or
  /// the derived default — without interrupting the recovery with a prompt.
  Future<void> _handleCodeMieSsoCommand(
    String codeMieUrl, {
    bool offerName = false,
  }) async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      final authenticate =
          config.codeMieSsoAuthenticateFn ??
          (url, onStatus) =>
              runCodeMieSsoCliFlow(codeMieUrl: url, onStatus: onStatus);
      final credentials = await authenticate(codeMieUrl, io.writeln);
      if (credentials != null) {
        await _applyCodeMieSsoCredentials(credentials, offerName: offerName);
      }
    } catch (e) {
      io.writeln('CodeMie SSO failed: $e');
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
  }

  /// Saves the SSO session: the full cookie string becomes the stored "key"
  /// of a saved custom provider pointing at `<apiUrl>/v1` (re-login replaces
  /// the key, keeps the last-used model). The model's headers carry a
  /// `cookie:` entry so the openai-completions adapter sends Cookie-header
  /// auth instead of the default `authorization: Bearer`. After saving, runs
  /// the guided project → model selection (matching the CodeMie CLI's setup
  /// flow) so the user lands on a working connection. [offerName] gates the
  /// provider-name step (explicit add flows only — see the caller).
  Future<void> _applyCodeMieSsoCredentials(
    CodeMieSsoCredentials credentials, {
    bool offerName = false,
  }) async {
    final cookie = credentials.authToken;
    if (cookie.isEmpty) {
      io.writeln('CodeMie SSO carried no cookies — aborted');
      return;
    }
    final baseUrl = '${credentials.apiUrl}/v1';
    final registry = config.customProviders;
    // Auto re-authorizations (mid-stream / startup / expired-cookie switch)
    // keep the entry's name silently; an EXPLICIT connect (typed command,
    // auth-method picker) ALWAYS asks for the provider-name step — Enter
    // keeps the existing entry (same-account cookie refresh), a new name
    // creates a separate entry for a second account.
    final existing = registry != null
        ? _entryForBaseUrl(registry, baseUrl)
        : null;
    final defaultName =
        existing?.name ?? registry?.deriveName(baseUrl) ?? 'codemie';
    final name = offerName && registry != null
        ? (await _askConnectProviderName(defaultName, sameBaseUrl: baseUrl)) ??
              defaultName
        : defaultName;
    final keyName = CustomProviderRegistry.keyNameFor(
      baseUrl,
      providerName: name,
    );
    final spec = providerCatalog['openai']!;
    await _storeProviderToken(spec, baseUrl, cookie, keyName: keyName);

    // Guided project → model selection. It runs for a NEW account — no entry
    // on this endpoint yet, or the user typed a DIFFERENT name (a second
    // account needs its own project/model pick). A re-login to the SAME
    // entry (Enter on the name prompt, or an automatic re-authorization)
    // keeps the existing model choice.
    final sameAccount = existing != null && name == existing.name;
    final modelId = sameAccount
        ? existing.modelId
        : (await _codemieGuidedSetup(credentials.apiUrl, cookie) ??
              existing?.modelId ??
              _agent.state.model.id);

    if (registry != null) {
      registry.add(
        CustomProviderEntry(
          name: name,
          apiType: 'openai',
          baseUrl: baseUrl,
          modelId: modelId,
          keyName: keyName,
          authMethod: CustomProviderAuthMethod.sso,
        ),
      );
      _activeCustomName = name;
      io.writeln('saved provider $name (listed first in /provider)');
    }
    await _switchCodeMieProvider(spec, baseUrl, modelId, cookie, keyName);
    final hours =
        (credentials.expiresAt - DateTime.now().millisecondsSinceEpoch) ~/
        3600000;
    io.writeln(
      'CodeMie session expires in ~${hours}h — re-run '
      '/provider codemie sso to renew',
    );
  }

  /// Post-SSO guided setup: fetch projects, let the user pick one, then
  /// fetch and pick a model. Returns the chosen model id, or null on cancel.
  /// Dispatches to the config-injected guided setup, or the real flow.
  Future<String?> _codemieGuidedSetup(String apiBase, String cookie) {
    final override = config.codeMieGuidedSetupFn;
    if (override != null) {
      return override(apiBase, cookie, _pickOption, _askLine);
    }
    return _codemiePickProjectAndModel(apiBase, cookie);
  }

  /// Switches to a CodeMie provider using Cookie-header auth instead of the
  /// default Bearer token. The cookie string is stored as the session key
  /// (for `/models` fetches and key status display), but the openai-completions
  /// adapter receives an empty apiKey (so it skips `authorization: Bearer`)
  /// while the model's `headers` carry `cookie: <full cookie string>`.
  Future<void> _switchCodeMieProvider(
    ProviderSpec spec,
    String baseUrl,
    String modelId,
    String cookie,
    String keyName,
  ) async {
    final modelLine = modelId == _agent.state.model.id
        ? '  model unchanged: $modelId — use /model to change'
        : '  model: $modelId';
    _providerKind = spec.kind;
    // The cookie is the "key" for session/display purposes, but the stream
    // function gets an empty string so the adapter generates NO authorization
    // header; the cookie rides in via model.headers instead.
    _apiKey = cookie;
    _explicitToken = true;
    _streamFunction = _catalogStreamFunction(spec.kind, '');
    _agent.streamFunction = _streamFunction;
    final builtModel = buildCatalogModel(spec.name, modelId, baseUrl: baseUrl);
    _agent.state.model = Model(
      id: builtModel.id,
      name: builtModel.name,
      api: builtModel.api,
      provider: builtModel.provider,
      baseUrl: builtModel.baseUrl,
      reasoning: builtModel.reasoning,
      input: inputModalitiesFor(modelId),
      cost: builtModel.cost,
      contextWindow: builtModel.contextWindow,
      maxTokens: builtModel.maxTokens,
      // Cookie-header auth: the adapter sees an empty apiKey (no Bearer) and
      // merges model.headers, adding `cookie: <full cookie jar>`.
      headers: {'cookie': cookie},
      compat: builtModel.compat,
    );
    _modelCache = const [];
    _modelContextWindows = const {};
    _modelMaxTokens = const {};
    _lastModelList = null;
    unawaited(_refreshModelCache());
    await _session?.appendModelChange(provider: spec.name, modelId: modelId);
    io.writeln('switched provider to ${spec.name} (${spec.api})');
    io.writeln('  endpoint: $baseUrl');
    io.writeln('  key: SSO cookie (saved as $keyName)');
    io.writeln(modelLine);
    config.onProviderChanged?.call(_providerKind, _apiKey);
  }

  Future<String?> _codemiePickProjectAndModel(
    String apiBase,
    String cookie,
  ) async {
    await _codemiePickProject(apiBase, cookie);
    return _codemiePickModel(apiBase, cookie);
  }

  /// Step 1: fetch and optionally pick a CodeMie project.
  Future<void> _codemiePickProject(String apiBase, String cookie) async {
    io.writeln('fetching CodeMie projects...');
    final projects = await fetchCodeMieProjects(apiBase, cookie).catchError((
      e,
    ) {
      return const <String>[];
    });
    if (projects.isEmpty) return;
    final projectPick = await _pickOption('CodeMie project', [
      for (final p in projects) (p, p, ''),
    ]);
    if (projectPick != null) io.writeln('selected project: $projectPick');
  }

  /// Step 2: fetch and pick a CodeMie model (or manual entry).
  Future<String?> _codemiePickModel(String apiBase, String cookie) async {
    io.writeln('fetching CodeMie models...');
    final models = await fetchCodeMieModels('$apiBase/v1', cookie).catchError((
      e,
    ) {
      return const <String>[];
    });
    if (models.isEmpty) {
      io.writeln('no models available — set one with /model <id>');
      return null;
    }
    return _pickModelFromList(models);
  }

  /// Picks a model from the fetched list, falling back to manual entry.
  Future<String?> _pickModelFromList(List<String> models) async {
    final modelPick = await _pickOption('CodeMie model', [
      for (final id in models) (id, id, visionMarker(id)),
      ('', '+ enter manually', ''),
    ]);
    if (modelPick == null) return null;
    if (modelPick.isNotEmpty) return modelPick;
    return _manualModelId();
  }

  /// Reads a manually entered model id from the user.
  Future<String?> _manualModelId() async {
    final manual = await _askLine("model id: ");
    return manual?.trim().isEmpty == false ? manual!.trim() : null;
  }

  /// The host-derived provider name for a CodeMie API base URL (the same
  /// candidate `CustomProviderRegistry.deriveName` builds, WITHOUT the
  /// dedupe suffix — re-login lookups need the plain name).
  String _codeMieHostName(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    var host = uri?.host ?? baseUrl;
    if (host.isEmpty) return 'codemie';
    final port = uri?.port;
    final defaultPort = uri?.scheme == 'https' ? 443 : 80;
    if (port != null && port != defaultPort) host = '$host:$port';
    return host;
  }

  /// The catalog-switch branch of [_handleProviderCommand]: resolves the
  /// provider name against the catalog and switches with the optional
  /// endpoint/token args.
  Future<void> _switchToCatalogProvider(List<String> args) async {
    final spec = catalogProvider(args[0]);
    if (spec == null) {
      io.writeln(
        'unknown provider: ${args[0]} — supported providers: '
        '${enabledProviderNames().join(', ')}',
      );
      return;
    }
    _activeCustomName = null;
    final baseUrl = args.length > 1 ? args[1] : spec.defaultBaseUrl;
    final token = args.length > 2 ? args[2] : null;
    await _switchProvider(spec, baseUrl, _agent.state.model.id, token: token);
  }

  /// The `preset:dial` guided setup: base URL (Enter applies the EPAM
  /// default) → DIAL API key (or DIAL_API_KEY from the environment) →
  /// deployment picked from `{baseUrl}/openai/models` (or typed manually).
  /// Switches to the dial provider with Api-Key auth; the key persists in
  /// the secure store under the endpoint-scoped name like every provider.
  /// The `preset:dial` / `/provider dial setup` guided flow: base URL (Enter
  /// applies the EPAM default) → DIAL API key (or DIAL_API_KEY from the
  /// environment) → deployment picked from `{baseUrl}/openai/models` (or
  /// typed manually). Switches to the dial provider with Api-Key auth; the
  /// key persists in the secure store under the endpoint-scoped name.
  Future<void> _startDialProviderSetup() async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      await _runDialProviderSetup();
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
  }

  /// The dial setup steps (see [_startDialProviderSetup] for the contract).
  /// Every `null` answer cancels the flow.
  Future<void> _runDialProviderSetup() async {
    final spec = providerCatalog['dial']!;
    final baseUrl = await _dialAskBaseUrl(spec);
    if (baseUrl == null) return io.writeln('dial setup cancelled');
    final key = await _dialAskKey(spec, baseUrl);
    if (key == null) return io.writeln('dial setup cancelled');
    final deployment = await _dialAskDeployment(baseUrl, key);
    if (deployment == null) return io.writeln('dial setup cancelled');
    final name = await _dialAskName(baseUrl);
    if (name == null) return io.writeln('dial setup cancelled');
    final keyName = _dialSaveRegistryEntry(baseUrl, key, deployment, name);
    await _switchProvider(
      spec,
      baseUrl,
      deployment,
      token: key.isEmpty ? null : key,
      tokenKeyName: keyName,
    );
  }

  /// The provider-name step: typed value, else the endpoint host (the
  /// `/provider` picker label); null cancels. Kept unique vs other entries.
  Future<String?> _dialAskName(String baseUrl) =>
      _askConnectProviderName(_codeMieHostName(baseUrl), sameBaseUrl: baseUrl);

  /// The provider-name step shared by every add/connect flow that saves a
  /// registry entry (dial, kimi, OAuth/SSO connects): the typed value, else
  /// [fallback] (usually the endpoint host). A name already used by an entry
  /// on a DIFFERENT endpoint retries, and so does a name matching a CATALOG
  /// provider — `/provider kimi` & friends route to the catalog flow before
  /// the registry lookup, so such an entry would be unreachable. Null only
  /// on cancel (Ctrl-C) — flows whose credentials are already minted
  /// (OAuth/SSO) substitute [fallback] instead of aborting.
  Future<String?> _askConnectProviderName(
    String fallback, {
    String? sameBaseUrl,
  }) async {
    final typed = await _askLine('provider name [$fallback]: ');
    if (typed == null) return null;
    final name = typed.trim().isEmpty ? fallback : typed.trim();
    if (providerCatalog.containsKey(name.toLowerCase())) {
      io.writeln(
        '"$name" is a built-in provider name — /provider $name routes to it, '
        'pick another name',
      );
      return _askConnectProviderName(fallback, sameBaseUrl: sameBaseUrl);
    }
    final clash = config.customProviders?.find(name);
    if (clash != null && clash.baseUrl != sameBaseUrl) {
      io.writeln('name "$name" is already used by ${clash.baseUrl} — retry');
      return _askConnectProviderName(fallback, sameBaseUrl: sameBaseUrl);
    }
    return name;
  }

  /// The first registry entry serving [baseUrl], or null. Base-URL lookups
  /// survive renames — a derived-name lookup would treat a renamed entry as
  /// absent and duplicate it on re-connect.
  CustomProviderEntry? _entryForBaseUrl(
    CustomProviderRegistry registry,
    String baseUrl,
  ) {
    for (final entry in registry.entries) {
      if (entry.baseUrl == baseUrl) return entry;
    }
    return null;
  }

  /// The base-URL step: typed value or the spec default; null cancels.
  Future<String?> _dialAskBaseUrl(ProviderSpec spec) async {
    final typed = await _askLine('base URL [${spec.defaultBaseUrl}]: ');
    if (typed == null) return null;
    return typed.trim().isEmpty ? spec.defaultBaseUrl : typed.trim();
  }

  /// The API-key step: typed value, else the env/keystore resolution (may
  /// be empty — a keyless switch); null cancels.
  Future<String?> _dialAskKey(ProviderSpec spec, String baseUrl) async {
    final typed = await _askLine('DIAL API key: ', secret: true);
    if (typed == null) return null;
    final key = typed.trim();
    if (key.isNotEmpty) return key;
    final envKey = _providerKeyFor(spec, baseUrl) ?? '';
    if (envKey.isEmpty) {
      io.writeln('no key given and DIAL_API_KEY is not set — keyless switch');
    }
    return envKey;
  }

  /// The deployment step: picked from `{baseUrl}/openai/models` when the
  /// endpoint answers, typed manually otherwise; null cancels.
  Future<String?> _dialAskDeployment(String baseUrl, String key) async {
    List<String> deployments = const [];
    try {
      deployments = await fetchDialModels(baseUrl, key);
    } on Object {
      // Dead endpoint / bad key — the user can still type a deployment.
    }
    String? modelId;
    if (deployments.isNotEmpty) {
      modelId = await _pickOption('DIAL deployment', [
        for (final id in deployments)
          (id, id, 'deployment ${_dialDeploymentLabel(id)}'),
      ]);
    }
    modelId ??= await _askLine('deployment (model id): ');
    final trimmed = modelId?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// Saves the dial org as a registry entry so it shows in the /provider
  /// picker and survives restarts (re-running setup just updates the model).
  /// A custom (non-derived) name scopes the store key — two dial orgs
  /// share one host otherwise and the second key would overwrite the
  /// first's slot. Returns the entry's key name (null when keyless) so the
  /// caller stores the typed key under the SAME slot the entry references.
  String? _dialSaveRegistryEntry(
    String baseUrl,
    String key,
    String deployment,
    String name,
  ) {
    final registry = config.customProviders;
    // The host-derived name (no dedupe suffix) keeps the endpoint-scoped
    // key slot; a custom name scopes it so two orgs on one host keep
    // separate keys.
    final derived = name == _codeMieHostName(baseUrl);
    final keyName = key.isEmpty
        ? null
        : CustomProviderRegistry.keyNameFor(
            baseUrl,
            providerName: derived ? null : name,
          );
    if (registry != null) {
      registry.add(
        CustomProviderEntry(
          name: name,
          apiType: 'dial',
          baseUrl: baseUrl,
          modelId: deployment,
          keyName: keyName,
        ),
      );
      _activeCustomName = name;
      io.writeln('saved provider $name (listed in /provider)');
    }
    return keyName;
  }

  /// Short human label for a deployment id in the picker descriptions.
  String _dialDeploymentLabel(String id) {
    final dot = id.indexOf('.');
    return dot > 0 && dot < id.length - 1 ? id.substring(0, dot) : id;
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
    try {
      final modelLine = modelId == _agent.state.model.id
          ? '  model unchanged: $modelId — use /model to change'
          : '  model: $modelId';
      final rolesResolver = config.modelRolesResolver;
      if (rolesResolver != null) {
        // Roles mode: pin the default role to the new provider/endpoint (a
        // single-entry chain for this session), mirroring `/model <id>`.
        // The key name MUST survive the pin: a typed key is persisted to the
        // secure store under it; without a token the existing chain entry's /
        // registry entry's keyName carries over — otherwise the pin silently
        // drops the scoped key and the next turn reads the (stale) catalog
        // env name instead ("the provider key reset itself").
        final preservedName =
            tokenKeyName ?? _rolesKeyNameFor(spec.name, baseUrl);
        final pinnedKeyName = token != null
            ? (preservedName ?? CustomProviderRegistry.keyNameFor(baseUrl))
            : preservedName;
        if (token != null) {
          await _storeProviderToken(
            spec,
            baseUrl,
            token,
            keyName: pinnedKeyName,
          );
          rolesResolver.addSecret(pinnedKeyName!, token);
        }
        try {
          rolesResolver.setDefaultChain([
            ModelRef(
              provider: spec.name,
              modelId: modelId,
              baseUrl: baseUrl,
              apiKeyName: pinnedKeyName,
            ),
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
        await _session?.appendModelChange(
          provider: spec.name,
          modelId: modelId,
        );
        io.writeln('switched provider to ${spec.name} (endpoint: $baseUrl)');
        io.writeln(modelLine);
        config.onModelChanged?.call(_agent.state.model);
        return;
      }
      final key = token ?? _providerKeyFor(spec, baseUrl) ?? '';
      _providerKind = spec.kind;
      _apiKey = key;
      _explicitToken = token != null;
      _streamFunction = _catalogStreamFunction(spec.kind, key);
      _agent.streamFunction = _streamFunction;
      final builtModel = buildCatalogModel(
        spec.name,
        modelId,
        baseUrl: baseUrl,
      );
      _agent.state.model = Model(
        id: builtModel.id,
        name: builtModel.name,
        api: builtModel.api,
        provider: builtModel.provider,
        baseUrl: builtModel.baseUrl,
        reasoning: builtModel.reasoning,
        // The catalog default claims ['text', 'image'] for every model of the
        // provider — the shared heuristic is more accurate per id.
        input: inputModalitiesFor(modelId),
        cost: builtModel.cost,
        contextWindow: builtModel.contextWindow,
        maxTokens: builtModel.maxTokens,
        headers: builtModel.headers,
        compat: builtModel.compat,
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
    } on ConfigException catch (error) {
      io.writeln('cannot switch provider: ${error.message}');
    } on Object catch (error) {
      io.writeln('provider switch failed: $error');
    }
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
    if (args.length == 3) return _handleKeySet3Arg(args);
    if (args.length > 3) {
      io.writeln('usage: /key set <NAME> [<value>]');
      return;
    }
    final name = args.length == 2 ? args[1] : null;
    final tui = _tuiController;
    if (_useTui && tui != null) {
      await _handleKeySetInteractive(tui: tui, name: name);
      return;
    }
    await _handleKeySetLineMode(name);
  }

  /// The scriptable 3-arg form: `/key set NAME value` (value verbatim).
  Future<void> _handleKeySet3Arg(List<String> args) async {
    final keys = config.secureKeys;
    final storeAvailable = keys != null && keys.available;
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
  }

  /// The line-mode branch of [_handleKeySet]: prompts for the value via
  /// a fire-and-forget flow so the REPL keeps reading lines.
  Future<void> _handleKeySetLineMode(String? name) async {
    final keys = config.secureKeys;
    if (name == null) return io.writeln('usage: /key set <NAME> [<value>]');
    if (!_keyNamePattern.hasMatch(name)) {
      return io.writeln('invalid key name: $name (use [A-Za-z0-9_]+)');
    }
    if (keys == null || !keys.available) {
      return io.writeln(
        'secure storage unavailable on this host — '
        'set $name in the environment instead',
      );
    }
    _providerFlowActive = true;
    unawaited(_promptAndSaveKey(keys, name));
  }

  /// The line-mode value prompt + store write behind `/key set` (runs after
  /// the command handler returns; resets the flow gate in `finally`).
  Future<void> _promptAndSaveKey(SecureKeyCache keys, String name) async {
    try {
      final value = await _promptLine('value for $name: ');
      if (value == null || value.isEmpty) {
        return io.writeln('cancelled');
      }
      if (!await keys.save(name, value)) {
        return io.writeln(
          'could not save $name to ${keys.label}: the write failed '
          '(locked or managed keychain?) — '
          'set $name in the environment instead',
        );
      }
      config.onSecretStored?.call(name, value);
      io.writeln('saved $name to ${keys.label}');
      _applySavedKeyToActiveProvider(name, value);
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
  }

  /// The TUI interactive variant of [_handleKeySet]: prompts for the key
  /// name (when [name] is null) and a masked value through the TUI prompt
  /// zone, then saves. Cancelling either prompt (Esc) aborts silently.
  Future<void> _handleKeySetInteractive({
    required FaTuiController tui,
    String? name,
  }) => _interactiveKeySetOrReport(name, tui);

  Future<void> _interactiveKeySetOrReport(
    String? name,
    FaTuiController tui,
  ) async {
    final keys = config.secureKeys;
    if (keys == null || !keys.available) {
      io.writeln('secure storage unavailable on this host');
      return;
    }
    await interactiveKeySet(
      name: name,
      keys: keys,
      onSecretStored: config.onSecretStored,
      prompt: tui.openPrompt,
      onResult: io.writeln,
      onSaved: _applySavedKeyToActiveProvider,
    );
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
      _streamFunction = _catalogStreamFunction(spec.kind, value);
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
    for (final spec in enabledProviders()) {
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

  /// Resolves the API key for [spec] at [baseUrl]. For the spec's DEFAULT
  /// hosted endpoint: env value → host-scoped store key → a saved registry
  /// entry's name-scoped key for the same endpoint (multi-account — the
  /// startup resolution in bin/fah.dart uses the same order) → legacy
  /// env-name store key. For ANY OTHER endpoint: only the
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
  /// host-scoped store key → registry-entry name-scoped key → legacy
  /// env-name store key (documented order).
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
  /// entry (`FA_KEY_<HOST>`), then a saved registry entry's name-scoped key
  /// for the same endpoint, then the legacy env-name entries.
  String? _storedDefaultEndpointKey(
    ProviderSpec spec,
    String baseUrl,
    SecureKeyCache keys,
  ) {
    final scoped = keys.read(CustomProviderRegistry.keyNameFor(baseUrl));
    if (scoped != null && scoped.isNotEmpty) return scoped;
    final entryKeyName = _registryEntryKeyName(baseUrl, keys);
    if (entryKeyName != null) return keys.read(entryKeyName);
    for (final name in spec.apiKeyEnvNames) {
      final value = keys.read(name);
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// The store key name of a saved registry entry serving [baseUrl] whose
  /// slot actually holds a value, or null. A second account's name-scoped
  /// key (`FA_KEY_API_KIMI_COM_WORK`) must resolve for the plain catalog
  /// switch too — otherwise every `/provider kimi` re-prompts for a key the
  /// named entry already saved (startup resolution in bin/fah.dart has the
  /// same fallback, right after the host-scoped slot).
  String? _registryEntryKeyName(String baseUrl, SecureKeyCache keys) {
    final registry = config.customProviders;
    if (registry == null) return null;
    for (final entry in registry.entries) {
      if (entry.baseUrl != baseUrl) continue;
      final keyName = entry.keyName;
      if (keyName != null && _nonEmptyStoredKey(keys, keyName) != null) {
        return keyName;
      }
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
  /// endpoint-scoped store entry → a registry entry's name-scoped slot →
  /// legacy env-name store entry, else a warning that the hosted endpoint
  /// has no key.
  String _defaultEndpointKeyLine(ProviderSpec spec, String baseUrl) {
    final keys = config.secureKeys;
    final env = _envKeyEntry(spec);
    if (env != null) return 'key: ${env.$1}';
    if (keys != null) {
      final scopedName = CustomProviderRegistry.keyNameFor(baseUrl);
      if (keys.read(scopedName) != null) {
        return 'key: $scopedName (${keys.label ?? 'secure store'})';
      }
      final entryKeyName = _registryEntryKeyName(baseUrl, keys);
      if (entryKeyName != null) {
        return 'key: $entryKeyName (${keys.label ?? 'secure store'})';
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
    if (keys == null) return 'key: none (keyless endpoint)';
    final hit = _activeCustomKeyEntry(keys) ?? _scopedKeyEntry(keys, baseUrl);
    if (hit == null) return 'key: none (keyless endpoint)';
    return 'key: $hit (${keys.label ?? 'secure store'})';
  }

  /// The active saved entry's key name when the store holds it, else null.
  String? _activeCustomKeyEntry(SecureKeyCache keys) {
    final entryKey = _activeCustomKeyName();
    if (entryKey != null && keys.read(entryKey) != null) return entryKey;
    return null;
  }

  /// The endpoint-scoped `FA_KEY_<HOST>` name when the store holds it.
  String? _scopedKeyEntry(SecureKeyCache keys, String baseUrl) {
    final scopedName = CustomProviderRegistry.keyNameFor(baseUrl);
    return keys.read(scopedName) != null ? scopedName : null;
  }
}
