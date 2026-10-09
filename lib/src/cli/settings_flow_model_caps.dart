/// The settings-hub Model capabilities flow (gh-1426) of [AgentCli]:
/// per-provider+model capability overrides — context window, max output
/// tokens, thinking level, the omit-max-output compat flag — pinned into
/// `models.overrides` and resolved by the layered capability resolver.
/// Split out of `settings_flow.dart` for the repo's 2800-line size gate.
/// Same library (a `part of`), so the extension sees the class's private
/// members and the shared config helpers.
part of 'agent_cli.dart';

/// Model-capabilities settings members of [AgentCli] (gh-1426).
extension ModelCapabilityCapsSettings on AgentCli {
  /// The settings-hub row and `/settings` summary label for the
  /// per-provider+model capability overrides (gh-1426).
  String _modelCapsStatusLabel() {
    final count = config.modelsConfig?.overrides.length ?? 0;
    return count == 0 ? 'none pinned' : '$count pinned';
  }

  /// Settings → Model capabilities (gh-1426): pin per-provider+model
  /// capability overrides — context window, max output tokens, thinking
  /// level, the omit-max-output compat flag — into `models.overrides`.
  /// The entries survive every catalog refresh (they live in the config
  /// file, never in catalog data), and the resolver's top layer reads
  /// exactly these keys. Loops until the pick is cancelled or `done`.
  Future<void> startModelCapsFlow() async {
    for (;;) {
      // Re-read EVERY iteration: a remove/add inside the loop must be
      // reflected in the next render — a pre-loop snapshot kept listing a
      // just-removed override and reopened a ghost edit menu.
      final pinnedEntries =
          config.modelsConfig?.overrides.entries ??
          const <
            ({String provider, String modelId, ModelCapabilityOverride caps})
          >[];
      final picked = await _pickOption('model capabilities', [
        (
          'set',
          'Pin or edit an override',
          'pick provider → model → capabilities',
        ),
        for (final entry in pinnedEntries)
          (
            'entry:${entry.provider}/${entry.modelId}',
            '${entry.provider}/${entry.modelId}',
            _capabilitySummary(entry.caps),
          ),
        ('done', 'Done', ''),
      ]);
      if (picked == null || picked == 'done') return;
      if (picked == 'set') {
        await runProviderModelFlow(
          title: 'model capabilities',
          apply: (choice) =>
              _editModelCapsOverride(choice.spec.name, choice.modelId),
        );
      } else if (picked.startsWith('entry:')) {
        final label = picked.substring(6);
        final slash = label.indexOf('/');
        await _editModelCapsOverride(
          label.substring(0, slash),
          label.substring(slash + 1),
        );
      }
    }
  }

  /// The one-line summary of a pinned override (menu descriptions).
  String _capabilitySummary(ModelCapabilityOverride caps) {
    final parts = <String>[
      if (caps.contextWindow != null) 'ctx ${caps.contextWindow}',
      if (caps.maxTokens != null) 'out ${caps.maxTokens}',
      if (caps.thinkingLevel != null) 'thinking ${caps.thinkingLevel}',
      if (caps.omitMaxOutputTokens ?? false) 'omit max-output field',
    ];
    return parts.isEmpty ? '(empty)' : parts.join(' · ');
  }

