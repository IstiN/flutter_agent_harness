/// The settings-hub flows of [AgentCli]: the two-level "provider → model"
/// pick (the Flutter app's settings pattern — pick the provider first, then
/// a model from its endpoint) driving the chat model and the media slots.
/// Split out of `agent_cli.dart` to keep that file under the repo's
/// 2800-line size gate. Same library (a `part of`), so the extension sees
/// the class's private members.
part of 'agent_cli.dart';

/// A completed provider → model pick: the endpoint, the wire spec, the
/// chosen model id, and the saved registry entry when the provider is a
/// custom one.
final class ProviderModelChoice {
  /// Creates the choice bundle.
  const ProviderModelChoice({
    required this.spec,
    required this.baseUrl,
    required this.modelId,
    this.savedEntry,
  });

  /// The chosen provider's catalog spec (api type, wire kind).
  final ProviderSpec spec;

  /// The endpoint the model list was fetched from.
  final String baseUrl;

  /// The picked (or manually entered) model id.
  final String modelId;

  /// Non-null when the provider is a saved custom-registry entry.
  final CustomProviderEntry? savedEntry;
}

/// Implementation members of [AgentCli] for the settings-hub flows. Named
/// (not anonymous) so hosts and tests can drive the flows directly.
extension SettingsFlow on AgentCli {
  /// The two-level "provider → model" pick: step 1 picks the provider
  /// (saved custom entries first, then the catalog), step 2 fetches that
  /// endpoint's `/models` (openai-like endpoints; manual entry otherwise or
  /// when the list is empty), then [apply] receives the choice. Cancelling
  /// any step aborts silently. [openAiCompatibleOnly] restricts the
  /// provider list to the wire format the media tools speak.
  /// [mediaSlot] opts the model-list fetch into catalog seeding — pass
  /// the slot name (e.g. `imageGeneration`) when the user is picking a
  /// media model so the remote catalog's per-slot ids show up in the
  /// result even when `/v1/models` returns an empty list.
  Future<void> runProviderModelFlow({
    required String title,
    bool openAiCompatibleOnly = false,
    String? mediaSlot,
    required Future<void> Function(ProviderModelChoice choice) apply,
  }) async {
    final provider = await _pickProviderStep(
      title,
      openAiCompatibleOnly: openAiCompatibleOnly,
    );
    if (provider == null) return;
    final (entry, spec, baseUrl) = provider;
    // The saved entry's own key authenticates the model-list fetch (the
    // generic key resolution knows nothing about entry key names).
    final entryKeyName = entry?.keyName;
    final entryToken = entryKeyName == null
        ? null
        : config.secureKeys?.read(entryKeyName);
    final modelId = await _pickModelStep(
      title,
      spec,
      baseUrl,
      entry?.modelId ?? _agent.state.model.id,
      token: entryToken,
      mediaSlot: mediaSlot,
    );
    if (modelId == null) return;
    await apply(
      ProviderModelChoice(
        spec: spec,
        baseUrl: baseUrl,
        modelId: modelId,
        savedEntry: entry,
      ),
    );
  }

  /// Step 1 of [runProviderModelFlow]: pick the provider (saved custom
  /// entries first, then the catalog). Returns null when the pick is
  /// cancelled.
  Future<(CustomProviderEntry?, ProviderSpec, String)?> _pickProviderStep(
    String title, {
    required bool openAiCompatibleOnly,
  }) async {
    final saved = config.customProviders?.entries ?? const [];
    final picked = await _pickOption(
      '$title — provider',
      _providerFlowOptions(saved, openAiCompatibleOnly: openAiCompatibleOnly),
    );
    if (picked == null) return null;
    if (picked.startsWith('saved:')) {
      final entry = saved.firstWhere((e) => e.name == picked.substring(6));
      return (entry, entry.spec, entry.baseUrl);
    }
    final spec = providerCatalog[picked.substring(8)]!;
    return (null, spec, spec.defaultBaseUrl);
  }

