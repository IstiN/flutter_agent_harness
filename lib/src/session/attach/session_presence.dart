/// Live-session presence: which sessions currently have a running agent
/// process (a `fa` CLI, a headless run) attached to them. A store is a
/// heartbeat registry — writers touch, readers list, stale entries
/// disappear on their own.
///
/// The interface is the seam: the file impl below serves local
/// same-machine attach (the shared sessions root); a network impl later
/// serves remote attach without touching any consumer.
library;

/// One live-session heartbeat record.
final class SessionPresence {
  /// Creates the record.
  const SessionPresence({
    required this.sessionId,
    required this.startedAt,
    required this.touchedAt,
    this.pid,
    this.host,
  });

  /// Parses the JSON shape the file store persists.
  factory SessionPresence.fromJson(
    String sessionId,
    Map<String, dynamic> json,
  ) => SessionPresence(
    sessionId: sessionId,
    startedAt:
        DateTime.tryParse(
          json['startedAt'] as String? ?? '',
        )?.toIso8601String() ??
        '',
    touchedAt:
        DateTime.tryParse(
          json['touchedAt'] as String? ?? '',
        )?.toIso8601String() ??
        '',
    pid: json['pid'] as int?,
    host: json['host'] as String?,
  );

  /// The session the running process owns.
  final String sessionId;

  /// When the process started (UTC ISO 8601).
  final String startedAt;

  /// When the process last proved liveness (UTC ISO 8601) — rewritten on
  /// every heartbeat tick.
  final String touchedAt;

  /// The OS process id, when known (diagnostics only).
  final int? pid;

  /// The machine host name, when known (diagnostics only; the remote
  /// future surfaces which machine owns the session).
  final String? host;

  Map<String, dynamic> toJson() => {
    'startedAt': startedAt,
    'touchedAt': touchedAt,
    if (pid != null) 'pid': pid,
    if (host != null) 'host': host,
  };
}

/// Registry of live sessions: a running agent process registers on
/// start, touches on every heartbeat tick, unregisters on exit. Readers
/// ([SessionPresenceStore.list]) see only fresh entries — a crashed
/// process is covered by staleness, not by cleanup.
abstract interface class SessionPresenceStore {
  /// Announces a live process owning [sessionId]. Also refreshes
  /// `touchedAt` (a register is a touch).
  Future<void> register(String sessionId, {int? pid, String? host});

  /// Refreshes the heartbeat for [sessionId] (no-op when not registered).
  Future<void> touch(String sessionId);

  /// Removes the heartbeat for [sessionId] (clean exit path).
  Future<void> unregister(String sessionId);

  /// The fresh presence records, keyed by session id. Stale entries
  /// (their `touchedAt` older than the store's staleness window) are
  /// treated as dead and never returned.
  Future<Map<String, SessionPresence>> list();
}