  /// The caps loop for one (provider, modelId) override: shows the pinned
  /// values, edits one field at a time through the validated upsert, and
  /// offers removal. Cancelling returns to the flow menu.
  Future<void> _editModelCapsOverride(String provider, String modelId) async {
    for (;;) {
      final current =
          config.modelsConfig?.overrides.lookup(provider, modelId) ??
          const ModelCapabilityOverride();
      final picked = await _pickOption('capabilities — $provider/$modelId', [
        (
          'contextWindow',
          'Context window',
          current.contextWindow == null
              ? 'not pinned (catalog default)'
              : '${current.contextWindow} tokens',
        ),
        (
          'maxTokens',
          'Max output tokens',
          current.maxTokens == null
              ? 'not pinned (catalog default)'
              : '${current.maxTokens} tokens',
        ),
        (
          'thinkingLevel',
          'Thinking level',
          current.thinkingLevel == null
              ? 'not pinned (no thinking requested)'
              : current.thinkingLevel!,
        ),
        (
          'omit',
          'Omit max-output field',
          (current.omitMaxOutputTokens ?? false)
              ? 'on (endpoints that reject the field)'
              : 'off',
        ),
        if (!current.isEmpty)
          ('remove', 'Remove this override', 'all pinned fields'),
        ('done', 'Done', ''),
      ]);
      if (picked == null || picked == 'done') return;
      switch (picked) {
        case 'remove':
          await _removeCapabilityOverride(provider, modelId);
          return;
        case 'contextWindow' || 'maxTokens':
          await _askCapabilityTokens(provider, modelId, picked);
        case 'thinkingLevel':
          await _askCapabilityThinkingLevel(provider, modelId);
        case 'omit':
          await _writeCapabilityField(
            provider,
            modelId,
            'omitMaxOutputTokens',
            current.omitMaxOutputTokens == true ? 'false' : 'true',
          );
      }
    }
  }

  /// The token-field branch: a positive integer at/above the boundary
  /// floor (16384 window reserve, 1024 output answer floor). The raw
  /// answer rides the validated upsert — an invalid value prints the
  /// parser's verbatim [ConfigException] and writes NOTHING.
  Future<void> _askCapabilityTokens(
    String provider,
    String modelId,
    String field,
  ) async {
    final floor = field == 'contextWindow'
        ? minOverrideContextWindow
        : minOverrideMaxTokens;
    final answer = await _askLine(
      '$field in tokens (min $floor, empty cancels): ',
    );
    if (answer == null) return;
    final value = answer.trim();
    if (value.isEmpty) return;
    await _writeCapabilityField(provider, modelId, field, value);
  }

  /// The thinking-level branch: pick a ladder rung (or `off` to unpin).
  Future<void> _askCapabilityThinkingLevel(
    String provider,
    String modelId,
  ) async {
    final picked = await _pickOption('thinking level', [
      ('off', 'Off', 'no thinking requested'),
      for (final rung in configThinkingLevels)
        (rung, rung, rung == 'high' ? 'top rung (xhigh/max fold here)' : ''),
    ]);
    if (picked == null) return;
    if (picked == 'off') {
      await _removeCapabilityField(provider, modelId, 'thinkingLevel');
      return;
    }
    // Persist the FOLDED rung — what the resolver reads is what the wire
    // gets (xhigh/max fold to high at every surface).
    final folded = normalizeConfigThinkingLevel(picked) ?? picked;
    await _writeCapabilityField(provider, modelId, 'thinkingLevel', folded);
  }

  /// The shared capability write path: a USER-file upsert of
  /// `models.overrides.<provider>.<modelId>.<field>`, validated with the
  /// real [ModelsConfig] parser BEFORE the write; then the live apply
  /// (reload-after-write, E6: last writer wins, both surfaces re-read).
  Future<void> _writeCapabilityField(
    String provider,
    String modelId,
    String field,
    String value,
  ) async {
    if (_userConfigPath() == null) {
      io.writeln('model capabilities: no user config on this host — not saved');
      return;
    }
    final wrote = await _upsertConfigYaml(
      ['models', 'overrides', provider, modelId, field],
      value,
      projectScope: false,
      validate: ModelsConfig.fromYaml,
    );
    if (wrote) await _applyCapabilityEdit(provider, modelId);
  }

