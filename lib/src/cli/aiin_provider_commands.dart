/// AIIN (aiin.by) provider command handling: the `/provider aiin` connect
/// flow (browser sign-in + automatic API-key registration) and the manual
/// `sk-aiin-…` key path.
///
/// Split out of `provider_commands.dart` to keep that file under the repo's
/// 2800-line size gate. Same library (a `part of`), so the extension sees
/// the class's private members and the helpers in `provider_commands.dart`.
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
    if (args[1] == 'key') {
      final token = args.length > 2 ? args[2] : null;
      if (args.length > 3) {
        io.writeln('usage: /provider aiin [key [apiKey]]');
        return true;
      }
      unawaited(_handleAiinConnectCommand(pasteKey: token));
      return true;
    }
    io.writeln('usage: /provider aiin [key [apiKey]]');
    return true;
  }

  /// The AIIN connect flow: sign-in method choice (browser or pasted key),
  /// the connect itself, then the shared model-pick + named-entry apply.
  Future<void> _handleAiinConnectCommand({String? pasteKey}) async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      String? key = pasteKey;
      String? email;
      if (key == null) {
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
          return;
        }
        if (choice == 'key') {
          final answer = await _askLine(
            'AIIN API key (sk-aiin-…): ',
            secret: true,
          );
          if (answer == null) {
            io.writeln('AIIN setup cancelled');
            return;
          }
          final trimmed = answer.trim();
          if (trimmed.isEmpty) {
            io.writeln('AIIN setup cancelled');
            return;
          }
          key = trimmed;
        }
      }
      if (key == null) {
        // Browser sign-in: pick the identity provider, then run the flow.
        final provider = await _pickAiinIdentityProvider();
        if (provider == null) {
          io.writeln('AIIN setup cancelled');
          return;
        }
        final result = await runAiinConnectCliFlow(
          provider: provider,
          onStatus: io.writeln,
        );
        if (result == null) return;
        key = result.apiKey.raw;
        email = result.email;
        io.writeln(
          'AIIN API key registered (${result.apiKey.prefix}…) — stored in '
          'the secure store; manage keys in the AIIN cabinet',
        );
      }
      await _applyAiinCredentials(key, email: email);
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
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
    final existing = registry != null
        ? _entryForBaseUrl(registry, url)
        : null;
    final defaultName = existing?.name ?? registry?.deriveName(url) ?? 'aiin';
    final name = registry == null
        ? defaultName
        : (await _askConnectProviderName(
            defaultName == 'aiin' && email != null ? email : defaultName,
            sameBaseUrl: url,
          )) ??
          defaultName;
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
