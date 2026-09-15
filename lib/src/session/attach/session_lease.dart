// ignore_for_file: prefer_initializing_formals

/// Session ownership lease (#428): a `_owner.json` sidecar next to the
/// session JSONL marks the ONE process driving the session. Every other
/// opener becomes a VIEWER — a viewer never seizes a live lease (Rev-2
/// owner ruling); the lease changes hands only by graceful release
/// (owner deletes the sidecar) or stale expiry (owner died, ~15s).
///
/// Layout: session files live at
/// `<sessionsRoot>/<encoded-cwd>/<timestamp>_<sessionId>.jsonl`; the
/// sidecar sits next to the file as `<timestamp>_<sessionId>.owner.json`
/// and carries the `sessionId` inside, so a project directory holding
/// many sessions leases each independently. Like the `.presence/` store,
/// staleness is judged on the LOCAL clock against the sidecar's file
/// mtime — the write clock of the filesystem, immune to cross-host
/// wall-clock skew (E1).
library;

import 'dart:convert';
import 'dart:math';

import '../../env/execution_env.dart';

/// One ownership lease: who drives a session, since when, last seen when.
final class SessionLease {
  /// Parses strictness: [fromJson] throws [FormatException] on a missing
  /// or mistyped required field (the sidecar is then treated as no lease
  /// — E4 fail-open — by the store); unknown fields are tolerated and
  /// reported in [unknownFieldNotes].
  SessionLease({
    required this.host,
    required this.sessionId,
    required this.pid,
    required this.bootId,
    required this.heartbeatAt,
    required this.acquiredAt,
    this.sessionName,
    this.unknownFieldNotes = const [],
  });

  /// The owning surface kind: `cli`, `macos`, `ios`, `extension`.
  final String host;

  /// The leased session id (the sidecar's key content — the file name is
  /// derived from the session file, the identity from here).
  final String sessionId;

  /// The owning process id (diagnostics + banner).
  final int pid;

  /// Random per-process-start id: a recycled PID from a previous boot
  /// never matches (E3).
  final String bootId;

  /// When the owner last proved liveness (UTC ISO 8601).
  final String heartbeatAt;

  /// When the lease was taken (UTC ISO 8601; the banner's "since").
  final String acquiredAt;

  /// The session's display name, when known (banner friendliness).
  final String? sessionName;

  /// One note per JSON field the parser did not know (tolerated with a
  /// note, never a refusal — older/newer writers interoperate).
  final List<String> unknownFieldNotes;

  static const _knownFields = {
    'host',
    'sessionId',
    'pid',
    'bootId',
    'sessionName',
    'heartbeatAt',
    'acquiredAt',
  };

  Map<String, dynamic> toJson() => {
    'host': host,
    'sessionId': sessionId,
    'pid': pid,
    'bootId': bootId,
    if (sessionName != null) 'sessionName': sessionName,
    'heartbeatAt': heartbeatAt,
    'acquiredAt': acquiredAt,
  };

  factory SessionLease.fromJson(Map<String, dynamic> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is String && value.isNotEmpty) return value;
      throw FormatException('lease field "$key" missing or not a string');
    }

    final pid = json['pid'];
    if (pid is! int) {
      throw FormatException('lease field "pid" missing or not an int');
    }
    final notes = [
      for (final key in json.keys)
        if (!_knownFields.contains(key)) 'unknown lease field "$key"',
    ];
    return SessionLease(
      host: requiredString('host'),
      sessionId: requiredString('sessionId'),
      pid: pid,
      bootId: requiredString('bootId'),
      heartbeatAt: requiredString('heartbeatAt'),
      acquiredAt: requiredString('acquiredAt'),
      sessionName: json['sessionName'] as String?,
      unknownFieldNotes: List.unmodifiable(notes),
    );
  }
}

/// The lease state a drive-open finds on disk.
final class LeaseInspect {
  const LeaseInspect._(this.state, this.lease);

  /// No sidecar on disk: the lease is free.
  factory LeaseInspect.free() => LeaseInspect._(LeaseState.free, null);

  /// A live lease held by [lease]: openers are viewers.
  factory LeaseInspect.live(SessionLease lease) =>
      LeaseInspect._(LeaseState.live, lease);

  /// An expired lease of a dead owner ([lease]) — free to take fresh.
  factory LeaseInspect.expired(SessionLease lease) =>
      LeaseInspect._(LeaseState.expired, lease);

  /// The classification of the sidecar that was read.
  final LeaseState state;

  /// The lease record when one exists on disk (live or expired), else
  /// null. An expired lease is surfaced so the acquirer can warn naming
  /// the dead owner.
  final SessionLease? lease;
}

/// The outcome states of [FileSessionLeaseStore.inspect].
enum LeaseState {
  /// No sidecar on disk (or an unreadable one): the lease is free.
  free,