  /// The provider list of [_pickProviderStep]: saved custom entries first
  /// (`saved:<name>` keys), then the catalog (`catalog:<name>` keys),
  /// optionally restricted to the wire format the media tools speak.
  /// "OpenAI-compatible" is read as "any provider whose media tools can
  /// ride the same OpenAI completions wire" — that includes MiniMax
  /// (its image/video/music/tts/asr endpoints all use Bearer + JSON, the
  /// same shape the OpenAI adapter speaks) and the literal
  /// `openai-completions` catalog kind. Without this opt-in a MiniMax
  /// entry never shows up in the media picker (the user just reported
  /// exactly that).
  List<FlowOption> _providerFlowOptions(
    List<CustomProviderEntry> saved, {
    required bool openAiCompatibleOnly,
  }) {
    bool mediaOk(String kind) =>
        !openAiCompatibleOnly ||
        kind == 'openai-completions' ||
        kind == 'minimax';
    return [
      for (final entry in saved)
        if (mediaOk(entry.spec.kind))
          (
            'saved:${entry.name}',
            entry.name,
            '${entry.baseUrl} · ${entry.modelId}',
          ),
      for (final spec in enabledProviders())
        if (mediaOk(spec.kind))
          ('catalog:${spec.name}', spec.name, spec.defaultBaseUrl),
    ];
  }

  /// Step 2 of [runProviderModelFlow]: pick a model from the provider's
  /// endpoint. Model-listing endpoints (OpenAI-compatible, DIAL
  /// deployments, CodeMie `/llm_models` — the dispatch lives in
  /// `_fetchModelsForFlow`) offer their list with a "+ enter manually"
  /// escape; anything else — an empty list included — falls back to manual
  /// entry. Returns null when any prompt is cancelled.
  Future<String?> _pickModelStep(
    String title,
    ProviderSpec spec,
    String baseUrl,
    String currentModelId, {
    String? token,
    String? mediaSlot,
  }) async {
    if (spec.kind == 'openai-completions' ||
        spec.kind == 'minimax' ||
        spec.name == 'dial') {
      io.writeln('fetching models from $baseUrl ...');
      final models = await _fetchModelsForFlow(
        spec,
        baseUrl,
        token: token,
        mediaSlot: mediaSlot,
      );
      if (models.isNotEmpty) {
        final picked = await _pickFromModelList(title, models, currentModelId);
        if (picked == null) return null;
        if (picked.isNotEmpty) return picked;
      }
    }
    return _askModelIdManually(currentModelId);
  }

  /// The endpoint-list pick of [_pickModelStep]: the fetched ids plus the
  /// "+ enter manually" escape (empty key). Null = cancelled.
  Future<String?> _pickFromModelList(
    String title,
    List<String> models,
    String currentModelId,
  ) {
    return _pickOption('$title — model', [
      for (final id in models) (id, id, visionMarker(id)),
      ('', '+ enter manually', ''),
    ], initialKey: models.contains(currentModelId) ? currentModelId : null);
  }

  /// The manual-entry fallback of [_pickModelStep]: an empty answer keeps
  /// [currentModelId]; null = cancelled.
  Future<String?> _askModelIdManually(String currentModelId) async {
    final manual = await _askLine("model id (empty keeps '$currentModelId'): ");
    if (manual == null) return null;
    return manual.trim().isEmpty ? currentModelId : manual.trim();
  }

  /// Settings → Chat model: provider → model, then switch the connection.
  /// Mirrors `_switchToSavedProvider` for saved entries (secure-store key
  /// resolution included) but applies the picked model instead of the
  /// entry's last-used one.
  Future<void> startChatModelFlow() {
    return runProviderModelFlow(
      title: 'chat model',
      apply: (choice) async {
        final entry = choice.savedEntry;
        if (entry != null) {
          _activeCustomName = entry.name;
          final keyName = entry.keyName;
          final token = keyName != null
              ? config.secureKeys?.read(keyName)
              : null;
          await _switchProvider(
            entry.spec,
            entry.baseUrl,
            choice.modelId,
            token: token,
            tokenKeyName: keyName,
          );
          // Keep the entry's last-used model in sync (the flow bypasses
          // _switchModel, which normally records it).
          _recordCustomModel(choice.modelId);
        } else {
          await _switchProvider(choice.spec, choice.baseUrl, choice.modelId);
        }
      },
    );
  }

