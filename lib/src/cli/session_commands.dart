/// Session management commands split from [AgentCli] to keep agent_cli.dart
/// under the repo's 2800-line size gate. Same library (a `part of`), so the
/// extension sees the class's private members.
part of 'agent_cli.dart';

/// Implementation members of [AgentCli] for named sessions: switching, initializing,
/// creating, loading, renaming, listing, and the empty-session cleanup.
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
    // Re-claim ownership for the new session (#428): free → drive,
    // live lease → viewer (no takeover ever).
    await _releaseSessionLease();
    await _claimSessionLease();
    await _printViewerBannerIfAny();
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
    // Re-claim ownership for the new session (#428): free → drive,
    // live lease → viewer (no takeover ever).
    await _releaseSessionLease();
    await _claimSessionLease();
    await _printViewerBannerIfAny();
    // Now that `_session` is assigned, the registry source can read the
    // resumed session's `subagent_registry` records. Awaited (issue #332):
    // zombie rows settle before the next prompt can spawn children, and no
    // same-id spawn can race the load.
    await _subagentManager.rehydrate();
    io.writeln("switched to session '$label' [${_pathBasename(metadata.cwd)}]");
    _replayRestoredHistory(_agent.state.messages, label);
  }

  /// Replays a restored session's transcript into the output so a resume
  /// doesn't look empty: compact per-message rows filling a row budget from
  /// the END (see [buildReplayEntries] — a typical session replays in full,
  /// only marathon ones truncate, and the header says so).
  void _replayRestoredHistory(List<Message> messages, String label) {
    // Restore the composer's ↑ history from the session's user messages so
    // recall — not viewport scrolling — answers ↑ right after a resume.
    _tuiController?.setInputHistory(restoredInputHistory(messages));
    if (messages.isEmpty) return;
    // Below the TUI history cap (2000 lines) so the replay never trims its
    // own head in TUI mode.
    final width = io.columns > 0 ? io.columns : 80;
    final (entries, firstIndex) = buildReplayEntries(
      messages,
      tui: _useTui,
      width: width,
      dim: _style.dim,
      cwd: _env.cwd,
      home: config.homeDir,
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
    // created in the Fa app or in another `fa` run are visible here. The
    // current folder's sessions lead the list (issue #83). Children render
    // nested under their parent (issue #198).
    final sessions = sortSessionsCurrentFolderFirst(
      await _repo.list(),
      _env.cwd,
    );
    if (sessions.isEmpty) {
      io.writeln('no sessions');
      return;
    }
    io.writeln('sessions:');
    for (final line in formatSessionListLines(
      buildSessionListRows(
        sessions: sessions,
        flat: false,
        names: await sessionDisplayNames(_repo, sessions),
        currentSessionPath: (await _session?.getMetadata())?.path,
      ),
      dim: _style.dim,
    )) {
      io.writeln(line);
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
    // Re-claim ownership for the new session (#428): free → drive,
    // live lease → viewer (no takeover ever).
    await _releaseSessionLease();
    await _claimSessionLease();
    await _printViewerBannerIfAny();
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
        if (line.isNotEmpty) unawaited(_dispatchInput(line, line, const []));
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
      // Issue #522: the journal names this surface; the trash keeps the
      // bytes recoverable; a live owner elsewhere refuses the delete.
      await _repo.delete(
        await session.getMetadata(),
        tool: 'delete_session_if_empty',
      );
      _session = null;
      // The session scope is gone — drop it from the resolution.
      unawaited(AgentCliTools(this).rebuildToolAvailability());
    } on Object {
      // Best-effort cleanup.
    }
  }

  Future<Session> _initializeSession() async {
    final name = config.sessionName?.trim();
    if (name != null && name.isNotEmpty) {
      final matches = await _sessionNameMatches(name);
      final metadata = _resolveSessionNameMatch(
        matches,
        onAmbiguous: (all) {
          // Interactive prompting is impossible this early (the input pump
          // starts after init): auto-resolve and let the TUI offer the
          // scoped picker after boot; line mode gets the printed hint.
          _startupAmbiguousSessions = all;
          _startupAmbiguousName = name;
        },
      );
      if (metadata != null) {
        if (matches.length > 1) {
          io.writeln(
            _style.dim(
              "note: ${matches.length} sessions named '$name' — opened "
              '${metadata.id} (${metadata.cwd}); pick another with '
              '/sessions or restart with fa --session <id>',
            ),
          );
        }
        return _loadSession(metadata);
      }
      return _createSession(name: name);
    }
    return _createSession();
  }

  Future<Session> _createSession({String? name}) async {
    try {
      final session = await _repo.create(
        JsonlSessionCreateOptions(
          cwd: _env.cwd,
          // `agent: cli` marks the owning process — the Fa app's live badge
          // and attach view key off presence, but the metadata tells
          // sessions apart in listings (the app writes 'fa').
          metadata: {'agent': 'cli', 'model': _agent.state.model.id},
        ),
      );
      if (name != null && name.isNotEmpty) {
        await session.appendSessionName(name);
      }
      return session;
    } on SessionException catch (error) {
      final fallbackRoot = '${config.homeDir ?? _env.cwd}/.fah/sessions';
      if (config.sessionRoot != fallbackRoot) {
        try {
          final fallbackRepo = JsonlSessionRepo(
            fs: _env,
            sessionsRoot: fallbackRoot,
          );
          final session = await fallbackRepo.create(
            JsonlSessionCreateOptions(
              cwd: _env.cwd,
              metadata: {'agent': 'cli', 'model': _agent.state.model.id},
            ),
          );
          _repo = fallbackRepo;
          // Storage moved — the mailboxes move with it. Without this the
          // fabric keeps pointing at the failed root: presence/register
          // throws, and an attached app's messages land where this process
          // never looks (the silent-dead-attach bug).
          _fileFabric.swap(
            FileMessagingRepository(
              env: _env,
              root: '$fallbackRoot/${encodeSessionCwd(_env.cwd)}/messages',
              decodeSessionCwd: decodeSessionCwd,
              homeDir: config.homeDir,
            ),
          );
          if (name != null && name.isNotEmpty) {
            await session.appendSessionName(name);
          }
          io.writeln(
            tuiWarning(
              'warning: Failed to create session under ${config.sessionRoot} (${error.message}).\n'
              'Falling back to session storage at $fallbackRoot.\n'
              'To fix permissions for shared macOS sessions, run:\n'
              '  sudo chown -R \$(whoami) ~/Library/"Group Containers"/group.dev.fa1.shared\n'
              '  chmod -R u+rwx ~/Library/"Group Containers"/group.dev.fa1.shared',
            ),
          );
          return session;
        } catch (_) {
          // Fall through to rethrow original error.
        }
      }
      rethrow;
    }
  }

  /// Every session whose id IS [name] (exact id short-circuits — ids are
  /// unique) or whose session_info name equals it, across every workspace
  /// (the exit hint prints `fa --session '<id>'` for unnamed sessions, so
  /// ids must resolve too). Several sessions can share a NAME — different
  /// project folders, or renamed twice — so callers get the full list and
  /// disambiguate (see [_resolveSessionNameMatch]). The id check is pure
  /// metadata — zero file IO; the name scan fans out through the bounded
  /// [JsonlSessionRepo.sessionNamesQuick] pool, so a 300-session store
  /// probes its files in parallel instead of per-file serial (issue
  /// #369).
  Future<List<SessionMetadata>> _sessionNameMatches(String name) async {
    final wanted = name.trim();
    final sessions = await _repo.list();
    for (final metadata in sessions) {
      if (metadata.id == wanted) return [metadata];
    }
    final repo = _repo;
    if (repo is! JsonlSessionRepo) {
      // Foreign repo implementation: no batch API - open per session.
      final matches = <SessionMetadata>[];
      for (final metadata in sessions) {
        final session = await _repo.open(metadata);
        final sessionName = await session.getSessionName();
        if (sessionName != null && sessionName.trim() == wanted) {
          matches.add(metadata);
        }
      }
      return matches;
    }
    final names = await repo.sessionNamesQuick(sessions);
    return [
      for (final metadata in sessions)
        if (names[metadata.id]?.trim() == wanted) metadata,
    ];
  }

  /// Finds a session by display name OR exact id — the first match. Kept
  /// for the rename-conflict check ("the name is taken anywhere").
  Future<SessionMetadata?> _findSessionByName(String name) async {
    final matches = await _sessionNameMatches(name);
    return matches.isEmpty ? null : matches.first;
  }

  /// Disambiguates same-named sessions: the LAUNCH folder's session beats a
  /// namesake from another project (the "fa --session X opens the wrong
  /// folder's session" bug); a clear single local wins silently, anything
  /// else is ambiguous and [onAmbiguous] receives the full match list so
  /// the caller can offer a choice. The fallback pick is the most recently
  /// updated local (or global when the folder has none).
  SessionMetadata? _resolveSessionNameMatch(
    List<SessionMetadata> matches, {
    void Function(List<SessionMetadata> matches)? onAmbiguous,
  }) {
    if (matches.isEmpty) return null;
    if (matches.length == 1) return matches.single;
    final local = [
      for (final m in matches)
        if (m.cwd == _env.cwd) m,
    ];
    if (local.length == 1) return local.single;
    onAmbiguous?.call(matches);
    final pool = local.isNotEmpty ? local : matches;
    pool.sort(
      (a, b) => (b.lastUpdatedAt ?? b.createdAt).compareTo(
        a.lastUpdatedAt ?? a.createdAt,
      ),
    );
    return pool.first;
  }

  /// Offers the startup ambiguity choice: the sessions picker scoped to
  /// the same-named matches. The current session stays the auto-resolved
  /// one; picking another switches, Esc keeps it.
  Future<void> _offerStartupSessionChoice() async {
    final matches = _startupAmbiguousSessions;
    final name = _startupAmbiguousName;
    _startupAmbiguousSessions = null;
    _startupAmbiguousName = null;
    if (matches == null || name == null) return;
    _lastSessionRows = await _sessionPickerRows(matches);
    _tuiController?.openPicker(
      'sessions',
      "Several sessions named '$name' — which one?",
      sessionPickerItems(
        _lastSessionRows!,
        flat: _sessionPickerFlat,
        toggle: false,
      ),
    );
  }

  Future<Session> _loadSession(SessionMetadata metadata) async {
    final session = await _repo.open(metadata);
    final messages = await session.buildContextMessages();
    // Loaded usage anchors are generation-time: post-compaction they
    // phantom-report the pre-compaction size (183k on a 27k branch) and
    // fire a no-op compaction on every resume. Re-anchor at chars/4.
    _agent.state.messages = resetLoadedUsageAnchors(messages);
    _persistedCount = messages.length;
    // Issue #437: persisted-but-unconsumed steering from a crashed
    // session re-enters the queue and wakes the idle agent (E1: one
    // record, consumed once — restart-safe).
    await _queueRecoveredSteering(session);
    // Adopt the session's original project folder. This matters both when
    // switching mid-run and when the CLI starts with --session: tools like
    // bash/read/edit must operate in the session's directory, not the launch
    // directory.
    if (_env.cwd != metadata.cwd) {
      _env.cwd = metadata.cwd;
      _modes = builtInAgentModes(_env.cwd, overrides: config.promptOverrides);
      _currentMode = _modes[_currentMode.name] ?? _modes['code']!;
      await _loadAgentContext();
    }
    // The session may live in a DIFFERENT folder than the launch cwd: the
    // boot applied the launch folder's model memory, so a session opened
    // across folders landed on the wrong provider (user report: a z.ai
    // session reopened as copilot). Re-apply the session folder's saved
    // triple.
    await _applySessionFolderModelState(session);
    return session;
  }

  /// Re-applies the model/provider triple saved for the CURRENT folder
  /// ([loadFolderModelState]) — the runtime twin of the boot restore in
  /// bin/fah.dart. Best-effort: a stale or broken state file keeps the
  /// current model.
  Future<void> _applySessionFolderModelState(Session session) async {
    if (!config.folderModelStateApplies) return;
    final state = await loadFolderModelState(
      _env,
      sessionsRoot: config.sessionRoot,
      cwd: _env.cwd,
    );
    if (state == null) return;
    final current = _agent.state.model;
    if (current.id == state.modelId && current.baseUrl == state.baseUrl) {
      return; // already on this triple (the boot applied this folder)
    }
    final Model built;
    try {
      built = buildCliDefaultModel(
        state.providerKind,
        modelId: state.modelId,
        baseUrl: state.baseUrl,
      );
    } on ConfigException {
      io.writeln(
        _style.dim(
          'note: saved folder model state is stale '
          '(${state.providerKind}) — keeping ${current.id}',
        ),
      );
      return;
    }
    final spec = catalogProvider(built.provider)!;
    final key = _providerKeyFor(spec, built.baseUrl) ?? '';
    _providerKind = state.providerKind;
    _apiKey = key;
    _explicitToken = false;
    _streamFunction = _catalogStreamFunction(state.providerKind, key);
    _agent.streamFunction = _streamFunction;
    _agent.state.model = built;
    // The cached model list belongs to the previous provider/endpoint.
    _modelCache = const [];
    _modelContextWindows = const {};
    _modelMaxTokens = const {};
    _lastModelList = null;
    unawaited(_refreshModelCache());
    await session.appendModelChange(
      provider: built.provider,
      modelId: built.id,
    );
    io.writeln(
      _style.dim('restored ${built.id} (${built.provider}) from this folder'),
    );
  }

  /// The label for a startup-resumed session's replay header, or null when
  /// this run started a fresh session (no messages to replay).
  Future<String?> _resumedSessionLabel() async {
    if (_agent.state.messages.isEmpty) return null;
    final session = _session;
    if (session == null) return null;
    return await session.getSessionName() ?? (await session.getMetadata()).id;
  }
}
