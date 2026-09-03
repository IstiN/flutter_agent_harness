/// Tool-availability wiring for [AgentCli] (issue #19): the capability
/// map, live scope resolution (global → project → session → runtime), the
/// `/tools` command, the settings-hub Tools flow, and the MCP re-filter.
/// Extracted from `agent_cli.dart` to keep the host under the 2800-line
/// gate. Scope files are read through the (web-safe) [ExecutionEnv] like
/// `/mcp reload` reads the mcp section.
part of 'agent_cli.dart';

/// Per-instance state of the tools wiring (extensions cannot add fields;
/// [AgentCli] holds exactly this one object).
final class _ToolsWiringState {
  /// The live GLOBAL `tools:` scope: read once from
  /// `<homeDir>/.fah/config.yaml`, then owned by `/tools ... global`
  /// (the host persists it through `onToolsConfigChanged`).
  ToolsConfig global = const ToolsConfig();
  bool globalLoaded = false;

  /// Last successfully-read project/session scopes — a broken file keeps
  /// the last good scope instead of silently falling back to empty.
  ToolsConfig project = const ToolsConfig();
  ToolsConfig session = const ToolsConfig();

  /// Unknown ids already warned about (warn once per distinct id).
  Set<String> warnedIds = const {};
}

/// Reads the `tools:` section of the yaml file at [path] through [env].
/// Returns `(null, null)` when the file or the section is absent,
/// `(null, message)` when the file/section is broken, else the parsed
/// config.
Future<(ToolsConfig?, String?)> readToolsScopeFile(
  ExecutionEnv env,
  String path,
) async {
  final text = (await env.readTextFile(path)).valueOrNull;
  if (text == null || text.trim().isEmpty) return (null, null);
  final Object? doc;
  try {
    doc = loadYaml(text);
  } on Object catch (error) {
    return (null, 'cannot parse $path: $error');
  }
  if (doc is! YamlMap) return (null, 'cannot parse $path: not a yaml map');
  final node = doc['tools'];
  if (node == null) return (const ToolsConfig(), null);
  try {
    return (ToolsConfig.fromYaml(node), null);
  } on ConfigException catch (error) {
    return (null, 'invalid tools section in $path: ${error.message}');
  }
}

/// Replaces the top-level `[key]:` block of a yaml [source] with
/// [replacement], or appends it when absent. A block is the key line plus
/// every following blank/indented line; everything else survives
/// byte-for-byte and the result stays parseable yaml.
String _replaceTopLevelYamlBlock(
  String source,
  String key,
  String replacement,
) {
  final lines = source.split('\n');
  var start = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('$key:')) {
      start = i;
      break;
    }
  }
  if (start < 0) {
    final separator = source.isEmpty || source.endsWith('\n') ? '' : '\n';
    return '$source$separator$replacement\n';
  }
  var end = start + 1;
  while (end < lines.length &&
      (lines[end].isEmpty ||
          lines[end].startsWith(' ') ||
          lines[end].startsWith('\t'))) {
    end++;
  }
  return [
    ...lines.sublist(0, start),
    replacement,
    ...lines.sublist(end),
  ].join('\n');
}

/// The directory part of a posix [path].
String _dirname(String path) {
  final slash = path.lastIndexOf('/');
  return slash <= 0 ? '/' : path.substring(0, slash);
}

/// The `/tools` command, capability mapping, and live scope resolution.
extension AgentCliTools on AgentCli {
  /// Static tool name → availability id. Aggregate families map several
  /// tools onto one id; dynamic MCP tools (`mcp__*`) are absent on purpose
  /// (per-server families, noted at registration time).
  static const _idByToolName = <String, String>{
    'read': 'read',
    'write': 'write',
    'edit': 'edit',
    'ls': 'ls',
    'bash': 'bash',
    'bash_job': 'bash_job',
    'lsp': 'lsp',
    'web_search': 'web_search',
    // The gate's family contract: `web_search` → [webSearchTool,
    // webFetchTool] — one id hides/restores both (AC16 headless parity).
    'web_fetch': 'web_search',
    'memory_add': 'memory',
    'memory_search': 'memory',
    'memory_list': 'memory',
    'memory_delete': 'memory',
    'schedule_message': 'schedule_message',
    'ask': 'ask',
    'request_secret': 'request_secret',
    'inspect_image': 'inspect_image',
    'transcribe_audio': 'transcribe_audio',
    'generate_image': 'generate_image',
    'generate_video': 'generate_video',
    'task': 'task',
    'task_cancel': 'task',
    'task_status': 'task',
    'task_observe': 'task',
    'task_send': 'task',
    'agent_directory': 'task',
    'reply': 'task',
    'agent_message': 'task',
    'checkpoint': 'checkpoint',
    'rewind': 'rewind',
  };

