part of 'agent_cli.dart';

/// Provider-preset helpers for [AgentCli]: the "Add provider" picker and the
/// catalog-specific setup flows it launches. Kept in a part file so the main
/// class stays under the line-count limit.
extension _AgentCliProviderPresets on AgentCli {
  /// The preset picker for adding a new provider: catalog presets each
  /// launching their specific setup flow, plus `Custom` as the generic
  /// openai-compatible path.
  void _openAddProviderPicker() {
    _tuiController?.openPicker('addProvider', 'Add provider', [
      ..._addProviderItems(),
    ]);
  }

  /// The rows of [_openAddProviderPicker]. Every `preset:<name>` key MUST
  /// have a matching entry in [_addProviderHandlers] — the picker used to
  /// ship without Copilot even though `/provider copilot` worked, because
  /// this list is hand-maintained (the test asserts the pairing).
  List<MenuItem> _addProviderItems() => [
    const MenuItem(
      key: 'preset:openrouter',
      label: 'OpenRouter',
      description: 'OAuth or API key — 300+ models',
    ),
    const MenuItem(
      key: 'preset:chatgpt',
      label: 'ChatGPT (Codex)',
      description: 'account sign-in via OAuth',
    ),
    const MenuItem(
      key: 'preset:copilot',
      label: 'GitHub Copilot',
      description: 'account sign-in via device flow',
    ),
    const MenuItem(
      key: 'preset:codemie',
      label: 'CodeMie',
      description: 'organization SSO sign-in',
    ),
    const MenuItem(
      key: 'preset:dial',
      label: 'DIAL',
      description: 'EPAM DIAL Core — Api key + deployment',
    ),
    const MenuItem(
      key: 'preset:kimi',
      label: 'Kimi',
      description: 'api.kimi.com/coding/v1 — key: KIMI_API_KEY',
    ),
    const MenuItem(
      key: 'preset:zai',
      label: 'Z.AI',
      description: 'GLM models — key: z.ai/manage-apikey/apikey-list',
    ),
    const MenuItem(
      key: 'preset:minimax',
      label: 'MiniMax',
      description: 'api.minimax.io — key: platform.minimax.io/interface-key',
    ),
    const MenuItem(
      key: 'preset:openai',
      label: 'OpenAI',
      description: 'api.openai.com — API key',
    ),
    const MenuItem(
      key: 'preset:anthropic',
      label: 'Anthropic',
      description: 'api.anthropic.com — API key',
    ),
    const MenuItem(
      key: 'preset:google',
      label: 'Google',
      description: 'Gemini models — API key',
    ),
    const MenuItem(
      key: 'custom',
      label: 'Custom',
      description: 'any OpenAI-compatible endpoint',
    ),
  ];

  /// Routes a preset-picker selection to the matching setup flow.
  Future<void> _tuiPickAddProvider(String key) async {
    if (key == 'custom') return _startProviderFlow();
    if (!key.startsWith('preset:')) return;
    await _addProviderHandlers[key.substring('preset:'.length)]?.call();
  }

