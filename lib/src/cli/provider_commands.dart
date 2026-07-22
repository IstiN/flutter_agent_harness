/// The provider/key management section of [AgentCli]: the `/provider` and
/// `/key` commands, the guided custom-provider flow glue, the TUI provider
/// picker, and the key-status helpers. Split out of `agent_cli.dart` to
/// keep that file under the repo's 2800-line size gate. Same library (a
/// `part of`), so the extension sees the class's private members.
part of 'agent_cli.dart';

/// Implementation members of [AgentCli] for provider and key management.
extension on AgentCli {
  /// Starts the guided custom-provider setup without awaiting it: the REPL
  /// loop must keep reading lines so the flow's prompts can be answered
  /// (awaiting it here would deadlock the loop on the first question).
  void _startCustomProviderFlow() {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    unawaited(
      runCustomProviderFlow(
        io,
        CustomProviderFlowConfig(
          promptLine: _promptLine,
          fetchModels: _fetchModelsForFlow,
          switchProvider: (spec, baseUrl, modelId, {token}) =>
              _switchProvider(spec, baseUrl, modelId, token: token),
          currentModelId: () => _agent.state.model.id,
          rolesActive: config.modelRolesResolver != null,
        ),
      ).whenComplete(() {
        _providerFlowActive = false;
        // Leftover buffered lines are flow answers, not user prompts.
        _promptLineBuffer.clear();
      }),
    );
  }

  /// The flow's `/models` fetch with the same key resolution the provider
  /// switch uses (explicit token, else the provider's env names).
  Future<List<String>> _fetchModelsForFlow(
    ProviderSpec spec,
    String baseUrl, {
    String? token,
  }) {
    final key = token ?? _providerKeyFromEnv(spec) ?? '';
    final fetch = config.modelsFetcher ?? _fetchOpenAiCompatibleModels;
    return fetch(baseUrl, apiKey: key);
  }

  /// Reads one input line for a guided-flow prompt (printed inline).
  /// Resolves to `null` on cancel (Ctrl-C interrupt or input shutdown),
  /// which the flow maps to "setup cancelled". Answers buffered while no
  /// prompt was pending (piped input) are consumed first.
  Future<String?> _promptLine(String question) async {
    // Guided flows run sequentially (one command at a time); complete a
    // stray pending prompt defensively as cancelled.
    final stray = _pendingPromptAnswer;
    if (stray != null && !stray.isCompleted) stray.complete(null);
    io.write(question);
    if (_promptLineBuffer.isNotEmpty) {
      final buffered = _promptLineBuffer.removeAt(0);
      // Piped lines are not echoed by the terminal; keep the transcript
      // readable like the interactively typed answers.
      io.writeln(buffered);
      return buffered;
    }
    final pending = Completer<String?>();
    _pendingPromptAnswer = pending;
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

  /// The TUI provider picker (bare `/provider`): the provider catalog with
  /// default endpoints, plus the guided custom-provider entry. A catalog
  /// selection switches with catalog defaults; custom base URLs and tokens
  /// go through the guided flow or the typed command.
  void _openProviderPicker() {
    final current = _agent.state.model.provider;
    final items = [
      for (final spec in providerCatalog.values)
        MenuItem(
          key: spec.name,
          label: spec.name,
          description:
              '${spec.defaultBaseUrl}'
              '${spec.name == current ? ' (current)' : ''}',
        ),
      const MenuItem(
        key: 'custom',
        label: '+ custom provider…',
        description: 'guided setup: api type, url, key, model',
      ),
    ];
    _tuiController?.openPicker('provider', 'Select provider', items);
  }

  /// `/provider [name] [baseUrl] [token] | custom` — shows the active
  /// provider, endpoint, and key status plus the supported catalog; switches
  /// the provider/endpoint at runtime; or starts the guided custom-provider
  /// setup (`custom`, see provider_flow.dart). Without an explicit token the
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
      _startCustomProviderFlow();
      return;
    }
    if (args.length > 3) {
      io.writeln('usage: /provider <name> [baseUrl] [token]');
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
    final baseUrl = args.length > 1 ? args[1] : spec.defaultBaseUrl;
    final token = args.length > 2 ? args[2] : null;
    await _switchProvider(spec, baseUrl, _agent.state.model.id, token: token);
  }

