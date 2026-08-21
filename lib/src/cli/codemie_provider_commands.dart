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
    unawaited(_handleCodeMieSsoCommand(url));
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
        await _handleCodeMieSsoCommand(defaultCodeMieBaseUrl);
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

  /// Saves a CodeMie JWT Bearer provider entry and switches to it.
  Future<void> _applyCodeMieJwtCredentials(
    String orgUrl,
    String baseUrl,
    String jwtToken,
    String modelId,
  ) async {
    final registry = config.customProviders;
    final candidate = _codeMieHostName(baseUrl);
    final existing = registry?.find(candidate);
    final name = existing?.name ?? registry?.deriveName(baseUrl) ?? 'codemie';
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
    config.onProviderChanged?.call(_providerKind, _apiKey);
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
} // extension on AgentCli
