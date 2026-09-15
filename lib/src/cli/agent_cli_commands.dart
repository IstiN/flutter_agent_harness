part of 'agent_cli.dart';

// Slash-command dispatch: routes a `/command [args]` line to the family
// that owns it (info/basic, model+provider, session switching, mode and
// approval) or to the unknown-command fallback (plugin commands, prompt
// templates, skill aliases, filesystem paths).

/// Whitespace splitter for command lines (hoisted: `_handleCommand` runs
/// per submitted line).
final _commandWhitespace = RegExp(r'\s+');

/// A leading `/word/` or `~/` — the shape of an absolute file path typed at
/// the prompt (hoisted: evaluated per submitted line).
final _leadingPathLike = RegExp(r'^/[^/\s]*\/');

/// The async info-command table: command name → handler. Each entry owns
/// one `/command` arm. `/mcp` lives here too (the basic handler is
/// synchronous and cannot host its async `reload` branch), as does
/// `/browser` (run via the bridge handle, then print).
final _infoCommandHandlers = <String, Future<void> Function(AgentCli, String)>{
  '/mcp': (cli, rest) async => cli._mcpSlash(rest),
  '/queue': (cli, rest) async => cli._queueSlash(rest),
  '/providers': (cli, rest) async => cli._providersSlash(rest),
  '/skills': (cli, rest) async => cli._skillsSlash(rest),
  '/tools': (cli, rest) async => cli._toolsSlash(rest),
  '/cube': (cli, rest) async => cli._handleCubeCommand(rest),
  '/memory': (cli, rest) async => cli._handleMemoryCommand(rest),
  '/redact': (cli, rest) async => cli._handleRedactCommand(rest),
  '/theme': (cli, rest) async => cli._themeSlash(rest),
  '/trajectory': (cli, rest) async => cli._handleTrajectoryCommand(rest),
  '/mail': (cli, rest) async => cli.handleMailCommand(rest),
  '/reply': (cli, rest) async => cli.handleReplyCommand(rest),
  '/agents': (cli, rest) async => cli.handleAgentsCommand(rest),
  '/browser': (cli, rest) async => cli._browserSlash(rest),
  '/a2a': (cli, rest) async => cli._printA2aStatus(),
  '/terminal-setup': (cli, rest) async => cli._printTerminalSetup(),
  '/ext': (cli, rest) async => cli._extSlash(rest),
  '/power': (cli, rest) async => cli._powerSlash(),
};

/// Slash-command dispatch on [AgentCli].
extension SlashCommandDispatch on AgentCli {
  Future<void> _handleCommand(String trimmed) async {
    final command = trimmed.split(_commandWhitespace).first;
    final rest = trimmed.substring(command.length).trim();
    if (await _handleInfoCommand(command, rest)) return;
    if (await _handleModelProviderCommand(command, rest)) return;
    if (await _handleSessionSwitchCommand(command, rest)) return;
    if (await _handleModeCommand(command, rest)) return;
    await _handleUnknownCommand(trimmed, command, rest);
  }

  /// Info commands without a TUI picker variant. Returns whether [command]
  /// was handled.
  Future<bool> _handleInfoCommand(String command, String rest) async {
    if (_handleInfoCommandBasic(command, rest)) return true;
    final handler = _infoCommandHandlers[command];
    if (handler != null) {
      await handler(this, rest);
      return true;
    }
    return _handleInfoCommandSession(command, rest);
  }

  /// The `/mcp` arm: `reload` re-reads the config; a plain `/mcp` just
  /// prints the status.
  Future<void> _mcpSlash(String rest) async {
    if (rest == 'reload') {
      await _reloadMcpConfig(this);
    } else {
      _printMcpStatus();
    }
  }