  /// Groups the full static tool set by availability id, from the SAME
  /// instances the constructor registered. The boot hook stores this map
  /// in `_toolGroupsById`; the sqlite variant swap replaces the `read`
  /// entry in place so the gate always re-registers the current variant.
  Map<String, List<AgentTool>> toolGroups() {
    final groups = <String, List<AgentTool>>{};
    for (final tool in _toolRegistry.agentTools) {
      final id = _availabilityId(tool.name);
      if (id != null) groups.putIfAbsent(id, () => []).add(tool);
    }
    return groups;
  }

  /// The availability id of a registered tool name, or null when the tool
  /// carries no id (dynamic MCP tools, unknown plugin tools — always on).
  String? _availabilityId(String name) {
    if (name.startsWith('mcp__')) return null;
    if (name.startsWith('dap_')) return 'dap';
    return _idByToolName[name];
  }

  /// The host wiring as capabilities: the hard floor below config.
  Map<String, ToolCapability> toolCapabilities() {
    const on = ToolCapability.available();
    return {
      'read': on,
      'write': on,
      'edit': on,
      'ls': on,
      'bash': on,
      'bash_job': on,
      'sqlite': config.sqliteEngine != null
          ? on
          : const ToolCapability.absent('SQLite engine not wired by this host'),
      'lsp': config.lspConfig != null
          ? on
          : const ToolCapability.absent('language-server transport not wired'),
      'web_search': config.webSearchConfig != null
          ? on
          : const ToolCapability.absent('web search not wired'),
      'mcp': _mcp.manager != null
          ? on
          : const ToolCapability.absent('no mcp: config'),
      'memory': on,
      'schedule_message': on,
      'ask': on,
      'request_secret': on,
      'task': on,
      'checkpoint': on,
      'rewind': on,
      'generate_image': on,
      'generate_video': on,
      'inspect_image': config.visionConfig != null
          ? on
          : const ToolCapability.absent('no vision model configured'),
      'transcribe_audio': config.transcribeConfig != null
          ? on
          : const ToolCapability.absent('no transcription endpoint configured'),
      'dap': (_toolGroupsById['dap']?.isNotEmpty ?? false)
          ? on
          : const ToolCapability.absent('no hub configured'),
    };
  }

  /// The live global `tools:` scope for the host's persistence; null
  /// before the first availability rebuild.
  ToolsConfig? get globalTools =>
      _toolsWiring.globalLoaded ? _toolsWiring.global : null;

  /// Re-reads every scope, resolves availability, and re-applies it to the
  /// live registry/prompt/executor: safe to call at any time (idempotent).
  Future<void> rebuildToolAvailability() async {
    final state = _toolsWiring;
    if (!state.globalLoaded) {
      state.globalLoaded = true;
      final home = config.homeDir;
      state.global = home == null
          ? const ToolsConfig()
          : await _readScopeKeepingLastGood(
              '$home/.fah/config.yaml',
              state.global,
              'global',
            );
    }
    state.project = await _readScopeKeepingLastGood(
      '${_env.cwd}/.fah/config.yaml',
      state.project,
      'project',
    );
    state.session = await _readSessionTools();
    final resolution = resolveToolAvailability(
      capabilities: toolCapabilities(),
      scopes: [
        (ToolScope.global, state.global),
        (ToolScope.project, state.project),
        (ToolScope.session, state.session),
        (ToolScope.runtime, config.runtimeTools ?? const ToolsConfig()),
      ],
    );
    _warnUnknownToolIds(resolution.unknownIds);
    _swapReadSqliteVariant(resolution);
    _toolGate.apply(
      resolution,
      _toolRegistry,
      _agent,
      rebuildPrompt: _applyPromptComposition,
    );
    refilterMcpTools(resolution);
  }

  /// Reads [path]; a broken file prints one warning and keeps [cached]
  /// (the last good scope) instead of silently falling back to empty.
  Future<ToolsConfig> _readScopeKeepingLastGood(
    String path,
    ToolsConfig cached,
    String scopeLabel,
  ) async {
    final (read, error) = await readToolsScopeFile(_env, path);
    if (error != null) {
      io.writeln(
        'tools: $error — $scopeLabel scope ignored, keeping last good',
      );
      return cached;
    }
    return read ?? const ToolsConfig();
  }

  /// The session scope file: `.tools/<sessionId>.yaml` next to the
  /// session's JSONL (the encoded-cwd directory is shared by every session
  /// of a workspace, so the file MUST be keyed by session id — a flat
  /// tools.yaml would leak one session's overrides into every other
  /// session of the same project). Root `tools:` map. An absent session
  /// resets the scope to empty.
  String? _sessionToolsPath() {
    final session = _session;
    if (session == null) return null;
    final metadata = session.cachedMetadata;
    if (metadata == null) return null;
    return '${_dirname(metadata.path)}/.tools/${metadata.id}.yaml';
  }

