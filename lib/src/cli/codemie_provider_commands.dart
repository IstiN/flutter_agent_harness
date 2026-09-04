/// CodeMie-specific provider command handling: the `/provider codemie ...`
/// subcommands (SSO and JWT Bearer) and switching to saved CodeMie entries.
///
/// Split out of `provider_commands.dart` to keep that file under the repo's
/// 2800-line size gate. Same library (a `part of`), so the extension sees
/// the class's private members.
part of 'agent_cli.dart';

/// CodeMie provider command handlers. Lives in the same library as
/// [AgentCli], so the extension body has access to the agent's private
/// fields and the helpers in `provider_commands.dart`.
extension on AgentCli {
  /// The `/provider codemie ...` dispatcher. Supports:
  ///
  /// - `/provider codemie` (no args) — asks whether to use SSO or JWT Bearer.
  /// - `/provider codemie sso [orgUrl]` — browser SSO flow.
  /// - `/provider codemie jwt [orgUrl] [token]` — JWT Bearer token flow.
  ///
  /// Returns true when the command targeted CodeMie.
  bool _startCodeMieArg(List<String> args) {
    if (args.first != 'codemie') return false;
    if (args.length == 1) {
      unawaited(_handleCodeMieAuthMethodChoice());
      return true;
    }
    final sub = args[1];
    if (sub == 'sso') return _startCodeMieSsoArg(args);
    if (sub == 'jwt') return _startCodeMieJwtArg(args);
    _printCodeMieUsage();
    return true;
  }

  /// Dispatches `/provider codemie sso [orgUrl]`.
  bool _startCodeMieSsoArg(List<String> args) {
    final url = args.length > 2 ? args[2] : defaultCodeMieBaseUrl;
    if (args.length > 3 || !_isHttpUrl(url)) {
      io.writeln('usage: /provider codemie sso [orgUrl]');
      return true;
    }
    unawaited(_handleCodeMieSsoCommand(url, offerName: true));
    return true;
  }

  /// Dispatches `/provider codemie jwt [orgUrl] [token]`.
  bool _startCodeMieJwtArg(List<String> args) {
    final url = args.length > 2 ? args[2] : defaultCodeMieBaseUrl;
    final token = args.length > 3 ? args[3] : null;
    if (args.length > 4 || !_isHttpUrl(url)) {
      io.writeln('usage: /provider codemie jwt [orgUrl] [token]');
      return true;
    }
    unawaited(_handleCodeMieJwtCommand(url, token));
    return true;
  }

  /// True when [value] starts with `http://` or `https://`.
  bool _isHttpUrl(String value) =>
      value.startsWith('http://') || value.startsWith('https://');

  /// Prints the CodeMie subcommand usage line.
  void _printCodeMieUsage() {
    io.writeln(
      'usage: /provider codemie [sso [orgUrl] | jwt [orgUrl] [token]]',
    );
  }

