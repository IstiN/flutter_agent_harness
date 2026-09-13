// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of agent_service.dart: the session persistence + lifecycle members
// of [AgentService] live here so the main file stays under the 2800-line
// guard. Same library, so private members resolve; notifications go
// through `_notify()` (`notifyListeners` is @protected, callable only
// inside the class).

part of 'agent_service.dart';

extension AgentServiceSessions on AgentService {
  /// Session-correlation env vars injected into bash tool executions (see
  /// [SessionVarsExecutionEnv]). Read live per exec, so a session (re)load
  /// or a provider/model switch is picked up by later commands. Never
  /// secret values — ids, paths, provider kinds, model ids.
  Map<String, String> _sessionEnvVars() => {
    sessionIdEnvVar: ?_sessionId,
    sessionFileEnvVar: ?_sessionFile,
    providerEnvVar: _providerKind,
    modelEnvVar: _agent.state.model.id,
  };

  /// Initializes session persistence — WITHOUT creating an empty JSONL file.
  ///
  /// The session file (and the agent's mailbox address in the messaging
  /// fabric) are materialised lazily on the first [_persist] run; a service
  /// that is initialised but never receives a user message leaves no file
  /// behind. [loadSession] still creates an OS-backed [_session] for the
  /// restored session.
  Future<void> initialize() async {
    // The session FILE materialises lazily on the first persist (an
    // untouched session never hits the disk), but the id is allocated
    // eagerly: hosts (FlutterSessionManager) key sessions by id from the
    // moment the service exists, and the prompt's messaging section needs
    // the real mailbox address before the first message.
    if (_session == null && _sessionId == null) {
      final id = createSessionId();
      _sessionId = id;
      _setMailboxPrefix(id);
    }
    // Compose the system prompt eagerly — messaging address defaults to the
    // host's local id (`main`) until the session materialises (so a brand
    // new, no-message service doesn't crash on prompt render).
    final config = _config;
    if (config != null) {
      _agent.state.systemPrompt = _composeSystemPrompt(config);
    }
    // Best-effort cleanup of legacy empty sessions (no transcript — only the
    // JSONL header). Runs in the background so it never slows startup.
    unawaited(_cleanupLegacyEmptySessions());
    // The watcher only exists with a messaging fabric (production ctor);
    // lightweight test services never start a timer.
    if (_subagentManager != null) _startInboxWatcher();
  }

  /// Removes every legacy empty `.jsonl` (only header) left on disk by the
  /// previous eager session-creation code paths. Idempotent and silently
  /// best-effort.
  Future<void> _cleanupLegacyEmptySessions() async {
    try {
      await _repo.cleanupEmptySessions();
    } on Object {
      // Never propagate — cleanup is best-effort, the next launch will
      // retry.
    }
  }

  /// Materialises the JSONL session file the first time persistence is
  /// required — no-op when the session is already open (e.g. loadSession).
  /// All callers that may produce a transcript ([_persist], subagent
  /// follow-up messages) must go through here.
  Future<void> _materialiseSessionIfNeeded() async {
    if (_session != null) return;
    final session = await _repo.create(
      JsonlSessionCreateOptions(
        cwd: env.sessionCwd,
        // Allocated eagerly in [initialize] — the file adopts it so the
        // id the host already keyed this session by stays stable.
        id: _sessionId,
        metadata: {'agent': 'fa', 'model': _agent.state.model.id},
      ),
    );
    _session = session;
    final sessionMetadata = await session.getMetadata();
    _sessionId = sessionMetadata.id;
    _sessionFile = sessionMetadata.path;
    _sessionCwd = sessionMetadata.cwd;
    _setMailboxPrefix(sessionMetadata.id);
    // Follow external appends (a running fa CLI on the same session).
    _startSessionWatch();
    // The messaging section now carries the real mailbox address.
    final config = _config;
    if (config != null) {
      _agent.state.systemPrompt = _composeSystemPrompt(config);
    }
    // Presence in the messaging fabric once an id is available.
    unawaited(
      _subagentManager?.messaging?.register(
        _subagentManager!.mailboxOf(_subagentManager!.selfId),
      ),
    );
  }