  /// `/queue [clear]` — clear the TUI composer's queued messages (issue
  /// #275). The queue strip itself is always visible above the composer;
  /// this arm exists so the queue is manageable from line mode too, and
  /// bare `/queue` just points there. Line mode has no queue.
  Future<void> _queueSlash(String rest) async {
    if (rest.trim() != 'clear') {
      io.writeln(
        'Queued messages render above the input while a run streams; '
        '/queue clear empties the queue.',
      );
      return;
    }
    final controller = _tuiController;
    if (controller == null) {
      io.writeln('No interactive TUI session — nothing is queued.');
      return;
    }
    controller.clearQueue();
    io.writeln('Queued messages cleared.');
  }

  /// The `/browser` arm: run the command and print its lines.
  Future<void> _browserSlash(String rest) async {
    List<String> lines;
    try {
      lines = await runBrowserCommand(config.browserBridgeHandle, rest);
    } on Object catch (error) {
      lines = ['bridge: $error'];
    }
    for (final line in lines) {
      io.writeln(line);
    }
  }

  /// The session's sleep-prevention controller (issues #325/#326) — null
  /// when no runner was injected. Exposed so wiring tests can assert the
  /// acquire/release lifecycle without spawning a real helper.
  @visibleForTesting
  PowerAssertionController? get powerAssertionsForTesting => _powerAssertions;

  /// Session-open hook for the sleep-prevention assertion (#326):
  /// acquires only in the explicit `power.hold: session` mode — the
  /// DEFAULT is per-run (see [runPowerAssertionsStarted]), so an idle
  /// agent never pins the machine awake. No-op without an injected
  /// runner (tests, web).
  @visibleForTesting
  Future<void> acquirePowerAssertions() async =>
      await _powerAssertions?.onSessionOpened();

  /// Releases the sleep-prevention assertion (idempotent,
  /// warn-not-crash) — both modes: the per-run mode's safety net for an
  /// exit mid-run, the session mode's regular release.
  @visibleForTesting
  Future<void> releasePowerAssertions() async =>
      await _powerAssertions?.onSessionClosed();

  /// Run-start hook (#326): the per-run hold acquires here, fire-and-
  /// forget — sleep prevention must never delay the first streamed byte.
  @visibleForTesting
  void runPowerAssertionsStarted() => _powerAssertions?.onRunStarted();

  /// Run-settle hook (#326): the per-run hold releases once the run has
  /// fully settled (post-run compaction included).
  @visibleForTesting
  Future<void> runPowerAssertionsSettled() async =>
      await _powerAssertions?.onRunSettled();

  /// `/power`: the configured `power.sleepPrevention` level, the
  /// `power.hold` lifecycle, and whether the assertion is held right
  /// now.
  Future<void> _powerSlash() async {
    final controller = _powerAssertions;
    if (controller == null) {
      io.writeln(
        'sleepPrevention=${config.powerSleepPrevention.value} '
        'hold=${config.powerSleepPreventionHold.value} held=no '
        '(no runner on this host)',
      );
    } else {
      io.writeln(controller.status().toString());
    }
    io.writeln(
      'configure: power.sleepPrevention: off|idle|display|system, '
      'power.hold: per-run|session (~/.fah/config.yaml, defaults '
      'idle + per-run)',
    );
  }

  /// `/exit`, `/help`, `/stats`, `/tasks`.
  bool _handleInfoCommandBasic(String command, String rest) {
    switch (command) {
      case '/exit':
        io.writeln('bye');
        _exited = true;
      case '/help':
        _printHelp(filter: rest);
      case '/stats':
        _printStats();
      case '/tasks':
        _listTaskJobs(rest);
      default:
        return false;
    }
    return true;
  }

  /// `/a2a` — Phase 5a status: per-server connecting/connected/failed.
  void _printA2aStatus() {
    for (final line in formatA2aStatusLines(_a2aManager)) {
      io.writeln(line);
    }
  }

  /// `/terminal-setup` — per-terminal Shift+Enter newline guidance
  /// (issue #36): what already works, what needs a one-line terminal
  /// config, and the fallback keys that work everywhere.
  void _printTerminalSetup() {
    final env = config.envVarValue;
    for (final line in terminalSetupLines(env ?? (name) => null)) {
      io.writeln(line);
    }
  }

