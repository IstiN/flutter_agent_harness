/// Flutter-facing multi-session manager: owns several [AgentService]
/// instances and switches between them without aborting in-flight work.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/agent_service.dart';

/// One managed chat session: the [AgentService] and the session id.
final class FlutterManagedSession {
  /// Creates a managed session.
  FlutterManagedSession({required this.id, required this.service});

  /// Session id (uuidv7).
  final String id;

  /// The agent service driving this session.
  final AgentService service;
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
    notifyListeners();
    return managed;
  }

  /// Adds an existing [AgentService] as a managed session, making it active.
  /// Used in tests where the service is already initialized.
  void addSession(String id, AgentService service) {
    _sessions[id] = FlutterManagedSession(id: id, service: service);
    _activeId = id;
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
      notifyListeners();
      return existing;
    }
    final service = await serviceFactory();
    await service.loadSession(metadata);
    final managed = FlutterManagedSession(id: metadata.id, service: service);
    _sessions[metadata.id] = managed;
    _activeId = metadata.id;
    notifyListeners();
    return managed;
  }

  /// Picks the persisted session to resume at boot, or null to mint a fresh
  /// one. The newest session wins when it was created today (local time) —
  /// a relaunched app continues the day's chat. Older sessions are reused
  /// only while still empty (no user messages), so every relaunch of an
  /// untouched app does not pile up another empty session file.
  Future<SessionMetadata?> findReusableSession() async {
    final List<SessionMetadata> all;
    try {
      all = await _repo.list();
    } on Object {
      // Storage-level failure — boot must not die on it; create fresh.
      return null;
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
      final session = await _repo.open(newest);
      final messages = await session.buildContextMessages();
      return messages.any((m) => m is UserMessage) ? null : newest;
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
    final reusable = await findReusableSession();
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
    }
    if (_activeId == sessionId) {
      _activeId = _sessions.isEmpty ? null : _sessions.keys.last;
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
