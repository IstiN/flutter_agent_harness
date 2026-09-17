/// Flutter-facing multi-session manager: owns several [AgentService]
/// instances and switches between them without aborting in-flight work.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/session_parse_factory.dart';
import 'package:fa/services/session_listing.dart';
import 'package:fa/services/sessions_root.dart';
import 'package:fa/services/subagent_parent_resolver.dart';

/// One managed chat session: the [AgentService] and the session id.
final class FlutterManagedSession {
  /// Creates a managed session. [createdAt] defaults to now (fresh session);
  /// disk-opened sessions pass their file-header creation time.
  FlutterManagedSession({
    required this.id,
    required this.service,
    DateTime? createdAt,
    DateTime? lastUpdatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       lastUpdatedAt = lastUpdatedAt ?? createdAt ?? DateTime.now();

  /// Session id (uuidv7).
  final String id;

  /// The agent service driving this session.
  final AgentService service;

  /// When the session was created (drives the date-derived display title).
  final DateTime createdAt;

  /// When the session was last modified on disk. For live sessions this is
  /// captured from [SessionMetadata] on open, or [createdAt] for fresh ones.
  final DateTime lastUpdatedAt;
}

/// Manages several concurrent [AgentService] sessions for the Flutter chat
/// UI. Shared resources (env, repo) are injected once; per-session resources
/// (the [AgentService]) are created lazily.
///
/// The load budget ([maxSessionLoadBytes], issue #381) is the instant-open
/// ceiling: sessions over it open through the windowed loader (tail window
/// + paged history) and boot never auto-resumes them — the typed
/// [SessionTooLargeException] survives only as the guard on the one path
/// that would still whole-file read them: a failed windowed open degrading
/// to a FULL open (the 2026-09-10 macOS freeze mode).
final class SessionTooLargeException implements Exception {
  /// Creates the exception.
  SessionTooLargeException(this.metadata, this.limitBytes);

  /// The refused session.
  final SessionMetadata metadata;

  /// The configured load budget in bytes.
  final int limitBytes;

  @override
  String toString() =>
      'Session ${metadata.id} is too large to load '
      '(${metadata.sizeBytes} bytes > $limitBytes limit)';
}

/// Opening this session for DRIVE was refused: another host holds a
/// live ownership lease (#428). No takeover exists — the app opens the
/// session as a VIEWER (attach path) and the composer mails the owner.
final class SessionDrivenElsewhereException implements Exception {
  /// Creates the exception.
  SessionDrivenElsewhereException(this.lease);

  /// The owner's live lease (banner material).
  final SessionLease lease;

  /// Who drives, human-labeled: `fa CLI (pid 85634)`.
  String get ownerLabel => leaseOwnerLabel(lease.host);

  @override
  String toString() =>
      'Session ${lease.sessionId} is driven by $ownerLabel '
      '(pid ${lease.pid})';
}

final class FlutterSessionManager extends ChangeNotifier {
  /// Creates a session manager.
  FlutterSessionManager({
    required this.env,
    required this.sessionsRoot,
    JsonlSessionRepo? repo,
    this.maxSessionLoadBytes = defaultMaxSessionLoadBytes,
    this.leaseStore,
    SubagentParentResolver? parentResolver,
  }) : _repo =
           repo ??
           // Issue #199: record parsing rides background isolates on IO
           // platforms (null = inline chunked parsing on web).
           JsonlSessionRepo(
             fs: env,
             sessionsRoot: sessionsRoot,
             parseExecutor: createSessionParseExecutor(),
             // Issue #522: the deletion gate reads the shared live-session
             // heartbeats — sidebar deletes refuse sessions a CLI owns.
             presenceStore: FileSessionPresenceStore(
               env: env,
               root: sessionsRoot,
             ),
           ),
       _parentResolver = parentResolver ?? SubagentParentResolver();

  /// The default per-session load budget (64 MiB): beyond it the session
  /// file would balloon to many times its size as Dart objects and wedge a
  /// host in a GC storm. Over-budget sessions still OPEN — windowed, only
  /// the tail chunk materializes (issue #381) — but boot never resumes
  /// them and a failed windowed open is refused instead of falling back
  /// to the whole-file load.
  static const int defaultMaxSessionLoadBytes = 64 * 1024 * 1024;

  /// The execution environment shared by all sessions.
  final ExecutionEnv env;

  /// Root directory for JSONL sessions.
  final String sessionsRoot;

  /// The instant-open budget: sessions whose file exceeds this many bytes
  /// are never auto-resumed at boot (a one-shot notice says why) and their
  /// [openSession] refuses the full-open fallback of a failed windowed
  /// open with [SessionTooLargeException].
  final int maxSessionLoadBytes;

  /// The ownership-lease store (from the shared env); null disables
  /// enforcement (tests, web) — the app then behaves exactly as before.
  final FileSessionLeaseStore? leaseStore;

  /// The sidecar path of the lease this manager holds, if driving leased.
  String? _heldLeasePath;

  /// Heartbeat keeping our lease live while a managed session is open.
  Timer? _leaseTimer;

  /// Per-manager lease identity (E3): pid recycling cannot impersonate a
  /// dead owner because this differs per app launch.
  late final String _leaseBootId = FileSessionLeaseStore.newBootId();

  /// True when [metadata]'s file is over the load budget (unknown size is
  /// allowed — only paths that know the size can guard).
  bool _tooLarge(SessionMetadata metadata) =>
      (metadata.sizeBytes ?? 0) > maxSessionLoadBytes;

  /// The last-active session boot skipped for size (issue #381), or null.
  /// The shells surface it once as a notice — a fresh session plus a
  /// tap-to-open-windowed action — instead of the old silent swap.
  SessionMetadata? bootSkippedOversize;

  final JsonlSessionRepo _repo;

  /// Re-links legacy child sessions (header `parent: ""`) to their parents
  /// via the parent transcripts' subagent_registry records (issue #426).
  /// Injectable so tests can pin the tail budget.
  final SubagentParentResolver _parentResolver;

  final Map<String, FlutterManagedSession> _sessions = {};
  String? _activeId;

  /// The service worker's live session id on hosted surfaces (the browser
  /// extension) — THE single source of truth for "which session am I in"
  /// for every session UI (wide sidebar, narrow drawer). The manager slot
  /// and per-surface pending hacks all settle against this. Null on local
  /// surfaces (desktop/mobile), where [activeId] stays authoritative.
  final ValueNotifier<String?> hostedLiveId = ValueNotifier<String?>(null);

  /// File (under [ExecutionEnv.cwd]) remembering the last ACTIVE session id
  /// across restarts — boot resumes the chat the user actually worked in,
  /// not just the newest file (which may be a fresh empty one).
  static const String lastActiveFile = 'last_active_session.json';

  String? _restoredLastActiveId;

  /// Path to the global last-active marker, kept inside the shared sessions
  /// root so it survives app-container restarts.
  String get _lastActivePath => '$sessionsRoot/$lastActiveFile';

  /// Persists [id] as the last active session (fire-and-forget, best effort).
  void _rememberActive(String? id) {
    if (id == null || id == _restoredLastActiveId) return;
    _restoredLastActiveId = id;
    unawaited(
      env
          .writeFile(_lastActivePath, '{"version":1,"id":${jsonEncode(id)}}')
          .then((_) {})
          .catchError((Object _) {}),
    );
  }

  /// Reads the persisted last-active session id (null when none/unreadable).
  Future<String?> _readLastActiveId() async {
    try {
      final result = await env.readTextFile(_lastActivePath);
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

  /// Every session persisted on disk, newest first (live ones included).
  /// Storage failures yield an empty list — a broken sessions dir must not
  /// break the sidebar listing.
  ///
  /// Hosted sessions (extension panel / app tab, the active service is a
  /// relay): the session files live in the SERVICE WORKER's filesystem —
  /// the page-local repo sees an empty tree and the sidebar collapsed to
  /// a single row. The relay service's [AgentService.listSessions]
  /// (sessions_query) is the authority there.
  Future<List<SessionMetadata>> listPersistedSessions() async {
    final active = this.active?.service;
    if (_isHostedListing(active)) {
      return _listViaHostService(active!);
    }
    try {
      final listed = await _listAcrossRoots();
      // Issue #426: legacy child files carry `parent: ""` (both hosts
      // pinned the subagent manager's parentSessionId before the session
      // id existed). Re-link them from the parent transcripts'
      // subagent_registry records — bounded + cached, so a listing with
      // nothing to resolve costs nothing.
      final relinked = await _parentResolver.resolve(listed);
      if (relinked.isEmpty) return listed;
      return relinkSubagentParents(listed, relinked);
    } on Object {
      return const [];
    }
  }

  /// Hosted sessions (extension panel / app tab): the session files live
  /// in the SERVICE WORKER's filesystem — the page-local repo sees an
  /// empty tree and the sidebar collapses to a single row. The relay
  /// service's [AgentService.listSessions] (sessions_query) is the
  /// authority there.
  Future<List<SessionMetadata>> _listViaHostService(
    AgentService active,
  ) async {
    try {
      return await active.listSessions();
    } on Object {
      return const [];
    }
  }

  /// The local listing: the default repo, or a merge across every session
  /// root (macOS App Group + fallback) when more than one exists.
  Future<List<SessionMetadata>> _listAcrossRoots() {
    final roots = allSessionRoots(sessionsRoot);
    if (roots.length <= 1) return _repo.list();
    return mergeSessionsAcrossRoots(
      roots: roots,
      listRoot: (root) async => root == sessionsRoot
          ? _repo.list()
          : JsonlSessionRepo(fs: env, sessionsRoot: root).list(),
    );
  }

  /// Whether the ACTIVE service is a hosted relay whose listing replaces
  /// the local repo's view.
  bool _isHostedListing(AgentService? active) =>
      active != null && active.liveSessionId != null;

  /// The active session, if any.
  FlutterManagedSession? get active =>
      _activeId == null ? null : _sessions[_activeId];

  /// The `session_info` display names of [sessions], keyed by session id —
  /// the names the CLI writes with `/rename` straight into the session
  /// JSONL. Best-effort: a session that fails to open contributes no name
  /// (its tile falls back to the derived title).
  Future<Map<String, String>> readSessionNames(
    List<SessionMetadata> sessions,
  ) async {
    // Bounded fan-out lives on the repo (issue #199 AC3): quick tail
    // scans, 16 at a time; results key by metadata.id.
    return _repo.sessionNamesQuick(sessions);
  }

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
    if (!_preCacheAdmitted(metadata)) return;
    try {
      final service = await serviceFactory();
      await service.loadSession(metadata);
      _installPreCached(metadata, service);
    } on Object {
      // Pre-cache failure is invisible to the user — they will see a
      // spinner when they actually swipe to this session, same as before.
    } finally {
      _preCaching.remove(metadata.id);
    }
  }

  /// The three early-exit guards: already managed, over the load budget
  /// (a speculative background open of a giant must not run — its
  /// windowed failure would degrade to the full-open fallback, the
  /// heap-storm path), already in flight. Admitting claims the
  /// in-flight slot.
  bool _preCacheAdmitted(SessionMetadata metadata) {
    if (_sessions.containsKey(metadata.id)) return false;
    if (_tooLarge(metadata)) return false;
    return _preCaching.add(metadata.id);
  }

  /// Installs a successfully pre-cached service as a managed session.
  /// Does NOT set _activeId or _rememberActive — this is background work.
  void _installPreCached(SessionMetadata metadata, AgentService service) {
    if (_sessions.containsKey(metadata.id)) return; // lost a race
    _sessions[metadata.id] = FlutterManagedSession(
      id: metadata.id,
      service: service,
      createdAt: metadata.createdAt,
      lastUpdatedAt: metadata.lastUpdatedAt ?? metadata.createdAt,
    );
    notifyListeners();
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
    try {
      final metadata = (await _repo.list())
          .where((m) => m.id == id)
          .firstOrNull;
      if (metadata != null) await _acquireDriveLease(metadata);
    } on Object {
      // Lease lookup must never block session creation (fail-open).
    }
    final now = DateTime.now();
    final managed = FlutterManagedSession(
      id: id,
      service: service,
      createdAt: now,
      lastUpdatedAt: now,
    );
    _sessions[id] = managed;
    _activeId = id;
    _rememberActive(id);
    notifyListeners();
    return managed;
  }

  /// Adds an existing [AgentService] as a managed session, making it active.
  /// Used in tests where the service is already initialized. [createdAt]
  /// pins the tile subtitle (goldens need deterministic timestamps).
  void addSession(
    String id,
    AgentService service, {
    DateTime? createdAt,
    DateTime? lastUpdatedAt,
  }) {
    _sessions[id] = FlutterManagedSession(
      id: id,
      service: service,
      createdAt: createdAt,
      lastUpdatedAt: lastUpdatedAt,
    );
    _activeId = id;
    _rememberActive(id);
    notifyListeners();
  }

  /// Re-keys the ACTIVE session slot to [newId] — the hosted equivalent
  /// of a session switch. The relay service adopts the SW's live session
  /// id on every session_new/session_open (from ANY surface, via the
  /// attach broadcast); without a re-key the manager slot keeps its boot
  /// id and every active-dot/tile label in the UI points at a session
  /// that is no longer live.
  void rekeyActiveSession(String newId, {DateTime? createdAt}) {
    final activeSlot = active;
    if (activeSlot == null) return;
    final oldId = activeSlot.id;
    if (oldId == newId) {
      // Same session — still refresh the stamp: the tile shows a time
      // label that would otherwise stay pinned to the slot's boot time.
      return;
    }
    _sessions.remove(oldId);
    _sessions[newId] = FlutterManagedSession(
      id: newId,
      service: activeSlot.service,
      createdAt: createdAt,
    );
    _activeId = newId;
    _rememberActive(newId);
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
      debugPrint(
        '[fah][sessions] open ${metadata.id}: slot already loaded — '
        'activating',
      );
      _activeId = metadata.id;
      _rememberActive(metadata.id);
      notifyListeners();
      return existing;
    }
    debugPrint(
      '[fah][sessions] open ${metadata.id}: not in memory — loading from '
      'disk (${_sessions.length} loaded)',
    );
    // Issue #381: over-budget sessions route through the WINDOWED open —
    // the old refuse-gate sat in front of a loader that only materializes
    // the tail window. The full-open fallback is refused for them: a
    // windowed failure there would degrade to a whole-file read of
    // exactly the file the budget exists for — SessionTooLargeException
    // is that fallback's guard, nothing else.
    final oversized = _tooLarge(metadata);
    // Ownership lease (#428): a live lease means another host is
    // DRIVING this session — refuse before any second writer exists.
    await _acquireDriveLease(metadata);
    final service = await serviceFactory();
    try {
      await service.loadSession(metadata, allowFullOpenFallback: !oversized);
    } on Object catch (error) {
      if (!oversized) rethrow;
      debugPrint(
        '[fah][sessions] open ${metadata.id}: windowed open failed '
        '($error) — over the $maxSessionLoadBytes-byte budget, '
        'REFUSING the full open',
      );
      throw SessionTooLargeException(metadata, maxSessionLoadBytes);
    }
    final managed = FlutterManagedSession(
      id: metadata.id,
      service: service,
      createdAt: metadata.createdAt,
      lastUpdatedAt: metadata.lastUpdatedAt ?? metadata.createdAt,
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
  /// Issue #199: the boot FULL open is gone — the user-message scan runs
  /// over a windowed open (newest chunk only), and an oversized file is
  /// refused without reading it at all. Decision semantics are unchanged.
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
    if (_tooLarge(newest)) return null;
    Future<bool> hasUserMessages(SessionStorage storage) async {
      final messages = await storage.findEntries('message');
      return messages.any(
        (r) => r is MessageRecord && r.message is UserMessage,
      );
    }

    try {
      final storage = (await _repo.open(newest, windowed: true)).getStorage();
      if (await hasUserMessages(storage)) return null;
      return newest;
    } on Object {
      // Windowed open failed (corrupt tail, IO hiccup) — fall back to the
      // legacy full open, matching loadSession's compatibility path.
      try {
        if (await hasUserMessages((await _repo.open(newest)).getStorage())) {
          return null;
        }
        return newest;
      } on Object {
        // Unreadable session file — do not resume it.
        return null;
      }
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
          if (_tooLarge(metadata)) {
            bootSkippedOversize = metadata;
            debugPrint(
              '[fah][sessions] boot: last active $lastActiveId is '
              '${metadata.sizeBytes} bytes — over the '
              '$maxSessionLoadBytes-byte load budget, NOT resuming. '
              'Starting fresh; the UI surfaces a notice to open it '
              'windowed.',
            );
            // Fall through to the reusable pick below.
          } else {
            debugPrint(
              '[fah][sessions] boot: resuming last active '
              '$lastActiveId (${cachedList.length} persisted)',
            );
            return await openSession(
              metadata,
              config: config,
              serviceFactory: openFactory,
            );
          }
        }
        debugPrint(
          '[fah][sessions] boot: last active $lastActiveId is gone '
          '(${cachedList.length} persisted) — picking reusable',
        );
      } on Object catch (error) {
        // Unreadable list/load — fall through to the reusable pick.
        debugPrint(
          '[fah][sessions] boot: last active $lastActiveId failed to '
          'list/load ($error) — picking reusable',
        );
      }
    } else {
      debugPrint(
        '[fah][sessions] boot: no last-active marker — picking reusable',
      );
    }
    final reusable = await findReusableSession(cachedSessionList: cachedList);
    if (reusable != null) {
      if (_tooLarge(reusable)) {
        debugPrint(
          '[fah][sessions] boot: reusable pick ${reusable.id} is '
          '${reusable.sizeBytes} bytes — over the load budget, creating '
          'a fresh session',
        );
      } else {
        debugPrint(
          '[fah][sessions] boot: reusable pick ${reusable.id} '
          '(created ${reusable.createdAt.toLocal()})',
        );
        try {
          return await openSession(
            reusable,
            config: config,
            serviceFactory: openFactory,
          );
        } on Object catch (error) {
          // The session failed to load (corrupt file, storage error) — fall
          // through to a fresh session rather than blocking the boot.
          debugPrint(
            '[fah][sessions] boot: reusable pick ${reusable.id} failed to '
            'load ($error) — creating a fresh session',
          );
        }
      }
    } else {
      debugPrint(
        '[fah][sessions] boot: no reusable session '
        '(${cachedList?.length ?? 'n/a'} persisted) — creating fresh',
      );
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
  /// Claims the ownership lease for a DRIVE-open of [metadata] (#428).
  /// A live lease throws [SessionDrivenElsewhereException] — no takeover
  /// exists; the caller opens the session as a viewer instead. Free or
  /// expired: acquired (a dead owner is only noted in the sidecar
  /// history). Lease IO failures never block opening (fail-open, E4).
  Future<void> _acquireDriveLease(SessionMetadata metadata) async {
    final store = leaseStore;
    if (store == null) return;
    final result = await store.acquire(
      sessionFilePath: metadata.path,
      sessionId: metadata.id,
      host: 'app',
      bootId: _leaseBootId,
      pid: 0,
    );
    switch (result) {
      case LeaseAcquired():
        _heldLeasePath = store.sidecarPath(metadata.path);
        _startLeaseHeartbeat();
      case LeaseBlocked():
        throw SessionDrivenElsewhereException(result.lease);
      case LeaseUnenforced():
        break;
    }
  }

  /// Keeps our lease live while the managed session is open (5s cadence,
  /// inside the 15s staleness window).
  void _startLeaseHeartbeat() {
    _leaseTimer?.cancel();
    _leaseTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final path = _heldLeasePath;
      final store = leaseStore;
      if (path == null || store == null) return;
      unawaited(store.heartbeat(path, _leaseBootId));
    });
  }

  /// Releases OUR lease (graceful close) and stops the heartbeat.
  void _releaseDriveLease() {
    _leaseTimer?.cancel();
    _leaseTimer = null;
    final path = _heldLeasePath;
    _heldLeasePath = null;
    final store = leaseStore;
    if (path != null && store != null) {
      unawaited(store.release(path, _leaseBootId));
    }
  }

  /// session becomes active, or none if the manager is empty.
  Future<void> closeSession(String sessionId, {bool deleteFile = false}) async {
    final managed = _sessions.remove(sessionId);
    if (managed == null) return;
    if (_heldLeasePath != null) _releaseDriveLease();
    managed.service.abort();
    if (deleteFile) {
      final metadata = (await _repo.list())
          .where((m) => m.id == sessionId)
          .firstOrNull;
      // A session deleted from another surface (or a file cleaned up
      // under us) must not crash the close — the manager forgets it
      // either way.
      if (metadata != null) {
        await _repo.delete(metadata, actor: 'app:close');
      }
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

  /// Deletes a session outright: a live one is closed (aborting any run)
  /// with its file removed; a persisted-only one ([metadata]) is deleted
  /// straight from the repo. Powers the sidebar tile menu.
  Future<void> deleteSession(String id, {SessionMetadata? metadata}) async {
    if (_sessions.containsKey(id)) {
      await closeSession(id, deleteFile: true);
      return;
    }
    final SessionMetadata? resolved =
        metadata ?? (await _repo.list()).where((m) => m.id == id).firstOrNull;
    if (resolved == null) return; // already gone (deleted elsewhere)
    await _repo.delete(resolved, actor: 'app:sidebar');
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

/// [listed] with every id in [relinked] re-pointed at its resolved parent
/// path (issue #426) — the mapping the sidebar's tree grouping consumes.
List<SessionMetadata> relinkSubagentParents(
  List<SessionMetadata> listed,
  Map<String, String> relinked,
) {
  return [
    for (final metadata in listed)
      relinked.containsKey(metadata.id)
          ? _withParentLink(metadata, relinked[metadata.id]!)
          : metadata,
  ];
}

/// A copy of [metadata] whose header `metadata.parent` is [parent] — the
/// relink the sidebar's tree grouping consumes (issue #426). Every other
/// header field is carried over unchanged.
SessionMetadata _withParentLink(SessionMetadata metadata, String parent) {
  return SessionMetadata(
    id: metadata.id,
    createdAt: metadata.createdAt,
    cwd: metadata.cwd,
    path: metadata.path,
    lastUpdatedAt: metadata.lastUpdatedAt,
    parentSessionPath: metadata.parentSessionPath,
    sizeBytes: metadata.sizeBytes,
    metadata: {
      ...?metadata.metadata,
      'parent': parent,
    },
  );
}
