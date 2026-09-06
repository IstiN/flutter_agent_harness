/// Session management commands split from [AgentCli] to keep agent_cli.dart
/// under the repo's 2800-line size gate. Same library (a `part of`), so the
/// extension sees the class's private members.
part of 'agent_cli.dart';

/// Implementation members of [AgentCli] for named sessions: switching,
/// creating, renaming, listing, and the empty-session cleanup.
extension on AgentCli {
  Future<void> _switchSession(String name) async {
    final trimmed = name.trim();
    await deleteSessionIfEmpty();
    _subagentManager.reset();
    // The status meter belongs to the session (see _switchToMetadata).
    _usage.reset();
    final matches = await _sessionNameMatches(trimmed);
    SessionMetadata? metadata;
    if (matches.length > 1 &&
        [
              for (final m in matches)
                if (m.cwd == _env.cwd) m,
            ].length !=
            1) {
      // Ambiguous: several in this folder or none in it — ask which one
      // (the TUI wizard picker, or a numbered list in line mode). The
      // caller's flow gate buffers an answer typed AHEAD of the prompt
      // instead of dispatching it as a command.
      final options = <FlowOption>[
        for (var i = 0; i < matches.length; i++)
          (
            '$i',
            '${matches[i].cwd} — ${matches[i].id}',
            _sessionMatchDescription(matches[i]),
          ),
      ];
      final picked = await _pickOption(
        "Several sessions named '$trimmed'",
        options,
      );
      if (picked == null) {
        io.writeln('session switch cancelled');
        return;
      }
      metadata = matches[int.parse(picked)];
    } else {
      metadata = _resolveSessionNameMatch(matches);
      if (matches.length > 1 && metadata != null) {
        io.writeln(
          _style.dim(
            "note: ${matches.length} sessions named '$trimmed' — opened "
            'this folder\'s (${metadata.id})',
          ),
        );
      }
    }
    if (metadata != null) {
      await _switchToMetadata(metadata, trimmed);
      return;
    }
    _agent.reset();
    _checkpoints.clear();
    _ttsr?.reset();
    _session = await _createSession(name: trimmed);
    _syncMailboxPrefix();
    _persistedCount = 0;
    io.writeln("created session '$trimmed'");
  }

  /// The `/session <name>` disambiguation row's second line: when the
  /// session was last active.
  String _sessionMatchDescription(SessionMetadata metadata) {
    final stamp = metadata.lastUpdatedAt ?? metadata.createdAt;
    return 'last active ${stamp.toIso8601String()}';
  }

  /// Switches to an existing session by metadata (picker, /resume). Adopts
  /// the session's original working directory so the agent keeps operating
  /// in the project the session belongs to.
  Future<void> _switchToMetadata(SessionMetadata metadata, String label) async {
    await deleteSessionIfEmpty();
    _subagentManager.reset();
    // The status meter belongs to the session: tok/cost/turn must not carry
    // the previous session's totals into the new one.
    _usage.reset();
    _agent.reset();
    _checkpoints.clear();
    _ttsr?.reset();
    _env.cwd = metadata.cwd;
    _modes = builtInAgentModes(_env.cwd, overrides: config.promptOverrides);
    _currentMode = _modes[_currentMode.name] ?? _modes['code']!;
    // Reload skills/project context for the new cwd so the system prompt
    // matches the session's project.
    await _loadAgentContext();
    _session = await _loadSession(metadata);
    _syncMailboxPrefix();
    // Now that `_session` is assigned, the registry source can read the
    // resumed session's `subagent_registry` records.
    unawaited(_subagentManager.rehydrate());
    io.writeln("switched to session '$label' [${_pathBasename(metadata.cwd)}]");
    _replayRestoredHistory(_agent.state.messages, label);
  }

  /// Replays a restored session's transcript into the output so a resume
  /// doesn't look empty: compact per-message rows filling a row budget from
  /// the END (see [buildReplayEntries] — a typical session replays in full,
  /// only marathon ones truncate, and the header says so).
  void _replayRestoredHistory(List<Message> messages, String label) {
    if (messages.isEmpty) return;
    // Below the TUI history cap (2000 lines) so the replay never trims its
    // own head in TUI mode.
    final width = io.columns > 0 ? io.columns : 80;
    final (entries, firstIndex) = buildReplayEntries(
      messages,
      tui: _useTui,
      width: width,
      dim: _style.dim,
    );
    final count = firstIndex > 0
        ? 'last ${messages.length - firstIndex} of ${messages.length}'
        : '${messages.length}';
    io.writeln(_style.dim('─── restored session: $label ($count messages)'));
    for (final entry in entries) {
      for (final line in entry) {
        io.writeln(line);
      }
    }
    io.writeln(_style.dim('─' * 20));
  }

  /// `/resume`: switches to the most recently created session across every
  /// workspace (the repo lists sessions newest-first).
  Future<void> _resumeLastSession() async {
    final sessions = await _repo.list();
    if (sessions.isEmpty) {
      io.writeln('no sessions');
      return;
    }
    final latest = sessions.first;
    final current = await _session?.getMetadata();
    final session = await _repo.open(latest);
    final label = await session.getSessionName() ?? latest.id;
    if (current?.path == latest.path) {
      io.writeln("already on the latest session '$label'");
      return;
    }
    await _switchToMetadata(latest, label);
  }

