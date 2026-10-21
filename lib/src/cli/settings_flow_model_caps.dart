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
  /// The settings-hub row description for Model capabilities (issue #1515):
  /// the ACTIVE model's effective summary — window, output cap, thinking —
  /// instead of the pin count. The user sees what applies now, not what is
  /// stored; the numbers are the live model's, already resolver-resolved.
  String _modelCapsStatusLabel() {
    final model = _agent.state.model;
    return '${formatTokenPreset(model.contextWindow)} ctx · '
        '${formatTokenPreset(model.maxTokens)} out · '
        'thinking ${model.thinkingLevel ?? 'off'}';
  }

  /// The roles-chain entry backing (provider, modelId) on the session's
  /// default chain — its explicit caps are the resolver's role-slot layer
  /// (capability_resolver.dart precedence 2). Null when the session runs
  /// legacy single-model wiring or the chain does not name the model.
  ModelRef? _currentRoleRef(String provider, String modelId) {
    final resolver = config.modelRolesResolver;
    if (resolver == null) return null;
    final chain = resolver.config.chainFor(
      defaultModelRole,
      cwd: resolver.cwd,
      homeDir: resolver.homeDir,
    );
    if (chain == null) return null;
    for (final ref in chain) {
      if (ref.provider == provider && ref.modelId == modelId) return ref;
    }
    return null;
  }

  /// The pinned override for (provider, modelId) as this flow sees it: the
  /// host config's live layer — the same map [_editModelCapsOverride] and
  /// the validated writes read and mutate — falling back to the
  /// process-wide boot layer only when the host carries no live config.
  /// E6 (reload-after-write) re-syncs both on every flow write, so they
  /// agree in production; the config layer wins because it is the surface
  /// this flow edits (a stale boot mirror must never outvote it).
  ModelCapabilityOverride? _pinnedCaps(String provider, String modelId) =>
      config.modelsConfig?.overrides.lookup(provider, modelId) ??
      modelCapabilityOverrides?.lookup(provider, modelId);

  /// The resolved effective caps for (provider, modelId) as this flow's
  /// rows and [_applyCapabilityEdit] see them (same call shape, same
  /// layering — the display can never disagree with the apply).
  EffectiveCaps _effectiveCapsFor(String provider, String modelId) {
    final spec = catalogProvider(provider);
    final role = _currentRoleRef(provider, modelId);
    return resolveModelCapabilities(
      provider: provider,
      modelId: modelId,
      override: _pinnedCaps(provider, modelId),
      roleContextWindow: role?.contextWindow,
      roleMaxTokens: role?.maxTokens,
      roleThinkingLevel: role?.thinkingLevel,
      spec: spec,
      api: spec?.api,
      reasoning: spec?.reasoning ?? true,
    );
  }

  /// The source-layer label of the effective context window for
  /// (provider, modelId): the models.overrides pin, the roles-chain slot,
  /// or the catalog/endpoint buckets below them (names follow
  /// capability_resolver.dart's precedence docs).
  String _windowLayer(String provider, String modelId) {
    if (_pinnedCaps(provider, modelId)?.contextWindow != null) {
      return 'pinned';
    }
    if (_currentRoleRef(provider, modelId)?.contextWindow != null) {
      return 'role override';
    }
    return 'catalog';
  }

  /// The source-layer label of the effective max output (see
  /// [_windowLayer]).
  String _maxTokensLayer(String provider, String modelId) {
    if (_pinnedCaps(provider, modelId)?.maxTokens != null) {
      return 'pinned';
    }
    if (_currentRoleRef(provider, modelId)?.maxTokens != null) {
      return 'role override';
    }
    return 'catalog';
  }

  /// The source-layer label of the effective thinking level: pin, role
  /// slot, or the no-layer default (thinking has no catalog layer — the
  /// resolver reads override > role slot, then gates on `reasoning`).
  String _thinkingLayer(String provider, String modelId) {
    if (_pinnedCaps(provider, modelId)?.thinkingLevel != null) {
      return 'pinned';
    }
    if (_currentRoleRef(provider, modelId)?.thinkingLevel != null) {
      return 'role override';
    }
    return 'default';
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

  /// The caps menu for one (provider, modelId) override: one row per
  /// pinnable field showing the CURRENT EFFECTIVE value and its source
  /// layer (issue #1515 AC3 — the user sees what applies before editing),
  /// the remove row (only when something is pinned), and Done.
  List<FlowOption> _capabilityMenuOptions(
    String provider,
    String modelId,
    ModelCapabilityOverride current,
  ) {
    final caps = _effectiveCapsFor(provider, modelId);
    final supportsThinking = catalogProvider(provider)?.reasoning ?? true;
    return [
      (
        'contextWindow',
        'Context window',
        '${caps.contextWindow} (${_windowLayer(provider, modelId)})',
      ),
      (
        'maxTokens',
        'Max output tokens',
        '${caps.maxTokens} (${_maxTokensLayer(provider, modelId)})',
      ),
      (
        'thinkingLevel',
        'Thinking level',
        supportsThinking
            ? '${caps.thinkingLevel ?? 'off'} '
                  '(${_thinkingLayer(provider, modelId)})'
            : 'off (model has no thinking — a pinned level is dropped)',
      ),
      (
        'omit',
        'Omit max-output field',
        // The flag is read by the openai-completions adapter only
        // (OpenAICompletionsCompat) — a pin on google/anthropic/chatgpt-
        // codex does nothing; say so where the pin is made.
        (current.omitMaxOutputTokens ?? false)
            ? 'on (openai-completions only — endpoints that reject the field)'
            : 'off (openai-completions only)',
      ),
      if (!current.isEmpty)
        ('remove', 'Remove this override', 'all pinned fields'),
      ('done', 'Done', ''),
    ];
  }

  /// The caps loop for one (provider, modelId) override: shows the pinned
  /// values, edits one field at a time through the validated upsert, and
  /// offers removal. Cancelling returns to the flow menu.
  Future<void> _editModelCapsOverride(String provider, String modelId) async {
    for (;;) {
      final current =
          config.modelsConfig?.overrides.lookup(provider, modelId) ??
          const ModelCapabilityOverride();
      final picked = await _pickOption(
        'capabilities — $provider/$modelId',
        _capabilityMenuOptions(provider, modelId, current),
      );
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

  /// The token-field branch: the model-edit preset ladder plus Custom…
  /// free input (ported from the retired `pickModelEditValue` /
  /// `_pickCustomTokenValue`, issue #1515), the current effective value
  /// preselected. A preset pick writes the override and applies it live;
  /// the raw custom answer rides the validated upsert — an invalid value
  /// prints the parser's verbatim [ConfigException] and writes NOTHING.
  Future<void> _askCapabilityTokens(
    String provider,
    String modelId,
    String field,
  ) async {
    final isContext = field == 'contextWindow';
    final presets = isContext
        ? const [4096, 8192, 16384, 32768, 65536, 131072, 204800, 1048576]
        : const [4096, 8192, 16384, 32768, 65536];
    final caps = _effectiveCapsFor(provider, modelId);
    final effective = isContext ? caps.contextWindow : caps.maxTokens;
    final picked = await _pickOption('$field in tokens', [
      for (final p in presets) ('$p', formatTokenPreset(p), '$p tokens'),
      ('custom', 'Custom…', 'Enter a number manually'),
    ], initialKey: presets.contains(effective) ? '$effective' : 'custom');
    if (picked == null) return;
    if (picked != 'custom') {
      await _writeCapabilityField(provider, modelId, field, picked);
      return;
    }
    final floor = isContext ? minOverrideContextWindow : minOverrideMaxTokens;
    final answer = await _askLine(
      '$field in tokens (min $floor, empty cancels): ',
    );
    if (answer == null) return;
    final value = answer.trim();
    if (value.isEmpty) return;
    await _writeCapabilityField(provider, modelId, field, value);
  }

  /// The thinking-level branch: an omp-style selector (issue #1515) — only
  /// the levels the model supports, each rung described with its thinking
  /// budget (`defaultThinkingBudgets`), the CURRENT level preselected, and
  /// `off` to unpin. The `xhigh`/`max` fold aliases are picker-less: the
  /// top rung's description names them, and the write path still folds.
  Future<void> _askCapabilityThinkingLevel(
    String provider,
    String modelId,
  ) async {
    final supportsThinking = catalogProvider(provider)?.reasoning ?? true;
    final current =
        _pinnedCaps(provider, modelId)?.thinkingLevel ??
        _currentRoleRef(provider, modelId)?.thinkingLevel;
    final picked = await _pickOption('thinking level', [
      ('off', 'Off', 'no thinking requested'),
      if (supportsThinking)
        for (final entry in defaultThinkingBudgets.entries)
          (
            entry.key,
            entry.key,
            '${entry.value}-token thinking budget'
                '${entry.key == 'high' ? ' — top rung (xhigh/max fold here)' : ''}',
          ),
    ], initialKey: current ?? 'off');
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
  ) => _removeCapabilityYaml([
    'models',
    'overrides',
    provider,
    modelId,
    field,
  ], 'models.overrides.$provider.$modelId.$field removed');

  /// Removes the whole override entry for (provider, modelId).
  Future<void> _removeCapabilityOverride(String provider, String modelId) =>
      _removeCapabilityYaml([
        'models',
        'overrides',
        provider,
        modelId,
      ], 'models.overrides.$provider.$modelId removed');

  /// The shared capability remove path (one body for both twins): removes
  /// the yaml node at [segments] from the USER config file, validated with
  /// the real [ModelsConfig] parser BEFORE the write ("not saved" on throw
  /// — never persist a file the next boot would reject); then the success
  /// [message] (naming the removed path) and the live apply
  /// (reload-after-write, E6). A doc with no `models:` section left is
  /// valid — the models config is optional at boot, and removing the last
  /// pinned field drops the whole block.
  Future<void> _removeCapabilityYaml(
    List<String> segments,
    String message,
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
    final edited = removeYamlPath(source, segments);
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
    await _notifyUserConfigFileChanged();
    io.writeln('$message → $path (${applicationNote('models')})');
    await _applyCapabilityEdit(segments[2], segments[3]);
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
    // Pin-apply is live (issue #1515 AC5): when the edit targets the
    // ACTIVE model, rebuild it from the resolved caps — the retired
    // /model-edit flow's live-mutation semantics, now backed by
    // models.overrides so the numbers survive a model/provider switch.
    // The full constructor (not [Model.copyWith] — it null-KEEPS, and an
    // unpin must be able to CLEAR thinkingLevel/compat) enumerates every
    // field, and a pin carrying the window publishes into the shared
    // registry as a userPin — main, children, and the meter resolve ONE
    // window per model identity (gh-1742 invariant 2).
    final current = _agent.state.model;
    if (current.provider == provider && current.id == modelId) {
      _agent.state.model = Model(
        id: current.id,
        name: current.name,
        api: current.api,
        provider: current.provider,
        baseUrl: current.baseUrl,
        reasoning: current.reasoning,
        input: current.input,
        thinkingLevel: caps.thinkingLevel,
        cost: current.cost,
        contextWindow: caps.contextWindow,
        maxTokens: caps.maxTokens,
        headers: current.headers,
        compat: caps.omitMaxOutputTokens
            ? const OpenAICompletionsCompat(omitMaxOutputTokens: true)
            : null,
        authHeader: current.authHeader,
        capabilityNotes: caps.notes,
        connectTimeout: current.connectTimeout,
        streamIdleTimeout: current.streamIdleTimeout,
        timeoutScopeLabel: current.timeoutScopeLabel,
      );
      if (_pinnedCaps(provider, modelId)?.contextWindow != null) {
        contextWindowRegistry.publish(
          model: _agent.state.model,
          window: caps.contextWindow,
          source: ContextWindowSource.userPin,
        );
      }
      unawaited(config.onModelChanged?.call(_agent.state.model));
    }
    for (final note in caps.notes) {
      io.writeln(_style.dim('note: $note'));
    }
  }
}
