/// AIIN (aiin.by) provider command handling: the `/provider aiin` connect
/// flow (browser sign-in + automatic API-key registration) and the manual
/// `sk-aiin-…` key path.
///
/// Split out of `provider_commands.dart` to keep that file under the repo's
/// 2800-line size gate. Same library (a `part of`), so the extension sees
/// the class's private members and the helpers in `provider_commands.dart`.
///
/// Deliberately decomposed into small helpers (CC ≤ 3) — the repo's CRAP
/// ratchet rejects methods whose untested cyclomatic complexity exceeds the
/// pinned threshold.
part of 'agent_cli.dart';

extension _AiinProviderCommands on AgentCli {
  /// Dispatches `/provider aiin [key [apiKey]]`:
  ///
  /// - `/provider aiin` — browser sign-in (OAuth proxy flow) + key
  ///   registration;
  /// - `/provider aiin key [apiKey]` — paste an existing `sk-aiin-…` key.
  ///
  /// Returns true when the command targeted AIIN.
  bool _startAiinArg(List<String> args) {
    if (args.first != 'aiin') return false;
    if (args.length == 1) {
      unawaited(_handleAiinConnectCommand());
      return true;
    }
    return args[1] == 'key' ? _startAiinKeyArg(args) : _aiinUsage();
  }

  /// `/provider aiin key [apiKey]` — true when the argument shape is valid.
  bool _startAiinKeyArg(List<String> args) {
    if (args.length > 3) return _aiinUsage();
    unawaited(
      _handleAiinConnectCommand(pasteKey: args.length > 2 ? args[2] : null),
    );
    return true;
  }

  /// Prints the command usage. Always "handled" (true).
  bool _aiinUsage() {
    io.writeln('usage: /provider aiin [key [apiKey]]');
    return true;
  }

  /// The AIIN connect flow: sign-in method choice (browser or pasted key),
  /// the connect itself, then the shared model-pick + named-entry apply.
  Future<void> _handleAiinConnectCommand({String? pasteKey}) async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      final credential = await _aiinAcquireCredential(pasteKey: pasteKey);
      if (credential != null) {
        await _applyAiinCredentials(credential.$1, email: credential.$2);
      }
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
  }

  /// Resolves the `sk-aiin-…` credential: the pasted [pasteKey], a key the
  /// user typed in, or the browser connect flow. Null = cancelled.
  Future<(String, String?)?> _aiinAcquireCredential({String? pasteKey}) async {
    if (pasteKey != null) return (pasteKey, null);
    final choice = await _pickOption('AIIN (aiin.by) sign-in', [
      (
        'browser',
        'Sign in with the browser',
        'register a new sk-aiin API key automatically',
      ),
      (
        'key',
        'Paste an existing API key',
        'for keys created in the AIIN cabinet',
      ),
    ], initialKey: 'browser');
    if (choice == null) {
      io.writeln('AIIN setup cancelled');
      return null;
    }
    return choice == 'key' ? _aiinAcquirePastedKey() : _aiinConnectViaBrowser();
  }

  /// Asks for an existing key. Null = cancelled / empty answer.
  Future<(String, String?)?> _aiinAcquirePastedKey() async {
    final answer = await _askLine(
      'AIIN API key (sk-aiin-…): ',
      secret: true,
    );
    final trimmed = answer?.trim() ?? '';
    if (trimmed.isEmpty) {
      io.writeln('AIIN setup cancelled');
      return null;
    }
    return (trimmed, null);
  }

  /// The browser connect: identity-provider pick, then the loopback OAuth
  /// proxy flow. Null = cancelled at either step.
  Future<(String, String?)?> _aiinConnectViaBrowser() async {
    final provider = await _pickAiinIdentityProvider();
    if (provider == null) {
      io.writeln('AIIN setup cancelled');
      return null;
    }
    final result = await _runAiinConnect(provider);
    if (result == null) {
      io.writeln('AIIN setup cancelled');
      return null;
    }
    io.writeln(
      'AIIN API key registered (${result.apiKey.prefix}…) — stored in '
      'the secure store; manage keys in the AIIN cabinet',
    );
    return (result.apiKey.raw, result.email);
  }

  /// Runs the connect flow, honoring the test seam.
  Future<AiinConnectResult?> _runAiinConnect(String provider) {
    final connectFn = config.aiinConnectFn;
    if (connectFn != null) {
      return connectFn(provider: provider, onStatus: io.writeln);
    }
    return runAiinConnectCliFlow(provider: provider, onStatus: io.writeln);
  }

  /// Fetches the live identity-provider list (google first, matching the
  /// AIIN cabinet's default) and lets the user pick. Falls back to google
  /// when the list cannot be fetched (offline / standalone mode).
  Future<String?> _pickAiinIdentityProvider() async {
    var providers = await fetchAiinOAuthProviders(
      client: config.modelsHttpClient,
    ).catchError((_) => const <String>[]);
    if (providers.isEmpty) providers = const [aiinDefaultOAuthProvider];
    providers = [
      aiinDefaultOAuthProvider,
      ...providers.where((p) => p != aiinDefaultOAuthProvider),
    ];
    return _pickOption(
      'AIIN sign-in provider',
      [for (final p in providers) (p, p, 'account sign-in via aiin.by')],
    );
  }

  /// Applies a connected AIIN credential: model pick from the live
  /// endpoint, a named registry entry (the account email, so several AIIN
  /// accounts coexist), secure-store persistence, and the provider switch.
  Future<void> _applyAiinCredentials(String key, {String? email}) async {
    final spec = providerCatalog['aiin']!;
    final url = spec.defaultBaseUrl;
    final registry = config.customProviders;
    final name = await _aiinEntryName(registry, url, email);
    final picked = await _aiinPickModel(url, key);
    if (picked == null) {
      io.writeln('AIIN setup cancelled');
      return;
    }
    await _applyCustomProviderSetup(
      CustomProviderSetup(
        spec: spec,
        baseUrl: url,
        name: name,
        modelId: picked,
        token: key,
      ),
    );
  }

  /// Resolves the registry entry name: an existing entry on the same
  /// endpoint keeps its name; otherwise the account email (or the derived
  /// default), confirmed through the shared name prompt.
  Future<String> _aiinEntryName(
    CustomProviderRegistry? registry,
    String url,
    String? email,
  ) async {
    final existing = registry != null ? _entryForBaseUrl(registry, url) : null;
    final defaultName = existing?.name ?? registry?.deriveName(url) ?? 'aiin';
    if (registry == null) return defaultName;
    // The signed-in account's email IS the natural entry name — several
    // AIIN accounts coexist. Re-logins to the same account keep the name.
    return await _askConnectProviderName(
          email ?? defaultName,
          sameBaseUrl: url,
        ) ??
        defaultName;
  }

  /// The AIIN model step: live `/v1/models` (public on api.aiin.by) with a
  /// manual-entry fallback. Null = cancelled.
  Future<String?> _aiinPickModel(String url, String key) async {
    final ids = await _fetchProviderModelIds('aiin', url, key);
    if (ids.isNotEmpty) return _pickModelFromList(ids, title: 'AIIN model');
    final manual = await _askLine('AIIN model id: ');
    final trimmed = manual?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }
}
