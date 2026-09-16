/// Session-file destructive-operation safety (issue #522).
///
/// A live 424 MB session file once vanished between two process
/// launches — no trash entry, no journal, no trace of who unlinked it.
/// This module makes that impossible from inside the harness:
///
/// * [SessionOpsJournal] — every delete/move/purge of a session file is
///   logged as an auditable JSONL record (who: pid/host/session/tool,
///   what: path → destination, when) into a per-root
///   `<sessionsRoot>/session_ops.journal`. A vanished file always has a
///   named culprit.
/// * [SessionDeletionGuard] / [PresenceLeaseSessionGuard] — deleting a
///   session with a LIVE registration (presence heartbeat or ownership
///   lease, #428) is refused with a named
///   [SessionErrorCode.sessionLive] error. Staleness is judged ONLY by
///   heartbeat expiry (a crashed owner stops blocking after the window).
/// * trash, never unlink — [JsonlSessionRepo.delete] and
///   `cleanupEmptySessions` move files into `<root>/.trash/` as
///   `<timestamp>_<name>` (recoverable until
///   [JsonlSessionRepo.purgeExpiredTrash] removes entries older than
///   the TTL).
library;

// Private fields are assigned from identically-named constructor
// parameters for documentation clarity (same as the attach stores).
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import '../env/execution_env.dart';
import 'attach/session_lease.dart';
import 'attach/session_presence.dart';

/// The kinds of destructive operation the journal records.
enum SessionOpKind {
  /// A session file was deleted (moved into `.trash/`).
  trash,

  /// A header-only legacy session was cleaned up (moved into `.trash/`).
  cleanupTrash,

  /// A trash entry older than the TTL was purged (the one allowed
  /// unlink — it deletes a file that is already deleted).
  purge,

  /// A deletion was REFUSED because the session has a live registration
  /// (the audit trail for "who tried").
  refusedLive,
}

/// Extension: the wire name of [SessionOpKind].
extension SessionOpKindName on SessionOpKind {
  /// The string persisted in the journal.
  String get wireName => switch (this) {
    SessionOpKind.trash => 'trash',
    SessionOpKind.cleanupTrash => 'cleanup_trash',
    SessionOpKind.purge => 'purge',
    SessionOpKind.refusedLive => 'refused_live',
  };
}

/// Parses a journal wire name; `null` for unknown strings.
SessionOpKind? parseSessionOpKind(String? name) => switch (name) {
  'trash' => SessionOpKind.trash,
  'cleanup_trash' => SessionOpKind.cleanupTrash,
  'purge' => SessionOpKind.purge,
  'refused_live' => SessionOpKind.refusedLive,
  _ => null,
};

/// Who performed a destructive session-file operation.
///
/// Hosts inject the acting process's identity ([SessionOpsActor]
/// closure on [JsonlSessionRepo]); the per-call `tool` names the agent
/// tool or UI surface that triggered the operation.
final class SessionOpsActor {
  /// Creates an actor record.
  const SessionOpsActor({this.pid, this.host, this.sessionId, this.tool});

  /// The acting process id, when known.
  final int? pid;

  /// The acting surface: `cli`, `app`, `macos`, …
  final String? host;

  /// The session the acting process is driving (its own id), when known.
  final String? sessionId;

  /// The tool or UI surface that triggered the operation
  /// (`sessions_ui`, `cleanup_boot`, …).
  final String? tool;

  /// This actor with [tool] overridden.
  SessionOpsActor withTool(String? newTool) => SessionOpsActor(
    pid: pid,
    host: host,
    sessionId: sessionId,
    tool: newTool ?? tool,
  );

  Map<String, dynamic> toJson() => {
    if (pid != null) 'pid': pid,
    if (host != null) 'host': host,
    if (sessionId != null) 'session': sessionId,
    if (tool != null) 'tool': tool,
  };

  /// Parses the journal shape; unknown fields tolerated, missing → null.
  static SessionOpsActor? fromJson(Map<String, dynamic> json) {
    final pid = json['pid'];
    if (json.isEmpty) return null;
    return SessionOpsActor(
      pid: pid is int ? pid : null,
      host: json['host'] as String?,
      sessionId: json['session'] as String?,
      tool: json['tool'] as String?,
    );
  }
}

/// One journal record: what happened to which file, who did it, when.
final class SessionOpRecord {
  /// Creates a record.
  const SessionOpRecord({
    required this.ts,
    required this.kind,
    required this.path,
    this.to,
    this.bytes,
    this.reason,
    this.actor,
  });

  /// When the operation happened (UTC).
  final DateTime ts;

  /// What happened.
  final SessionOpKind kind;

  /// The session file the operation targeted.
  final String path;

  /// The destination path (trash entry) for move-shaped operations.
  final String? to;

  /// The file size at deletion time, when known.
  final int? bytes;

  /// Free-form context (refusal owner, cleanup reason, …).
  final String? reason;

  /// Who did it.
  final SessionOpsActor? actor;

  /// Parses one journal line; `null` on a torn or foreign line (the
  /// journal is append-only best-effort — a bad line skips, never fails).
  static SessionOpRecord? fromJson(Map<String, dynamic> json) {
    final kind = parseSessionOpKind(json['op'] as String?);
    final ts = DateTime.tryParse(json['ts'] as String? ?? '');
    final path = json['path'] as String?;
    if (kind == null || ts == null || path == null) return null;
    final actorJson = json['actor'];
    final bytes = json['bytes'];
    return SessionOpRecord(
      ts: ts,
      kind: kind,
      path: path,
      to: json['to'] as String?,
      bytes: bytes is int ? bytes : null,
      reason: json['reason'] as String?,
      actor: actorJson is Map<String, dynamic>
          ? SessionOpsActor.fromJson(actorJson)
          : null,
    );
  }