  /// Applies a provider/endpoint switch: rebuilds the model and stream
  /// (roles mode pins the default chain instead), records the change, and
  /// prints the confirmation. [modelId] replaces the active id (the typed
  /// command keeps it, the custom flow lets the user pick); [token] is an
  /// explicit session key — persisted to the secure store when available,
  /// never to the config file. Without [token] the key resolves from the
  /// provider's catalog env names.
  Future<void> _switchProvider(
    ProviderSpec spec,
    String baseUrl,
    String modelId, {
    String? token,
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
      _lastModelList = null;
      await _session?.appendModelChange(provider: spec.name, modelId: modelId);
      io.writeln('switched provider to ${spec.name} (endpoint: $baseUrl)');
      io.writeln(modelLine);
      config.onModelChanged?.call(_agent.state.model);
      return;
    }
    final key = token ?? _providerKeyFromEnv(spec) ?? '';
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
    _lastModelList = null;
    unawaited(_refreshModelCache());
    await _session?.appendModelChange(provider: spec.name, modelId: modelId);
    var keyLine = _providerKeyLine(spec, baseUrl, explicit: token != null);
    if (token != null) {
      final savedTo = await _storeProviderToken(spec, token);
      if (savedTo != null) {
        keyLine =
            'key: provided (saved to $savedTo; '
            'remove with /key delete ${spec.apiKeyEnvNames.first})';
      }
    }
    io.writeln('switched provider to ${spec.name} (${spec.api})');
    io.writeln('  endpoint: $baseUrl');
    io.writeln('  $keyLine');
    io.writeln(modelLine);
    config.onProviderChanged?.call(_providerKind, _apiKey);
  }

  /// Persists an explicit `/provider` token in the platform secure store
  /// (under the provider's primary env name) so future starts resolve it
  /// without env vars. Returns the store label on success, null when secure
  /// storage is unavailable (the token then stays session-only).
  Future<String?> _storeProviderToken(ProviderSpec spec, String token) async {
    final keys = config.secureKeys;
    if (keys == null || !keys.available) return null;
    final name = spec.apiKeyEnvNames.first;
    if (await keys.save(name, token)) {
      config.onSecretStored?.call(name, token);
      return keys.label;
    }
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
        await keys.save(args[1], args[2]);
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
  /// plus the supported catalog with default endpoints.
  void _printProviderStatus() {
    final model = _agent.state.model;
    io.writeln('provider: ${model.provider} (${model.api})');
    io.writeln('  endpoint: ${model.baseUrl}');
    final keyStatus = _keyStatusLine(model);
    if (keyStatus != null) io.writeln('  $keyStatus');
    io.writeln('supported providers:');
    for (final spec in providerCatalog.values) {
      io.writeln('  ${spec.name} — ${spec.defaultBaseUrl}');
    }
    io.writeln(
      'use /provider <name> [baseUrl] [token] to switch, '
      'or /provider custom for a guided setup',
    );
  }

  /// Resolves the API key for [spec] from the host environment: the first
  /// of the catalog env names with a non-empty value. Null when the host
  /// exposes no values (tests, web) or nothing is set.
  String? _providerKeyFromEnv(ProviderSpec spec) {
    final read = config.envVarValue;
    if (read == null) return null;
    for (final name in spec.apiKeyEnvNames) {
      final value = read(name);
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// The `/provider` confirmation's key line: the source of the resolved
  /// key (env var name, or "provided" for an explicit token — never the
  /// value), a keyless note for a custom endpoint (local servers may
  /// legitimately run without a key), or a warning when a hosted endpoint
  /// has no key.
  String _providerKeyLine(
    ProviderSpec spec,
    String baseUrl, {
    required bool explicit,
  }) {
    if (explicit) return 'key: provided';
    final read = config.envVarValue;
    if (read != null) {
      for (final name in spec.apiKeyEnvNames) {
        final value = read(name);
        if (value != null && value.isNotEmpty) return 'key: $name';
      }
    }
    if (baseUrl != spec.defaultBaseUrl) return 'key: none (keyless endpoint)';
    return 'key: no key found (want ${spec.apiKeyEnvNames.first})';
  }
}
