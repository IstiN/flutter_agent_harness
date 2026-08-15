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
    if (answer != 'y') return io.writeln('delete cancelled');
    removeProvider(entry);
  }

  /// The flow's free-form questions: a TUI text prompt when the controller
  /// is up (masked input for secrets), a plain line prompt otherwise.
  Future<String?> _askLine(String question, {bool secret = false}) async {
    final tui = _tuiController;
    if (_useTui && tui != null) {
      return _askLineTui(tui, question, secret);
    }
    return _promptLine(question);
  }

  /// The TUI branch of [_askLine].
  Future<String?> _askLineTui(
    FaTuiController tui,
    String question,
    bool secret,
  ) async {
    final spec = TextPromptSpec(
      question: question,
      defaultValue: _extractDefault(question),
      secret: secret,
    );
    final result = await tui.openPrompt(spec);
    return result is TextPromptAnswer ? result.value : null;
  }

  /// Parses a `(empty = X):` or `(empty keeps 'X'):` hint from [question],
  /// returning `X` so the TUI prompt can show it as the default value, or
  /// null when no default hint is present.
  String? _extractDefault(String question) => extractDefaultValue(question);

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
  /// restores its last-used model and marks it active. CodeMie endpoints
  /// (detected by the `/code-assistant-api/` URL marker) use Cookie-header
  /// auth instead of the default Bearer token.
  Future<void> _switchToSavedProvider(CustomProviderEntry entry) async {
    final keyName = entry.keyName;
    final token = keyName != null ? config.secureKeys?.read(keyName) : null;
    _activeCustomName = entry.name;
    if (token != null && entry.baseUrl.contains('/code-assistant-api/')) {
      await _switchCodeMieProvider(
        entry.spec,
        entry.baseUrl,
        entry.modelId,
        token,
        keyName ?? '',
      );
      return;
    }
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
      await _switchToSavedProvider(saved);
      return;
    }
    await _switchToCatalogProvider(args);
  }

  /// Dispatches the subcommand forms of `/provider` (custom, openrouter
  /// oauth, chatgpt oauth, codemie sso, dial setup). Returns true when one
  /// handled it.
  bool _dispatchProviderSubcommand(List<String> args) {
    if (_startCustomProviderArg(args)) return true;
    if (_startOpenRouterOAuthArg(args)) return true;
    if (_startChatGptOAuthArg(args)) return true;
    if (_startCodeMieSsoArg(args)) return true;
    if (_startDialSetupArg(args)) return true;
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

  /// Saves an OAuth-derived OpenRouter key and switches to OpenRouter. The
  /// org is also saved as a registry entry — a connected provider must show
  /// in the `/provider` picker and survive restarts like every other one
  /// (CodeMie/dial already do); without the entry the key was only stored
  /// and OpenRouter stayed invisible in the list.
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
    _saveCatalogConnectEntry(spec);
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
  /// entry named by its endpoint host, so it appears in the `/provider`
  /// picker and `/provider <name>` restores it. Idempotent — re-connect
  /// keeps the entry (and its model memory).
  void _saveCatalogConnectEntry(ProviderSpec spec) {
    final registry = config.customProviders;
    if (registry == null) return;
    final name = _codeMieHostName(spec.defaultBaseUrl);
    final existing = registry.find(name);
    registry.add(
      CustomProviderEntry(
        name: name,
        apiType: spec.name,
        baseUrl: spec.defaultBaseUrl,
        modelId: existing?.modelId ?? _agent.state.model.id,
        keyName: CustomProviderRegistry.keyNameFor(spec.defaultBaseUrl),
      ),
    );
    _activeCustomName = name;
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
  /// backend so the session is usable at once.
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

  /// The `/provider codemie sso [url]` branch: browser SSO against a
  /// CodeMie organization (localhost callback), then the full cookie string
  /// rides the standard openai-completions adapter via a `cookie:` model
  /// header (suppressing the default Bearer auth). The org is saved as a
  /// custom provider entry (host-derived name) so it shows up in the
  /// /provider picker and re-login just refreshes its key. Returns true
  /// when the command targeted the SSO flow.
  bool _startCodeMieSsoArg(List<String> args) {
    if (args.first != 'codemie') return false;
    if (args.length < 2 || args[1] != 'sso') return false;
    final url = args.length > 2 ? args[2] : defaultCodeMieBaseUrl;
    if (args.length > 3 ||
        (!url.startsWith('http://') && !url.startsWith('https://'))) {
      io.writeln('usage: /provider codemie sso [orgUrl]');
      return true;
    }
    unawaited(_handleCodeMieSsoCommand(url));
    return true;
  }

  /// Runs the CodeMie SSO flow and applies the resulting credentials.
  Future<void> _handleCodeMieSsoCommand(String codeMieUrl) async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      final authenticate =
          config.codeMieSsoAuthenticateFn ??
          (url, onStatus) =>
              runCodeMieSsoCliFlow(codeMieUrl: url, onStatus: onStatus);
      final credentials = await authenticate(codeMieUrl, io.writeln);
      if (credentials != null) {
        await _applyCodeMieSsoCredentials(credentials);
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
  /// flow) so the user lands on a working connection.
  Future<void> _applyCodeMieSsoCredentials(
    CodeMieSsoCredentials credentials,
  ) async {
    final cookie = credentials.authToken;
    if (cookie.isEmpty) {
      io.writeln('CodeMie SSO carried no cookies — aborted');
      return;
    }
    final baseUrl = '${credentials.apiUrl}/v1';
    final registry = config.customProviders;
    final candidate = _codeMieHostName(baseUrl);
    final existing = registry?.find(candidate);
    final name = existing?.name ?? registry?.deriveName(baseUrl) ?? 'codemie';
    final keyName = CustomProviderRegistry.keyNameFor(
      baseUrl,
      providerName: name,
    );
    final spec = providerCatalog['openai']!;
    await _storeProviderToken(spec, baseUrl, cookie, keyName: keyName);

    // Guided project → model selection (first login only; re-login keeps
    // the existing model choice).
    final modelId =
        existing?.modelId ??
        await _codemieGuidedSetup(credentials.apiUrl, cookie) ??
        _agent.state.model.id;

    if (registry != null) {
      registry.add(
        CustomProviderEntry(
          name: name,
          apiType: 'openai',
          baseUrl: baseUrl,
          modelId: modelId,
          keyName: keyName,
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
    _dialSaveRegistryEntry(baseUrl, key, deployment, name);
    await _switchProvider(
      spec,
      baseUrl,
      deployment,
      token: key.isEmpty ? null : key,
    );
  }

  /// The provider-name step: typed value, else the endpoint host (the
  /// `/provider` picker label); null cancels. Kept unique vs other entries.
  Future<String?> _dialAskName(String baseUrl) async {
    final fallback = _codeMieHostName(baseUrl);
    final typed = await _askLine('provider name [$fallback]: ');
    if (typed == null) return null;
    final name = typed.trim().isEmpty ? fallback : typed.trim();
    final clash = config.customProviders?.find(name);
    if (clash != null && clash.baseUrl != baseUrl) {
      io.writeln('name "$name" is already used by ${clash.baseUrl} — retry');
      return _dialAskName(baseUrl);
    }
    return name;
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
  void _dialSaveRegistryEntry(
    String baseUrl,
    String key,
    String deployment,
    String name,
  ) {
    final registry = config.customProviders;
    if (registry == null) return;
    registry.add(
      CustomProviderEntry(
        name: name,
        apiType: 'dial',
        baseUrl: baseUrl,
        modelId: deployment,
        keyName: key.isEmpty
            ? null
            : CustomProviderRegistry.keyNameFor(baseUrl),
      ),
    );
    _activeCustomName = name;
    io.writeln('saved provider $name (listed in /provider)');
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
    _streamFunction = _catalogStreamFunction(spec.kind, key);
    _agent.streamFunction = _streamFunction;
    final builtModel = buildCatalogModel(spec.name, modelId, baseUrl: baseUrl);
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
    return _crossProviderModelMenuItems(_crossProviderCandidates(filter));
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
    final pipe = key.indexOf('|');
    if (pipe < 0) return _handleModelCommand(key);
    await _switchCrossProviderModel(key, pipe);
  }

  /// Switches to the provider/model encoded as `provider|model`.
  Future<void> _switchCrossProviderModel(String key, int pipe) async {
    final providerName = key.substring(0, pipe);
    final modelId = key.substring(pipe + 1);
    final entry = config.customProviders?.find(providerName);
    if (entry != null && entry.name != _activeCustomName) {
      await _switchToSavedProvider(entry);
    }
    await _switchModel(modelId);
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
      // Always include the active provider's fallback list.
      final activeProvider = _agent.state.model.provider;
      if (!_allProvidersModelCache.containsKey(activeProvider)) {
        _allProvidersModelCache[activeProvider] =
            _knownModels[activeProvider] ?? [_agent.state.model.id];
      }
      _allProvidersCacheRefreshed = true;
      _tuiController?.sendModelsRefresh();
    } finally {
      _modelCacheFuture = null;
      completer.complete();
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
    return _fetchOpenAiShapeIds(entry, cookieOrKey);
  }

  /// The openai-completions branch of [_fetchIdsForProvider] (other kinds
  /// answer an empty list — their endpoints have no /models dialect here).
  Future<List<String>> _fetchOpenAiShapeIds(
    CustomProviderEntry entry,
    String cookieOrKey,
  ) async {
    if (entry.spec.kind != 'openai-completions') return const [];
    final fetch = config.modelsFetcher ?? _fetchOpenAiCompatibleModels;
    return fetch(entry.baseUrl, apiKey: cookieOrKey);
  }

  /// Returns cross-provider model candidates as `(providerName, modelId)`
  /// pairs, optionally filtered by a lowercase substring match on either
  /// the provider name or the model id.
  List<(String, String)> _crossProviderCandidates([String filter = '']) {
    final registryEntries = _collectRegistryCandidates();
    final entries = registryEntries.isEmpty
        ? _activeProviderFallback()
        : registryEntries;
    return _filterCandidates(entries, filter);
  }

  /// Collects `(provider, model)` pairs from all saved custom providers.
  List<(String, String)> _collectRegistryCandidates() {
    final registry = config.customProviders;
    if (registry == null) return const [];
    return [
      for (final entry in registry.entries)
        for (final modelId
            in _allProvidersModelCache[entry.name] ?? [entry.modelId])
          (entry.name, modelId),
    ];
  }

  /// Fallback candidates from the active provider's known models.
  List<(String, String)> _activeProviderFallback() {
    final activeProvider = _agent.state.model.provider;
    final activeName = _activeCustomName ?? activeProvider;
    final known =
        _allProvidersModelCache[activeName] ??
        (_modelCache.isNotEmpty
            ? _modelCache
            : (_knownModels[activeProvider] ?? [_agent.state.model.id]));
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
          if (config.modelRolesResolver == null) {
            _applyDetectedContextWindow(model);
            _applyDetectedMaxTokens(model);
          }
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

  /// Fetches the active provider's model ids: CodeMie exposes its list at
  /// /llm_models (LiteLLM-shaped), DIAL serves deployments at /openai/models
  /// (recording features/limits), everything else uses the OpenAI /models.
  Future<List<String>> _fetchActiveProviderModels(Model model) async {
    if (model.baseUrl.contains('/code-assistant-api/')) {
      return fetchCodeMieModels(model.baseUrl, _apiKey);
    }
    if (model.provider == 'dial') {
      return _fetchDialModelsAndFeatures(model.baseUrl);
    }
    final fetch = config.modelsFetcher ?? _fetchOpenAiCompatibleModels;
    return fetch(model.baseUrl, apiKey: _apiKey);
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

  /// [fetchDialModelsInfo] wrapper for [_refreshModelCache]: records the
  /// `features.cache` deployment set (drives [DialOptions.cacheMarkersSupported])
  /// and the endpoint-reported limits (context window / max output from
  /// `limits`, the MAXIMUM values — never the `defaults`), and answers the
  /// plain id list.
  Future<List<String>> _fetchDialModelsAndFeatures(String baseUrl) async {
    final (ids, cacheSupported, windows, maxTokens) = await fetchDialModelsInfo(
      baseUrl,
      _apiKey,
    );
    if (cacheSupported.isNotEmpty) _dialCacheModels = cacheSupported;
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
        ),
      ]);
      rolesResolver.applyToAgent(_agent);
      _streamFunction = _agent.streamFunction;
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
      // _recordCustomModel persists via its own onModelChanged (the
      // per-provider model memory write must survive restarts even when
      // nothing else changed).
      _recordCustomModel(modelId);
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
    _recordCustomModel(modelId);
    config.onModelChanged?.call(_agent.state.model);
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
