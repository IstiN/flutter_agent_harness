/// JS extension wiring for [AgentCli] (issue #32): the background load, the
/// REPL sinks (notes, follow-ups, io), the `/ext` slash family, and the
/// `## JS extensions` prompt section — extracted from `agent_cli.dart` to
/// keep the host under the 2800-line gate.
part of 'agent_cli.dart';

/// Per-instance state of the JS-extension wiring (extensions cannot add
/// fields; [AgentCli] holds exactly this one object).
final class AgentCliExtState {
  /// The live host; null until [AgentCliExt.initJsExtensions] ran (or when
  /// extensions are disabled: no factory or the master switch off).
  JsExtensionHost? host;

  /// Slash commands of the currently ENABLED extensions, keyed WITH the
  /// leading `/`. Consulted after plugin handlers; name conflicts are
  /// prevented at load via reserved names (E4).
  final Map<String, SlashCommand> slashCommands = {};

  /// The cached `## JS extensions` prompt section ('' without extensions);
  /// kept so every recomposition preserves it.
  var promptSection = '';

  /// Whether the one-time "engine unavailable" startup line was printed.
  var engineUnavailableWarned = false;
}

/// Bootstraps, sinks, and the `/ext` surface on [AgentCli].
extension AgentCliExt on AgentCli {
  /// Loads installed JS extensions in the background (fire-and-forget from
  /// the constructor, like MCP boot — never blocks the REPL): build the
  /// store + host, wire the sinks, `loadAll`, register the tool surface +
  /// prompt section, and attach the hooks.
  ///
  /// Attach ORDER matters: the constructor already wrapped approval +
  /// redaction, so [JsExtensionHost.attachHooks] lands OUTERMOST — the JS
  /// hooks run LAST (after redaction) and a Dart-side deny always wins.
  Future<void> initJsExtensions() async {
    final factory = config.extRuntimeFactory;
    if (!config.jsExtensionsEnabled || factory == null) return;
    final host = JsExtensionHost(
      env: _env,
      store: _extStore(),
      runtimeFactory: factory,
      bootstrapJs: config.extBootstrapJs,
      config: ExtHostConfig(
        redact: config.redactionPipeline == null
            ? null
            : (text) => config.redactionPipeline!.redact(text),
      ),
    );
    _ext.host = host;
    host.onLog = (line) => io.writeln('[ext] $line');
    host.onAppendNote = _appendExtNote;
    host.onFollowUp = (text) => _agent.followUp(UserMessage.text(text));
    host.onIoWrite = io.write;
    host.onIoWriteln = io.writeln;
    host.setToolSyncCallbacks(
      syncTools: _syncExtTools,
      rebuildPrompt: _extRefreshSurface,
    );
    final report = await host.loadAll(
      platform: ExtPlatformTag.cli,
      trustPrompt: io.isInteractive ? _extTrustPrompt : null,
      reservedNames: _extReservedNames(),
    );
    _reportExtLoad(report);
    if (host.tools.isNotEmpty) {
      _toolRegistry.registerAll(host.tools);
      _agent.state.tools = _toolRegistry.tools;
    }
    _extRefreshSurface();
    final resolution = _toolGate.resolution;
    if (resolution != null) {
      // Re-apply the availability decision to the fresh ext surface (same
      // path as /tools reload — mirrors _onMcpChanged).
      AgentCliTools(this).refilterMcpTools(resolution);
    }
    host.attachHooks(_agent);
    // v1: fired once after the load completes; extension side effects land
    // through the session bridges (notes append once a session exists).
    await host.sessionStart();
  }

  /// The project + user extension store over the session env.
  ExtensionStore _extStore() => ExtensionStore(
    env: _env,
    projectDir: _env.cwd,
    userDir: config.homeDir ?? _env.cwd,
  );

  /// Every tool/slash name the CLI already owns — `loadAll` fails a later
  /// extension on collision instead of shadowing (E4).
  Set<String> _extReservedNames() => {
    for (final tool in _toolRegistry.tools) tool.name,
    ..._mcp.toolNames,
    for (final name in builtinSlashCommands.keys)
      if (name.startsWith('/')) name.substring(1),
    for (final name in _pluginSlashCommands.keys)
      if (name.startsWith('/')) name.substring(1),
  };

