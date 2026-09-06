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
  '/skills': (cli, rest) async => cli._skillsSlash(rest),
  '/tools': (cli, rest) async => cli._toolsSlash(rest),
  '/cube': (cli, rest) async => cli._handleCubeCommand(rest),
  '/memory': (cli, rest) async => cli._handleMemoryCommand(rest),
  '/redact': (cli, rest) async => cli._handleRedactCommand(rest),
  '/trajectory': (cli, rest) async => cli._handleTrajectoryCommand(rest),
  '/agents': (cli, rest) async => cli.handleAgentsCommand(rest),
  '/browser': (cli, rest) async => cli._browserSlash(rest),
  '/a2a': (cli, rest) async => cli._printA2aStatus(),
  '/ext': (cli, rest) async => cli._extSlash(rest),
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
