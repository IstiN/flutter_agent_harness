/// Settings-hub → Media models: the per-slot flow — pick the slot, then
/// how it is served (a dedicated provider/model, the explicit
/// main-connection opt-in, or marked unsupported). Split out of
/// `settings_flow.dart` for the repo's 2800-line size gate (issue #2085
/// added the action step). Same library (a `part of`), so the extension
/// sees the class's private members.
part of 'agent_cli.dart';

extension MediaSlotFlow on AgentCli {
  /// Settings → Media models: pick the slot, then how the slot is served —
  /// a dedicated provider/model, the main connection (the explicit gh-1844
  /// opt-in, i.e. "same model as main"), or marked unsupported (issue
  /// #2085: the media capability is removed — media tools refuse the slot
  /// and the pickers stop suggesting it). The choice pins immediately and
  /// applies live (the media resolvers read the config per call).
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
    // The action menu marks the slot's CURRENT state (issue #2085 review).
    final current = models.slots[selectedSlot];
    final action = await _pickOption(
      'media $selectedSlot',
      [
        ('pick', 'Pick a model', 'provider → model list'),
        (
          'main',
          'Use the main connection',
          'serve the slot with the main model',
        ),
        ('unsupported', 'Mark unsupported', 'remove the media capability'),
      ],
      initialKey: current == null
          ? null
          : current.unsupported
          ? 'unsupported'
          : current.useMainConnection
          ? 'main'
          : 'pick',
    );
    if (action == null) return;
    switch (action) {
      case 'main':
        models.setSlotOverride(
          selectedSlot,
          MediaSlotModelConfig(useMainConnection: true),
        );
        io.writeln('slot $selectedSlot → main connection');
        config.onModelsConfigChanged?.call();
        // gh-1984 (review thread 5): the availability pass follows the
        // live slot — a mid-session vision/transcription pin must not
        // leave /tools contradicting the slot until some unrelated
        // rebuild happens to run.
        unawaited(AgentCliTools(this).rebuildToolAvailability());
        return;
      case 'unsupported':
        models.setSlotOverride(
          selectedSlot,
          MediaSlotModelConfig(unsupported: true),
        );
        io.writeln('slot $selectedSlot → unsupported (capability removed)');
        config.onModelsConfigChanged?.call();
        unawaited(AgentCliTools(this).rebuildToolAvailability());
        return;
    }
    await runProviderModelFlow(
      title: 'media $selectedSlot',
      openAiCompatibleOnly: true,
      mediaSlot: selectedSlot,
      apply: (choice) async {
        models.setSlotOverride(
          selectedSlot,
          MediaSlotModelConfig(
            providerKind: _factoryProviderKind,
            baseUrl: choice.baseUrl,
            modelId: choice.modelId,
            // The saved custom provider's key authenticates the media
            // endpoint; without it fall back to the host-scoped key.
            apiKeyName:
                choice.savedEntry?.keyName ??
                CustomProviderRegistry.keyNameFor(choice.baseUrl),
          ),
        );
        io.writeln(
          'slot $selectedSlot → ${choice.modelId} @ ${choice.baseUrl} '
          '(openai-completions)',
        );
        config.onModelsConfigChanged?.call();
        unawaited(AgentCliTools(this).rebuildToolAvailability());
      },
    );
  }

  /// The media-slot picker's description: which of the four per-slot
  /// states the slot is in — unconfigured, unsupported, the explicit
  /// main-connection opt-in, or the pinned override.
  String _mediaSlotDescription(ModelsConfig models, String slot) {
    final override = models.slots[slot];
    if (override == null) return 'not configured';
    if (override.unsupported) return 'unsupported (capability removed)';
    if (override.useMainConnection) return 'main connection';
    return '${override.modelId} @ ${override.baseUrl}';
  }
}
