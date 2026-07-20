/// Multi-session manager: owns several concurrent [Agent] sessions and
/// switches between them without aborting in-flight work.
///
/// The manager keeps one [Agent] per active session, persists each session's
/// transcript via [JsonlSessionRepo], and notifies listeners when the active
/// session changes or a session's state (streaming/idle) flips.
library;

import 'dart:async';

import '../agent/agent.dart';
import '../env/execution_env.dart';
import 'session_repo.dart';
import 'session_storage.dart';
import 'session_tree.dart';

/// One managed session: the [Agent], its persistent [Session], and the
/// metadata that identifies it.
final class ManagedSession {
  /// Creates a managed session.
  ManagedSession({
    required this.id,
    required this.agent,
    required this.session,
  });

  /// Session id (uuidv7).
  final String id;

  /// The agent driving this session.
  final Agent agent;

  /// The persistent session backing this agent's transcript.
  final Session session;

  /// Number of messages already persisted to [session].
  var persistedCount = 0;

  /// Whether the agent is currently streaming.
  bool get isStreaming => agent.state.isStreaming;
}

/// Manages several concurrent agent sessions.
///
/// Shared resources (the execution environment and the session repository)
/// are injected once; per-session resources (the [Agent] and its [Session])
/// are created lazily and kept alive until explicitly closed.
final class AgentSessionManager {
  /// Creates a session manager.
  AgentSessionManager({
    required this.env,
    required this.sessionsRoot,
    JsonlSessionRepo? repo,
  }) : _repo = repo ?? JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot);

  /// The execution environment shared by all sessions.
  final ExecutionEnv env;

  /// Root directory for JSONL sessions.
  final String sessionsRoot;

  final JsonlSessionRepo _repo;

  final Map<String, ManagedSession> _sessions = {};
  String? _activeId;
  final _changes = StreamController<void>.broadcast();

  /// Stream of change notifications (session created/closed/switched/state).
  Stream<void> get changes => _changes.stream;

  /// All managed sessions, newest first.
  List<ManagedSession> get sessions =>
      _sessions.values.toList()..sort((a, b) => b.id.compareTo(a.id));

  /// The active session, if any.
  ManagedSession? get active => _activeId == null ? null : _sessions[_activeId];

  /// The active session id, if any.
  String? get activeId => _activeId;

  /// Creates a new session and makes it active.
  ///
  /// [agentFactory] builds the [Agent] for the new session; the manager owns
  /// it from then on. [metadata] is written to the session header.
  Future<ManagedSession> createSession({
    required Agent Function() agentFactory,
    Map<String, dynamic>? metadata,
  }) async {
    final agent = agentFactory();
    final session = await _repo.create(
      JsonlSessionCreateOptions(
        cwd: agent.state.model.provider,
        metadata: metadata,
      ),
    );
    final id = (await session.getMetadata()).id;
    final managed = ManagedSession(id: id, agent: agent, session: session);
    _sessions[id] = managed;
    _activeId = id;
    _changes.add(null);
    return managed;
  }

  /// Opens an existing session from disk and makes it active.
  Future<ManagedSession> openSession(
    SessionMetadata metadata, {
    required Agent Function() agentFactory,
  }) async {
    final existing = _sessions[metadata.id];
    if (existing != null) {
      _activeId = metadata.id;
      _changes.add(null);
      return existing;
    }
    final agent = agentFactory();
    final session = await _repo.open(metadata);
    final contextMessages = await session.buildContextMessages();
    agent.state.messages = contextMessages;
    final managed = ManagedSession(
      id: metadata.id,
      agent: agent,
      session: session,
    )..persistedCount = contextMessages.length;
    _sessions[metadata.id] = managed;
    _activeId = metadata.id;
    _changes.add(null);
    return managed;
  }

  /// Switches the active session without aborting its run.
  void switchTo(String sessionId) {
    if (!_sessions.containsKey(sessionId)) return;
    if (_activeId == sessionId) return;
    _activeId = sessionId;
    _changes.add(null);
  }

  /// Closes a session: aborts its run (if any), removes it from the manager,
  /// and optionally deletes the session file.
  ///
  /// When the active session is closed, the most recently created remaining
  /// session becomes active, or none if the manager is empty.
  Future<void> closeSession(String sessionId, {bool deleteFile = false}) async {
    final managed = _sessions.remove(sessionId);
    if (managed == null) return;
    managed.agent.abort();
    if (deleteFile) {
      final metadata = await managed.session.getMetadata();
      await _repo.delete(metadata);
    }
    if (_activeId == sessionId) {
      _activeId = _sessions.isEmpty ? null : _sessions.keys.last;
    }
    _changes.add(null);
  }

  /// Persists pending messages of every session (best effort).
  Future<void> persistAll() async {
    for (final managed in _sessions.values) {
      final all = managed.agent.state.messages;
      for (final message in all.skip(managed.persistedCount)) {
        await managed.session.appendMessage(message);
      }
      managed.persistedCount = all.length;
    }
  }
}