  /// Applies the host's enable/disable tool delta to the registry and the
  /// agent's tool list (the setToolSyncCallbacks seam).
  void _syncExtTools(List<AgentTool> add, List<String> remove) {
    for (final name in remove) {
      _toolRegistry.unregister(name);
    }
    _toolRegistry.registerAll(add);
    _agent.state.tools = _toolRegistry.tools;
  }

  /// Recomputes the ext slash map + prompt section and recomposes the
  /// system prompt. Doubles as the host's rebuildPrompt callback, so
  /// enable/disable keep both derived surfaces fresh.
  void _extRefreshSurface() {
    final host = _ext.host;
    _ext.slashCommands
      ..clear()
      ..addAll({
        for (final entry
            in host?.slashCommands.entries ??
                const <MapEntry<String, SlashCommand>>[])
          '/${entry.key}': entry.value,
      });
    _ext.promptSection = _buildExtPromptSection();
    _applyPromptComposition();
  }

  /// The `## JS extensions` provenance section; '' when nothing is loaded.
  String _buildExtPromptSection() {
    final host = _ext.host;
    if (host == null || !host.hasExtensions) return '';
    final tools = host.toolsByExtension;
    final hooks = host.hooksByExtension;
    return [
      '## JS extensions',
      for (final entry in tools.entries)
        '- ${entry.key}: '
            'tools [${entry.value.join(', ')}]'
            '${_extHookList(hooks[entry.key])}',
    ].join('\n');
  }

  String _extHookList(Set<ExtHookEvent>? events) {
    if (events == null || events.isEmpty) return '';
    return ', hooks [${events.map(extHookEventJson).join(', ')}]';
  }

  /// One line per skip/error; the engine-unavailable case collapses into a
  /// single actionable startup hint (E1).
  void _reportExtLoad(ExtLoadReport report) {
    report.skipped.forEach((name, reason) {
      if (reason.startsWith('engine unavailable')) {
        if (!_ext.engineUnavailableWarned) {
          _ext.engineUnavailableWarned = true;
          io.writeln(
            'js extensions: engine unavailable — install quickjs-ng (qjs) '
            'to enable',
          );
        }
        return;
      }
      io.writeln('ext: skipped $name ($reason)');
    });
    report.errors.forEach((name, error) {
      io.writeln('ext: failed to load $name: $error');
    });
  }

  /// Interactive trust prompt for untrusted extensions; a non-interactive
  /// host never prompts (loadAll tombstone-skips).
  Future<bool> _extTrustPrompt(ExtTrustRequest request) async {
    io.writeln(
      'ext: "${request.name}" is not trusted yet '
      '(${request.source.name}: ${request.sourceRef})',
    );
    for (final line in request.humanSummary()) {
      io.writeln('  $line');
    }
    final answer = await _askLine('trust it for this session? [y/N]: ');
    return answer?.trim().toLowerCase().startsWith('y') ?? false;
  }

  /// `session.appendNote` sink: one displayed ext_note custom record.
  void _appendExtNote(String text) {
    final session = _session;
    if (session == null) {
      io.writeln('[ext] note dropped (no session yet): $text');
      return;
    }
    unawaited(
      session.appendCustomMessageEntry(
        customType: 'ext_note',
        content: text,
        display: true,
      ),
    );
  }

  /// Bounded [JsExtensionHost.sessionEnd] — teardown must never hang on a
  /// stuck extension hook.
  Future<void> _extSessionEndBounded() async {
    final host = _ext.host;
    if (host == null) return;
    try {
      await host.sessionEnd().timeout(const Duration(seconds: 30));
    } on Object catch (error) {
      io.writeln('ext: session end failed: $error');
    }
  }

  // --- /ext ----------------------------------------------------------------

  /// `/ext [list|enable|disable|audit|remove|update|reload]`.
  Future<void> _extSlash(String rest) async {
    final parts = _extSlashParts(rest);
    final sub = parts.isEmpty ? 'list' : parts.first;
    if (await _dispatchExtSub(sub, parts)) return;
    io.writeln(
      'usage: /ext [list|enable <name>|disable <name>|audit <name>|'
      'remove <name>|update <name> [source]|reload]',
    );
  }