  Future<ToolsConfig> _readSessionTools() async {
    final path = _sessionToolsPath();
    if (path == null) return _toolsWiring.session = const ToolsConfig();
    return _toolsWiring.session = await _readScopeKeepingLastGood(
      path,
      _toolsWiring.session,
      'session',
    );
  }

  /// Warns once per distinct unknown id (AC5: non-fatal).
  void _warnUnknownToolIds(Set<String> ids) {
    final fresh = ids.difference(_toolsWiring.warnedIds);
    for (final id in fresh) {
      io.writeln('tools: unknown tool id "$id" in tools: config — ignored');
    }
    if (fresh.isNotEmpty) {
      _toolsWiring.warnedIds = {..._toolsWiring.warnedIds, ...fresh};
    }
  }

  /// Swaps the registered `read` tool when the sqlite decision flipped:
  /// same shared snapshot store (hashline anchors recorded by either
  /// variant validate for `edit`), same env, only the description and the
  /// engine change.
  void _swapReadSqliteVariant(ToolAvailabilityResolution resolution) {
    final wantSqlite = resolution.byId['sqlite']?.enabled ?? false;
    final group = _toolGroupsById['read'];
    if (group == null || group.isEmpty) return;
    final hasSqlite = group.first.description.contains(readSqliteSectionPrompt);
    if (wantSqlite == hasSqlite) return;
    final fresh = readFileTool(
      _coreToolEnv,
      snapshots: _snapshotStore,
      model: () => _agent.state.model,
      sqlite: wantSqlite ? config.sqliteEngine : null,
    );
    _toolRegistry.unregister('read');
    _toolRegistry.register(fresh);
    group[0] = fresh;
  }

  /// Re-filters the dynamic MCP surface against [resolution]: disabled
  /// servers get their tools unregistered (and their names noted so the
  /// gate tombstones them), re-enabled servers get their tools registered
  /// straight from the manager — no server restart (AC13).
  void refilterMcpTools(ToolAvailabilityResolution resolution) {
    bool allows(String server) =>
        resolution.mcpServers[server] ??
        (resolution.byId['mcp']?.enabled ?? true);
    _mcp.serverFilter = allows;
    final manager = _mcp.manager;
    if (manager != null) {
      for (final entry in manager.toolsByServer.entries) {
        final names = entry.value.map((tool) => tool.name).toList();
        _toolGate.noteHiddenNames('mcp:${entry.key}', names);
        if (allows(entry.key)) {
          _toolRegistry.registerAll([
            for (final tool in entry.value)
              if (!_toolRegistry.contains(tool.name)) tool,
          ]);
        } else {
          for (final name in names) {
            _toolRegistry.unregister(name);
          }
        }
      }
    }
    _agent.state.tools = _toolRegistry.tools;
    _applyPromptComposition();
  }

  /// `/tools [enable|disable <id> [global|project|session]|reload]`.
  ///
  /// Dispatch only — each branch body lives in its own CC≤2 helper (the
  /// `/skills` pattern).
  Future<void> _toolsSlash(String rest) async {
    final parts = rest
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    final sub = parts.isEmpty ? '' : parts.first;
    switch (sub) {
      case '':
        _toolsList();
      case 'reload':
        await rebuildToolAvailability();
        io.writeln('tools: availability reloaded');
      case 'enable' || 'disable':
        await _toolsToggleSlash(sub == 'enable', parts);
      default:
        io.writeln(
          'unknown /tools subcommand: $sub (try enable, disable, reload)',
        );
    }
  }

  /// The `/tools` listing: one line per known id with its approval tier,
  /// on/off state, deciding scope, and (when off) the reason.
  void _toolsList() {
    final resolution = _toolGate.resolution;
    if (resolution == null) {
      io.writeln('tools: availability still loading — try /tools reload');
      return;
    }
    io.writeln('tool             tier   state scope    reason');
    for (final id in knownToolIds) {
      io.writeln(_toolsListLine(id, resolution.byId[id]!));
    }
  }

  String _toolsListLine(String id, ResolvedToolAvailability availability) {
    final tools = _toolGroupsById[id] ?? const <AgentTool>[];
    final tier = tools.isEmpty ? '-' : tools.first.tier.name;
    return '${id.padRight(16)} ${tier.padRight(6)} '
            '${(availability.enabled ? 'on' : 'off').padRight(5)} '
            '${availability.scope.name.padRight(8)} ${availability.reason ?? ''}'
        .trimRight();
  }

  Future<void> _toolsToggleSlash(bool enable, List<String> parts) async {
    if (parts.length < 2) {
      io.writeln(
        'usage: /tools ${enable ? 'enable' : 'disable'} <id> '
        '[global|project|session]',
      );
      return;
    }
    await _applyToolsToggle(
      enable,
      parts[1],
      parts.length > 2 ? parts[2] : 'project',
    );
  }

