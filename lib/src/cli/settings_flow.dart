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
  Future<void> runProviderModelFlow({
    required String title,
    bool openAiCompatibleOnly = false,
    required Future<void> Function(ProviderModelChoice choice) apply,
  }) async {
    final provider = await _pickProviderStep(
      title,
      openAiCompatibleOnly: openAiCompatibleOnly,
    );
    if (provider == null) return;
    final (entry, spec, baseUrl) = provider;
    final modelId = await _pickModelStep(
      title,
      spec,
      baseUrl,
      entry?.modelId ?? _agent.state.model.id,
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
  List<FlowOption> _providerFlowOptions(
    List<CustomProviderEntry> saved, {
    required bool openAiCompatibleOnly,
  }) {
    return [
      for (final entry in saved)
        if (!openAiCompatibleOnly || entry.spec.kind == 'openai-completions')
          (
            'saved:${entry.name}',
            entry.name,
            '${entry.baseUrl} · ${entry.modelId}',
          ),
      for (final spec in enabledProviders())
        if (!openAiCompatibleOnly || spec.kind == 'openai-completions')
          ('catalog:${spec.name}', spec.name, spec.defaultBaseUrl),
    ];
  }

  /// Step 2 of [runProviderModelFlow]: pick a model from the provider's
  /// endpoint. OpenAI-like endpoints offer their `/models` list (with a
  /// "+ enter manually" escape); anything else — an empty list included —
  /// falls back to manual entry. Returns null when any prompt is cancelled.
  Future<String?> _pickModelStep(
    String title,
    ProviderSpec spec,
    String baseUrl,
    String currentModelId,
  ) async {
    if (spec.kind == 'openai-completions') {
      io.writeln('fetching models from $baseUrl/models ...');
      final models = await _fetchModelsForFlow(spec, baseUrl);
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
    return _pickOption(
      '$title — model',
      [
        for (final id in models) (id, id, visionMarker(id)),
        ('', '+ enter manually', ''),
      ],
      initialKey: models.contains(currentModelId) ? currentModelId : null,
    );
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
    final slot = await _pickOption('media slot', [
      for (final id in mediaModelSlotIds)
        (id, id, _mediaSlotDescription(models, id)),
    ]);
    if (slot == null) return;
    await runProviderModelFlow(
      title: 'media $slot',
      openAiCompatibleOnly: true,
      apply: (choice) async {
        models.setSlotOverride(
          slot,
          MediaSlotModelConfig(
            providerKind: 'openai-completions',
            baseUrl: choice.baseUrl,
            modelId: choice.modelId,
          ),
        );
        io.writeln(
          'slot $slot → ${choice.modelId} @ ${choice.baseUrl} '
          '(openai-completions)',
        );
        config.onModelsConfigChanged?.call();
      },
    );
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
    'approval': () async => _openApprovalPicker(),
    'mode': () async => _openModePicker(),
    'keys': () => _handleKeyCommand(''),
    'mcp': () async => _printMcpStatus(),
  };

  /// The line-mode `/settings` summary (the TUI opens the hub instead).
  void _printSettingsSummary() {
    final model = _agent.state.model;
    io.writeln('provider: ${model.provider}');
    io.writeln('model: ${model.id}');
    io.writeln('approval: ${_approval.mode.label}');
    io.writeln('mode: ${_currentMode.name}');
    io.writeln('change via /provider, /model, /approval, /mode, /key, /mcp');
  }
}