  List<String> _extSlashParts(String rest) =>
      rest.split(_commandWhitespace).where((part) => part.isNotEmpty).toList();

  Future<bool> _dispatchExtSub(String sub, List<String> parts) async {
    if (sub == 'list') {
      await _extPrintList();
      return true;
    }
    if (sub == 'reload') {
      await _extReload();
      return true;
    }
    return _dispatchExtArgSub(sub, parts);
  }

  /// The subcommands that take an extension name argument. False when
  /// [sub] is unknown here (or the argument is missing).
  Future<bool> _dispatchExtArgSub(String sub, List<String> parts) async {
    if (parts.length < 2) return false;
    final name = parts[1];
    switch (sub) {
      case 'enable':
        await _extSetEnabled(name, true);
      case 'disable':
        await _extSetEnabled(name, false);
      case 'audit':
        await _extPrintAudit(name);
      case 'remove':
        await _extRemove(name);
      case 'update':
        await _extUpdate(name, parts.length > 2 ? parts[2] : null);
      default:
        return false;
    }
    return true;
  }

  /// The installed-extensions table: name, state, kind, tools, engine,
  /// scope — plus the store's invalid-directory problems.
  Future<void> _extPrintList() async {
    final host = _ext.host;
    final installed = await _extStore().list();
    if (installed.extensions.isEmpty && installed.problems.isEmpty) {
      io.writeln(
        'no JS extensions installed (project: ${_env.cwd}/.fah/js-ext)',
      );
      return;
    }
    final tools = host?.toolsByExtension ?? const <String, List<String>>{};
    final engines = host?.enginesByExtension ?? const <String, String>{};
    final loaded = host?.loadedNames ?? const <String>[];
    io.writeln('JS extensions:');
    for (final problem in installed.problems.entries) {
      io.writeln('  ${problem.key}: invalid (${problem.value})');
    }
    for (final ext in installed.extensions) {
      final String state;
      if (ext.trust == null) {
        state = 'untrusted';
      } else if (loaded.contains(ext.name)) {
        state = tools.containsKey(ext.name) ? 'enabled' : 'disabled';
      } else {
        state = 'not loaded';
      }
      io.writeln(
        '  ${ext.name.padRight(20)} $state  '
        '${extKindJson(ext.manifest.kind)}  '
        'tools: ${tools[ext.name]?.length ?? 0}  '
        'engine: ${engines[ext.name] ?? '-'}  '
        '(${ext.scope.name})',
      );
    }
  }

  /// `/ext enable|disable <name>` — live via the host; the registry sync
  /// and prompt rebuild ride the host's own callbacks.
  Future<void> _extSetEnabled(String name, bool enable) async {
    final host = _ext.host;
    if (host == null) {
      io.writeln('ext: JS extensions are not active');
      return;
    }
    try {
      if (enable) {
        await host.enable(name);
      } else {
        await host.disable(name);
      }
    } on ArgumentError {
      io.writeln('ext: no loaded extension named $name (try /ext list)');
      return;
    }
    io.writeln('ext: ${enable ? 'enabled' : 'disabled'} $name');
  }

  /// `/ext audit <name>` — the trust record plus install provenance.
  Future<void> _extPrintAudit(String name) async {
    final ext = await _extStore().find(name);
    if (ext == null) {
      io.writeln('ext: not installed: $name');
      return;
    }
    io.writeln('name: ${ext.name}');
    io.writeln('version: ${ext.manifest.version}');
    io.writeln('kind: ${extKindJson(ext.manifest.kind)}');
    io.writeln('scope: ${ext.scope.name} (${ext.dir})');
    final trust = ext.trust;
    if (trust == null) {
      io.writeln('trust: none (never granted — will not load)');
      return;
    }
    io.writeln('trust source: ${trust.source.name} (${trust.sourceRef})');
    io.writeln('content sha256: ${trust.contentSha256}');
    io.writeln('granted at: ${trust.grantedAt.toIso8601String()}');
  }

  /// `/ext remove <name>` — live-disable (when loaded) then delete the
  /// stored directory.
  Future<void> _extRemove(String name) async {
    final host = _ext.host;
    if (host != null) {
      try {
        await host.disable(name);
      } on ArgumentError {
        // Not loaded — the removal still applies.
      }
    }
    await _extStore().remove(name);
    _extRefreshSurface();
    io.writeln('ext: removed $name');
  }