  /// Switches to the catalog Kimi provider (Kimi Code API). The key step
  /// depends on what already resolves for the endpoint:
  ///
  /// - nothing resolves → a masked prompt (empty skips; the switch then
  ///   reports the missing key as before). A freshly typed key becomes a
  ///   saved NAMED registry entry (provider-name step included — the same
  ///   shape the custom wizard produces), so a second Kimi account keeps its
  ///   own name and name-scoped store key instead of overwriting the
  ///   host-scoped slot;
  /// - a key resolves (env / store / a named entry's slot) → a picker: use
  ///   it, or add ANOTHER Kimi with a different key. The second account
  ///   routes into the generic wizard so it lands in its own named entry
  ///   with a name-scoped store key the env var can't shadow on the next
  ///   start.
  ///
  /// The preset picker and the typed `/provider kimi` both land here.
  Future<void> _handleKimiCommand({String? baseUrl}) async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    // True when the generic wizard took over (it manages the gate itself).
    var handedOff = false;
    try {
      final spec = providerCatalog['kimi']!;
      final url = baseUrl ?? spec.defaultBaseUrl;
      final resolved = _providerKeyFor(spec, url);
      final outcome = resolved != null && baseUrl == null
          ? await _kimiResolvedKeyChoice(spec, url)
          : await _kimiFreshKeyPath(spec, url, resolved);
      switch (outcome) {
        case _KimiOutcome.handedOff:
          handedOff = true;
        case _KimiOutcome.switched:
          break;
      }
    } finally {
      if (!handedOff) {
        _providerFlowActive = false;
        _promptLineBuffer.clear();
      }
    }
  }

  /// The resolved-key branch of [_handleKimiCommand]: offer "use it / add a
  /// second account"; the second hands off to the generic wizard.
  Future<_KimiOutcome> _kimiResolvedKeyChoice(
    ProviderSpec spec,
    String url,
  ) async {
    final choice = await _pickOption('Kimi API key', [
      (
        'current',
        'Use the resolved key',
        _providerKeyLine(spec, url, explicit: false),
      ),
      (
        'another',
        'Use a different API key',
        'adds a separately-named Kimi entry — a second account',
      ),
    ], initialKey: 'current');
    if (choice == null) {
      io.writeln('kimi setup cancelled');
      return _KimiOutcome.switched;
    }
    if (choice == 'another') {
      // Hand off to the wizard: release the gate first, it takes its own.
      _providerFlowActive = false;
      _startProviderFlow(
        initialType: 'openai',
        initialBaseUrl: url,
        initialModelId: 'k3',
      );
      return _KimiOutcome.handedOff;
    }
    // A catalog switch (resolved key): the previously-active custom entry
    // must stop receiving `/model` memory updates.
    _activeCustomName = null;
    await _switchProvider(spec, url, 'k3');
    return _KimiOutcome.switched;
  }

  /// The no-resolved-key branch of [_handleKimiCommand]: ask for a key
  /// (empty = keyless switch); a typed key becomes a NAMED entry.
  Future<_KimiOutcome> _kimiFreshKeyPath(
    ProviderSpec spec,
    String url,
    String? resolved,
  ) async {
    String? typed;
    if (resolved == null) {
      final answer = await _askLine(
        'Kimi API key (empty to skip, env ${spec.apiKeyEnvNames.first}): ',
        secret: true,
      );
      if (answer == null) {
        io.writeln('kimi setup cancelled');
        return _KimiOutcome.switched;
      }
      final trimmed = answer.trim();
      typed = trimmed.isEmpty ? null : trimmed;
    }
    final registry = config.customProviders;
    if (typed == null || registry == null) {
      // A resolved env/store key stays an implicit resolution inside
      // `_switchProvider` (the "key: KIMI_API_KEY" line, no re-store); a
      // keyless switch reports the missing key as before. Without a
      // registry there is nothing to save an entry into — the plain
      // catalog switch still stores the typed key under the host slot.
      _activeCustomName = null;
      await _switchProvider(spec, url, 'k3', token: typed);
      return _KimiOutcome.switched;
    }
    // A freshly typed key is a NEW account: save it as a named entry (the
    // provider-name step every add flow offers), so it lists in /provider
    // and a custom name keeps its key in a name-scoped store slot.
    final name = await _askConnectProviderName(
      registry.deriveName(url),
      sameBaseUrl: url,
    );
    if (name == null) {
      io.writeln('kimi setup cancelled');
      return _KimiOutcome.switched;
    }
    await _applyCustomProviderSetup(
      CustomProviderSetup(
        spec: spec,
        baseUrl: url,
        name: name,
        modelId: 'k3',
        token: typed,
      ),
    );
    return _KimiOutcome.switched;
  }

  /// Preset name → the setup flow it launches.
  Map<String, Future<void> Function()> get _addProviderHandlers => {
    'openrouter': () => _handleOpenRouterAuthMethodChoice(),
    'chatgpt': () => _handleChatGptOAuthCommand(headless: false),
    'codemie': () => _handleCodeMieAuthMethodChoice(),
    'dial': () => _startDialProviderSetup(),
    'openai': () async => _startProviderFlow(initialType: 'openai'),
    'anthropic': () async => _startProviderFlow(initialType: 'anthropic'),
    'google': () async => _startProviderFlow(initialType: 'google'),
    'kimi': _handleKimiCommand,
    'zai': () async => _startProviderFlow(
      initialType: 'openai',
      initialBaseUrl: 'https://api.z.ai/api/coding/paas/v4',
      initialName: 'z.ai',
      initialModelId: 'glm-4.5',
    ),
    'minimax': () async => _startProviderFlow(
      initialType: 'minimax',
      initialBaseUrl: 'https://api.minimax.io/v1',
      initialName: 'minimax',
      initialModelId: 'MiniMax-M3',
    ),
  };
}

/// Terminal outcomes of the kimi flow branches (gate handling differs).
enum _KimiOutcome { handedOff, switched }