  Future<void> _renameSession(String name) async {
    final trimmed = name.trim();
    final session = _session;
    if (session == null) {
      io.writeln('no active session');
      return;
    }
    await session.appendSessionName(trimmed);
    io.writeln("renamed current session to '$trimmed'");
  }

  Future<void> _listSessions() async {
    // List every session in the shared root, across workspaces, so sessions
    // created in the Fa app or in another `fa` run are visible here.
    final sessions = await _repo.list();
    if (sessions.isEmpty) {
      io.writeln('no sessions');
      return;
    }
    final current = await _session?.getMetadata();
    io.writeln('sessions:');
    for (var i = 0; i < sessions.length; i++) {
      final metadata = sessions[i];
      final session = await _repo.open(metadata);
      final sessionName = await session.getSessionName();
      final label = sessionName ?? metadata.id;
      final marker = current?.path == metadata.path ? '*' : ' ';
      final folder = _pathBasename(metadata.cwd);
      final folderTag = folder.isEmpty ? '' : ' [$folder]';
      io.writeln(
        '  $marker${i + 1}) $label$folderTag  '
        '${_style.dim(metadata.createdAt.toLocal().toIso8601String())}',
      );
    }
    io.writeln(
      _style.dim('switch: /session <name> · rename: /rename-session <name>'),
    );
  }

  Future<void> _createNamedSession(String name) async {
    final trimmed = name.trim();
    final existing = await _findSessionByName(trimmed);
    if (existing != null) {
      io.writeln("session '$trimmed' already exists");
      return;
    }
    await deleteSessionIfEmpty();
    _subagentManager.reset();
    _agent.reset();
    _checkpoints.clear();
    _ttsr?.reset();
    _session = await _createSession(name: trimmed);
    _syncMailboxPrefix();
    _persistedCount = 0;
    io.writeln("created session '$trimmed'");
  }

  /// `/sessions`: a bare command opens the TUI picker; anything else prints
  /// the session list.
  Future<void> _sessionsSlash(String rest) async {
    if (rest.isEmpty && _useTui && _tuiController != null) {
      await _openSessionsPicker();
    } else {
      await _listSessions();
    }
  }

  /// A `/session-new`-style command requiring a name argument.
  Future<void> _namedSessionSlash(
    String rest,
    String command,
    Future<void> Function(String) action,
  ) async {
    if (rest.trim().isEmpty) {
      io.writeln('usage: /$command <name>');
    } else {
      await action(rest.trim());
    }
  }

  Future<void> _handleSessionCommand(String rest) async {
    final trimmed = rest.trim();
    if (trimmed.isEmpty) {
      final session = _session;
      if (session == null) {
        io.writeln('no active session');
        return;
      }
      final metadata = await session.getMetadata();
      final name = await session.getSessionName();
      io.writeln('session: ${name ?? '(unnamed)'}  ${metadata.path}');
      io.writeln(_style.dim('rename: /rename-session <name>'));
      return;
    }
    // Detached (see _switchSessionGated): the ambiguity picker's answer
    // must reach the pending prompt through the NEXT line dispatch.
    unawaited(_switchSessionGated(trimmed));
  }

  /// The detached switch: runs OUTSIDE the sequential line dispatch so the
  /// ambiguity picker's answer line can be routed to the pending prompt —
  /// awaiting the switch inline would deadlock the line REPL (the dispatch
  /// waits for the switch, the switch waits for the answer only the next
  /// dispatch could deliver — the reason the guided provider flows run
  /// detached too). The gate buffers input for the switch's lifetime; a
  /// second `/session` while one runs is ignored.
  Future<void> _switchSessionGated(String trimmed) {
    if (_providerFlowActive) return Future<void>.value();
    _providerFlowActive = true;
    return _switchSession(trimmed).whenComplete(() {
      _providerFlowActive = false;
      // Lines typed DURING the switch are real input, not flow junk —
      // redispatch them after the switch (in order), never drop them:
      // `/session new` + a prompt typed right after used to lose the
      // prompt to the flow-junk clear.
      final buffered = List<String>.of(_promptLineBuffer);
      _promptLineBuffer.clear();
      // The switch runs outside the dispatch's prompt lifecycle: redraw
      // the idle prompt so the status meter (zeroed by the switch) shows
      // in the transcript like it did when the switch was awaited inline.
      if (!_exited && !isBusy) _writeIdlePrompt();
      for (final line in buffered) {
        if (line.isNotEmpty) unawaited(_dispatchInput(line, line));
      }
    });
  }

  /// Whether nothing was ever said in the session and nothing owns it.
  bool _sessionIsEmpty() =>
      _sessionHasNoContent &&
      _subagentManager.handles.isEmpty &&
      _session != null;

  /// No live messages and no records persisted to disk.
  bool get _sessionHasNoContent =>
      _agent.state.messages.isEmpty && _persistedCount == 0;

  Future<void> _deleteEmptySessionFile() async {
    final session = _session;
    if (session == null) return;
    try {
      await _repo.delete(await session.getMetadata());
      _session = null;
      // The session scope is gone — drop it from the resolution.
      unawaited(AgentCliTools(this).rebuildToolAvailability());
    } on Object {
      // Best-effort cleanup.
    }
  }
}