  /// `/memory [maintain]` — Phase 2 memory surface: stats by default,
  /// `maintain` runs the consolidation pipeline now.
  Future<void> _handleMemoryCommand(String rest) async {
    final sub = rest.split(_commandWhitespace).first.trim();
    if (sub == 'maintain') {
      await _runMemoryMaintain();
      return;
    }
    await _printMemoryStats();
  }

  /// The `/memory maintain` branch: runs maintenance with the running-guard
  /// feedback.
  Future<void> _runMemoryMaintain() async {
    io.writeln('maintaining memory (levels + consolidation)…');
    final started = await _memory.maintain();
    if (!started) {
      io.writeln('maintenance already running — skipped');
      return;
    }
    io.writeln('memory maintenance complete');
  }

  /// The bare `/memory` branch: entry counts per type + last maintenance.
  Future<void> _printMemoryStats() async {
    for (final line in formatMemoryStatsLines(
      await _memory.list(limit: 500),
      await _memory.lastMaintenanceAt(),
      await _memory.maintenanceDue(),
    )) {
      io.writeln(line);
    }
  }

  /// `/redact [on|off|block on|block off|stats|layers]` — layered secret
  /// redaction status and runtime toggles (issue #24). The logic is the
  /// pure [handleRedactCommand]; this only prints and installs the
  /// returned config.
  Future<void> _handleRedactCommand(String rest) async {
    final outcome = handleRedactCommand(
      config.redactionPipeline,
      rest.split(_commandWhitespace).where((part) => part.isNotEmpty).toList(),
    );
    for (final line in outcome.lines) {
      io.writeln(line);
    }
    final newConfig = outcome.newConfig;
    if (newConfig != null) {
      config.redactionPipeline?.config = newConfig;
    }
  }

  /// `/allow`, `/reset`, `/compact`.
  Future<bool> _handleInfoCommandSession(String command, String rest) async {
    switch (command) {
      case '/allow':
        _handleAllow(rest);
      case '/reset':
        _agent.reset();
        _checkpoints.clear();
        _ttsr?.reset();
        _session = await _createSession();
        _syncMailboxPrefix();
        _persistedCount = 0;
        io.writeln('new session started');
      case '/compact':
        // `/compact` is a manual override — always run the compactor even
        // when the auto-trigger threshold isn't crossed. The user is
        // asking for it explicitly, so we honour the request.
        await _runManualCompact();
      default:
        return false;
    }
    return true;
  }

  /// Model and provider commands. Returns whether [command] was handled.
  Future<bool> _handleModelProviderCommand(String command, String rest) async {
    switch (command) {
      case '/model':
        await _handleModelCommand(rest);
      case '/models':
        await _handleModelsCommand(rest);
      case '/model-edit':
        await _handleModelEdit(rest);
      case '/provider':
      case '/providers':
        await _providerSlash(rest);
      case '/key':
        await _handleKeyCommand(rest);
      default:
        return false;
    }
    return true;
  }

  /// `/provider`: a bare command opens the TUI picker; anything else goes to
  /// the provider command handler.
  Future<void> _providerSlash(String rest) async {
    if (rest.isEmpty && _useTui && _tuiController != null) {
      _openProviderPicker();
    } else {
      await _handleProviderCommand(rest);
    }
  }

  /// Session switching/naming commands. Returns whether [command] was
  /// handled.
  Future<bool> _handleSessionSwitchCommand(String command, String rest) async {
    switch (command) {
      case '/sessions':
        // In the TUI a bare /sessions opens the picker (same as /models);
        // with an argument or in line mode it prints the list.
        await _sessionsSlash(rest);
      case '/session':
        await _handleSessionCommand(rest);
      case '/session-new':
        await _namedSessionSlash(rest, 'session-new', _createNamedSession);
      case '/rename-session':
        await _namedSessionSlash(rest, 'rename-session', _renameSession);
      case '/resume':
        await _resumeLastSession();
      default:
        return false;
    }
    return true;
  }