  /// A live lease: heartbeat fresher than the staleness window. The
  /// opener becomes a viewer — no path seizes a live lease.
  live,

  /// The sidecar exists but its heartbeat is older than the window: the
  /// owner is dead (crash, kill -9, suspended past the window). The
  /// lease is simply free — the next drive-open acquires it fresh.
  expired,
}

/// The outcome of [FileSessionLeaseStore.acquire].
sealed class LeaseAcquire {
  const LeaseAcquire();
}

/// This process now owns the session: heartbeat + release with [bootId].
final class LeaseAcquired extends LeaseAcquire {
  const LeaseAcquired(this.lease);

  /// The fresh lease as written (acquiredAt == heartbeatAt == now).
  final SessionLease lease;
}

/// A live lease blocked the drive-open: this opener is a VIEWER. No
/// takeover exists — the viewer messages the owner through the fabric.
final class LeaseBlocked extends LeaseAcquire {
  const LeaseBlocked(this.lease);

  /// The owner's live lease (banner material).
  final SessionLease lease;
}

/// This process opened for drive, but the lease could not be enforced
/// (a write/rename/verify failure — E4): the drive proceeds WITHOUT a
/// lease. Honest fail-open: nothing blocks a session over lease IO, and
/// the caller may warn.
final class LeaseUnenforced extends LeaseAcquire {
  const LeaseUnenforced(this.lease);

  /// The lease as attempted (not on disk, or unverifiable).
  final SessionLease lease;
}

/// File-backed ownership lease over an [ExecutionEnv]: the `_owner.json`
/// sidecar next to the session JSONL. All failures are fail-open (E4): a
/// lease that cannot be read is no lease; nothing here ever blocks
/// opening a session for reading.
final class FileSessionLeaseStore {
  /// Creates the store. [now] and [staleAfter] are injectable for tests;
  /// the heartbeat cadence lives with the owners (CLI ~4s on the inbox
  /// tick, app 5s timer) — the store only judges staleness.
  FileSessionLeaseStore({
    required ExecutionEnv env,
    DateTime Function()? now,
    this.staleAfter = const Duration(seconds: 15),
  }) : _env = env,
       _now = now ?? DateTime.now;

  final ExecutionEnv _env;
  final DateTime Function() _now;

  /// How old a lease's last heartbeat may be before its owner is dead.
  final Duration staleAfter;

  /// The sidecar path for a session JSONL path:
  /// `<timestamp>_<sessionId>.jsonl` → `<timestamp>_<sessionId>.owner.json`.
  String sidecarPath(String sessionFilePath) =>
      sessionFilePath.replaceAll(RegExp(r'\.jsonl$'), '.owner.json');

  /// A random per-process boot id (E3: recycles PIDs never match).
  static String newBootId() {
    final random = Random();
    final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return '$micros-${random.nextInt(1 << 32).toRadixString(36)}';
  }