  /// `/ext update <name> [source]` — re-plans through the install machinery
  /// (TOFU / capability-diff prompts included). [source] is `gh:owner/repo`,
  /// `catalog:<id>`, or a local path; default: the stored install dir.
  Future<void> _extUpdate(String name, String? source) async {
    final store = _extStore();
    final client = http.Client();
    try {
      final plan = await _extUpdatePlan(name, source, store, client);
      if (plan == null) return;
      if (plan.name != name) {
        io.writeln('ext: source points at "${plan.name}", not "$name"');
        return;
      }
      await _applyExtUpdate(name, plan, store);
    } on Object catch (error) {
      io.writeln('ext: update failed: $error');
    } finally {
      client.close();
    }
  }

  /// The re-install plan for [name] from [source] — stored dir (default or
  /// local path), `gh:owner/repo`, `catalog:<id>`, or a bare local path.
  /// Null after reporting (not installed / source mismatch).
  Future<ExtInstallPlan?> _extUpdatePlan(
    String name,
    String? source,
    ExtensionStore store,
    http.Client client,
  ) async {
    if (source == null || _looksLocal(source)) {
      final installed = await store.find(name);
      if (installed == null) {
        io.writeln('ext: not installed: $name');
        return null;
      }
      return planLocalInstall(source ?? installed.dir, _env);
    }
    return switch (source) {
      _ when source.startsWith('gh:') => planGithubInstall(
        source.substring(3),
        client,
      ),
      _ when source.startsWith('catalog:') => planCatalogInstall(
        source.substring(8),
        baseUrl: kExtCatalogBaseUrl,
        client: client,
      ),
      _ => planLocalInstall(source, _env),
    };
  }

  bool _looksLocal(String source) =>
      source.startsWith('/') || source.startsWith('~');

  /// Applies the plan with the interactive trust prompt when one is
  /// available, then reports the outcome.
  Future<void> _applyExtUpdate(
    String name,
    ExtInstallPlan plan,
    ExtensionStore store,
  ) async {
    final outcome = await applyInstall(
      plan,
      store,
      prompt: io.isInteractive ? _extTrustPrompt : null,
    );
    io.writeln(
      outcome.installed
          ? 'ext: updated $name — /ext reload to load it'
          : 'ext: update skipped: ${outcome.reason}',
    );
  }

  /// `/ext reload` — dispose the live host (unregistering its tools first,
  /// so they are not reserved against the fresh load) and re-run the load.
  Future<void> _extReload() async {
    final previous = _ext.host;
    if (previous != null) {
      _ext.host = null;
      for (final tool in previous.tools) {
        _toolRegistry.unregister(tool.name);
      }
      _agent.state.tools = _toolRegistry.tools;
      await previous.dispose();
    }
    _ext.engineUnavailableWarned = false;
    await initJsExtensions();
  }

  // --- ext provider flows (AC5) ---------------------------------------------

  /// The enabled extensions' provider flows, keyed `'ext:<name>:<id>'`
  /// (registration order). Empty without a host or without flows.
  Map<String, ExtFlowEntry> get _extProviderFlows =>
      _ext.host?.providerFlows ?? const {};

  /// The provider picker's Extension-providers entries: label
  /// `'<title> (ext:<name>)'`, key the namespaced map key. Namespacing IS
  /// the E10 guarantee — a flow key can never equal a catalog or
  /// saved-provider bare id, so nothing can shadow core entries.
  Iterable<MenuItem> _extProviderItems() => [
    for (final MapEntry(key: key, value: flow) in _extProviderFlows.entries)
      MenuItem(
        key: key,
        label: '${flow.flow.title} (ext:${flow.extension})',
        description: flow.flow.description,
      ),
  ];

  /// The `extension providers:` section of the line-mode `/provider`
  /// status. Nothing prints without flows; each row carries the
  /// `/provider <key>` invocation since line mode has no picker.
  void _printExtProviders() {
    final flows = _extProviderFlows;
    if (flows.isEmpty) return;
    io.writeln('extension providers:');
    for (final MapEntry(key: key, value: flow) in flows.entries) {
      final description = flow.flow.description;
      io.writeln(
        '  ${flow.flow.title} (ext:${flow.extension})'
        '${description.isEmpty ? '' : ' — $description'}'
        ' [/provider $key]',
      );
    }
  }

