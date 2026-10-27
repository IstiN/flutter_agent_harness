/// The CodeMie SSO/session block of the provider commands (issue #1809
/// + #1921): the SSO connect/apply flow, the guided project/model
/// setup, the cookie switch, the model picker, and the host-name
/// derivation. Split out of `provider_commands.dart` for the repo's
/// 2800-line size gate — same library (a `part of`), so the extension
/// sees the class's private members and the shared config helpers.
part of 'agent_cli.dart';

extension ProviderCodeMieSso on AgentCli {
  /// Runs the CodeMie SSO flow and applies the resulting credentials.
  /// [offerName] is true only for the explicit add flows (typed command,
  /// auth-method picker): the automatic re-authorizations (startup, saved
  /// entry switch, mid-stream expiry) keep the existing entry's name — or
  /// the derived default — without interrupting the recovery with a prompt.
  /// [noBrowser] (the `--no-browser` flag) skips the automatic browser
  /// launch — the URL prints prominently instead (gh-1450).
  Future<void> _handleCodeMieSsoCommand(
    String codeMieUrl, {
    bool offerName = false,
    bool noBrowser = false,
  }) async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      final authenticate =
          config.codeMieSsoAuthenticateFn ??
          (url, onStatus) => runCodeMieSsoCliFlow(
            codeMieUrl: url,
            onStatus: onStatus,
            shouldOpenBrowserFn: () =>
                shouldLaunchBrowser(noBrowserFlag: noBrowser),
          );
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
  /// the key). The model's headers carry a `cookie:` entry so the
  /// openai-completions adapter sends Cookie-header auth instead of the
  /// default `authorization: Bearer`. After saving, runs the guided
  /// project → model selection (matching the CodeMie CLI's setup flow) so
  /// the user lands on a working connection — on EVERY connect now
  /// (issue #1809 AC2): a re-login to the same entry leads the project
  /// picker with a keep-current row. [offerName] gates the provider-name
  /// step (explicit add flows only — see the caller).
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

    // Guided project → model selection. It runs for a NEW account AND on a
    // re-login to the SAME entry (issue #1809 AC2 — the old sameAccount
    // skip hid the picker from every re-auth path): the re-login leads the
    // picker with a keep-current row, so Enter keeps the existing
    // project/model while a pick switches.
    final sameAccount = existing != null && name == existing.name;
    final guided = await _codemieGuidedSetup(
      credentials.apiUrl,
      cookie,
      currentProject: sameAccount ? existing.project : null,
      currentModelId: sameAccount ? existing.modelId : null,
      // The name step already ran above — the fetch rides the final
      // (possibly user-chosen) identity's binding.
      providerName: name,
    );
    final project = guided.$1 ?? (sameAccount ? existing.project : null);
    final modelId = guided.$2 ?? existing?.modelId ?? _agent.state.model.id;