  /// The journal line shape.
  Map<String, dynamic> toJson() => {
    'ts': ts.toUtc().toIso8601String(),
    'op': kind.wireName,
    'path': path,
    if (to != null) 'to': to,
    if (bytes != null) 'bytes': bytes,
    if (reason != null) 'reason': reason,
    if (actor != null) 'actor': actor!.toJson(),
  };
}

/// Append-only audit journal for session-file destructive operations
/// (issue #522): one JSON line per operation under
/// `<sessionsRoot>/session_ops.journal`.
///
/// Best-effort by design: a journal that cannot be written (read-only
/// storage, full disk) never blocks the operation it observes — the
/// operation's own success/failure is reported through its normal path.
final class SessionOpsJournal {
  /// Creates a journal over [sessionsRoot]. [actor] supplies the acting
  /// process identity lazily, per record (the driving session changes
  /// over a process's lifetime).
  SessionOpsJournal({
    required FileSystem fs,
    required String sessionsRoot,
    SessionOpsActor Function()? actor,
    DateTime Function()? now,
  }) : _fs = fs,
       _sessionsRoot = sessionsRoot,
       _actor = actor,
       _now = now ?? DateTime.now;

  /// The journal file name under the sessions root.
  static const String fileName = 'session_ops.journal';

  final FileSystem _fs;
  final String _sessionsRoot;
  final SessionOpsActor Function()? _actor;
  final DateTime Function() _now;

  /// Appends one record. Never throws.
  Future<void> record(
    SessionOpKind kind, {
    required String path,
    String? to,
    int? bytes,
    String? reason,
    String? tool,
  }) async {
    try {
      final actor = _actor?.call().withTool(tool);
      final line = jsonEncode(
        SessionOpRecord(
          ts: _now().toUtc(),
          kind: kind,
          path: path,
          to: to,
          bytes: bytes,
          reason: reason,
          actor: actor,
        ).toJson(),
      );
      await _fs.appendFile(await _journalPath(), '$line\n');
    } on Object {
      // The journal observes operations; it never gates them.
    }
  }

  /// Reads every well-formed record, oldest first (forensics + tests).
  Future<List<SessionOpRecord>> entries() async {
    final raw = (await _fs.readTextFile(await _journalPath())).valueOrNull;
    if (raw == null || raw.isEmpty) return const [];
    final out = <SessionOpRecord>[];
    for (final line in raw.split('\n')) {
      if (line.trim().isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on Object {
        continue; // torn tail line from a crash — skip.
      }
      if (decoded is! Map<String, dynamic>) continue;
      final record = SessionOpRecord.fromJson(decoded);
      if (record != null) out.add(record);
    }
    return out;
  }

  Future<String> _journalPath() async =>
      (await _fs.joinPath([_sessionsRoot, fileName])).valueOrNull ??
      '$_sessionsRoot/$fileName';
}

/// A live registration that blocks a session-file deletion: who owns
/// the session right now.
final class LiveSessionOwner {
  /// Creates the owner record.
  const LiveSessionOwner({required this.source, this.pid, this.host});

  /// Where the registration lives: `presence` (heartbeat store) or
  /// `lease` (ownership sidecar, #428).
  final String source;

  /// The owning process id, when known.
  final int? pid;

  /// The owning surface (`cli`, `app`, …), when known.
  final String? host;

  @override
  String toString() =>
      '$source pid ${pid ?? '?'}'
      '${host == null ? '' : ' ($host)'}';
}

/// The live-registration seam consulted before any destructive session
/// operation (issue #522). A guard answers ONE question: does a process
/// with a FRESH heartbeat own this session right now? Staleness is
/// judged inside the guard's stores — heartbeat expiry only, never
/// "the file looks idle".
abstract interface class SessionDeletionGuard {
  /// The live owner of the session [sessionId] at file [path], or null
  /// when no fresh registration exists.
  Future<LiveSessionOwner?> liveOwnerOf({
    required String sessionId,
    required String path,
  });
}

/// Combines the two registration sources: presence heartbeats (keyed by
/// session id — what a running `fa` CLI publishes) and ownership leases
/// (the `_owner.json` sidecar next to the file, #428). Either one being
/// fresh makes the session live.
final class PresenceLeaseSessionGuard implements SessionDeletionGuard {
  /// Creates the guard over whichever stores the host wires.
  PresenceLeaseSessionGuard({this.presence, this.lease});

  /// The live-session heartbeat store (CLI runs), when wired.
  final SessionPresenceStore? presence;

  /// The ownership-lease store (#428), when wired.
  final FileSessionLeaseStore? lease;

  @override
  Future<LiveSessionOwner?> liveOwnerOf({
    required String sessionId,
    required String path,
  }) async {
    final registered = await presence?.list();
    final row = registered?[sessionId];
    if (row != null) {
      // The store already dropped stale heartbeats: what it returns is
      // fresh by construction.
      return LiveSessionOwner(source: 'presence', pid: row.pid, host: row.host);
    }
    final store = lease;
    if (store != null) {
      final found = await store.inspect(path);
      if (found.state == LeaseState.live) {
        return LiveSessionOwner(
          source: 'lease',
          pid: found.lease!.pid,
          host: found.lease!.host,
        );
      }
    }
    return null;
  }
}