  /// Starts an extension provider flow (`/provider ext:<name>:<id>` or the
  /// picker selection) without awaiting it: the REPL loop must keep
  /// reading lines so the wizard's prompts can be answered — the same
  /// gate pattern as the custom-provider wizard.
  void _startExtProviderFlow(String key) {
    final flow = _extProviderFlows[key];
    if (flow == null) {
      io.writeln('ext: no provider flow $key (/provider lists the keys)');
      return;
    }
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    unawaited(
      _runExtProviderFlow(key, flow).whenComplete(() {
        _providerFlowActive = false;
        // Leftover buffered lines are flow answers, not user prompts.
        _promptLineBuffer.clear();
      }),
    );
  }

  /// The flow wizard: prompts [ExtFlowDef.fields] sequentially through the
  /// shared line prompt (the custom wizard's helper — `secret` fields mask
  /// through the TUI prompt zone and read as plain lines in line mode),
  /// then hands the collected values to the extension's `onSubmit`. The
  /// result persists through the SAME seams the custom wizard uses —
  /// secure store for the key, the custom-provider registry plus
  /// [AgentCliConfig.onProviderChanged] for the entry — the extension
  /// never touches files itself. A cancel (Ctrl-C / empty answer), a null
  /// or empty submit result, or a submit failure persists nothing.
  Future<void> _runExtProviderFlow(String key, ExtFlowEntry flow) async {
    io.writeln('${flow.flow.title} (ext:${flow.extension})');
    final values = <String, String>{};
    for (final field in flow.flow.fields) {
      final answer = await _askLine('${field.label}: ', secret: field.secret);
      if (answer == null || answer.trim().isEmpty) {
        return io.writeln('canceled');
      }
      values[field.name] = answer.trim();
    }
    final Object? result;
    try {
      result = await flow.submit(values);
    } on Object catch (error) {
      // Structured failure: nothing was persisted.
      io.writeln('[ext:${flow.extension}] flow failed: $error');
      return;
    }
    if (result is! Map || result.isEmpty) return io.writeln('canceled');
    final answered = {
      for (final entry in result.entries)
        if (entry.key is String && entry.value != null)
          entry.key as String: '${entry.value}',
    };
    final baseUrl = answered['baseUrl'] ?? '';
    if (baseUrl.isEmpty) return io.writeln('canceled');
    final keyName = await _persistExtFlowKey(baseUrl, answered['apiKey']);
    var providerName = answered['providerName'] ?? '';
    if (providerName.isEmpty) {
      providerName = config.customProviders?.deriveName(baseUrl) ?? 'ext';
    }
    final modelName = answered['modelName'] ?? '';
    await _saveCustomProviderEntry(
      CustomProviderEntry(
        name: providerName,
        apiType: 'openai',
        baseUrl: baseUrl,
        modelId: modelName.isNotEmpty ? modelName : _agent.state.model.id,
        keyName: keyName,
      ),
    );
    io.writeln(
      'ext provider $providerName saved: $baseUrl '
      '(key: ${keyName ?? 'none'})',
    );
  }

  /// The extension flow's key step — the `/key set` persistence path
  /// ([SecureKeyCache.save] plus `onSecretStored`): the key lands under
  /// the host-scoped `FA_KEY_<HOST>` name derived from [baseUrl]. Returns
  /// the name on success, null when keyless or when the store is
  /// unavailable (the entry then carries no key — the custom wizard's
  /// degraded path too).
  Future<String?> _persistExtFlowKey(String baseUrl, String? apiKey) async {
    if (apiKey == null || apiKey.isEmpty) return null;
    final keyName = CustomProviderRegistry.keyNameFor(baseUrl);
    final keys = config.secureKeys;
    if (keys == null || !keys.available || !await keys.save(keyName, apiKey)) {
      io.writeln(
        'could not save the key to the secure store (unavailable, locked, '
        'or managed) — it is not saved with the provider',
      );
      return null;
    }
    config.onSecretStored?.call(keyName, apiKey);
    return keyName;
  }
}