  /// Removes one pinned FIELD from an override (the validated remove).
  Future<void> _removeCapabilityField(
    String provider,
    String modelId,
    String field,
  ) async {
    final path = _userConfigPath();
    if (path == null) {
      io.writeln('model capabilities: no user config on this host — not saved');
      return;
    }
    final read = await _env.readTextFile(path);
    final String source;
    switch (read) {
      case Ok(:final value):
        source = value;
      case Err(:final error):
        io.writeln('cannot read $path: $error — not saved');
        return;
    }
    final edited = removeYamlPath(source, [
      'models',
      'overrides',
      provider,
      modelId,
      field,
    ]);
    // Never persist a file the next boot would reject. A doc with no
    // `models:` section left is valid — the models config is optional at
    // boot, and removing the last pinned field drops the whole block.
    final doc = loadYaml(edited);
    final models = doc is YamlMap ? doc['models'] : null;
    try {
      if (models != null) ModelsConfig.fromYaml(models);
    } on Object catch (error) {
      io.writeln('not saved: $error');
      return;
    }
    if (await _env.writeFile(path, edited) is Err) {
      io.writeln('could not write $path');
      return;
    }
    io.writeln(
      'models.overrides.$provider.$modelId.$field removed → $path '
      '(${applicationNote('models')})',
    );
    await _applyCapabilityEdit(provider, modelId);
  }

  /// Removes the whole override entry for (provider, modelId).
  Future<void> _removeCapabilityOverride(
    String provider,
    String modelId,
  ) async {
    final path = _userConfigPath();
    if (path == null) {
      io.writeln('model capabilities: no user config on this host — not saved');
      return;
    }
    final read = await _env.readTextFile(path);
    final String source;
    switch (read) {
      case Ok(:final value):
        source = value;
      case Err(:final error):
        io.writeln('cannot read $path: $error — not saved');
        return;
    }
    final edited = removeYamlPath(source, [
      'models',
      'overrides',
      provider,
      modelId,
    ]);
    // Same rule as the field remove: no `models:` section left is valid —
    // the last override's removal drops the whole block.
    final doc = loadYaml(edited);
    final models = doc is YamlMap ? doc['models'] : null;
    try {
      if (models != null) ModelsConfig.fromYaml(models);
    } on Object catch (error) {
      io.writeln('not saved: $error');
      return;
    }
    if (await _env.writeFile(path, edited) is Err) {
      io.writeln('could not write $path');
      return;
    }
    io.writeln(
      'models.overrides.$provider.$modelId removed → $path '
      '(${applicationNote('models')})',
    );
    await _applyCapabilityEdit(provider, modelId);
  }

  /// The live apply after every capability write (E6): re-read the saved
  /// file with the boot parser, reinstall the process-wide override layer
  /// and the host's live [ModelsConfig], drop the roles resolver's cached
  /// wrappers so the next run rebuilds through the new caps, and print the
  /// resolver's notes for the edited model (gate + divergence, loud).
  Future<void> _applyCapabilityEdit(String provider, String modelId) async {
    final path = _userConfigPath();
    if (path != null) {
      switch (await _env.readTextFile(path)) {
        case Ok(:final value):
          final doc = loadYaml(value);
          // The `models:` section is optional at boot: removing the last
          // override drops the whole block, and the live layer must then
          // reinstall EMPTY (nothing pinned), not throw.
          final section = doc is YamlMap ? doc['models'] : null;
          final models = section == null
              ? ModelsConfig()
              : ModelsConfig.fromYaml(section);
          modelCapabilityOverrides = models.overrides;
          config.modelsConfig?.overrides = models.overrides;
        case Err():
          // The write just succeeded; a read race keeps the current live
          // layer — the next write re-syncs.
          break;
      }
    }
    config.modelRolesResolver?.refreshCapabilities();
    final spec = catalogProvider(provider);
    final caps = resolveModelCapabilities(
      provider: provider,
      modelId: modelId,
      override: modelCapabilityOverrides?.lookup(provider, modelId),
      spec: spec,
      api: spec?.api,
      reasoning: spec?.reasoning ?? true,
    );
    for (final note in caps.notes) {
      io.writeln(_style.dim('note: $note'));
    }
  }
}