  /// Waits until the agent becomes idle.
  Future<void> waitForIdle() => _agent.waitForIdle();

  /// Clears the in-memory transcript and starts a new session.
  Future<void> reset() async {
    await deleteSessionIfEmpty();
    // Detach the old session so [initialize] allocates a fresh id — the
    // old file (when it has content) stays on disk for the session list.
    _session = null;
    _sessionId = null;
    _sessionFile = null;
    _agent.reset();
    messages.clear();
    await dynamicMessages.forgetAll();
    error = null;
    _persistedCount = 0;
    _historyAboveCount = null;
    _viewBranch = null;
    _historyLoadError = null;
    _loadingHistory = false;
    _trajectory.reset();
    _currentAssistantMessage = null;
    await initialize();
    _notify();
  }

  /// Deletes the session file when nothing was ever said in it: a session
  /// the user never typed into must not litter the session list. Called on
  /// close/reset; best-effort — never throws.
  Future<void> deleteSessionIfEmpty() async {
    if (_agent.state.messages.isNotEmpty) return;
    final session = _session;
    if (session == null) return;
    try {
      await _repo.delete(await session.getMetadata());
      _session = null;
      _sessionId = null;
      _sessionFile = null;
    } on Object {
      // Best-effort cleanup.
    }
  }

  /// Creates a new [AgentService] with the same config and env, for a fresh
  /// session. The clone shares the [env] and the session repository but owns
  /// its own [Agent], transcript, and session persistence.
  AgentService clone() {
    final config = _config;
    if (config == null) {
      throw StateError(
        'Cannot clone an AgentService built from a pre-constructed Agent',
      );
    }
    // Reuse the current stream function so test doubles keep working; a real
    // service would recreate it from the provider kind.
    return AgentService._withEnv(
      env: env,
      config: config,
      sessionsRoot: sessionsRoot,
      redactor: _redactor,
      streamFunction: _agent.streamFunction,
      // Clones inherit the external-watch setting (tests disable it).
      watchExternalSessions: _watchExternalSessions,
      resolveSecretName: _resolveSecretName,
      // Clones share the live secrets env and the Keys store, so a
      // `request_secret` grant in one session is live and persisted for all.
      secretsEnv: _secretsEnv,
      sessionKeys: _sessionKeys,
      taskModelsStore: _taskModelsStore,
      // Clones inherit the CURRENT approval mode (not a fresh disk read) and
      // share the store so their mode changes persist too.
      initialApprovalMode: approval.mode,
      approvalModeStore: _approvalModeStore,
      // Same for the skills-access consent: the live choice + shared store.
      initialSkillsAccess: _skillsAccess,
      skillsAccessStore: _skillsAccessStore,
      // Same for the per-tool availability: the live config + shared store.
      initialToolsConfig: _toolsAvailability.config,
      toolsAvailabilityStore: _toolsAvailabilityStore,
    );
  }