  /// Mode and approval commands. Returns whether [command] was handled.
  Future<bool> _handleModeCommand(String command, String rest) async {
    switch (command) {
      case '/mode':
        await _modeSlash(rest);
      case '/approval':
        _approvalSlash(rest);
      case '/settings':
        await _settingsSlash(rest);
      case '/code' || '/architect' || '/review':
        await _switchMode(command.substring(1));
      default:
        return false;
    }
    return true;
  }

  /// `/mode`: a bare command opens the TUI picker; anything else goes to the
  /// mode handler.
  Future<void> _modeSlash(String rest) async {
    if (rest.isEmpty && _useTui && _tuiController != null) {
      _openModePicker();
    } else {
      await _handleMode(rest);
    }
  }

  /// `/approval`: a bare command opens the TUI picker; anything else sets
  /// the approval mode.
  void _approvalSlash(String rest) {
    if (rest.isEmpty && _useTui && _tuiController != null) {
      _openApprovalPicker();
    } else {
      _handleApprovalMode(rest);
    }
  }

  /// Anything that is not a builtin command: a plugin slash command, a
  /// prompt template, a menu filter, or simply unknown.
  Future<void> _handleUnknownCommand(
    String trimmed,
    String command,
    String rest,
  ) async {
    final handler =
        _pluginSlashCommands[command] ?? _ext.slashCommands[command];
    if (handler != null) {
      await handler(rest.split(RegExp(r'\s+')));
      return;
    }
    final expanded = expandPromptTemplate(trimmed, _templates);
    if (expanded != trimmed) {
      _startRun(expanded);
      return;
    }
    // Claude/Copilot-style slash alias: `/<skill-name> [args]` invokes the
    // skill directly (user-invocable skills only).
    final alias = _skills
        .where(
          (s) =>
              s.userInvocable &&
              s.name.toLowerCase() == command.substring(1).toLowerCase(),
        )
        .firstOrNull;
    if (alias != null) {
      await _runSkillCommand('${alias.name}${rest.isEmpty ? '' : ' $rest'}');
      return;
    }
    if (trimmed.startsWith('/') && trimmed.length > 1) {
      _handlePathLikeInput(trimmed);
      return;
    }
    io.writeln('unknown command: $command (try /help)');
  }

  /// A string starting with `/` followed by no spaces and containing at
  /// least one more `/` is a filesystem path (absolute or `~/...`), never a
  /// slash command. When the referenced file EXISTS, the message is sent
  /// with the file attached (resolveInteractiveFileReference); a
  /// nonexistent path keeps the load hint — it cannot be attached.
  void _handlePathLikeInput(String trimmed) {
    if (!_leadingPathLike.hasMatch(trimmed) && !trimmed.startsWith('~/')) {
      _printHelp(filter: trimmed.substring(1));
      return;
    }
    if (resolveInteractiveFileReference(trimmed) != trimmed) {
      _startRun(trimmed);
      return;
    }
    io.writeln(
      'looks like a filesystem path, not a command — '
      'paste the contents (e.g. `cat ${trimmed.split(' ').first}`), '
      'or use `@${trimmed.split(' ').first}` to load it as context.',
    );
  }

  Future<void> _handleMode(String rest) async {
    if (rest.isEmpty) {
      io.writeln('mode: ${_currentMode.name}');
      io.writeln('modes: ${(_modes.keys.toList()..sort()).join(', ')}');
      return;
    }
    await _switchMode(rest);
  }
}

/// Builds the session's sleep-prevention controller (issues #325/#326)
/// from the host-injected runner + configured level + hold lifecycle; a
/// null runner (tests, web) means no assertions — power is
/// host-best-effort.
PowerAssertionController? sessionPowerAssertions(
  AgentCliConfig config,
  void Function(String message) onWarn,
) => config.powerRunner == null
    ? null
    : PowerAssertionController(
        runner: config.powerRunner!,
        level: config.powerSleepPrevention,
        hold: config.powerSleepPreventionHold,
        onWarn: onWarn,
      );