  /// Persists the toggle to [scope], then re-resolves availability. A
  /// failed/unwritable target leaves the live state untouched.
  Future<void> _applyToolsToggle(bool enable, String id, String scope) async {
    final persisted = switch (scope) {
      'project' => await _persistProjectTools(id, enable),
      'session' => await _persistSessionTools(id, enable),
      'global' => await _persistGlobalTools(id, enable),
      _ => null,
    };
    if (persisted == null) {
      io.writeln('unknown scope: $scope (try global, project, session)');
      return;
    }
    if (!persisted) return;
    await rebuildToolAvailability();
    io.writeln('tools: ${enable ? 'enabled' : 'disabled'} $id (scope: $scope)');
  }

  Future<bool> _persistProjectTools(String id, bool enabled) {
    return _mergeToolsIntoFile(
      '${_env.cwd}/.fah/config.yaml',
      'project',
      id,
      enabled,
    );
  }

  Future<bool> _persistSessionTools(String id, bool enabled) async {
    final path = _sessionToolsPath();
    if (path == null) {
      io.writeln('tools: no active session — session scope unavailable');
      return false;
    }
    return _mergeToolsIntoFile(path, 'session', id, enabled);
  }

  /// The global scope is host-owned: the CLI updates its live view and the
  /// executable persists it through `onToolsConfigChanged`.
  Future<bool> _persistGlobalTools(String id, bool enabled) async {
    final state = _toolsWiring;
    state.global = ToolsConfig(tools: {...state.global.tools, id: enabled});
    state.globalLoaded = true;
    final hook = config.onToolsConfigChanged;
    if (hook == null) {
      io.writeln(
        'tools: no persistence hook — global change kept for this session',
      );
      return true;
    }
    await hook();
    return true;
  }

  /// Merges `id: enabled` into the `tools:` section of the yaml file at
  /// [path] (surgical top-level block rewrite; other sections survive
  /// byte-for-byte) and writes it back. Prints an error and returns false
  /// — leaving the file untouched — when the file is broken or unwritable.
  Future<bool> _mergeToolsIntoFile(
    String path,
    String scopeLabel,
    String id,
    bool enabled,
  ) async {
    final source = (await _env.readTextFile(path)).valueOrNull;
    var current = const ToolsConfig();
    if (source != null && source.trim().isNotEmpty) {
      final (read, error) = await readToolsScopeFile(_env, path);
      if (error != null) {
        io.writeln('tools: cannot merge $scopeLabel scope — $error');
        return false;
      }
      current = read ?? const ToolsConfig();
    }
    final updated = ToolsConfig(tools: {...current.tools, id: enabled});
    final body = updated.toYaml();
    final next = (source == null || source.trim().isEmpty)
        ? body
        : _replaceTopLevelYamlBlock(source, 'tools', body);
    if (await _env.writeFile(path, '$next\n') is Err) {
      io.writeln('tools: could not write $path');
      return false;
    }
    return true;
  }

  /// The settings-hub row and `/settings` summary label: the live on/off
  /// balance.
  String _toolsStatusLabel() {
    final resolution = _toolGate.resolution;
    if (resolution == null) return 'availability pending';
    final on = resolution.byId.values
        .where((decision) => decision.enabled)
        .length;
    return '$on of ${resolution.byId.length} tools available';
  }

  /// The settings-hub Tools flow: pick a tool, flip it, pick the scope to
  /// persist in (project default) — loops until cancelled or done.
  Future<void> _toolsSettingsFlow() async {
    for (;;) {
      final id = await _pickOption('tools — pick a tool', [
        for (final id in knownToolIds) (id, id, _toolsEntryDetail(id)),
        ('done', 'Done', ''),
      ]);
      if (id == null || id == 'done') return;
      final action = await _pickOption('tools — $id', [
        ('enable', 'Enable', 'offer the tool to the model again'),
        ('disable', 'Disable', 'hide it and tombstone calls'),
      ]);
      if (action == null || action == 'done') return;
      final scope = await _pickOption('tools — $action $id in', [
        ('project', 'Project', '${_env.cwd}/.fah/config.yaml'),
        ('session', 'Session', 'this session only'),
        ('global', 'Global', '~/.fah/config.yaml'),
      ]);
      if (scope == null) return;
      await _applyToolsToggle(action == 'enable', id, scope);
    }
  }

  String _toolsEntryDetail(String id) {
    final decision = _toolGate.resolution?.byId[id];
    if (decision == null) return '';
    return decision.enabled
        ? 'on (${decision.scope.name})'
        : 'off (${decision.reason})';
  }
}
