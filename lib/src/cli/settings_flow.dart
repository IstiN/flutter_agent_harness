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
          await _recordCustomModel(choice.modelId);
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

  /// Settings → DAP / Hub: view the live hub snapshot (url, agent name,
  /// connection state), set the hub url or the agent name (persisted
  /// through [AgentCliConfig.onDapHubConfigChanged] — the hub client's
  /// `~/.dap/config.json` read-modify-write, so channels and invites
  /// survive), test the connection, or write the `hub: false` plugin
  /// opt-out into `.fah/packages.yaml`. Loops until the pick is cancelled
  /// or `done`.
  Future<void> startDapHubFlow() async {
    await _refreshDapHubSnapshot();
    for (;;) {
      final snapshot = _dapHubSnapshot;
      final picked = await _pickOption('dap / hub', [
        ('view', 'View current config', 'url, agent name, connection state'),
        ('url', 'Set hub URL', snapshot?.url ?? 'not configured'),
        ('name', 'Set agent name', snapshot?.name ?? 'not set'),
        (
          'test',
          'Test connection',
          (snapshot?.connected ?? false)
              ? 'currently connected'
              : 'not connected',
        ),
        (
          'optout',
          'Opt out of the hub plugin',
          'writes hub: false to .fah/packages.yaml',
        ),
        ('done', 'Done', ''),
      ]);
      switch (picked) {
        case null:
        case 'done':
          return;
        case 'view':
          _printDapHubConfig();
        case 'url':
          await _editDapHubValue(isUrl: true);
        case 'name':
          await _editDapHubValue(isUrl: false);
        case 'test':
          await _refreshDapHubSnapshot();
          _printDapHubConnection();
        case 'optout':
          await _writeDapHubOptOut();
      }
    }
  }

  /// Settings → Tools: pick a tool, flip it, choose the scope to persist
  /// in (project default). Loops until cancelled or `done`.
  Future<void> startToolsFlow() => _toolsSettingsFlow();

  /// Settings → Compaction: pick the engine (classic | structured), pick
  /// the scope to persist in (session = live only), and apply. The yaml
  /// write is surgical (other sections survive byte-for-byte) and the
  /// edited file is validated with the REAL parser before it is written —
  /// the flow can never persist a file the next boot would reject.
  /// Cancelling either pick aborts silently.
  Future<void> startCompactionEngineFlow() async {
    final engine = await _pickCompactionEngine();
    if (engine == null) return;
    final scope = await _pickCompactionScope();
    if (scope == null) return;
    await _applyCompactionEngineScope(engine, scope);
  }

  /// The engine menu of [_pickCompactionEngine]: one row per engine, the
  /// effective one marked `(current)` by the picker. Pure builder.
  List<FlowOption> _compactionEngineOptions() => [
    for (final engine in const [
      CompactionEngine.classic,
      CompactionEngine.structured,
    ])
      (
        engine.value,
        engine == CompactionEngine.classic ? 'Classic' : 'Structured',
        engine == CompactionEngine.classic
            ? 'lossy prefix summary'
            : 'judge-hide + checkpoint passes',
      ),
  ];

  /// Step 1 of [startCompactionEngineFlow]: pick the engine (the current
  /// effective one preselected); null on cancel.
  Future<CompactionEngine?> _pickCompactionEngine() async {
    final picked = await _pickOption(
      'compaction engine',
      _compactionEngineOptions(),
      initialKey: _effectiveCompactionEngine().value,
    );
    return picked == null
        ? null
        : CompactionEngine.tryParse(picked, label: 'settings');
  }

  /// Step 2 of [startCompactionEngineFlow]: pick the scope the engine
  /// applies in (session = live only); null on cancel.
  Future<String?> _pickCompactionScope() =>
      _pickOption('compaction engine — scope', [
        ('session', 'Session', 'this session only (no file change)'),
        ('project', 'Project', '${_env.cwd}/.fah/config.yaml'),
        ('global', 'Global', _userConfigPath() ?? 'unavailable on this host'),
      ]);

  /// Step 3 of [startCompactionEngineFlow]: apply [engine] in [scope] —
  /// `session` flips the live override only; `project`/`global` persist
  /// the validated yaml section first and go live only when the write
  /// lands.
  Future<void> _applyCompactionEngineScope(
    CompactionEngine engine,
    String scope,
  ) async {
    if (scope == 'session') {
      config.liveCompactionEngine = engine;
      io.writeln(
        'compaction engine → ${engine.value} (this session; applies at '
        'the next compaction)',
      );
      return;
    }
    final projectScope = scope == 'project';
    if (!projectScope && _userConfigPath() == null) {
      io.writeln('compaction: no user config on this host — not saved');
      return;
    }
    if (await _writeCompactionEngineYaml(engine, projectScope: projectScope)) {
      config.liveCompactionEngine = engine;
    }
  }

  /// The confirm/write step shared by the `project` and `global` scopes:
  /// the surgical `compaction.engine` upsert, validated with the real
  /// parser before the file is written.
  Future<bool> _writeCompactionEngineYaml(
    CompactionEngine engine, {
    required bool projectScope,
  }) => _upsertConfigYaml(
    const ['compaction', 'engine'],
    engine.value,
    projectScope: projectScope,
    validate: (node) =>
        CompactionEngine.fromSection(node, label: 'settings flow'),
  );

  /// The engine the next compaction pass will use (live override wins;
  /// structured is the resolved default since #287/#295).
  CompactionEngine _effectiveCompactionEngine() =>
      config.liveCompactionEngine ??
      config.compactionEngine ??
      CompactionEngine.structured;

  /// The settings-hub row and `/settings` summary label for the engine.
  String _compactionStatusLabel() => _effectiveCompactionEngine().value;

  /// The user config path, or null on hosts without a home directory.
  String? _userConfigPath() =>
      config.homeDir == null ? null : '${config.homeDir}/.fah/config.yaml';

  /// Settings → Memory: edit the long-term memory store locations
  /// (`memory.projectPath` / `memory.userPath`). The project path belongs
  /// in the project config, the user path in the user config (the same
  /// files the boot loader reads); writes are surgical and validated with
  /// the real [MemoryConfig] parser first. Applies live — the memory
  /// controller re-reads the section before every memory operation.
  Future<void> startMemoryStoresFlow() async {
    final picked = await _pickOption('memory stores', [
      ('projectPath', 'Project memory', _memoryPathLabel(project: true)),
      ('userPath', 'User memory', _memoryPathLabel(project: false)),
    ]);
    if (picked == null) return;
    final isProject = picked == 'projectPath';
    if (!isProject && _userConfigPath() == null) {
      io.writeln('memory: no user config on this host — not saved');
      return;
    }
    final answer = await _askLine(
      "${isProject ? 'project' : 'user'} memory path (empty keeps "
      "'${_memoryPathLabel(project: isProject)}'): ",
    );
    if (answer == null) return;
    final value = answer.trim();
    if (value.isEmpty) return;
    await _upsertConfigYaml(
      ['memory', picked],
      value,
      projectScope: isProject,
      validate: MemoryConfig.fromYaml,
    );
  }

  /// The resolved (or default) store path shown in the pickers.
  String _memoryPathLabel({required bool project}) {
    final section = config.memoryConfig;
    if (project) {
      return section?.resolveProjectPath(_env.cwd) ?? '${_env.cwd}/.fah/memory';
    }
    final home = config.homeDir;
    if (home == null) return '(no home directory on this host)';
    return section?.resolveUserPath(home) ?? '$home/.fah/memory';
  }

  /// Settings → Stream rules (TTSR): list the `ttsr:` section's rules
  /// (pattern, scope, enabled?) with per-rule enable/disable and delete,
  /// plus an add-rule prompt (name, pattern, body, scope). The section is
  /// read fresh for every action (a concurrent edit survives — E3) and
  /// written back surgically into `~/.fah/config.yaml` — the boot-real
  /// home of the section (project `.fah/rules.yaml` is a separate file; a
  /// `ttsr:` block in the project config is never read for TTSR). Every
  /// write is validated with the real [TtsrConfig] parser first (AC4).
  /// When the session booted a live rule engine, the same rule diff is
  /// applied to the running manager (rules are consulted per stream — no
  /// restart); otherwise the flow says the change lands at next boot
  /// (AC3). Loops until cancelled or done.
  Future<void> startTtsrRulesFlow() async {
    final path = _userConfigPath();
    if (path == null) {
      io.writeln('ttsr: no user config on this host — not saved');
      return;
    }
    for (;;) {
      final current = await _readTtsrSection(path);
      if (current == null) return; // malformed/unreadable — reported
      final picked = await _pickOption('stream rules (ttsr) — $path', [
        for (final rule in current.rules)
          ('rule:${rule.name}', rule.name, _ttsrRuleDescription(rule)),
        ('add', 'Add a rule', 'name, pattern, body, scope'),
        ('done', 'Done', ''),
      ]);
      if (picked == null || picked == 'done') return;
      if (picked == 'add') {
        await _ttsrAddAction(path);
        continue;
      }
      await _ttsrRuleAction(path, picked.substring('rule:'.length));
    }
  }

  /// The add branch: prompt for the rule, then reload-before-write so a
  /// concurrent edit that landed while the menus sat open survives (E3).
  Future<void> _ttsrAddAction(String path) async {
    final rule = await _promptTtsrRule();
    if (rule == null) return;
    final fresh = await _readTtsrSection(path);
    if (fresh == null) return;
    await _writeTtsrSection(
      path,
      TtsrConfig(settings: fresh.settings, rules: [...fresh.rules, rule]),
      before: fresh.rules,
    );
  }

  /// The per-rule branch (toggle/delete) for the rule named [name]:
  /// pick the action, reload, and write the same diff.
  Future<void> _ttsrRuleAction(String path, String name) async {
    final current = await _readTtsrSection(path);
    final rule = _ttsrFindRule(current?.rules, name);
    if (rule == null) return;
    final action = await _pickOption('rule ${rule.name}', [
      (
        'toggle',
        rule.enabled ? 'Disable' : 'Enable',
        'persists and applies ${ttsr == null ? 'at next boot' : 'live'}',
      ),
      ('delete', 'Delete', 'remove from the section'),
      ('back', 'Back', ''),
    ]);
    if (action != 'toggle' && action != 'delete') return;
    final fresh = await _readTtsrSection(path);
    if (fresh == null) return;
    final target = _ttsrFindRule(fresh.rules, name);
    if (target == null) {
      io.writeln('ttsr: rule "$name" is gone from $path — not saved');
      return;
    }
    if (action == 'toggle') {
      await _ttsrToggleRule(path, fresh, target);
    } else {
      await _ttsrDeleteRule(path, fresh, name);
    }
  }

  /// Persists the rule with its `enabled` flag flipped.
  Future<void> _ttsrToggleRule(
    String path,
    TtsrConfig fresh,
    TtsrRule target,
  ) async {
    final flipped = TtsrRule(
      name: target.name,
      patterns: target.patterns,
      body: target.body,
      path: target.path,
      enabled: !target.enabled,
      scope: target.scope,
    );
    final flippedName = flipped.name;
    await _writeTtsrSection(
      path,
      TtsrConfig(
        settings: fresh.settings,
        rules: [
          for (final existing in fresh.rules)
            existing.name == flippedName ? flipped : existing,
        ],
      ),
      before: fresh.rules,
    );
  }

  /// Persists the removal of the rule named [name].
  Future<void> _ttsrDeleteRule(
    String path,
    TtsrConfig fresh,
    String name,
  ) async {
    await _writeTtsrSection(
      path,
      TtsrConfig(
        settings: fresh.settings,
        rules: [
          for (final existing in fresh.rules)
            if (existing.name != name) existing,
        ],
      ),
      before: fresh.rules,
    );
  }

  /// The rule named [name] in [rules] (last wins, matching registration
  /// dedupe); null when the list is null or the rule is gone.
  TtsrRule? _ttsrFindRule(List<TtsrRule>? rules, String name) {
    if (rules == null) return null;
    TtsrRule? found;
    for (final candidate in rules) {
      if (candidate.name == name) found = candidate;
    }
    return found;
  }

  /// Reads and parses the `ttsr:` section of [path]. An absent section
  /// (or file) parses as defaults (E1); a malformed one reports the
  /// parser's verbatim message and returns null — the flow never edits
  /// from a half-parsed section and never writes over one (AC4).
  Future<TtsrConfig?> _readTtsrSection(String path) async {
    final String source;
    switch (await _env.readTextFile(path)) {
      case Ok(:final value):
        source = value;
      case Err(:final error) when error.code == FileErrorCode.notFound:
        return const TtsrConfig();
      case Err(:final error):
        io.writeln('ttsr: cannot read $path: $error — not saved');
        return null;
    }
    if (source.trim().isEmpty) return const TtsrConfig();
    try {
      final doc = loadYaml(source);
      final node = doc is YamlMap ? doc['ttsr'] : null;
      return node == null
          ? const TtsrConfig()
          : TtsrConfig.fromYaml(node, sourcePath: path);
    } on Object catch (error) {
      io.writeln('ttsr: not saved: $error');
      return null;
    }
  }

  /// The add-rule prompts: name, regex pattern, body, and the scope guard
  /// (empty answer = the default text+tool scope). Cancelling any prompt
  /// aborts the add.
  Future<TtsrRule?> _promptTtsrRule() async {
    final name = (await _askLine('rule name: '))?.trim() ?? '';
    if (name.isEmpty) return null;
    final pattern = (await _askLine('pattern (regex): '))?.trim() ?? '';
    if (pattern.isEmpty) return null;
    final body = (await _askLine('body: '))?.trim() ?? '';
    if (body.isEmpty) return null;
    final scopeAnswer =
        (await _askLine('scope (empty = text + tool): '))?.trim() ?? '';
    final warnings = <String>[];
    final scope = TtsrScope.parse(
      scopeAnswer.isEmpty ? null : scopeAnswer.split(','),
      ruleName: name,
      warnings: warnings,
    );
    for (final warning in warnings) {
      io.writeln('[ttsr] $warning');
    }
    return TtsrRule(name: name, patterns: [pattern], body: body, scope: scope);
  }

  /// The surgical `ttsr:` write shared by every action: block replace in
  /// [path] (absent block appends), validated with the real parser BEFORE
  /// the write, then the same diff applied to the live rule engine when
  /// one is running. Returns true when written.
  Future<bool> _writeTtsrSection(
    String path,
    TtsrConfig next, {
    required List<TtsrRule> before,
  }) async {
    // Implied provenance (rule.path == this file) stays implicit so a
    // pure toggle doesn't grow the block with `path:` lines.
    final section = TtsrConfig(
      settings: next.settings,
      rules: [
        for (final rule in next.rules)
          rule.path == path ? _withoutImpliedTtsrPath(rule) : rule,
      ],
    );
    final String source;
    switch (await _env.readTextFile(path)) {
      case Ok(:final value):
        source = value;
      case Err(:final error) when error.code == FileErrorCode.notFound:
        source = '';
      case Err(:final error):
        io.writeln('ttsr: cannot read $path: $error — not saved');
        return false;
    }
    final edited = _replaceTopLevelYamlBlock(source, 'ttsr', section.toYaml());
    // Never persist a file the next boot would reject.
    final doc = loadYaml(edited);
    final node = doc is YamlMap ? doc['ttsr'] : null;
    try {
      TtsrConfig.fromYaml(node, sourcePath: path);
    } on Object catch (error) {
      io.writeln('ttsr: not saved: $error');
      return false;
    }
    if (await _env.writeFile(path, edited) is Err) {
      io.writeln('ttsr: could not write $path');
      return false;
    }
    final live = _syncLiveTtsrRules(before, section);
    io.writeln(
      'ttsr saved → $path '
      '${live ? '(rule edits apply live — rules are consulted per stream)' : '(applies at next boot — no live rule engine this session)'}',
    );
    return true;
  }

  /// [rule] with the file-implied provenance dropped (the section already
  /// names the file; boot re-derives it).
  TtsrRule _withoutImpliedTtsrPath(TtsrRule rule) => TtsrRule(
    name: rule.name,
    patterns: rule.patterns,
    body: rule.body,
    enabled: rule.enabled,
    scope: rule.scope,
  );

  /// Applies the section rule diff to the live rule engine ([ttsr]):
  /// every rule that was added, removed, or changed re-registers by name
  /// (the registry is name-keyed, first wins — a same-named rule from
  /// `.fah/rules.yaml` is replaced by the variant the user just edited).
  /// Returns false when no engine runs this session (the change then
  /// lands at next boot).
  bool _syncLiveTtsrRules(List<TtsrRule> before, TtsrConfig after) {
    final controller = ttsr;
    if (controller == null) return false;
    final manager = controller.manager;
    final beforeByName = {for (final rule in before) rule.name: rule};
    final afterByName = {for (final rule in after.rules) rule.name: rule};
    final touched = <String>{
      for (final entry in beforeByName.entries)
        if (_ttsrRuleChanged(entry.value, afterByName[entry.key])) entry.key,
      for (final name in afterByName.keys)
        if (!beforeByName.containsKey(name)) name,
    };
    for (final name in touched) {
      manager.removeRule(name);
    }
    for (final rule in after.rules) {
      if (!rule.enabled || !touched.contains(rule.name)) continue;
      final warningsBefore = manager.warnings.length;
      final added = manager.addRule(rule);
      for (final warning in manager.warnings.sublist(warningsBefore)) {
        io.writeln('[ttsr] $warning');
      }
      if (!added && manager.warnings.length == warningsBefore) {
        io.writeln(
          'ttsr: rule "${rule.name}" is not active this session '
          '(duplicate name?) — applies at next boot',
        );
      }
    }
    return true;
  }

  /// Whether [next] differs from [rule] in any field the manager
  /// compiles (a null [next] means the rule is gone).
  bool _ttsrRuleChanged(TtsrRule rule, TtsrRule? next) =>
      next == null ||
      next.enabled != rule.enabled ||
      next.body != rule.body ||
      next.patterns.join(' ') != rule.patterns.join(' ') ||
      !_sameTtsrScope(next.scope, rule.scope);

  bool _sameTtsrScope(TtsrScope a, TtsrScope b) =>
      a.allowText == b.allowText &&
      a.allowThinking == b.allowThinking &&
      a.allowAnyTool == b.allowAnyTool &&
      a.toolNames.join(' ') == b.toolNames.join(' ');

  /// The rule-row description: enabled state, the pattern(s), the scope.
  String _ttsrRuleDescription(TtsrRule rule) {
    final pattern = rule.patterns.first;
    final more = rule.patterns.length > 1
        ? ' (+${rule.patterns.length - 1})'
        : '';
    return '${rule.enabled ? '' : 'off · '}$pattern$more · '
        'scope: ${_ttsrScopeLabel(rule.scope)}';
  }

  /// The comma-separated stream list a scope watches (the default scope
  /// renders as `text, tool`).
  String _ttsrScopeLabel(TtsrScope scope) {
    if (scope.allowText &&
        !scope.allowThinking &&
        scope.allowAnyTool &&
        scope.toolNames.isEmpty) {
      return 'text, tool';
    }
    return [
      if (scope.allowText) 'text',
      if (scope.allowThinking) 'thinking',
      if (scope.allowAnyTool) 'tool',
      for (final name in scope.toolNames) 'tool:$name',
    ].join(', ');
  }

  /// The settings-hub row and `/settings` summary label for TTSR: the
  /// live rule count when the engine runs this session, otherwise an
  /// honest inactive/not-configured state.
  String _ttsrStatusLabel() {
    final controller = ttsr;
    if (controller != null) {
      final count = controller.manager.rules.length;
      return '$count rule${count == 1 ? '' : 's'} · live';
    }
    final section = config.ttsr;
    if (section == null) return 'not configured';
    if (!section.settings.enabled) return 'disabled';
    return 'inactive this session';
  }

  /// The settings-hub row and `/settings` summary label for MCP: the
  /// live per-server connection counts when a manager runs this session,
  /// otherwise an honest inactive/not-configured state.
  String _mcpStatusLabel() {
    final manager = _mcp.manager;
    final section = manager?.config ?? config.mcpConfig?.config;
    if (section == null || section.servers.isEmpty) {
      return manager == null ? 'not configured' : '0 servers · live';
    }
    var connected = 0;
    for (final state in manager?.states.values ?? const <McpServerState>[]) {
      if (state.status == McpServerStatus.connected) connected++;
    }
    final total = section.servers.length;
    final stateWord = manager == null ? 'inactive this session' : 'live';
    if (manager == null) return '$total server${_s(total)} · $stateWord';
    return '$total server${_s(total)} · $connected connected · live';
  }

  /// The plural suffix for [n] (empty for 1).
  String _s(int n) => n == 1 ? '' : 's';

  /// Settings → MCP servers (issue #396): manage the `mcp:` section live
  /// — per-server status (connecting/connected/failed) with view-tools /
  /// reconnect / edit / remove (confirm), plus an add wizard (stdio
  /// command/args/env or remote url/transport/headers). Every action
  /// re-reads the section (a concurrent edit survives — E3) and is
  /// validated with the real [McpConfig] parser BEFORE the surgical write
  /// into `~/.fah/config.yaml` (AC2/AC4). With a live manager the same
  /// section diff applies through [McpManager.applyConfig] — only the
  /// touched servers reconnect; without one the note defers to the next
  /// boot (AC3). Loops until cancelled or done.
  Future<void> startMcpServersFlow() async {
    final path = _userConfigPath();
    if (path == null) {
      io.writeln('mcp: no user config on this host — not saved');
      return;
    }
    for (;;) {
      if (!await _mcpMenuRound(path)) return;
    }
  }

  /// One main-menu round. Returns false when the flow must end: the
  /// section is malformed/unreadable (reported), the user cancelled, or
  /// picked Done.
  Future<bool> _mcpMenuRound(String path) async {
    final current = await _readMcpSection(path);
    if (current == null) return false;
    final picked = await _pickOption('mcp servers — $path', [
      for (final server in current.servers.values)
        ('server:${server.name}', server.name, _mcpServerDescription(server)),
      ('add', 'Add a server', 'stdio (command) or remote (url)'),
      ('done', 'Done', ''),
    ]);
    if (picked == null || picked == 'done') return false;
    if (picked == 'add') {
      await _mcpAddAction(path);
      return true;
    }
    await _mcpServerAction(path, picked.substring('server:'.length));
    return true;
  }

  /// The per-server menu row: transport + endpoint detail, then the live
  /// status (connecting/connected/failed) when a manager runs this
  /// session, or the honest inactive marker when it does not.
  String _mcpServerDescription(McpServerConfig server) {
    final manager = _mcp.manager;
    final detail = switch (server) {
      McpStdioServerConfig(:final command, :final args) =>
        'stdio · $command${args.isEmpty ? '' : ' ${args.join(' ')}'}',
      McpHttpServerConfig(:final url) => 'remote · $url',
    };
    final state = manager?.states[server.name];
    if (manager == null) return '$detail · inactive this session';
    return switch (state?.status) {
      McpServerStatus.connected =>
        '$detail · connected · ${state!.tools.length} tool(s)',
      McpServerStatus.failed =>
        '$detail · failed: ${state!.error ?? 'unknown'}',
      McpServerStatus.connecting || null => '$detail · connecting…',
    };
  }

  /// The per-server branch: view tools / reconnect / edit / delete. The
  /// live-manager-only actions are offered only when one runs.
  Future<void> _mcpServerAction(String path, String name) async {
    for (;;) {
      final current = await _readMcpSection(path);
      final server = current?.servers[name];
      final manager = _mcp.manager;
      final state = manager?.states[name];
      if (server == null) return;
      final action = await _pickOption(
        'mcp server $name',
        _mcpServerMenuOptions(name, server, manager, state),
      );
      if (!await _mcpHandleServerAction(path, name, action, server, state)) {
        return;
      }
    }
  }

  /// The submenu rows: tools/reconnect appear only with a live manager
  List<(String, String, String)> _mcpServerMenuOptions(
    String name,
    McpServerConfig server,
    McpManager? manager,
    McpServerState? state,
  ) => [
    if (state != null && state.status == McpServerStatus.connected)
      (
        'tools',
        'View tools',
        '${state.tools.length} advertised as mcp__${name}__*',
      ),
    if (manager != null)
      ('reconnect', 'Reconnect', 'stop and reconnect just this server'),
    (
      'edit',
      'Edit',
      '${server is McpStdioServerConfig ? 'stdio' : 'remote'} fields',
    ),
    ('delete', 'Delete', 'remove from the section (confirm)'),
    ('back', 'Back', ''),
  ];

  /// Dispatches one submenu action. Returns false when the submenu must
  /// end (edit/delete consumed it, or back/cancelled).
  Future<bool> _mcpHandleServerAction(
    String path,
    String name,
    String? action,
    McpServerConfig server,
    McpServerState? state,
  ) async {
    switch (action) {
      case 'tools':
        _printMcpServerTools(name, state!.tools);
        return true;
      case 'reconnect':
        await _mcpReconnectAction(name);
        return true;
      default:
        await _mcpLeaveAction(path, name, action, server);
        return false;
    }
  }

  /// The submenu-leaving actions: edit and delete write the section;
  /// back/cancelled falls through with nothing written.
  Future<void> _mcpLeaveAction(
    String path,
    String name,
    String? action,
    McpServerConfig server,
  ) async {
    switch (action) {
      case 'edit':
        await _mcpEditAction(path, server);
      case 'delete':
        await _mcpDeleteAction(path, name);
      default:
        break; // back / cancelled
    }
  }

  /// Reconnect stops just this server's loop and starts a fresh one;
  /// the other servers keep their connections.
  Future<void> _mcpReconnectAction(String name) async {
    await _mcp.manager!.restartServer(name);
    io.writeln('mcp: "$name" reconnecting');
  }

  /// The connected server's advertised tools (read-only view).
  void _printMcpServerTools(String name, List<McpToolInfo> tools) {
    if (tools.isEmpty) {
      io.writeln('mcp: "$name" advertises no tools');
      return;
    }
    io.writeln('mcp: "$name" advertises ${tools.length} tool(s):');
    for (final tool in tools) {
      final description = tool.description;
      io.writeln(
        '  mcp__${name}__${tool.name}'
        '${description == null ? '' : ' — $description'}',
      );
    }
  }

  /// The add branch: kind → name → fields, then reload-before-write (E3)
  /// so a server added meanwhile is not clobbered.
  Future<void> _mcpAddAction(String path) async {
    final server = await _mcpPromptNewServer();
    if (server == null) return;
    await _mcpWriteFresh(
      path,
      server.name,
      expectPresent: false,
      write: (fresh) async {
        await _writeMcpSection(
          path,
          McpConfig(
            servers: {...fresh.servers, server.name: server},
            toolCallTimeout: fresh.toolCallTimeout,
          ),
          before: fresh,
        );
      },
    );
  }

  /// The add wizard: kind → name → fields. Returns null on cancel, an
  /// empty name, or a body the user aborted (reported).
  Future<McpServerConfig?> _mcpPromptNewServer() async {
    final kind = await _pickOption('add server — kind', [
      ('stdio', 'stdio', 'spawns a local command (process-capable hosts)'),
      ('remote', 'remote', 'HTTP endpoint (streamable-http or sse)'),
    ]);
    if (kind == null) return null;
    final name = (await _askLine('server name: '))?.trim() ?? '';
    if (name.isEmpty) return null;
    return _promptMcpServerBody(
      name,
      kind == 'stdio'
          ? const McpStdioServerConfig(name: '', command: '')
          : const McpHttpServerConfig(name: '', url: ''),
    );
  }

  /// The shared reload-before-write tail (E3): re-reads the section
  /// fresh, refuses when [name]'s presence does not match
  /// [expectPresent] (a concurrent edit — reported, nothing written),
  /// and otherwise hands the fresh section to [write].
  Future<void> _mcpWriteFresh(
    String path,
    String name, {
    required bool expectPresent,
    required Future<void> Function(McpConfig fresh) write,
  }) async {
    final fresh = await _readMcpSection(path);
    if (fresh == null) return;
    if (fresh.servers.containsKey(name) != expectPresent) {
      io.writeln(
        expectPresent
            ? 'mcp: server "$name" is gone from $path — not saved'
            : 'mcp: server "$name" already exists — not saved',
      );
      return;
    }
    await write(fresh);
  }

  /// The edit branch: prompt the fields with the current values as the
  /// keep-on-empty defaults (the name and stdio/remote kind stay fixed —
  /// a rename or a kind switch is delete + add), then reload-before-write
  /// (E3).
  Future<void> _mcpEditAction(String path, McpServerConfig server) async {
    final next = await _promptMcpServerBody(server.name, server);
    if (next == null) return;
    await _mcpWriteFresh(
      path,
      server.name,
      expectPresent: true,
      write: (fresh) async {
        await _writeMcpSection(
          path,
          McpConfig(
            servers: {...fresh.servers, server.name: next},
            toolCallTimeout: fresh.toolCallTimeout,
          ),
          before: fresh,
        );
      },
    );
  }

  /// The delete branch: confirm, then reload-before-write (E3). Deleting
  /// the last server leaves a valid empty `servers: {}` section.
  Future<void> _mcpDeleteAction(String path, String name) async {
    final sure = (await _askLine("remove server '$name'? (y/N): "))?.trim();
    if (sure?.toLowerCase() != 'y') return;
    await _mcpWriteFresh(
      path,
      name,
      expectPresent: true,
      write: (fresh) async {
        await _writeMcpSection(
          path,
          McpConfig(
            servers: {
              for (final entry in fresh.servers.entries)
                if (entry.key != name) entry.key: entry.value,
            },
            toolCallTimeout: fresh.toolCallTimeout,
          ),
          before: fresh,
        );
      },
    );
  }

  /// Prompts the fields of one server. [current] seeds the keep-on-empty
  /// defaults (edit) or empty seeds (add); [name] is fixed beforehand.
  /// Returns null when the user cancels or an entry is malformed
  /// (reported — nothing is written).
  Future<McpServerConfig?> _promptMcpServerBody(
    String name,
    McpServerConfig current,
  ) async {
    switch (current) {
      case McpStdioServerConfig():
        return _promptMcpStdioBody(name, current);
      case McpHttpServerConfig():
        return _promptMcpHttpBody(name, current);
    }
  }

  /// The stdio fields: command (required), args (optional list), env
  /// (KEY=VALUE pairs).
  Future<McpStdioServerConfig?> _promptMcpStdioBody(
    String name,
    McpStdioServerConfig current,
  ) async {
    final command = await _askMcpRequired('command', current.command);
    if (command == null) return null;
    final argsAnswer = await _askMcpOptional(
      'args (comma-separated)',
      current.args.join(', '),
    );
    final env = await _askMcpPairs('env', current.env);
    if (env == null) return null;
    return McpStdioServerConfig(
      name: name,
      command: command,
      args: _splitMcpList(argsAnswer),
      env: env,
    );
  }

  /// The remote fields: url (required), transport (validated with the
  /// real parser BEFORE further prompts — a mistake never reaches the
  /// write), headers (KEY=VALUE pairs).
  Future<McpHttpServerConfig?> _promptMcpHttpBody(
    String name,
    McpHttpServerConfig current,
  ) async {
    final url = await _askMcpRequired('url', current.url);
    if (url == null) return null;
    final transportAnswer =
        (await _askLine(
          "transport (streamable-http or sse, empty keeps "
          "'${current.transport.label}'): ",
        ))?.trim() ??
        '';
    final transport = _mcpTransportOrNull(transportAnswer, current, name);
    if (transport == null) return null;
    final headers = await _askMcpPairs('headers', current.headers);
    if (headers == null) return null;
    return McpHttpServerConfig(
      name: name,
      url: url,
      transport: transport,
      headers: headers,
    );
  }

  /// Parses the transport answer with the real parser; null (reported)
  /// on an unknown kind, [current]'s kind on empty (keep).
  McpHttpTransportKind? _mcpTransportOrNull(
    String answer,
    McpHttpServerConfig current,
    String name,
  ) {
    if (answer.isEmpty) return McpHttpTransportKind.streamableHttp;
    try {
      return McpHttpTransportKind.parse(answer, server: name);
    } on ConfigException catch (error) {
      io.writeln('mcp: not saved: ${error.message}');
      return null;
    }
  }

  /// One prompted line for a REQUIRED field: on edit (non-empty [seed])
  /// an empty answer keeps the seed; on add an empty answer cancels.
  Future<String?> _askMcpRequired(String label, String seed) async {
    final answer = seed.isEmpty
        ? await _askLine('$label: ')
        : await _askLine("$label (empty keeps '$seed'): ");
    final trimmed = answer?.trim() ?? '';
    if (trimmed.isEmpty) return seed.isEmpty ? null : seed;
    return trimmed;
  }

  /// One prompted line for an OPTIONAL list field: empty keeps [seed]
  /// (usually empty = none). Never cancels.
  Future<String> _askMcpOptional(String label, String seed) async =>
      (seed.isEmpty
          ? await _askLine('$label (empty = none): ')
          : await _askLine("$label (empty keeps '$seed'): ")) ??
      '';

  /// The comma-separated pieces of [answer] (trimmed, empties dropped).
  List<String> _splitMcpList(String answer) => [
    for (final piece in answer.split(','))
      if (piece.trim().isNotEmpty) piece.trim(),
  ];

  /// KEY=VALUE pairs (comma-separated) for env/headers. An empty answer
  /// keeps [seed]; `-` clears; a malformed entry reports and cancels the
  /// action with nothing written. ponytail: values with literal commas
  /// need the file — upgrade to a per-value prompt flow if that bites.
  Future<Map<String, String>?> _askMcpPairs(
    String label,
    Map<String, String> seed,
  ) async {
    final rendered = [
      for (final entry in seed.entries) '${entry.key}=${entry.value}',
    ].join(', ');
    final answer = rendered.isEmpty
        ? await _askLine('$label (KEY=VALUE comma-separated, empty = none): ')
        : await _askLine("$label (empty keeps '$rendered', '-' clears): ");
    final trimmed = answer?.trim() ?? '';
    if (trimmed.isEmpty) return seed;
    if (trimmed == '-') return const {};
    final pairs = <String, String>{};
    for (final piece in trimmed.split(',')) {
      final entry = piece.trim();
      if (entry.isEmpty) continue;
      final eq = entry.indexOf('=');
      if (eq <= 0) {
        io.writeln('mcp: $label entries must be KEY=VALUE — not saved');
        return null;
      }
      pairs[entry.substring(0, eq)] = entry.substring(eq + 1);
    }
    _warnInlineMcpSecrets(label, pairs.keys);
    return pairs;
  }

  /// Points credential-looking keys at the existing key flow (the secure
  /// store behind `/key`, env-first `FA_KEY_*` resolution) instead of an
  /// inline yaml value.
  void _warnInlineMcpSecrets(String label, Iterable<String> keys) {
    final pattern = RegExp(
      r'token|secret|password|key|auth',
      caseSensitive: false,
    );
    final flagged = [
      for (final key in keys)
        if (pattern.hasMatch(key)) key,
    ];
    if (flagged.isEmpty) return;
    io.writeln(
      'mcp: $label ${flagged.join(', ')} looks like a credential — prefer '
      'the host environment (an exported FA_KEY_* variable) over inline '
      'yaml',
    );
  }

  /// Reads and parses the `mcp:` section of [path]. An absent section (or
  /// file) parses as an empty server map (E1); a malformed one reports
  /// the parser's verbatim message and returns null — the flow never
  /// edits from a half-parsed section and never writes over one (AC4).
  Future<McpConfig?> _readMcpSection(String path) async {
    final String source;
    switch (await _env.readTextFile(path)) {
      case Ok(:final value):
        source = value;
      case Err(:final error) when error.code == FileErrorCode.notFound:
        return McpConfig(servers: {});
      case Err(:final error):
        io.writeln('mcp: cannot read $path: $error — not saved');
        return null;
    }
    if (source.trim().isEmpty) return McpConfig(servers: {});
    try {
      final doc = loadYaml(source);
      final node = doc is YamlMap ? doc['mcp'] : null;
      return node == null ? McpConfig(servers: {}) : McpConfig.fromYaml(node);
    } on Object catch (error) {
      io.writeln('mcp: not saved: $error');
      return null;
    }
  }

  /// The surgical `mcp:` write shared by every action: block replace in
  /// [path] (absent block appends), validated with the real parser BEFORE
  /// the write (AC4), then the same section diff applied to the live
  /// manager — only touched servers reconnect (AC3). Returns true when
  /// written.
  Future<bool> _writeMcpSection(
    String path,
    McpConfig next, {
    required McpConfig before,
  }) async {
    final String source;
    switch (await _env.readTextFile(path)) {
      case Ok(:final value):
        source = value;
      case Err(:final error) when error.code == FileErrorCode.notFound:
        source = '';
      case Err(:final error):
        io.writeln('mcp: cannot read $path: $error — not saved');
        return false;
    }
    final edited = _replaceTopLevelYamlBlock(source, 'mcp', next.toYaml());
    // Never persist a file the next boot would reject.
    final doc = loadYaml(edited);
    final node = doc is YamlMap ? doc['mcp'] : null;
    try {
      McpConfig.fromYaml(node);
    } on Object catch (error) {
      io.writeln('mcp: not saved: $error');
      return false;
    }
    if (await _env.writeFile(path, edited) is Err) {
      io.writeln('mcp: could not write $path');
      return false;
    }
    final manager = _mcp.manager;
    if (manager == null) {
      io.writeln(
        'mcp saved → $path (applies at next boot — no live MCP manager '
        'this session)',
      );
      return true;
    }
    await manager.applyConfig(next);
    io.writeln('mcp saved → $path ${_mcpApplyNote(before, next)}');
    return true;
  }

  /// The honest liveness detail (AC3): which servers the section change
  /// touches on the live manager — connecting/reconnecting/stopped — or
  /// nothing when the section is value-identical.
  String _mcpApplyNote(McpConfig before, McpConfig next) {
    final notes = <String>[];
    for (final entry in next.servers.entries) {
      final old = before.servers[entry.key];
      if (old == null) {
        notes.add('${entry.key} connecting');
      } else if (entry.value != old) {
        notes.add('${entry.key} reconnecting');
      }
    }
    for (final name in before.servers.keys) {
      if (!next.servers.containsKey(name)) notes.add('$name stopped');
    }
    return notes.isEmpty
        ? '(applies live)'
        : '(applies live — ${notes.join(', ')})';
  }

  /// The settings-hub row and `/settings` summary label for redaction
  /// (issue #391): the live pipeline state, or plain `off` when the boot
  /// config disabled redaction (no pipeline exists).
  String _redactionStatusLabel() {
    final pipeline = config.redactionPipeline;
    if (pipeline == null) return 'off';
    final cfg = pipeline.config;
    return '${cfg.enabled ? 'on' : 'off'}, '
        'block ${cfg.blockMode ? 'on' : 'off'}, '
        '${pipeline.stats.total} match(es) this session';
  }

  /// The pipeline's effective config, or the parser defaults when no
  /// pipeline is running.
  RedactionConfig get _redactionConfig =>
      config.redactionPipeline?.config ?? const RedactionConfig();

  /// Settings → Redaction: the `redact:` yaml section as an interactive
  /// flow (issue #391) — quick toggles, the entropy knobs, the allowlist
  /// and per-tool policy lists, per-layer toggles and a stats reset.
  /// Writes go through the surgical validated-yaml upsert into the USER
  /// config (the machine-level file `fa config set redact…` also uses);
  /// with a live pipeline the saved section is reloaded from disk and
  /// installed on the spot, without one the note honestly defers to the
  /// next boot. Loops until the pick is cancelled or `done`.
  Future<void> startRedactionFlow() async {
    for (;;) {
      final picked = await _pickOption('redaction', _redactionMenuOptions());
      if (picked == null || picked == 'done') return;
      await _applyRedactionPick(picked);
    }
  }

  /// Dispatches one [startRedactionFlow] menu pick; the caller re-renders
  /// the menu afterwards. Split out to keep each function's complexity
  /// under the repo's CRAP gate.
  Future<void> _applyRedactionPick(String picked) async {
    switch (picked) {
      case 'enabled':
        await _writeRedactionKey(const [
          'redact',
          'enabled',
        ], '${!_redactionConfig.enabled}');
      case 'blockMode':
        await _writeRedactionKey(const [
          'redact',
          'blockMode',
        ], '${!_redactionConfig.blockMode}');
      case 'minEntropy':
        await _askRedactionScalar(const [
          'redact',
          'minEntropy',
        ], 'min entropy in bits/char');
      case 'minLength':
        await _askRedactionScalar(const [
          'redact',
          'minLength',
        ], 'min token length');
      case 'allowlist':
        await _askRedactionList(const [
          'redact',
          'allowlist',
        ], 'allowlist regex(es)');
      case 'toolAllow':
        await _askRedactionList(const [
          'redact',
          'toolAllow',
        ], 'tool allow (only these)');
      case 'toolDeny':
        await _askRedactionList(const [
          'redact',
          'toolDeny',
        ], 'tool deny (never redacted)');
      case 'layers':
        await _redactionLayersFlow();
      case 'reset':
        _resetRedactionStats();
    }
  }

  /// The main menu of [startRedactionFlow]: one row per editable field of
  /// the section plus the quick actions. Pure builder.
  List<FlowOption> _redactionMenuOptions() {
    final cfg = _redactionConfig;
    final layers = RedactionLayer.values;
    return [
      ('enabled', 'Toggle redaction', cfg.enabled ? 'on → off' : 'off → on'),
      (
        'blockMode',
        'Toggle block mode',
        cfg.blockMode ? 'on → off' : 'off → on',
      ),
      ('minEntropy', 'Entropy threshold', '${cfg.minEntropy} bits/char'),
      ('minLength', 'Entropy min length', '${cfg.minLength} chars'),
      (
        'allowlist',
        'Allowlist regexes',
        '${cfg.allowlistRegexes.length} pattern(s)',
      ),
      (
        'toolAllow',
        'Tool allow list',
        cfg.toolAllow.isEmpty ? '(all tools)' : cfg.toolAllow.join(', '),
      ),
      (
        'toolDeny',
        'Tool deny list',
        cfg.toolDeny.isEmpty ? '(none)' : cfg.toolDeny.join(', '),
      ),
      (
        'layers',
        'Layer toggles',
        '${layers.where(cfg.isLayerEnabled).length}/${layers.length} on',
      ),
      (
        'reset',
        'Reset stats',
        '${config.redactionPipeline?.stats.total ?? 0} match(es)',
      ),
      ('done', 'Done', ''),
    ];
  }

  /// The shared write path: a USER-file upsert of [segments] → [value]
  /// with the whole `redact:` section validated by the real parser first
  /// (AC4: the parser's verbatim error, nothing written), then the
  /// reload-after-write that installs the saved section on the live
  /// pipeline (AC3/E3).
  Future<void> _writeRedactionKey(List<String> segments, String value) async {
    if (_userConfigPath() == null) {
      io.writeln('redaction: no user config on this host — not saved');
      return;
    }
    final wrote = await _upsertConfigYaml(
      segments,
      value,
      projectScope: false,
      validate: validateRedactSection,
      note: _redactionNote(),
    );
    if (wrote) await _reloadRedactionPipeline();
  }

  /// The honest liveness note (AC3): the flow installs the saved section
  /// into the running pipeline whenever one exists; only the pipeline-less
  /// boot (`redact.enabled: false`) must wait for the next start.
  String _redactionNote() => config.redactionPipeline == null
      ? applicationNote('redact')
      : 'applies live — the running pipeline reloads the saved section';

  /// Reload-after-write (E3): what's live is what's on disk — the saved
  /// file is re-parsed and installed on the pipeline, so a concurrent
  /// editor's values survive and the menu re-renders the fresh state.
  Future<void> _reloadRedactionPipeline() async {
    final pipeline = config.redactionPipeline;
    final path = _userConfigPath();
    if (pipeline == null || path == null) return;
    switch (await _env.readTextFile(path)) {
      case Ok(:final value):
        final doc = loadYaml(value);
        pipeline.config = RedactionConfig.fromYaml(
          doc is YamlMap ? doc['redact'] as Map<dynamic, dynamic>? : null,
        );
      case Err():
        // The write just succeeded; a read race keeps the current live
        // config — the next write re-syncs.
        break;
    }
  }

  /// The scalar-field branch (entropy knobs): an empty answer keeps the
  /// current value; a non-number is refused before any write (the boot
  /// parser would silently fall back to the default, breaking the
  /// round-trip AC).
  Future<void> _askRedactionScalar(List<String> segments, String label) async {
    final current = segments.last == 'minEntropy'
        ? _redactionConfig.minEntropy
        : _redactionConfig.minLength;
    final answer = await _askLine("$label (empty keeps '$current'): ");
    if (answer == null) return;
    final value = answer.trim();
    if (value.isEmpty) return;
    final parsed = segments.last == 'minLength'
        ? int.tryParse(value)
        : double.tryParse(value);
    if (parsed == null) {
      io.writeln('not saved: ${segments.last} must be a number (got "$value")');
      return;
    }
    await _writeRedactionKey(segments, value);
  }

  /// The list-field branch (allowlist, toolAllow, toolDeny): a
  /// comma-separated answer renders as a yaml block list, `-` clears, an
  /// empty answer keeps the current value.
  Future<void> _askRedactionList(List<String> segments, String label) async {
    final current = switch (segments.last) {
      'allowlist' => _redactionConfig.allowlistRegexes.length,
      'toolAllow' => _redactionConfig.toolAllow.length,
      _ => _redactionConfig.toolDeny.length,
    };
    final answer = await _askLine(
      "$label, comma-separated ('-' clears; empty keeps the current "
      "$current): ",
    );
    if (answer == null) return;
    final value = answer.trim();
    if (value.isEmpty) return;
    final entries = value == '-'
        ? const <String>[]
        : [
            for (final entry in value.split(','))
              if (entry.trim().isNotEmpty) entry.trim(),
          ];
    await _writeRedactionKey(segments, jsonEncode(entries));
  }

  /// The per-layer toggle submenu: one row per [RedactionLayer], each
  /// flip persisted as `redact.layers.<name>`. Loops until cancelled or
  /// `done`.
  Future<void> _redactionLayersFlow() async {
    for (;;) {
      final cfg = _redactionConfig;
      final picked = await _pickOption('redaction layers', [
        for (final layer in RedactionLayer.values)
          (layer.name, layer.name, cfg.isLayerEnabled(layer) ? 'on' : 'off'),
        ('done', 'Done', ''),
      ]);
      if (picked == null || picked == 'done') return;
      await _writeRedactionKey([
        'redact',
        'layers',
        picked,
      ], '${!cfg.isLayerEnabled(RedactionLayer.values.byName(picked))}');
    }
  }

  /// The stats-reset action: zeroes the pipeline counters (the same
  /// counters `/redact stats` prints).
  void _resetRedactionStats() {
    final pipeline = config.redactionPipeline;
    if (pipeline == null) {
      io.writeln('redaction: pipeline not running on this host');
      return;
    }
    pipeline.stats.reset();
    io.writeln('redaction stats reset');
  }

  /// The settings-hub row and `/settings` summary label for the image
  /// registry (issue #395): the kill-switch state (what `registry: false`
  /// means — byte-identical legacy requests) and the per-request cap.
  String _imagesStatusLabel() {
    final cfg = imageRegistryConfig;
    return '${cfg.enabled ? 'on' : 'off · legacy request shape'} · '
        'cap ${cfg.maxPerRequest}';
  }

  /// Settings → Images: the `images:` config section (issue #395) — the
  /// registry kill switch (`images.registry: false` reproduces today's
  /// request shape byte-for-byte) and the per-request unique-image cap.
  /// Writes go through the surgical validated-yaml upsert into the USER
  /// config (the file `bin/fah.dart` boots the registry from), and every
  /// successful write re-publishes the process-wide [imageRegistryConfig]
  /// from the saved file — the request build consults that global, so the
  /// change lands on the next request build without a restart (AC3/E3:
  /// what's live is what's on disk). Loops until cancelled or `done`.
  Future<void> startImagesFlow() async {
    for (;;) {
      final picked = await _pickOption('images', _imagesMenuOptions());
      if (picked == null || picked == 'done') return;
      await _applyImagesPick(picked);
    }
  }

  /// Dispatches one [startImagesFlow] menu pick; the caller re-renders
  /// the menu afterwards. Split out to keep each function's complexity
  /// under the repo's CRAP gate.
  Future<void> _applyImagesPick(String picked) async {
    switch (picked) {
      case 'registry':
        await _writeImagesKey(const [
          'images',
          'registry',
        ], '${!imageRegistryConfig.enabled}');
      case 'maxPerRequest':
        await _askImagesCap();
    }
  }

  /// The main menu of [startImagesFlow]: one row per editable field of
  /// the section. Pure builder.
  List<FlowOption> _imagesMenuOptions() {
    final cfg = imageRegistryConfig;
    return [
      (
        'registry',
        'Toggle registry (kill switch)',
        cfg.enabled ? 'on → off (byte-identical legacy requests)' : 'off → on',
      ),
      (
        'maxPerRequest',
        'Per-request cap',
        '${cfg.maxPerRequest} unique image(s) per request',
      ),
      ('done', 'Done', ''),
    ];
  }

  /// The settings-hub row and `/settings` summary label for the power
  /// section (issue #397): the effective sleep-prevention level and hold
  /// lifecycle, plus whether an assertion is held right now. Without a
  /// runner (tests, web) the boot config fields still say what a capable
  /// host would apply.
  String _powerStatusLabel() {
    final status = _powerAssertions?.status();
    if (status == null) {
      return '${config.powerSleepPrevention.value} · '
          '${config.powerSleepPreventionHold.value} · '
          'no runner on this host';
    }
    return '${status.level.value} · ${status.hold.value} · '
        '${status.held ? 'assertion held' : 'not held'}';
  }

  /// Settings → Power: the `power:` config section (sleep prevention,
  /// issues #325/#326) — the `sleepPrevention` level and the `hold`
  /// lifecycle. Writes go through the surgical validated-yaml upsert
  /// into the USER config, and every successful write re-arms the
  /// session's assertion from the saved file ([_reloadPowerAssertions]
  /// — what's live is what's on disk). Loops until cancelled or `done`.
  Future<void> startPowerFlow() async {
    for (;;) {
      final picked = await _pickOption('power', _powerMenuOptions());
      if (picked == null || picked == 'done') return;
      await _applyPowerPick(picked);
    }
  }

  /// Dispatches one [startPowerFlow] menu pick; the caller re-renders
  /// the menu afterwards. Split out to keep each function's complexity
  /// under the repo's CRAP gate.
  Future<void> _applyPowerPick(String picked) async {
    switch (picked) {
      case 'sleepPrevention':
        await _askPowerLevel();
      case 'hold':
        await _togglePowerHold();
    }
  }

  /// The main menu of [startPowerFlow]: one row per editable field of
  /// the section. Pure builder.
  List<FlowOption> _powerMenuOptions() {
    final level = _powerAssertions?.level ?? config.powerSleepPrevention;
    final hold = _powerAssertions?.hold ?? config.powerSleepPreventionHold;
    return [
      (
        'sleepPrevention',
        'Sleep prevention level',
        "off|idle|display|system — now '${level.value}'",
      ),
      (
        'hold',
        'Toggle hold lifecycle',
        '${hold.value} → '
            '${hold == PowerAssertionHold.perRun ? 'session' : 'per-run'}',
      ),
      ('done', 'Done', ''),
    ];
  }

  /// The level branch: an empty answer keeps the current value; anything
  /// else rides verbatim into the yaml upsert — the strict boot parser
  /// ([parsePowerSection]) validates the edited section BEFORE the
  /// write, so a bad value prints the parser's own message and nothing
  /// is written (AC4).
  Future<void> _askPowerLevel() async {
    final current =
        (_powerAssertions?.level ?? config.powerSleepPrevention).value;
    final answer = await _askLine(
      "sleepPrevention off|idle|display|system (empty keeps '$current'): ",
    );
    if (answer == null) return;
    final value = answer.trim();
    if (value.isEmpty) return;
    await _writePowerKey(const ['power', 'sleepPrevention'], value);
  }

  /// The hold toggle: per-run ↔ session, one keypress. The current value
  /// is the live controller's (it tracks the writes), so the toggle
  /// always offers the other lifecycle.
  Future<void> _togglePowerHold() async {
    final current = _powerAssertions?.hold ?? config.powerSleepPreventionHold;
    final next = current == PowerAssertionHold.perRun
        ? PowerAssertionHold.session
        : PowerAssertionHold.perRun;
    await _writePowerKey(const ['power', 'hold'], next.value);
  }

  /// The shared write path: a USER-file upsert of [segments] → [value]
  /// validated with the real boot parser first, then reload-after-write
  /// re-arms the session's assertion from the saved file.
  Future<void> _writePowerKey(List<String> segments, String value) async {
    if (_userConfigPath() == null) {
      io.writeln('power: no user config on this host — not saved');
      return;
    }
    final wrote = await _upsertConfigYaml(
      segments,
      value,
      projectScope: false,
      validate: parsePowerSection,
    );
    if (wrote) await _reloadPowerAssertions();
  }

  /// Reload-after-write (AC3/E3): the boot-built controller keeps its
  /// construction-time level/hold, so the saved section re-arms the
  /// session's assertion — the old assertion releases, a session-held
  /// level re-acquires immediately and per-run waits for the next run
  /// start. Without a runner on this host there is no assertion
  /// lifecycle to re-arm (the change lands at next boot where one
  /// exists); a read race after the successful write keeps the current
  /// live controller — the next write re-syncs.
  Future<void> _reloadPowerAssertions() async {
    final path = _userConfigPath();
    if (path == null) return;
    switch (await _env.readTextFile(path)) {
      case Ok(:final value):
        final doc = loadYaml(value);
        await _rearmPowerAssertions(
          parsePowerSection(doc is YamlMap ? doc['power'] : null),
        );
      case Err():
        break;
    }
  }

  /// Swaps the session's sleep-prevention controller for one built from
  /// [section] (issues #325/#326 wiring): release, rebuild, and a
  /// session-held level re-acquires at once. The boot construction in
  /// `agent_cli.dart` applies the same defaults.
  Future<void> _rearmPowerAssertions(PowerSection section) async {
    final runner = config.powerRunner;
    if (runner == null) return;
    await _powerAssertions?.onSessionClosed();
    final controller = PowerAssertionController(
      runner: runner,
      level: section.sleepPrevention ?? PowerAssertionLevel.idle,
      hold: section.hold ?? PowerAssertionHold.perRun,
      onWarn: io.writeln,
    );
    _powerAssertions = controller;
    await controller.onSessionOpened();
  }

  /// The settings-hub row and `/settings` summary label for the owner cap
  /// (issue #394): the model's raw window vs the effective cap.
  String _contextCapStatusLabel() {
    final cap = config.contextWindowCap;
    final window = _agent.state.model.contextWindow;
    return cap == null ? 'off (window $window)' : '$window → $cap';
  }

  /// Settings → Context cap: the `agent:` section (`contextWindowCap`,
  /// issue #394) — set or clear the owner-side cap the compaction
  /// thresholds, the ctx meter and the loop's over-window guard clamp
  /// through. Writes go through the surgical validated-yaml upsert into
  /// the USER config (the machine-level file `fa config set agent…`
  /// also uses); the running session keeps its boot cap (honest note).
  /// Loops until the pick is cancelled or `done`.
  Future<void> startContextCapFlow() async {
    for (;;) {
      final picked = await _pickOption('context cap', _contextCapMenuOptions());
      if (picked == null || picked == 'done') return;
      await _applyContextCapPick(picked);
    }
  }

  /// Dispatches one [startContextCapFlow] menu pick; the caller re-renders
  /// the menu afterwards. Split out to keep each function's complexity
  /// under the repo's CRAP gate.
  Future<void> _applyContextCapPick(String picked) async {
    switch (picked) {
      case 'set':
        await _askContextCapValue();
      case 'clear':
        await _clearContextCap();
    }
  }

  /// The main menu of [startContextCapFlow]. Pure builder.
  List<FlowOption> _contextCapMenuOptions() {
    final cap = config.contextWindowCap;
    return [
      ('set', 'Set the cap', cap == null ? 'currently off' : 'currently $cap'),
      (
        'clear',
        'Clear the cap',
        cap == null ? 'already off' : 'removes agent.contextWindowCap',
      ),
      ('done', 'Done', ''),
    ];
  }

  /// The cap branch: an empty answer keeps the current value; anything
  /// else rides verbatim into the yaml upsert — the strict boot parser
  /// ([parseImagesSection]) validates the edited section BEFORE the
  /// write, so a bad value prints the parser's own message and nothing
  /// is written (AC4).
  Future<void> _askImagesCap() async {
    final current = imageRegistryConfig.maxPerRequest;
    final answer = await _askLine("per-request cap (empty keeps '$current'): ");
    if (answer == null) return;
    final value = answer.trim();
    if (value.isEmpty) return;
    await _writeImagesKey(const ['images', 'maxPerRequest'], value);
  }

  /// The shared write path: a USER-file upsert of [segments] → [value]
  /// validated with the real boot parser first, then reload-after-write
  /// republishes the global the request build consults.
  Future<void> _writeImagesKey(List<String> segments, String value) async {
    if (_userConfigPath() == null) {
      io.writeln('images: no user config on this host — not saved');
      return;
    }
    final wrote = await _upsertConfigYaml(
      segments,
      value,
      projectScope: false,
      validate: parseImagesSection,
    );
    if (wrote) await _reloadImageRegistry();
  }

  /// Reload-after-write (E3): the process-wide registry settings are
  /// re-parsed from the saved file, so the next request build applies
  /// exactly what's on disk and a concurrent editor's values survive.
  Future<void> _reloadImageRegistry() async {
    final path = _userConfigPath();
    if (path == null) return;
    switch (await _env.readTextFile(path)) {
      case Ok(:final value):
        final doc = loadYaml(value);
        imageRegistryConfig =
            parseImagesSection(doc is YamlMap ? doc['images'] : null) ??
            const ImageRegistryConfig();
      case Err():
        // The write just succeeded; a read race keeps the current live
        // config — the next write re-syncs.
        break;
    }
  }

  /// The set branch: a positive integer at or above the compaction
  /// reserve. The raw answer goes through the validated upsert — an
  /// invalid value prints the parser's verbatim [ConfigException] and
  /// writes NOTHING (AC4). A cap at or above the model's own window
  /// clamps nothing — the flow warns after a successful write.
  Future<void> _askContextCapValue() async {
    final current = config.contextWindowCap;
    final answer = await _askLine(
      'context cap in tokens (min 16384, empty keeps '
      "${current ?? 'off'}): ",
    );
    if (answer == null) return;
    final value = answer.trim();
    if (value.isEmpty) return;
    final wrote = await _upsertConfigYaml(
      const ['agent', 'contextWindowCap'],
      value,
      projectScope: false,
      validate: validateAgentSection,
    );
    if (wrote) _warnCapNoOp(value);
  }

  /// The ≥-window warning: the cap only CLAMPS below the model's window;
  /// at or above it the setting is a legal no-op.
  void _warnCapNoOp(String value) {
    final cap = int.tryParse(value);
    final window = _agent.state.model.contextWindow;
    if (cap != null && window > 0 && cap >= window) {
      io.writeln('note: $cap ≥ model window $window — the cap clamps nothing');
    }
  }

  /// The clear branch: the `agent:` section's only key is
  /// `contextWindowCap`, so clearing drops the whole top-level block
  /// (a bare `agent:` would fail the strict diagnostics validator).
  Future<void> _clearContextCap() async {
    if (config.contextWindowCap == null) {
      io.writeln('context cap: already off — nothing to clear');
      return;
    }
    final path = _userConfigPath();
    if (path == null) {
      io.writeln('context cap: no user config on this host — not saved');
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
    final edited = _dropTopLevelBlock(source, 'agent');
    // Never persist a file the next boot would reject.
    try {
      loadYaml(edited);
    } on Object catch (error) {
      io.writeln('not saved: $error');
      return;
    }
    if (await _env.writeFile(path, edited) is Err) {
      io.writeln('could not write $path');
      return;
    }
    io.writeln(
      'agent.contextWindowCap removed → $path (${applicationNote('agent')})',
    );
  }

  /// Removes the top-level `[key]:` block from [source] — the key line
  /// plus every following blank/indented line. Everything else survives
  /// byte-for-byte; an absent key is a no-op.
  String _dropTopLevelBlock(String source, String key) {
    final lines = source.split('\n');
    final start = lines.indexWhere((line) => line.startsWith('$key:'));
    if (start < 0) return source;
    var end = start + 1;
    while (end < lines.length &&
        (lines[end].isEmpty ||
            lines[end].startsWith(' ') ||
            lines[end].startsWith('\t'))) {
      end++;
    }
    return [...lines.sublist(0, start), ...lines.sublist(end)].join('\n');
  }

  /// The effective retry policy: the roles resolver's, or the parser
  /// defaults when no resolver runs (the `retry:` section rides the
  /// `roles:` group).
  ModelRolesRetryPolicy get _effectiveRetryPolicy =>
      config.modelRolesResolver?.config.retry ?? const ModelRolesRetryPolicy();

  /// The settings-hub row and `/settings` summary label for resilience
  /// (issue #393): the effective watchdog timeouts and the retry budget.
  String _resilienceStatusLabel() =>
      'connect ${effectiveProviderConnectTimeout.inMilliseconds}ms, '
      'idle ${effectiveProviderStreamIdleTimeout.inMilliseconds}ms, '
      'retries ×${_effectiveRetryPolicy.retriesPerEntry}';

  /// Settings → Resilience: the `providerTimeouts:` watchdog knobs and the
  /// `retry:` backoff policy as an interactive flow (issue #393). Writes
  /// go through the surgical validated-yaml upsert into the USER config;
  /// the saved timeouts are re-published onto the process-wide override
  /// the watchdogs read on every request, and the saved retry policy is
  /// installed on the roles resolver when one runs. Loops until the pick
  /// is cancelled or `done`.
  Future<void> startResilienceFlow() async {
    for (;;) {
      final picked = await _pickOption('resilience', _resilienceMenuOptions());
      if (picked == null || picked == 'done') return;
      await _applyResiliencePick(picked);
    }
  }

  /// Dispatches one [startResilienceFlow] menu pick; the caller re-renders
  /// the menu afterwards. Split out to keep each function's complexity
  /// under the repo's CRAP gate.
  Future<void> _applyResiliencePick(String picked) async {
    switch (picked) {
      case 'connect':
        await _askResilienceMs(
          'connectTimeoutMs',
          'connect watchdog (first headers)',
        );
      case 'streamIdle':
        await _askResilienceMs('streamIdleTimeoutMs', 'stream-idle watchdog');
      case 'retriesPerEntry':
      case 'baseDelayMs':
      case 'maxBackoffMs':
      case 'maxWaitMs':
      case 'keyBackoffMs':
        await _askRetryScalar(picked);
    }
  }

  /// The main menu of [startResilienceFlow]: the two watchdog knobs (the
  /// built-in defaults shown, so an override reads as an override) and
  /// the five retry knobs (each marked `default` when it equals the
  /// parser default). Pure builder.
  List<FlowOption> _resilienceMenuOptions() {
    final retry = _effectiveRetryPolicy;
    const defaults = ModelRolesRetryPolicy();
    String inherit(int value, int fallback) =>
        value == fallback ? 'default' : 'default is $fallback';
    return [
      (
        'connect',
        'Connect watchdog',
        '${effectiveProviderConnectTimeout.inMilliseconds}ms '
            '(built-in ${providerConnectTimeout.inMilliseconds}ms)',
      ),
      (
        'streamIdle',
        'Stream-idle watchdog',
        '${effectiveProviderStreamIdleTimeout.inMilliseconds}ms '
            '(built-in ${providerStreamIdleTimeout.inMilliseconds}ms)',
      ),
      (
        'retriesPerEntry',
        'Retries per chain entry',
        '${retry.retriesPerEntry} '
            '(${inherit(retry.retriesPerEntry, defaults.retriesPerEntry)})',
      ),
      (
        'baseDelayMs',
        'Backoff base delay',
        '${retry.baseDelay.inMilliseconds}ms (${inherit(retry.baseDelay.inMilliseconds, defaults.baseDelay.inMilliseconds)})',
      ),
      (
        'maxBackoffMs',
        'Backoff cap',
        '${retry.maxBackoff.inMilliseconds}ms (${inherit(retry.maxBackoff.inMilliseconds, defaults.maxBackoff.inMilliseconds)})',
      ),
      (
        'maxWaitMs',
        'Give-up threshold (failover past it)',
        '${retry.maxWait.inMilliseconds}ms (${inherit(retry.maxWait.inMilliseconds, defaults.maxWait.inMilliseconds)})',
      ),
      (
        'keyBackoffMs',
        'Key cooldown',
        '${retry.keyBackoff.inMilliseconds}ms (${inherit(retry.keyBackoff.inMilliseconds, defaults.keyBackoff.inMilliseconds)})',
      ),
      ('done', 'Done', ''),
    ];
  }

  /// The watchdog-knob branch: prompts for milliseconds and feeds the raw
  /// answer through the validated upsert (AC4: a bad value shows the
  /// parser's verbatim message and writes nothing).
  Future<void> _askResilienceMs(String key, String label) async {
    final answer = await _askLine(
      '$label in ms (empty keeps the current value): ',
    );
    if (answer == null) return;
    final value = answer.trim();
    if (value.isEmpty) return;
    await _writeProviderTimeout(key, value);
  }

  /// The retry-knob branch: prompts for the field's yaml unit (a plain
  /// count for `retriesPerEntry`, milliseconds for the rest) and feeds
  /// the raw answer through the validated upsert.
  Future<void> _askRetryScalar(String key) async {
    final retry = _effectiveRetryPolicy;
    final current = switch (key) {
      'retriesPerEntry' => '${retry.retriesPerEntry}',
      'baseDelayMs' => '${retry.baseDelay.inMilliseconds}',
      'maxBackoffMs' => '${retry.maxBackoff.inMilliseconds}',
      'maxWaitMs' => '${retry.maxWait.inMilliseconds}',
      _ => '${retry.keyBackoff.inMilliseconds}',
    };
    final answer = await _askLine('$key (empty keeps $current): ');
    if (answer == null) return;
    final value = answer.trim();
    if (value.isEmpty) return;
    await _writeRetryKey(key, value);
  }

  /// The shared timeout write path: a USER-file upsert of
  /// `providerTimeouts.<key>` validated by the real section parser first
  /// (AC4), then the re-publish that installs the saved section on the
  /// process-wide override (AC3/E3).
  Future<void> _writeProviderTimeout(String key, String value) async {
    if (_userConfigPath() == null) {
      io.writeln('resilience: no user config on this host — not saved');
      return;
    }
    final wrote = await _upsertConfigYaml(
      ['providerTimeouts', key],
      value,
      projectScope: false,
      validate: validateProviderTimeoutsSection,
      note:
          'applies to new requests — the watchdogs read the saved '
          'override on every request',
    );
    if (wrote) await _publishProviderTimeouts();
  }

  /// Reload-after-publish (E3): what's live is what's on disk — the saved
  /// file is re-parsed with the boot parser and installed on the
  /// process-wide override, so a concurrent editor's values survive and
  /// the menu re-renders the fresh state.
  Future<void> _publishProviderTimeouts() async {
    final path = _userConfigPath();
    if (path == null) return;
    switch (await _env.readTextFile(path)) {
      case Ok(:final value):
        final doc = loadYaml(value);
        providerTimeoutsOverride = parseProviderTimeouts(
          doc is YamlMap ? doc['providerTimeouts'] : null,
        );
      case Err():
        // The write just succeeded; a read race keeps the current live
        // override — the next write re-syncs.
        break;
    }
  }

  /// The shared retry write path: a USER-file upsert of `retry.<key>`,
  /// validated by the real roles-group parser over the WHOLE document
  /// (the group parses together — `retry:` without `roles:` is refused
  /// with the parser's verbatim message), then the reload that installs
  /// the saved policy on the running resolver when one exists.
  Future<void> _writeRetryKey(String key, String value) async {
    if (_userConfigPath() == null) {
      io.writeln('resilience: no user config on this host — not saved');
      return;
    }
    final wrote = await _upsertConfigYaml(
      ['retry', key],
      value,
      projectScope: false,
      validateDoc: ModelRolesConfig.fromYaml,
      note: _retryNote(),
    );
    if (wrote) await _reloadRetryPolicy();
  }

  /// The honest liveness note (AC3): with a resolver the new policy
  /// governs new failures (the run already streaming keeps the old one);
  /// without one the section waits for the next boot.
  String _retryNote() => config.modelRolesResolver == null
      ? applicationNote('retry')
      : 'applies to new failures — the run already streaming keeps the '
            'old policy';

  /// Reload-after-write (E3): the saved file is re-parsed and the policy
  /// installed on the resolver (wrappers rebuilt), so a concurrent
  /// editor's values survive and the menu re-renders the fresh state.
  Future<void> _reloadRetryPolicy() async {
    final resolver = config.modelRolesResolver;
    final path = _userConfigPath();
    if (resolver == null || path == null) return;
    switch (await _env.readTextFile(path)) {
      case Ok(:final value):
        final doc = loadYaml(value);
        if (doc is! YamlMap) return;
        resolver.setRetryPolicy(ModelRolesConfig.fromYaml(doc).retry);
      case Err():
        // The write just succeeded; a read race keeps the current live
        // policy — the next write re-syncs.
        break;
    }
  }

  /// Upserts [segments] → [value] in the project or user config file,
  /// validating the edited section with [validate] (the real parser)
  /// BEFORE the write — and, when [validateDoc] is given, the WHOLE
  /// parsed document with it (the roles group `roles:` / `retry:` parses
  /// together, so the retry flow validates at document level). A JSON
  /// array/object value renders as a yaml block (list-valued keys — see
  /// [configLeafLines]); anything else is the single scalar line. [note]
  /// overrides the liveness note printed on success (default:
  /// [applicationNote] for the section). Returns true when written;
  /// failures print and leave the file untouched.
  Future<bool> _upsertConfigYaml(
    List<String> segments,
    String value, {
    required bool projectScope,
    void Function(Object? node)? validate,
    void Function(YamlMap doc)? validateDoc,
    String? note,
  }) async {
    final path = projectScope
        ? '${_env.cwd}/.fah/config.yaml'
        : _userConfigPath()!;
    final read = await _env.readTextFile(path);
    final String source;
    switch (read) {
      case Ok(:final value):
        source = value;
      case Err(:final error) when error.code == FileErrorCode.notFound:
        source = '';
      case Err(:final error):
        io.writeln('cannot read $path: $error — not saved');
        return false;
    }
    final edited = upsertYamlPath(
      source,
      segments,
      configLeafLines(value, depth: segments.length - 1),
    );
    // Never persist a file the next boot would reject.
    final doc = loadYaml(edited);
    final section = doc is YamlMap ? doc[segments.first] : null;
    try {
      validate?.call(section);
      if (doc is YamlMap) validateDoc?.call(doc);
    } on Object catch (error) {
      io.writeln('not saved: $error');
      return false;
    }
    if (await _env.writeFile(path, edited) is Err) {
      io.writeln('could not write $path');
      return false;
    }
    io.writeln(
      '${segments.join('.')} = $value → $path '
      '(${note ?? applicationNote(segments.first)})',
    );
    return true;
  }

  /// Re-fetches the DAP/1 hub snapshot through the host's seam — file
  /// reads plus the hub plugin's local status snapshot, never a network
  /// dial. A missing seam leaves the null (nothing fetched); a failing one
  /// keeps the last good snapshot rather than blanking the UI.
  Future<void> _refreshDapHubSnapshot() async {
    final fetch = config.dapHubState;
    if (fetch == null) return;
    try {
      _dapHubSnapshot = await fetch();
    } on Object {
      // Keep the last snapshot (or null) — the next render retries.
    }
  }

  /// The settings-hub row and `/settings` summary label: the resolved hub
  /// url, or the unconfigured note when no snapshot exists.
  String _dapHubStatusLabel() => _dapHubSnapshot?.url ?? 'not configured';

  /// The flow's "view" action: the resolved hub url, the agent name, and
  /// the live connection state.
  void _printDapHubConfig() {
    final snapshot = _dapHubSnapshot;
    if (snapshot == null) {
      io.writeln('dap: hub state unavailable on this host');
      return;
    }
    io.writeln('dap hub url: ${snapshot.url}');
    io.writeln('dap agent name: ${snapshot.name ?? '(hostname default)'}');
    if (snapshot.connected ?? false) {
      io.writeln(
        'dap connection: connected as '
        '${snapshot.agentId ?? snapshot.name}',
      );
    } else {
      io.writeln('dap connection: not connected');
    }
  }

  /// The flow's "test" action report: one honest line about the live
  /// plugin's connection state.
  void _printDapHubConnection() {
    final snapshot = _dapHubSnapshot;
    if (snapshot == null) {
      io.writeln('dap: hub state unavailable on this host');
    } else if (snapshot.connected ?? false) {
      io.writeln(
        'dap: connected to ${snapshot.url} as '
        '${snapshot.agentId ?? snapshot.name}',
      );
    } else {
      io.writeln('dap: not connected to ${snapshot.url}');
    }
  }

  /// The flow's set/change branch: prompts for the hub url or the agent
  /// name, keeps the current value on an empty answer, and persists through
  /// [AgentCliConfig.onDapHubConfigChanged]. Without a host hook the change
  /// is refused (never half-applied).
  Future<void> _editDapHubValue({required bool isUrl}) async {
    final persist = config.onDapHubConfigChanged;
    if (persist == null) {
      io.writeln('dap: no hub config hook on this host — not saved');
      return;
    }
    final current = isUrl ? _dapHubSnapshot?.url : _dapHubSnapshot?.name;
    final fallback = current ?? (isUrl ? 'not configured' : 'hostname default');
    final answer = await _askLine(
      "${isUrl ? 'hub url' : 'agent name'} (empty keeps '$fallback'): ",
    );
    final value = answer?.trim() ?? '';
    if (value.isEmpty) return;
    await persist(url: isUrl ? value : null, name: isUrl ? null : value);
    await _refreshDapHubSnapshot();
    io.writeln('dap: saved ${isUrl ? 'hub url' : 'agent name'} $value');
    // Higher-precedence sources (env, the yaml `hub:` section, the running
    // client's startup values) can shadow the persisted value until they
    // clear — say so instead of letting the menu silently show another url.
    final effective = isUrl ? _dapHubSnapshot?.url : _dapHubSnapshot?.name;
    if (effective != null && effective != value) {
      io.writeln(
        'dap: effective stays $effective (env / hub: section / live '
        'client override wins until it clears)',
      );
    }
  }

  /// The flow's opt-out: writes `hub: false` into `<cwd>/.fah/packages.yaml`
  /// — the file the plugin loader reads at startup — preserving every other
  /// section byte-for-byte (see [_withHubOptOut]).
  Future<void> _writeDapHubOptOut() async {
    final path = '${_env.cwd}/.fah/packages.yaml';
    final String updated;
    switch (await _env.readTextFile(path)) {
      case Ok(:final value):
        updated = _withHubOptOut(value);
      case Err(:final error) when error.code == FileErrorCode.notFound:
        updated = 'hub: false\n';
      case Err():
        io.writeln('dap: cannot read $path — opt-out not written');
        return;
    }
    if (await _env.writeFile(path, updated) is Err) {
      io.writeln('dap: could not write $path');
      return;
    }
    io.writeln('dap: hub plugin disabled in $path (applies at next start)');
  }

  /// `/settings`: a bare command opens the TUI settings hub; anything else
  /// (and line mode) prints the current settings summary.
  Future<void> _settingsSlash(String rest) async {
    await _refreshDapHubSnapshot();
    if (rest.isEmpty && _useTui && _tuiController != null) {
      _openSettingsPicker();
    } else {
      _printSettingsSummary();
    }
  }

  /// The settings-hub rows: one entry per configurable area, each
  /// launching the same interactive flow its dedicated slash command
  /// would. Pure builder so tests can assert the hub carries every area
  /// without a TUI controller.
  List<MenuItem> settingsHubItems() {
    final model = _agent.state.model;
    return [
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
      MenuItem(
        key: 'dap',
        label: 'DAP / Hub',
        description: _dapHubStatusLabel(),
      ),
      MenuItem(
        key: 'keys',
        label: 'API keys',
        description: 'set or inspect stored keys',
      ),
      MenuItem(key: 'tools', label: 'Tools', description: _toolsStatusLabel()),
      MenuItem(
        key: 'compaction',
        label: 'Compaction',
        description: 'engine: ${_compactionStatusLabel()}',
      ),
      MenuItem(
        key: 'ttsr',
        label: 'Stream rules (TTSR)',
        description: _ttsrStatusLabel(),
      ),
      MenuItem(
        key: 'memory',
        label: 'Memory',
        description: _memoryPathLabel(project: true),
      ),
      MenuItem(
        key: 'resilience',
        label: 'Resilience',
        description: _resilienceStatusLabel(),
      ),
      MenuItem(
        key: 'redact',
        label: 'Redaction',
        description: _redactionStatusLabel(),
      ),
      MenuItem(
        key: 'context-cap',
        label: 'Context cap',
        description: _contextCapStatusLabel(),
      ),
      MenuItem(
        key: 'images',
        label: 'Images',
        description: _imagesStatusLabel(),
      ),
      MenuItem(key: 'power', label: 'Power', description: _powerStatusLabel()),
      MenuItem(
        key: 'mcp',
        label: 'MCP servers',
        description: _mcpStatusLabel(),
      ),
    ];
  }

  /// The settings hub picker: opens the [settingsHubItems] list.
  void _openSettingsPicker() {
    _tuiController?.openPicker('settings', 'Settings', settingsHubItems());
  }

  @visibleForTesting
  List<MenuItem> settingsHubItemsForTest() => settingsHubItems();

  @visibleForTesting
  Set<String> settingsPickerHandlerKeysForTest() =>
      _settingsPickerHandlers.keys.toSet();

  /// The live MCP manager when one runs this session (the flow tests
  /// assert real reconnect behavior through it).
  @visibleForTesting
  McpManager? get mcpManagerForTest => _mcp.manager;

  /// A settings-hub selection launches the same flow its dedicated slash
  /// command would open.
  Future<void> _tuiPickSetting(String key) async {
    await _settingsPickerHandlers[key]?.call();
  }

  /// Settings-hub key → the flow its dedicated slash command would open.
  Map<String, Future<void> Function()> get _settingsPickerHandlers => {
    'provider': () async => _openProviderPicker(),
    'model': startChatModelFlow,
    'approval': () async => _openApprovalPicker(),
    'mode': () async => _openModePicker(),
    'model-edit': () => _handleModelEdit(''),
    'media': startMediaSlotFlow,
    'agent-models': startAgentModelFlow,
    'tools': _toolsSettingsFlow,
    'compaction': startCompactionEngineFlow,
    'ttsr': startTtsrRulesFlow,
    'keys': () => _handleKeyCommand(''),
    'dap': startDapHubFlow,
    'cube': startCubeSandboxFlow,
    'resilience': startResilienceFlow,
    'redact': startRedactionFlow,
    'context-cap': startContextCapFlow,
    'memory': startMemoryStoresFlow,
    'images': startImagesFlow,
    'power': startPowerFlow,
    'mcp': startMcpServersFlow,
  };

  /// The line-mode `/settings` summary (the TUI opens the hub instead).
  void _printSettingsSummary() {
    final model = _agent.state.model;
    io.writeln('provider: ${model.provider}');
    io.writeln('model: ${model.id}');
    io.writeln('approval: ${_approval.mode.label}');
    io.writeln('mode: ${_currentMode.name}');
    io.writeln('cube: ${_cubeStatusLabel()}');
    io.writeln('resilience: ${_resilienceStatusLabel()}');
    io.writeln('dap: ${_dapHubStatusLabel()}');
    io.writeln('tools: ${_toolsStatusLabel()}');
    io.writeln('compaction: ${_compactionStatusLabel()}');
    io.writeln('ttsr: ${_ttsrStatusLabel()}');
    io.writeln('redact: ${_redactionStatusLabel()}');
    io.writeln('ctx cap: ${_contextCapStatusLabel()}');
    io.writeln('images: ${_imagesStatusLabel()}');
    io.writeln('power: ${_powerStatusLabel()}');
    io.writeln('mcp: ${_mcpStatusLabel()}');
    io.writeln(
      'change via /provider, /model, /approval, /mode, /key, /mcp, /cube, '
      '/tools (agent models: the /settings hub)',
    );
  }
}

/// Replaces the top-level `hub:` block of a `.fah/packages.yaml` body with
/// the `hub: false` opt-out, or appends the key when absent. A block is the
/// `hub:` key line plus every following blank/indented line; everything
/// else survives byte-for-byte and the result stays parseable yaml (the
/// plugin loader reads the same shape it always did).
String _withHubOptOut(String source) =>
    _replaceTopLevelYamlBlock(source, 'hub', 'hub: false');