  /// Loads a persisted session into the chat: the agent's context and the
  /// visible transcript are replaced by the session's active branch, and new
  /// messages append to that session. The session's effective model (the
  /// last `model_change` record at the leaf — every provider/model switch
  /// in the CLI and the app appends one) is restored: the DEFAULT chat
  /// model only applies to NEW sessions, not to reopening an old one.
  Future<void> loadSession(SessionMetadata metadata) async {
    abort();
    await waitForIdle();
    // Windowed open (issue #135): header + newest chunk only; older
    // records page in through loadOlderHistory. Small sessions load
    // completely either way. A windowed-open failure (a corrupt tail,
    // an IO hiccup on the ranged-read path) falls back to the FULL
    // open rather than failing the session — the compatibility path
    // (round-4 review); paging surfaces stay null for full-open.
    Session session;
    try {
      session = await _repo.open(metadata, windowed: true);
    } on Object {
      session = await _repo.open(metadata);
    }
    // The count belongs to the session being opened; the background
    // refresh at the end of this method fills it in.
    _historyAboveCount = null;
    _viewBranch = await session.getBranch();
    final context = await session.buildContext();
    final contextMessages = context.messages;
    _agent.reset();
    _agent.state.messages = contextMessages;
    _session = session;
    _sessionId = metadata.id;
    _sessionFile = metadata.path;
    _sessionCwd = metadata.cwd;
    _setMailboxPrefix(metadata.id);
    // Follow external appends (a running fa CLI on the same session).
    _startSessionWatch();
    // The ledger re-projects the active branch (records carry richer
    // structure than the rebuilt message list).
    await _rebuildTrajectory(records: _viewBranch);
    // Restore the session's own model: same wire kind → modelId override;
    // the provider itself stays the configured connection (its key lives
    // in the Keychain, not in the session). An unresolvable or
    // cross-kind mismatch keeps the current model — reopening a session
    // must never hard-fail on this. Works with a config-less service
    // too (pre-constructed agents): the kind check then compares against
    // the agent's live model.
    final config = _config;
    final sessionModel = context.model;
    final activeApi = _agent.state.model.api;
    if (sessionModel != null &&
        sessionModel.modelId.isNotEmpty &&
        sessionModel.modelId != _agent.state.model.id &&
        (config == null
            ? sessionModel.provider == activeApi
            : (sessionModel.provider == config.providerKind ||
                  sessionModel.provider == config.toModel().api))) {
      if (config != null) {
        reconfigure(config.withModelId(sessionModel.modelId));
      } else {
        final model = _agent.state.model;
        _agent.state.model = Model(
          id: sessionModel.modelId,
          name: sessionModel.modelId,
          api: model.api,
          provider: model.provider,
          baseUrl: model.baseUrl,
          reasoning: model.reasoning,
          input: inputModalitiesFor(sessionModel.modelId),
          cost: model.cost,
          contextWindow: model.contextWindow,
          maxTokens: model.maxTokens,
          headers: model.headers,
          compat: model.compat,
        );
      }
      debugPrint(
        '[Fa] session model restored: ${sessionModel.provider}/'
        '${sessionModel.modelId}',
      );
    }
    // The prompt's messaging section carries the live mailbox address.
    final activeConfig = _config;
    if (activeConfig != null) {
      _agent.state.systemPrompt = _composeSystemPrompt(activeConfig);
    }
    unawaited(
      _subagentManager?.messaging?.register(
        _subagentManager!.mailboxOf(_subagentManager!.selfId),
      ),
    );
    _persistedCount = contextMessages.length;
    _currentAssistantMessage = null;
    error = null;
    // Dynamic messages replay (issue #102): materialise the session's
    // widget definitions and splice their transcript markers back into
    // position — the branch walk counts message records, so each marker
    // lands right after the reply that emitted it.
    await dynamicMessages.forgetAll();
    final widgetMarkers = await dynamicMessages.adoptBranch(
      await session.getBranch(),
    );
    final rebuilt = contextMessages.map(AgentService._toChatMessage).toList();
    for (final (index, marker) in widgetMarkers) {
      final at = index > rebuilt.length ? rebuilt.length : index;
      rebuilt.insert(at, marker);
      dynamicMessages.byId(marker.data?.toString() ?? '')?.markerIndex = at;
    }
    messages
      ..clear()
      ..addAll(rebuilt);
    _notify();
    // Background count of the records above the window (newline stream,
    // no decode): fills in the banner count without blocking the load.
    unawaited(_refreshHistoryAbove());
  }

  /// Deletes a persisted session. Deleting the ACTIVE session starts a new
  /// empty one, so the chat never points at a removed file.
  Future<void> deleteSession(SessionMetadata metadata) async {
    final isActive = metadata.id == _sessionId;
    if (isActive) {
      // Stop any in-flight run and let its persistence settle before the
      // session file disappears underneath it.
      abort();
      await waitForIdle();
    }
    await _repo.delete(metadata);
    if (isActive) await reset();
  }
}