  /// Settings → Media models: pick the slot, then provider → model, then
  /// pin the slot override (same persistence as `/models set`).
  Future<void> startMediaSlotFlow() async {
    final models = config.modelsConfig;
    if (models == null) {
      io.writeln('models config is unavailable on this host');
      return;
    }
    final selectedSlot = await _pickOption('media slot', [
      for (final id in mediaModelSlotIds)
        (id, id, _mediaSlotDescription(models, id)),
    ]);
    if (selectedSlot == null) return;
    await runProviderModelFlow(
      title: 'media $selectedSlot',
      openAiCompatibleOnly: true,
      mediaSlot: selectedSlot,
      apply: (choice) async {
        models.setSlotOverride(
          selectedSlot,
          MediaSlotModelConfig(
            providerKind: 'openai-completions',
            baseUrl: choice.baseUrl,
            modelId: choice.modelId,
            // The saved custom provider's key authenticates the media
            // endpoint; without it the tool sends no Authorization header.
            apiKeyName: choice.savedEntry?.keyName,
          ),
        );
        io.writeln(
          'slot $selectedSlot → ${choice.modelId} @ ${choice.baseUrl} '
          '(openai-completions)',
        );
        config.onModelsConfigChanged?.call();
      },
    );
  }

  /// Settings → Agent models: pick the task role (Quick model / Subagents
  /// model), then provider → model through the shared two-level flow, and
  /// the role's chain is pinned — live on the resolver from the next spawn
  /// and persisted into the config's `roles:` section. A role can also be
  /// cleared back to the main model (the chain is dropped, the role
  /// inherits `default`).
  Future<void> startAgentModelFlow() async {
    final role = await _pickOption('agent models — role', [
      for (final roleId in const [smolModelRole, subagentModelRole])
        (
          'role:$roleId',
          _agentRoleLabel(roleId),
          _agentRoleChainSummary(roleId),
        ),
    ]);
    if (role == null) return;
    final roleId = role.substring(5);
    final action =
        await _pickOption('agent models — ${_agentRoleLabel(roleId)}', [
          ('set', 'Pick a model', 'provider → model list'),
          ('clear', 'Use the main model', 'drop the override'),
        ]);
    if (action == null) return;
    if (action == 'clear') {
      final resolver = config.modelRolesResolver;
      if (resolver != null) {
        resolver.clearRoleChain(roleId);
        config.onModelsConfigChanged?.call();
      }
      io.writeln('role $roleId → main model');
      return;
    }
    await runProviderModelFlow(
      title: 'agent ${_agentRoleLabel(roleId)}',
      apply: (choice) async {
        final entry = choice.savedEntry;
        final ref = ModelRef(
          provider: choice.spec.name,
          modelId: choice.modelId,
          // The catalog default URL is implicit; a saved custom entry (or a
          // non-default endpoint) pins its URL explicitly.
          baseUrl: entry != null || choice.baseUrl != choice.spec.defaultBaseUrl
              ? choice.baseUrl
              : null,
          apiKeyName: entry?.keyName,
        );
        _ensureRolesResolver().setRoleChain(roleId, [ref]);
        config.onModelsConfigChanged?.call();
        io.writeln('role $roleId → ${choice.modelId} @ ${choice.baseUrl}');
      },
    );
  }

  /// The display label of an agent-model role (mirrors the app's
  /// TaskModelsSection titles).
  String _agentRoleLabel(String roleId) => switch (roleId) {
    smolModelRole => 'Quick model (smol)',
    subagentModelRole => 'Subagents model (subagent)',
    _ => roleId,
  };

  /// The role picker's description: the pinned chain head, or the
  /// main-connection fallback when the role carries no chain.
  String _agentRoleChainSummary(String roleId) {
    final chain = config.modelRolesResolver?.config.roles[roleId];
    if (chain == null || chain.isEmpty) return 'main connection';
    final head = chain.first;
    return '${head.provider}/${head.modelId}';
  }