  /// Reads and classifies the current lease for [sessionFilePath].
  /// Corrupt/unreadable sidecar → free (E4, with the file simply
  /// overwritten by the next acquire).
  Future<LeaseInspect> inspect(String sessionFilePath) async {
    final raw = (await _env.readTextFile(
      sidecarPath(sessionFilePath),
    )).valueOrNull;
    if (raw == null) return LeaseInspect.free();
    final SessionLease lease;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return LeaseInspect.free();
      lease = SessionLease.fromJson(decoded);
    } on FormatException {
      return LeaseInspect.free();
    } on Object {
      return LeaseInspect.free();
    }
    // Staleness on the sidecar's mtime vs the reader clock (E1): the
    // filesystem's write clock is the one clock every host on the fabric
    // shares. The injectable [now] stands in for it in tests
    // ([MemoryExecutionEnv.setMtime] moves the file side too).
    final info = (await _env.fileInfo(
      sidecarPath(sessionFilePath),
    )).valueOrNull;
    final mtimeMs = info?.mtimeMs;
    if (mtimeMs == null) return LeaseInspect.free();
    final age = _now().millisecondsSinceEpoch - mtimeMs;
    if (age >= staleAfter.inMilliseconds) {
      return LeaseInspect.expired(lease);
    }
    return LeaseInspect.live(lease);
  }

  /// Attempts to acquire the lease for a drive-open. A live lease is
  /// never seized — the caller becomes a viewer ([LeaseBlocked]). A free
  /// or expired lease is (re-)acquired atomically (temp + rename, E5);
  /// the write is verified by re-reading: a racer that renamed last owns
  /// it, the loser sees a foreign bootId and stands down.
  Future<LeaseAcquire> acquire({
    required String sessionFilePath,
    required String sessionId,
    required String host,
    required String bootId,
    required int pid,
    String? sessionName,
  }) async {
    final found = await inspect(sessionFilePath);
    if (found.state == LeaseState.live) return LeaseBlocked(found.lease!);
    final nowIso = _now().toUtc().toIso8601String();
    final lease = SessionLease(
      host: host,
      sessionId: sessionId,
      pid: pid,
      bootId: bootId,
      sessionName: sessionName,
      heartbeatAt: nowIso,
      acquiredAt: nowIso,
    );
    final path = sidecarPath(sessionFilePath);
    final renamable = _env is RenamableFileSystem
        ? _env as RenamableFileSystem
        : null;
    if (renamable == null) {
      // No atomic rename on this backend (pure web stores): ownership
      // cannot be enforced safely — drive unleased rather than publish a
      // sidecar a concurrent reader could see half-written (E5).
      return LeaseUnenforced(lease);
    }
    // Atomic publish (E5): a unique temp per attempt, then one rename.
    // ponytail: rename-over leaves a microsecond double-claim window
    // (A publishes, B overwrites before A re-reads); the 5s heartbeat +
    // 15s staleness make it self-healing — a real fight shows up as both
    // sides heartbeating and needs a compare-and-swap primitive in
    // ExecutionEnv first.
    final tmp = '$path.${bootId.hashCode.toRadixString(36)}.tmp';
    final encoded = const JsonEncoder.withIndent('  ').convert(lease.toJson());
    final write = await _env.writeFile(tmp, encoded);
    final renamed = write.isOk ? await renamable.renamePath(tmp, path) : write;
    if (renamed.isErr) {
      // E4: a broken lease store never blocks opening a session — the
      // drive proceeds without enforcement (the honest kind of fail-open).
      await _env.remove(tmp, force: true);
      return LeaseUnenforced(lease);
    }
    // Verify ownership: the freshest rename wins; a loser stands down.
    final verify = await _readLease(path);
    if (verify == null) return LeaseUnenforced(lease);
    if (verify.bootId != bootId) return LeaseBlocked(verify);
    return LeaseAcquired(verify);
  }

  /// Refreshes the heartbeat of OUR lease: a no-op (returning false) when
  /// the sidecar moved on — the caller lost the lease and must demote.
  Future<bool> heartbeat(String sessionFilePath, String bootId) async {
    final path = sidecarPath(sessionFilePath);
    final lease = await _readLease(path);
    if (lease == null || lease.bootId != bootId) return false;
    final refreshed = SessionLease(
      host: lease.host,
      sessionId: lease.sessionId,
      pid: lease.pid,
      bootId: lease.bootId,
      sessionName: lease.sessionName,
      heartbeatAt: _now().toUtc().toIso8601String(),
      acquiredAt: lease.acquiredAt,
      unknownFieldNotes: lease.unknownFieldNotes,
    );
    final write = await _env.writeFile(
      path,
      const JsonEncoder.withIndent('  ').convert(refreshed.toJson()),
    );
    return write.isOk;
  }

  /// Graceful release: the sidecar is deleted — only when it is still
  /// OURS (a viewer exiting never deletes the owner's lease).
  Future<void> release(String sessionFilePath, String bootId) async {
    final path = sidecarPath(sessionFilePath);
    final lease = await _readLease(path);
    if (lease == null || lease.bootId != bootId) return;
    await _env.remove(path, force: true);
  }

  Future<SessionLease?> _readLease(String path) async {
    final raw = (await _env.readTextFile(path)).valueOrNull;
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return SessionLease.fromJson(decoded);
    } on Object {
      return null;
    }
  }
}

/// Human label for a lease host in banners: `cli` → `fa CLI`,
/// app surfaces → `Fa.app`, else the raw kind.
String leaseOwnerLabel(String host) => switch (host) {
  'cli' => 'fa CLI',
  'macos' || 'ios' || 'android' => 'Fa.app',
  'extension' => 'Fa extension',
  _ => host,
};

/// The viewer banner (AC3/AC9). Live:
/// `Driven by fa CLI (pid 85634) since 14:32 — you are viewing. Your
/// messages are delivered to the live agent.`
/// Stale (owner's heartbeat expired while we watch):
/// the same provenance plus the reopen hint — a viewer still never
/// drives; the reopen is a fresh drive-open of a free lease.
String viewerBannerText(SessionLease lease, {required bool stale}) {
  final since = DateTime.tryParse(lease.acquiredAt)?.toLocal();
  final clock = since == null
      ? '?'
      : '${since.hour.toString().padLeft(2, '0')}:'
            '${since.minute.toString().padLeft(2, '0')}';
  final head =
      'Driven by ${leaseOwnerLabel(lease.host)} (pid ${lease.pid}) '
      'since $clock';
  return stale
      ? '$head — the owner looks gone (stale). Close and reopen this '
            'session to drive it; your messages still go to its inbox.'
      : '$head — you are viewing. Your messages are delivered to the '
            'live agent.';
}
