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
    ]);
  }

  /// Routes a preset-picker selection to the matching setup flow.
  Future<void> _tuiPickAddProvider(String key) async {
    if (key == 'custom') return _startProviderFlow();
    if (!key.startsWith('preset:')) return;
    await _addProviderHandlers[key.substring('preset:'.length)]?.call();
  }

  /// Switches to the catalog Kimi provider (Kimi Code API).
  Future<void> _handleKimiCommand({String? baseUrl}) async {
    final spec = providerCatalog['kimi']!;
    await _switchProvider(spec, baseUrl ?? spec.defaultBaseUrl, 'k3');
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
