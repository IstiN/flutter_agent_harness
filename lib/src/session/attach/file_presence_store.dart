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
  FileSessionPresenceStore({
    required ExecutionEnv env,
    required String root,
    DateTime Function()? now,
    this.staleAfter = const Duration(seconds: 15),
  }) : _env = env,
       _root = root,
       _now = now ?? DateTime.now;

  static const _dirName = '.presence';

  final ExecutionEnv _env;
  final String _root;
  final DateTime Function() _now;

  /// How old a heartbeat may be before its process is considered dead.
  final Duration staleAfter;

  String get _dirPath => '$_root/$_dirName';
  String _file(String sessionId) => '$_dirPath/${_sanitize(sessionId)}.json';

  @override
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
      if (json == null) continue;
      final presence = SessionPresence.fromJson(_idFromFileName(name), json);
      // Stale heartbeat = the process died without unregistering
      // (crash, kill -9): the session is not live.
      final touched = DateTime.tryParse(presence.touchedAt);
      if (touched == null || touched.isBefore(cutoff)) continue;
      out[presence.sessionId] = presence;
    }
    return out;
  }

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
