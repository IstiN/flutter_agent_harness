part of 'agent_cli.dart';

// Slash-command dispatch: routes a `/command [args]` line to the family
// that owns it (info/basic, model+provider, session switching, mode and
// approval) or to the unknown-command fallback (plugin commands, prompt
// templates, skill aliases, filesystem paths).

/// Slash-command dispatch on [AgentCli].
extension SlashCommandDispatch on AgentCli {
  Future<void> _handleCommand(String trimmed) async {
    final command = trimmed.split(RegExp(r'\s+')).first;
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
    // `/mcp` needs the async [rest == 'reload'] branch, so it is owned here
    // (the basic handler is synchronous); a plain `/mcp` still just prints
    // the status.
    if (command == '/mcp') {
      if (rest == 'reload') {
        await _reloadMcpConfig(this);
      } else {
        _printMcpStatus();
      }
      return true;
    }
    if (_handleInfoCommandBasic(command, rest)) return true;
    if (command == '/skills') {
      await _skillsSlash(rest);
      return true;
    }
    if (command == '/cube') {
      await _handleCubeCommand(rest);
      return true;
    }
    if (command == '/memory') {
      await _handleMemoryCommand(rest);
      return true;
    }
    if (command == '/trajectory') {
      await _handleTrajectoryCommand(rest);
      return true;
    }
    if (command == '/agents') {
      await handleAgentsCommand(rest);
      return true;
    }
    if (command == '/a2a') {
      _printA2aStatus();
      return true;
    }
    return _handleInfoCommandSession(command, rest);
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
    final sub = rest.split(RegExp(r'\s+')).first.trim();
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
    final pluginHandler = _pluginSlashCommands[command];
    if (pluginHandler != null) {
      await pluginHandler(rest.split(RegExp(r'\s+')));
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
    // Unknown slash command: treat it as a filter for the command menu.
    // A string starting with `/` followed by no spaces and containing at
    // least one more `/` is a filesystem path (absolute or `~/...`),
    // never a slash command. When the referenced file EXISTS, the message
    // is sent with the file attached (resolveInteractiveFileReference);
    // a nonexistent path keeps the load hint — it cannot be attached.
    if (trimmed.startsWith('/') && trimmed.length > 1) {
      final looksAbsolutePath =
          RegExp(r'^/[^/\s]*\/').hasMatch(trimmed) || trimmed.startsWith('~/');
      if (looksAbsolutePath) {
        if (resolveInteractiveFileReference(trimmed) != trimmed) {
          _startRun(trimmed);
          return;
        }
        io.writeln(
          'looks like a filesystem path, not a command — '
          'paste the contents (e.g. `cat ${trimmed.split(' ').first}`), '
          'or use `@${trimmed.split(' ').first}` to load it as context.',
        );
        return;
      }
      _printHelp(filter: trimmed.substring(1));
      return;
    }
    io.writeln('unknown command: $command (try /help)');
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