extension ProviderQueueEditor on AgentCli {
  /// `/providers` — the provider-queue editor (issue #418). Line mode:
  ///
  ///     /providers                                        queue + health
  ///     /providers queue add <kind> <model> <apiKeyEnv> [baseUrl]
  ///     /providers queue remove <index>
  ///     /providers queue move <from> <to>
  ///     /providers queue test <index>
  ///
  /// Writes go to the PROJECT `.fah/config.yaml` `providersQueue:` section
  /// (surgical upsert, validated with the real parser before the write).
  /// A winning FA_PROVIDERS_QUEUE env scope cannot be rewritten — the
  /// command says so instead of pretending. Edits go live at the next turn
  /// boundary: the runtime is rebuilt from the boot scopes after a write.
  Future<void> _providersSlash(String rest) async {
    final parts = rest.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    final sub = parts.isEmpty || parts.first != 'queue'
        ? ''
        : (parts.length == 1 ? '' : parts[1]);
    switch (sub) {
      case '':
        _printProviderQueue();
      case 'add' when parts.length >= 4:
        await _providerQueueAdd(
          parts[2],
          parts[3],
          parts.length >= 5 ? parts[4] : null,
          parts.length >= 6 ? parts[5] : null,
        );
      case 'remove' when parts.length == 3:
        await _providerQueueEdit(
          (entries) => providerQueueRemoveAt(entries, int.parse(parts[2])),
        );
      case 'move' when parts.length == 4:
        await _providerQueueEdit(
          (entries) => providerQueueMove(
            entries,
            int.parse(parts[2]),
            int.parse(parts[3]),
          ),
        );
      case 'test' when parts.length == 3:
        await _providerQueueTest(int.parse(parts[2]));
      default:
        io.writeln(
          'usage: /providers queue [add <kind> <model> <apiKeyEnv> [baseUrl] | '
          'remove <n> | move <from> <to> | test <n>]',
        );
    }
  }

  /// The live queue with per-entry health badges (current / healthy /
  /// cooldown ETA / dead + lastError).
  void _printProviderQueue() {
    final runtime = config.providersQueueRuntime;
    if (runtime == null) {
      io.writeln(
        'no provider queue set — FA_PROVIDERS_QUEUE env, or `providersQueue:` '
        'in project/user yaml (issue #418)',
      );
      return;
    }
    final state = runtime.state;
    final now = DateTime.now();
    for (var index = 0; index < runtime.entries.length; index++) {
      final entry = runtime.entries[index];
      final badge = index == state.currentIndex
          ? 'current'
          : switch (state.cooldownRemaining(index, now)) {
              null => state.lastError(index) == null ? 'healthy' : 'recovering',
              final left => 'cooldown ${_queueEta(left)}',
            };
      final error = state.lastError(index);
      io.writeln(
        '$index. ${entry.label} [$badge]'
        '${error == null ? '' : ' — ${state.lastErrorKind(index)?.label}: $error'}',
      );
    }
  }

  /// Appends an entry (validated like the parsers) and persists.
  Future<void> _providerQueueAdd(
    String kind,
    String model,
    String? apiKeyEnv,
    String? baseUrl,
  ) async {
    final entry = ProviderQueueEntry(
      providerType: kind,
      model: model,
      apiKeyEnv: apiKeyEnv,
      baseUrl: baseUrl,
    );
    await _providerQueueEdit((entries) => providerQueueAdd(entries, entry));
  }