  /// Prompts the user to pick CodeMie SSO or JWT Bearer auth, then runs the
  /// chosen flow. The sub-flows manage [_providerFlowActive] themselves, so this
  /// picker releases the gate before handing off.
  Future<void> _handleCodeMieAuthMethodChoice() async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      final choice = await _pickOption('CodeMie sign-in method', [
        (
          'sso',
          'Browser SSO',
          'enterprise sign-in via the organization portal',
        ),
        ('jwt', 'JWT Bearer token', 'headless/CI token (paste your JWT)'),
      ]);
      if (choice == null) {
        io.writeln('CodeMie setup cancelled');
        return;
      }
      // Release the flow gate so the sub-flow can take its own lock.
      _providerFlowActive = false;
      if (choice == 'sso') {
        await _handleCodeMieSsoCommand(defaultCodeMieBaseUrl, offerName: true);
      } else {
        await _handleCodeMieJwtCommand(defaultCodeMieBaseUrl, null);
      }
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
  }

  /// Runs the CodeMie JWT Bearer flow: asks for the organization URL and a JWT
  /// token, validates it, fetches models, saves the provider, and switches.
  /// An explicit [token] skips the prompt (scriptable form).
  Future<void> _handleCodeMieJwtCommand(
    String codeMieUrl,
    String? token,
  ) async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      final orgUrl = codeMieUrl;

      final jwtToken = token ?? await _askLine('JWT token: ', secret: true);
      if (jwtToken == null || jwtToken.trim().isEmpty) {
        io.writeln('CodeMie JWT setup cancelled');
        return;
      }
      final trimmedToken = jwtToken.trim();

      if (!isCodeMieJwtToken(trimmedToken)) {
        io.writeln(
          'Invalid JWT token format (expected header.payload.signature)',
        );
        return;
      }
      if (codeMieJwtExpired(trimmedToken)) {
        final expiresAt = codeMieJwtExpiresAtMs(trimmedToken);
        final when = expiresAt != null
            ? DateTime.fromMillisecondsSinceEpoch(expiresAt).toIso8601String()
            : 'already';
        io.writeln('JWT token expired on $when');
        return;
      }

      final apiBase = '${codeMieApiBase(orgUrl)}/v1';
      final modelId = await _codemieJwtGuidedSetup(apiBase, trimmedToken);
      if (modelId == null || modelId.isEmpty) {
        io.writeln('CodeMie JWT setup cancelled');
        return;
      }

      await _applyCodeMieJwtCredentials(orgUrl, apiBase, trimmedToken, modelId);
    } catch (e) {
      io.writeln('CodeMie JWT setup failed: $e');
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
  }

  /// Guided setup for JWT Bearer auth: fetches and picks a model. Returns the
  /// chosen model id, or null on cancel. Project fetching is skipped — the
  /// project selection is informational and would add an extra prompt.
  Future<String?> _codemieJwtGuidedSetup(
    String apiBase,
    String jwtToken,
  ) async {
    io.writeln('fetching CodeMie models...');
    final models =
        await fetchCodeMieModelsWithJwt(
          apiBase,
          jwtToken,
          client: config.modelsHttpClient,
        ).catchError((_) {
          return const <String>[];
        });
    return _codemiePickModelFromList(models);
  }

  /// Picks a model from the fetched list, falling back to manual entry.
  Future<String?> _codemiePickModelFromList(List<String> models) async {
    final modelPick = await _pickOption('CodeMie model', [
      for (final id in models) (id, id, visionMarker(id)),
      ('', '+ enter manually', ''),
    ]);
    if (modelPick == null) return null;
    if (modelPick.isNotEmpty) return modelPick;
    final manual = await _askLine('model id: ');
    return manual?.trim().isNotEmpty == true ? manual!.trim() : null;
  }

  /// Saves a CodeMie JWT Bearer provider entry and switches to it. A first
  /// connect offers the provider-name step every add flow has (a cancel
  /// keeps the derived default — the token is already validated); a
  /// re-connect keeps the existing entry's name.
  Future<void> _applyCodeMieJwtCredentials(
    String orgUrl,
    String baseUrl,
    String jwtToken,
    String modelId,
  ) async {
    final registry = config.customProviders;
    final existing = registry != null
        ? _entryForBaseUrl(registry, baseUrl)
        : null;
    final defaultName =
        existing?.name ?? registry?.deriveName(baseUrl) ?? 'codemie';
    // Explicit JWT connect always asks for a name — Enter keeps the
    // existing entry (same-account token refresh), a new name creates a
    // separate entry for a second account.
    final name = registry == null
        ? defaultName
        : (await _askConnectProviderName(defaultName, sameBaseUrl: baseUrl)) ??
              defaultName;
    final keyName = CustomProviderRegistry.keyNameFor(
      baseUrl,
      providerName: name,
    );
    final spec = providerCatalog['openai']!;
    await _storeProviderToken(spec, baseUrl, jwtToken, keyName: keyName);

    if (registry != null) {
      registry.add(
        CustomProviderEntry(
          name: name,
          apiType: 'openai',
          baseUrl: baseUrl,
          modelId: modelId,
          keyName: keyName,
          authMethod: CustomProviderAuthMethod.jwt,
        ),
      );
      _activeCustomName = name;
      io.writeln('saved provider $name (listed first in /provider)');
    }
    await _switchCodeMieJwtProvider(spec, baseUrl, modelId, jwtToken, keyName);
    final expiresAt = codeMieJwtExpiresAtMs(jwtToken);
    if (expiresAt != null) {
      final hours =
          (expiresAt - DateTime.now().millisecondsSinceEpoch) ~/ 3600000;
      io.writeln('CodeMie JWT token expires in ~${hours}h');
    }
  }

  /// Switches to a CodeMie provider using JWT Bearer auth. The token is stored
  /// as the session key and passed to the openai-completions adapter as the
  /// regular Bearer apiKey (no cookie header needed).
  Future<void> _switchCodeMieJwtProvider(
    ProviderSpec spec,
    String baseUrl,
    String modelId,
    String jwtToken,
    String keyName,
  ) async {
    final modelLine = modelId == _agent.state.model.id
        ? '  model unchanged: $modelId — use /model to change'
        : '  model: $modelId';
    _providerKind = spec.kind;
    _apiKey = jwtToken;
    _explicitToken = true;
    _streamFunction = _catalogStreamFunction(spec.kind, jwtToken);
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
      headers: builtModel.headers,
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
    io.writeln('  key: JWT Bearer token (saved as $keyName)');
    io.writeln(modelLine);
    await config.onProviderChanged?.call(_providerKind, _apiKey);
  }

  /// Switches to a saved CodeMie provider, dispatching on its auth method:
  /// SSO cookie auth or JWT Bearer auth.
  Future<void> _switchToSavedCodeMieProvider(CustomProviderEntry entry) async {
    final keyName = entry.keyName;
    final token = keyName != null ? config.secureKeys?.read(keyName) : null;
    _activeCustomName = entry.name;

    if (entry.authMethod == CustomProviderAuthMethod.jwt ||
        (token != null && isCodeMieJwtToken(token))) {
      if (token == null || token.isEmpty) {
        io.writeln('CodeMie JWT token missing — re-run /provider codemie jwt');
        return;
      }
      if (codeMieJwtExpired(token)) {
        io.writeln('CodeMie JWT token expired — re-run /provider codemie jwt');
        return;
      }
      await _switchCodeMieJwtProvider(
        entry.spec,
        entry.baseUrl,
        entry.modelId,
        token,
        keyName ?? '',
      );
      return;
    }

    // SSO cookie auth (default for legacy CodeMie entries).
    if (token == null || token.isEmpty || codeMieCookieExpired(token)) {
      final orgUrl = codeMieOrgUrl(entry.baseUrl);
      io.writeln(
        'CodeMie session expired or missing — restarting SSO for $orgUrl...',
      );
      await _handleCodeMieSsoCommand(orgUrl);
      return;
    }
    await _switchCodeMieProvider(
      entry.spec,
      entry.baseUrl,
      entry.modelId,
      token,
      keyName ?? '',
    );
  }

  /// Restores CodeMie SSO cookie auth on startup when the saved
  /// provider/model/baseUrl triple points at a CodeMie custom provider.
  /// Without this, the stored cookie is sent as `Authorization: Bearer`,
  /// which CodeMie rejects with a 302 redirect to the SSO portal.
  ///
  /// If the cookie is expired, SSO is restarted immediately instead of
  /// waiting for the first request to fail with a 302.
  void _restoreCodeMieCookieAuthIfNeeded() {
    final registry = config.customProviders;
    if (registry == null) return;
    final model = _agent.state.model;
    final entry = _findCodeMieSsoEntry(registry, model.baseUrl);
    if (entry == null) return;
    final cookie = _resolveCodeMieCookie(entry.keyName);
    if (cookie == null || cookie.isEmpty) return;

    if (codeMieCookieExpired(cookie)) {
      final orgUrl = codeMieOrgUrl(entry.baseUrl);
      io.writeln(
        _style.yellow(
          'CodeMie session expired — opening browser to re-authorize $orgUrl...',
        ),
      );
      unawaited(_handleCodeMieSsoCommand(orgUrl));
      return;
    }

    _applyCodeMieCookieAuth(entry, cookie);
  }

  CustomProviderEntry? _findCodeMieSsoEntry(
    CustomProviderRegistry registry,
    String baseUrl,
  ) {
    return registry.entries
        .where(
          (e) =>
              e.baseUrl == baseUrl &&
              e.authMethod == CustomProviderAuthMethod.sso,
        )
        .firstOrNull;
  }

  String? _resolveCodeMieCookie(String? keyName) {
    // The cookie lives in the secure store under the saved entry's keyName.
    // Do NOT trust config.apiKey here: if the user has OPENAI_API_KEY (or
    // another catalog env var) set, config.apiKey would be that key, and
    // sending it as a Cookie: header would still get a 302 from CodeMie.
    if (keyName != null) {
      final stored = config.secureKeys?.read(keyName);
      if (stored != null && stored.isNotEmpty) return stored;
    }
    // Back-compat for tests/old entries that have no keyName: accept the
    // apiKey only when it looks like a cookie (k=v[;...]), not a raw API key.
    final fallback = config.apiKey;
    if (fallback.contains('=') || fallback.contains(';')) return fallback;
    return null;
  }

  void _applyCodeMieCookieAuth(CustomProviderEntry entry, String cookie) {
    final model = _agent.state.model;
    _apiKey = cookie;
    _explicitToken = true;
    _streamFunction = _catalogStreamFunction(entry.spec.kind, '');
    _agent.streamFunction = _streamFunction;
    _agent.state.model = Model(
      id: model.id,
      name: model.name,
      api: model.api,
      provider: model.provider,
      baseUrl: model.baseUrl,
      reasoning: model.reasoning,
      input: model.input,
      cost: model.cost,
      contextWindow: model.contextWindow,
      maxTokens: model.maxTokens,
      headers: {'cookie': cookie},
      compat: model.compat,
    );
  }
} // extension on AgentCli