    if (registry != null) {
      registry.add(
        CustomProviderEntry(
          name: name,
          apiType: 'openai',
          baseUrl: baseUrl,
          modelId: modelId,
          keyName: keyName,
          authMethod: CustomProviderAuthMethod.sso,
          project: project,
        ),
      );
      _activeCustomName = name;
      io.writeln('saved provider $name (listed first in /provider)');
    }
    await _switchCodeMieProvider(
      spec,
      baseUrl,
      modelId,
      cookie,
      keyName,
      project: project,
      providerName: name,
    );
    final hours =
        (credentials.expiresAt - DateTime.now().millisecondsSinceEpoch) ~/
        3600000;
    io.writeln(
      'CodeMie session expires in ~${hours}h — re-run '
      '/provider codemie sso to renew',
    );
  }

  /// Post-SSO guided setup: fetch projects, let the user pick one, then
  /// fetch and pick a model. Returns the (project, modelId) pair — a null
  /// modelId is a cancel. Dispatches to the config-injected guided setup
  /// (a test seam returning a model id only — the project stays null), or
  /// the real flow, which leads a re-login with a keep-current row
  /// ([currentModelId] set, issue #1809 AC2).
  Future<(String?, String?)> _codemieGuidedSetup(
    String apiBase,
    String cookie, {
    String? currentProject,
    String? currentModelId,
    required String providerName,
  }) async {
    final override = config.codeMieGuidedSetupFn;
    if (override != null) {
      final modelId = await override(apiBase, cookie, _pickOption, _askLine);
      return (null, modelId);
    }
    return _codemiePickProjectAndModel(
      apiBase,
      cookie,
      currentProject: currentProject,
      currentModelId: currentModelId,
      providerName: providerName,
    );
  }

  /// Switches to a CodeMie provider using Cookie-header auth instead of the
  /// default Bearer token. The cookie string is stored as the session key
  /// (for `/models` fetches and key status display), but the openai-completions
  /// adapter receives an empty apiKey (so it skips `authorization: Bearer`)
  /// while the model's `headers` carry `cookie: <full cookie string>`.
  /// [project] rides as the `x-codemie-project` header (issue #1809).
  Future<void> _switchCodeMieProvider(
    ProviderSpec spec,
    String baseUrl,
    String modelId,
    String cookie,
    String keyName, {
    String? project,
    required String providerName,
  }) async {
    final modelLine = modelId == _agent.state.model.id
        ? '  model unchanged: $modelId — use /model to change'
        : '  model: $modelId';
    _providerKind = spec.kind;
    // The cookie is the "key" for session/display purposes, but the stream
    // function gets an empty string so the adapter generates NO authorization
    // header; the cookie rides in via model.headers instead.
    _apiKey = cookie;
    _explicitToken = true;
    // The SAVED ENTRY's name keys the `providers:` gate — `spec` here is
    // the catalog openai spec, never the binding identity (issue #1921
    // round-4: keying 'openai' sent bound entries' cookie-bearing chat
    // traffic direct).
    _streamFunction = _catalogStreamFunction(
      spec.kind,
      '',
      providerName: providerName,
    );
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
      // merges model.headers, adding `cookie: <full cookie jar>` — plus the
      // picked project (issue #1809 AC4).
      headers: {'cookie': cookie, 'x-codemie-project': ?project},
      compat: builtModel.compat,
      maxImages: builtModel.maxImages,
    );
    _modelCache = const [];
    _modelContextWindows = const {};
    _modelMaxTokens = const {};
    _lastModelList = null;
    unawaited(_refreshModelCache());
    await _session?.appendModelChange(
      provider: spec.name,
      modelId: modelId,
      // A LIVE switch records the pin too (gh-1000 AC1, round-3 review).
      baseUrl: baseUrl,
      customProvider: _activeCustomName,
    );
    io.writeln('switched provider to ${spec.name} (${spec.api})');
    io.writeln('  endpoint: $baseUrl');
    io.writeln('  key: SSO cookie (saved as $keyName)');
    io.writeln(modelLine);
    _printRoleModelsNote();
    await config.onProviderChanged?.call(_providerKind, _apiKey);
  }

  /// Step 2: fetch and pick a CodeMie model (or manual entry).
  /// [providerName] keys the `providers:` `network:` proxy gate (issue
  /// #1921) — the fetch rides the same bound client as the chat stream.
  Future<String?> _codemiePickModel(
    String apiBase,
    String cookie, {
    required String providerName,
  }) async {
    io.writeln('fetching CodeMie models...');
    final models =
        await fetchCodeMieModels(
          '$apiBase/v1',
          cookie,
          client: modelFetchClient(providerName),
        ).catchError((e) {
          return const <String>[];
        });
    if (models.isEmpty) {
      io.writeln('no models available — set one with /model <id>');
      return null;
    }
    return _pickModelFromList(models);
  }

  /// Picks a model from the fetched list, falling back to manual entry.
  Future<String?> _pickModelFromList(
    List<String> models, {
    String title = 'CodeMie model',
  }) async {
    final modelPick = await _pickOption(title, [
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
}