  /// Runs [edit] on the live entries, persists the new list into the
  /// project config (validated upsert), and rebuilds the runtime — the
  /// edit is live from the next turn.
  Future<void> _providerQueueEdit(
    List<ProviderQueueEntry> Function(List<ProviderQueueEntry>) edit,
  ) async {
    final runtime = config.providersQueueRuntime;
    if (runtime == null) {
      io.writeln('no provider queue to edit — add the first entry first');
      return;
    }
    final List<ProviderQueueEntry> next;
    try {
      next = edit(runtime.entries);
    } on Object catch (error) {
      io.writeln('not applied: $error');
      return;
    }
    final scope = resolveProviderQueueAtBoot(
      projectDir: config.env.cwd,
      homeDir: config.homeDir ?? config.env.cwd,
    );
    if (scope.scope == ProviderQueueScope.env) {
      io.writeln(
        'FA_PROVIDERS_QUEUE env wins over any file queue — edit the env '
        'value or unset it; nothing written',
      );
      return;
    }
    final body = const JsonEncoder.withIndent(
      '  ',
    ).convert([for (final entry in next) entry.toJson()]);
    final path = '${config.env.cwd}/.fah/config.yaml';
    final read = await config.env.readTextFile(path);
    final source = switch (read) {
      Ok(:final value) => value,
      Err(:final error) when error.code == FileErrorCode.notFound => '',
      Err(:final error) => _queueEditFail('cannot read $path: $error'),
    };
    final edited = upsertYamlPath(source, const [
      'providersQueue',
    ], configLeafLines(body, depth: 0));
    // Never persist a file the next boot would reject.
    try {
      parseProviderQueueYaml(loadYaml(edited)['providersQueue'], source: path);
    } on Object catch (error) {
      _queueEditFail('not saved: $error');
      return;
    }
    if (await config.env.writeFile(path, edited) is Err) {
      _queueEditFail('could not write $path');
      return;
    }
    await _rebuildProviderQueueRuntime();
    io.writeln(
      'providersQueue updated (${next.length} entries) → $path — '
      'live from the next turn',
    );
  }

  String _queueEditFail(String message) {
    io.writeln(message);
    return message;
  }

  /// Rebuilds the queue runtime from the boot scopes after an edit so the
  /// next run resolves through the fresh queue (turn-boundary liveness).
  Future<void> _rebuildProviderQueueRuntime() async {
    try {
      final queue = resolveProviderQueueAtBoot(
        projectDir: config.env.cwd,
        homeDir: config.homeDir ?? config.env.cwd,
      );
      config.providersQueueRuntime = queue.entries.isEmpty
          ? null
          : ProviderQueueRuntime.build(
              queue,
              secrets: collectQueueSecrets(
                queue.entries,
                config.secureKeys ?? _secureKeysMissing,
              ),
            );
    } on ConfigException catch (error) {
      io.writeln('queue reload failed: ${error.message}');
    }
  }

  /// No secure store on this host: the env is the only key source (the
  /// chain builder reports missing keys per entry).
  SecureKeyCache get _secureKeysMissing => SecureKeyCache(null);

  /// Runs a one-shot probe against entry [index]: a real minimal request
  /// through the entry's own adapter. Prints the outcome, never advances
  /// the cursor (the probe bypasses the queue state entirely).
  Future<void> _providerQueueTest(int index) async {
    final runtime = config.providersQueueRuntime;
    if (runtime == null || index < 0 || index >= runtime.entries.length) {
      io.writeln('no such queue entry: $index');
      return;
    }
    final entry = runtime.entries[index];
    final secrets = collectQueueSecrets([
      entry,
    ], config.secureKeys ?? _secureKeysMissing);
    try {
      final chain = buildProviderQueueChain([entry], secrets: secrets);
      final probe = chain.single;
      final stream = probe.streamForKey(probe.keyRing.currentCredential.value)(
        probe.model,
        Context(
          messages: [UserMessage.text('ping', timestamp: DateTime.now())],
        ),
      );
      final sw = Stopwatch()..start();
      Object? firstError;
      await for (final event in stream) {
        if (event is TextDeltaEvent || event is DoneEvent) break;
        if (event is ErrorEvent) {
          firstError = event.error.errorMessage;
          break;
        }
      }
      sw.stop();
      if (firstError != null) {
        io.writeln('${entry.label}: FAILED — $firstError');
      } else {
        io.writeln('${entry.label}: ok (${sw.elapsedMilliseconds}ms)');
      }
    } on ConfigException catch (error) {
      io.writeln('${entry.label}: cannot probe — ${error.message}');
    }
  }

  String _queueEta(Duration left) =>
      left.inMinutes >= 1 ? '${left.inMinutes}m' : '${left.inSeconds}s';
}
