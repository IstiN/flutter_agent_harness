/// File-backed [SessionPresenceStore] over an [ExecutionEnv]: one JSON
/// heartbeat file per live session under `<sessionsRoot>/.presence/`.
/// Two Fa processes sharing the sessions root (the macOS App Group) see
/// each other's live sessions through the filesystem — no live process
/// coupling needed.
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import '../../env/execution_env.dart';
import 'session_presence.dart';

final class FileSessionPresenceStore implements SessionPresenceStore {
  /// Creates the store over [root] (the shared sessions root; the
  /// heartbeats live in a `.presence` subdirectory that never collides
  /// with the cwd-encoded session folders). [now] and [staleAfter] are
  /// injectable for tests.
  ///
  /// [cleanupAfter] is the garbage-collection grace (gh-1660): a stale
  /// heartbeat file is DELETED once it ages past it (or earlier, when
  /// [pidAlive] pronounces its process dead) — `list()` no longer only
  /// filters dead entries, it sweeps them. [pidAlive] is the host
  /// liveness probe (`kill -0`); a `null` answer means "no probe here"
  /// and falls back to the time-based grace. Null keeps the sweep purely
  /// time-based.
  FileSessionPresenceStore({
    required ExecutionEnv env,
    required String root,
    DateTime Function()? now,
    this.staleAfter = const Duration(seconds: 15),
    this.cleanupAfter = defaultCleanupAfter,
    bool? Function(int pid)? pidAlive,
  }) : _env = env,
       _root = root,
       _now = now ?? DateTime.now,
       _pidAlive = pidAlive;

  /// How old a heartbeat file may get before `list()` deletes it
  /// (gh-1660): long enough that a suspended process (laptop sleep)
  /// still finds its file to resume heartbeating, short enough that
  /// crash/kill -9 garbage stays bounded. A file with a live pid is
  /// never deleted, whatever its age.
  static const defaultCleanupAfter = Duration(minutes: 5);

  static const _dirName = '.presence';

  final ExecutionEnv _env;
  final String _root;
  final DateTime Function() _now;
  final bool? Function(int pid)? _pidAlive;

  /// How old a heartbeat may be before its process is considered dead.
  final Duration staleAfter;

  /// How old a dead heartbeat FILE may get before the sweep deletes it
  /// (see [defaultCleanupAfter]).
  final Duration cleanupAfter;

  String get _dirPath => '$_root/$_dirName';
  String _file(String sessionId) => '$_dirPath/${_sanitize(sessionId)}.json';

  @override
  Future<void> register(String sessionId, {int? pid, String? host}) async {
    try {
      (await _env.createDir(_dirPath)).getOrThrow();
      final now = _now().toUtc().toIso8601String();
      await _write(
        sessionId,
        SessionPresence(
          sessionId: sessionId,
          startedAt: now,
          touchedAt: now,
          pid: pid,
          host: host,
        ),
      );
    } on Object {
      // Best-effort presence registration.
    }
  }

  @override
  Future<void> touch(String sessionId) async {
    try {
      final existing = await _read(sessionId);
      if (existing == null) return;
      await _write(
        sessionId,
        SessionPresence(
          sessionId: sessionId,
          startedAt: existing.startedAt,
          touchedAt: _now().toUtc().toIso8601String(),
          pid: existing.pid,
          host: existing.host,
        ),
      );
    } on Object {
      // Best-effort presence touch.
    }
  }

  @override
  Future<void> unregister(String sessionId) async {
    try {
      final path = _file(sessionId);
      if ((await _env.exists(path)).valueOrNull != true) return;
      await _env.remove(path, force: true);
    } on Object {
      // Best-effort presence unregister.
    }
  }