  /// The roles resolver, created on demand when the session started without
  /// a `roles:` config section. Auxiliary roles (smol/subagent) resolve
  /// lazily through it; the untouched `default` role keeps the legacy
  /// single-provider wiring. Secrets come from the secure-key snapshot so
  /// `apiKeyName` chain entries authenticate like startup-built ones.
  ModelRolesResolver _ensureRolesResolver() {
    final existing = config.modelRolesResolver;
    if (existing != null) return existing;
    final keys = config.secureKeys;
    final resolver = ModelRolesResolver(
      config: ModelRolesConfig(roles: const {}),
      secrets: keys == null
          ? const {}
          : {for (final name in keys.names) name: keys.read(name)!},
    );
    config.modelRolesResolver = resolver;
    return resolver;
  }

  /// The media-slot picker's description: the current override or the
  /// main-connection fallback.
  String _mediaSlotDescription(ModelsConfig models, String slot) {
    final override = models.slots[slot];
    if (override == null) return 'main connection';
    return '${override.modelId} @ ${override.baseUrl}';
  }

  /// `/settings`: a bare command opens the TUI settings hub; anything else
  /// (and line mode) prints the current settings summary.
  Future<void> _settingsSlash(String rest) async {
    if (rest.isEmpty && _useTui && _tuiController != null) {
      _openSettingsPicker();
    } else {
      _printSettingsSummary();
    }
  }

  /// The settings hub picker: one entry per configurable area, each
  /// launching the same interactive flow its dedicated slash command would.
  void _openSettingsPicker() {
    final model = _agent.state.model;
    final items = [
      MenuItem(key: 'provider', label: 'Provider', description: model.provider),
      MenuItem(key: 'model', label: 'Chat model', description: model.id),
      const MenuItem(
        key: 'model-edit',
        label: 'Model parameters',
        description: 'context window, token limits',
      ),
      const MenuItem(
        key: 'media',
        label: 'Media models',
        description: 'image, speech, music, video slots',
      ),
      const MenuItem(
        key: 'agent-models',
        label: 'Agent models',
        description: 'quick + subagent model overrides',
      ),
      MenuItem(
        key: 'approval',
        label: 'Approval mode',
        description: _approval.mode.label,
      ),
      MenuItem(
        key: 'mode',
        label: 'Agent mode',
        description: _currentMode.name,
      ),
      MenuItem(
        key: 'cube',
        label: 'Cube sandbox',
        description: _cubeStatusLabel(),
      ),
      const MenuItem(
        key: 'keys',
        label: 'API keys',
        description: 'set or inspect stored keys',
      ),
      const MenuItem(
        key: 'mcp',
        label: 'MCP servers',
        description: 'status and config reload',
      ),
    ];
    _tuiController?.openPicker('settings', 'Settings', items);
  }

  /// A settings-hub selection launches the same flow its dedicated slash
  /// command would open.
  Future<void> _tuiPickSetting(String key) async {
    await _settingsPickerHandlers[key]?.call();
  }

  /// Settings-hub key → the flow its dedicated slash command would open.
  Map<String, Future<void> Function()> get _settingsPickerHandlers => {
    'provider': () async => _openProviderPicker(),
    'model': startChatModelFlow,
    'model-edit': () => _handleModelEdit(''),
    'media': startMediaSlotFlow,
    'agent-models': startAgentModelFlow,
    'approval': () async => _openApprovalPicker(),
    'mode': () async => _openModePicker(),
    'keys': () => _handleKeyCommand(''),
    'cube': startCubeSandboxFlow,
  };

  /// The line-mode `/settings` summary (the TUI opens the hub instead).
  void _printSettingsSummary() {
    final model = _agent.state.model;
    io.writeln('provider: ${model.provider}');
    io.writeln('model: ${model.id}');
    io.writeln('approval: ${_approval.mode.label}');
    io.writeln('mode: ${_currentMode.name}');
    io.writeln('cube: ${_cubeStatusLabel()}');
    io.writeln(
      'change via /provider, /model, /approval, /mode, /key, /mcp, /cube '
      '(agent models: the /settings hub)',
    );
  }
}
