/// Flutter-facing multi-session manager: owns several [AgentService]
/// instances and switches between them without aborting in-flight work.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/agent_service.dart';

/// One managed chat session: the [AgentService] and the session id.
final class FlutterManagedSession {
  /// Creates a managed session. [createdAt] defaults to now (fresh session);
  /// disk-opened sessions pass their file-header creation time.
  FlutterManagedSession({
    required this.id,
    required this.service,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Session id (uuidv7).
  final String id;

  /// The agent service driving this session.
  final AgentService service;

  /// When the session was created (drives the date-derived display title).
  final DateTime createdAt;
}

/// Manages several concurrent [AgentService] sessions for the Flutter chat
/// UI. Shared resources (env, repo) are injected once; per-session resources
/// (the [AgentService]) are created lazily.
final class FlutterSessionManager extends ChangeNotifier {
  /// Creates a session manager.
  FlutterSessionManager({
    required this.env,
    required this.sessionsRoot,
    JsonlSessionRepo? repo,
  }) : _repo = repo ?? JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot);

  /// The execution environment shared by all sessions.
  final ExecutionEnv env;

  /// Root directory for JSONL sessions.
  final String sessionsRoot;

  final JsonlSessionRepo _repo;

  final Map<String, FlutterManagedSession> _sessions = {};
  String? _activeId;

  /// File (under [ExecutionEnv.cwd]) remembering the last ACTIVE session id
  /// across restarts — boot resumes the chat the user actually worked in,
  /// not just the newest file (which may be a fresh empty one).
  static const String lastActiveFile = 'last_active_session.json';

  String? _restoredLastActiveId;

  /// Persists [id] as the last active session (fire-and-forget, best effort).
  void _rememberActive(String? id) {
    if (id == null || id == _restoredLastActiveId) return;
    _restoredLastActiveId = id;
    unawaited(
      env
          .writeFile(
            '${env.cwd}/$lastActiveFile',
            '{"version":1,"id":${jsonEncode(id)}}',
          )
          .then((_) {})
          .catchError((Object _) {}),
    );
  }

  /// Reads the persisted last-active session id (null when none/unreadable).
  Future<String?> _readLastActiveId() async {
    try {
      final result = await env.readTextFile('${env.cwd}/$lastActiveFile');
      final raw = result.valueOrNull;
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded['id'] as String? : null;
    } on Object {
      return null;
    }
  }

  /// All managed sessions, newest first.
  List<FlutterManagedSession> get sessions =>
      _sessions.values.toList()..sort((a, b) => b.id.compareTo(a.id));

  /// The active session, if any.
  FlutterManagedSession? get active =>
      _activeId == null ? null : _sessions[_activeId];

  /// The active session id, if any.
  String? get activeId => _activeId;

  /// Whether any session is currently streaming.
  bool get anyStreaming => _sessions.values.any((s) => s.service.isStreaming);

  /// The ids of sessions currently being pre-cached (opened in the
  /// background without switching the active session). Prevents duplicate
  /// speculative loads for the same session.
  final Set<String> _preCaching = {};

  /// Opens a persisted session in the background **without** making it
  /// active. Used for speculative pre-caching of adjacent sessions in the
  /// pager so the user does not see a spinner when swiping to a neighbor.
  ///
  /// Silently skips sessions that are already live or already being
  /// pre-cached. Never throws — a failed pre-cache is a no-op.
  Future<void> preCacheSession(
    SessionMetadata metadata, {
    required AgentConfig config,
    required FutureOr<AgentService> Function() serviceFactory,
  }) async {
    if (_sessions.containsKey(metadata.id)) return;
    if (!_preCaching.add(metadata.id)) return; // already in flight
    try {
      final service = await serviceFactory();
      await service.loadSession(metadata);
      if (_sessions.containsKey(metadata.id)) return; // lost a race
      _sessions[metadata.id] = FlutterManagedSession(
        id: metadata.id,
        service: service,
        createdAt: metadata.createdAt,
      );
      // Do NOT set _activeId or _rememberActive — this is background work.
      notifyListeners();
    } on Object {
      // Pre-cache failure is invisible to the user — they will see a
      // spinner when they actually swipe to this session, same as before.
    } finally {
      _preCaching.remove(metadata.id);
    }
  }

  /// Creates a new session and makes it active.
  Future<FlutterManagedSession> createSession({
    required AgentConfig config,
    required Future<AgentService> Function() serviceFactory,
  }) async {
    final service = await serviceFactory();
    await service.initialize();
    final id = service.currentSessionId;
    if (id == null) {
      throw StateError('AgentService did not initialize a session id');
    }
    final managed = FlutterManagedSession(id: id, service: service);
    _sessions[id] = managed;
    _activeId = id;
    _rememberActive(id);
    notifyListeners();
    return managed;
  }

  /// Adds an existing [AgentService] as a managed session, making it active.
  /// Used in tests where the service is already initialized.
  void addSession(String id, AgentService service) {
    _sessions[id] = FlutterManagedSession(id: id, service: service);
    _activeId = id;
    _rememberActive(id);
    notifyListeners();
  }

  /// Opens an existing session from disk and makes it active.
  Future<FlutterManagedSession> openSession(
    SessionMetadata metadata, {
    required AgentConfig config,
    required FutureOr<AgentService> Function() serviceFactory,
  }) async {
    final existing = _sessions[metadata.id];
    if (existing != null) {
      _activeId = metadata.id;
      _rememberActive(metadata.id);
      notifyListeners();
      return existing;
    }
    final service = await serviceFactory();
    await service.loadSession(metadata);
    final managed = FlutterManagedSession(
      id: metadata.id,
      service: service,
      createdAt: metadata.createdAt,
    );
    _sessions[metadata.id] = managed;
    _activeId = metadata.id;
    _rememberActive(metadata.id);
    notifyListeners();
    return managed;
  }

  /// Picks the persisted session to resume at boot, or null to mint a fresh
  /// one. The newest session wins when it was created today (local time) —
  /// a relaunched app continues the day's chat. Older sessions are reused
  /// only while still empty (no user messages), so every relaunch of an
  /// untouched app does not pile up another empty session file.
  ///
  /// [cachedSessionList] avoids a redundant `_repo.list()` call when the
  /// boot path already fetched the list.
  Future<SessionMetadata?> findReusableSession({
    List<SessionMetadata>? cachedSessionList,
  }) async {
    final List<SessionMetadata> all;
    if (cachedSessionList != null) {
      all = cachedSessionList;
    } else {
      try {
        all = await _repo.list();
      } on Object {
        // Storage-level failure — boot must not die on it; create fresh.
        return null;
      }
    }
    if (all.isEmpty) return null;
    final newest = all.first;
    final created = newest.createdAt.toLocal();
    final now = DateTime.now();
    if (created.year == now.year &&
        created.month == now.month &&
        created.day == now.day) {
      return newest;
    }
    try {
      // Lightweight check: scan raw message records instead of building the
      // full context tree (which is O(n²) for long sessions). We only need
      // to know whether any user message exists.
      final session = await _repo.open(newest);
      final messages = await session.getStorage().findEntries('message');
      final hasUser = messages.any(
        (r) => r is MessageRecord && r.message is UserMessage,
      );
      return hasUser ? null : newest;
    } on Object {
      // Unreadable session file — do not resume it.
      return null;
    }
  }

  /// Boot entry point: resumes the session picked by [findReusableSession]
  /// when there is one, otherwise creates a fresh session.
  Future<FlutterManagedSession> createOrResumeSession({
    required AgentConfig config,
    required Future<AgentService> Function() createFactory,
    required FutureOr<AgentService> Function() openFactory,
  }) async {
    // The last ACTIVE session wins over the newest file: the user may have
    // switched back to an older chat (or a fresh empty session may have been
    // minted after it) — reopen the conversation they actually left.
    final lastActiveId = await _readLastActiveId();
    // Cache the session list once — findReusableSession also needs it,
    // and a redundant _repo.list() scans all session directories.
    List<SessionMetadata>? cachedList;
    if (lastActiveId != null) {
      try {
        cachedList = await _repo.list();
        final metadata = cachedList
            .where((m) => m.id == lastActiveId)
            .firstOrNull;
        if (metadata != null) {
          return await openSession(
            metadata,
            config: config,
            serviceFactory: openFactory,
          );
        }
      } on Object {
        // Unreadable list/load — fall through to the reusable pick.
      }
    }
    final reusable = await findReusableSession(cachedSessionList: cachedList);
    if (reusable != null) {
      try {
        return await openSession(
          reusable,
          config: config,
          serviceFactory: openFactory,
        );
      } on Object {
        // The session failed to load (corrupt file, storage error) — fall
        // through to a fresh session rather than blocking the boot.
      }
    }
    return createSession(config: config, serviceFactory: createFactory);
  }

  /// Switches the active session without aborting its run.
  void switchTo(String sessionId) {
    if (!_sessions.containsKey(sessionId)) return;
    if (_activeId == sessionId) return;
    _activeId = sessionId;
    _rememberActive(sessionId);
    notifyListeners();
  }

  /// Closes a session: aborts its run (if any), removes it from the manager,
  /// and optionally deletes the session file.
  ///
  /// When the active session is closed, the most recently created remaining
  /// session becomes active, or none if the manager is empty.
  Future<void> closeSession(String sessionId, {bool deleteFile = false}) async {
    final managed = _sessions.remove(sessionId);
    if (managed == null) return;
    managed.service.abort();
    if (deleteFile) {
      final metadata = await _repo.list().then(
        (all) => all.firstWhere((m) => m.id == sessionId),
      );
      await _repo.delete(metadata);
    } else {
      // A session nobody wrote to leaves no file behind.
      await managed.service.deleteSessionIfEmpty();
    }
    if (_activeId == sessionId) {
      _activeId = _sessions.isEmpty ? null : _sessions.keys.last;
      _rememberActive(_activeId);
    }
    notifyListeners();
  }

  /// Creates a fresh session when the active one is closed and none remain.
  /// Used by the chat screen to guarantee an active session after deletion.
  Future<void> ensureActiveSession({
    required AgentConfig config,
    required Future<AgentService> Function() serviceFactory,
  }) async {
    if (active != null) return;
    await createSession(config: config, serviceFactory: serviceFactory);
  }

  /// Persists pending messages of every session (best effort).
  Future<void> persistAll() async {
    for (final managed in _sessions.values) {
      await managed.service.waitForIdle();
    }
  }
}