  @override
  Future<Map<String, SessionPresence>> list() async {
    if ((await _env.exists(_dirPath)).valueOrNull != true) return const {};
    final files = (await _env.listDir(_dirPath)).valueOrNull ?? const [];
    final cutoff = _now().toUtc().subtract(staleAfter);
    final cleanupCutoff = _now().toUtc().subtract(cleanupAfter);
    final out = <String, SessionPresence>{};
    for (final info in files) {
      // Memory and IO envs disagree on whether FileInfo.name carries the
      // extension — derive the file name from the path instead.
      final slash = info.path.lastIndexOf('/');
      final name = slash >= 0 ? info.path.substring(slash + 1) : info.path;
      if (name.isEmpty || !name.endsWith('.json')) continue;
      final raw = (await _env.readTextFile('$_dirPath/$name')).valueOrNull;
      if (raw == null) continue;
      final json = _tryJson(raw);
      if (json == null) {
        _sweepIfAged(info, null, cleanupCutoff);
        continue;
      }
      final presence = SessionPresence.fromJson(_idFromFileName(name), json);
      // Stale heartbeat = the process died without unregistering
      // (crash, kill -9): the session is not live — and (gh-1660) the
      // file itself is swept once the process is provably dead, so the
      // .presence directory does not grow without bound.
      final touched = DateTime.tryParse(presence.touchedAt);
      if (touched == null || touched.isBefore(cutoff)) {
        await _sweepIfAged(info, presence, cleanupCutoff);
        continue;
      }
      out[presence.sessionId] = presence;
    }
    return out;
  }

  /// gh-1660 garbage collection: removes a dead heartbeat file when this
  /// reader can pronounce its process dead. Best-effort — a failed
  /// remove leaves the file for the next sweep, and readers only ever
  /// delete inside the `.presence` directory they are listing.
  ///
  /// A file with a [SessionPresence.pid] and a host [pidAlive] probe is
  /// deleted exactly when the probe reports the process dead — no grace
  /// needed, a gone pid cannot resume (a live pid's file stays whatever
  /// its age: a suspended process may resume heartbeating). Without a
  /// pid or a probe the file's own age decides: `touchedAt` older than
  /// the cleanup grace, or — for torn files whose timestamps do not
  /// parse — the file mtime as the fallback age. Within the grace the
  /// file only drops out of the listing.
  Future<void> _sweepIfAged(
    FileInfo info,
    SessionPresence? presence,
    DateTime cleanupCutoff,
  ) async {
    final pid = presence?.pid;
    final probe = pid == null || _pidAlive == null ? null : _pidAlive(pid);
    if (probe != null) {
      // A gone pid cannot resume — no grace needed. A live pid's file
      // stays whatever its age (a suspended process may resume).
      if (probe) return;
    } else {
      final touched = presence == null
          ? null
          : DateTime.tryParse(presence.touchedAt);
      final aged = touched ?? _fromMtimeMs(info.mtimeMs);
      if (!aged.isBefore(cleanupCutoff)) return;
    }
    try {
      await _env.remove(info.path, force: true);
    } on Object {
      // Best-effort sweep; the next reader retries.
    }
  }

  static DateTime _fromMtimeMs(int mtimeMs) =>
      DateTime.fromMillisecondsSinceEpoch(mtimeMs).toUtc();

  Future<void> _write(String sessionId, SessionPresence presence) async {
    (await _env.writeFile(
      _file(sessionId),
      const JsonEncoder.withIndent('  ').convert(presence.toJson()),
    )).getOrThrow();
  }

  Future<SessionPresence?> _read(String sessionId) async {
    final raw = (await _env.readTextFile(_file(sessionId))).valueOrNull;
    if (raw == null) return null;
    final json = _tryJson(raw);
    if (json == null) return null;
    return SessionPresence.fromJson(sessionId, json);
  }

  // The heartbeat file name IS the session id (uuids are filesystem-safe
  // already); strip the .json suffix to recover it.
  String _idFromFileName(String name) =>
      name.substring(0, name.length - '.json'.length);

  static Map<String, dynamic>? _tryJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  // Defensive: keep any id filesystem-safe (mirrors the messaging
  // fabric's sanitization).
  static final _unsafe = RegExp(r'[^a-zA-Z0-9._-]');
  static String _sanitize(String id) => id.replaceAll(_unsafe, '_');
}
