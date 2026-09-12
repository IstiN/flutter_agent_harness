// ponytail: small extension twin of flutter_app/lib/sandbox/persistent_web_env.dart.
// MemoryExecutionEnv is `final` (can't extend outside lib/), so this wraps it —
// same shape as the Flutter sandbox's wrapper.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';

import 'chrome_api.dart' show StorageApi;

/// [ExecutionEnv] persisted into `chrome.storage.local`.
///
/// Wraps a [MemoryExecutionEnv] (whole fs in memory, never-throw invariant)
/// and mirrors mutations into two storage shapes (issue #228):
///
///  * the versioned JSON envelope under [storageKey] — the whole tree
///    EXCEPT session files, so it stays small and an oversized session can
///    never take unrelated saves down with it (quota isolation);
///  * one record per session file under [sessionKeyPrefix] — the live
///    `/session.jsonl` plus every `/session-<id>.jsonl` archive. Session
///    records are version-independent (an envelope schema bump can no
///    longer wipe chat history), are written EAGERLY on mutation (the SW
///    can be reaped inside the old 800 ms debounce window and has no
///    `beforeunload`), and fail one-at-a-time: a torn or over-quota record
///    damages at most that session.
///
/// A v1 envelope (sessions inline) is migrated on restore, never wiped; an
/// unreadable or newer-version envelope is copied to [backupKey] before any
/// save may overwrite it. Snapshots encode from [FsSnapshotExporter]'s
/// synchronous point-in-time export, so a saved record is never a torn
/// mid-walk view. Persistence problems never crash boot; post-boot save
/// failures stay dirty and retry on the next mutation or [flush].
///
/// Two ordering guarantees pin the migration promise (issue #238): the v1
/// envelope is replaced by the session-stripped v2 shape only in a pass
/// that wrote EVERY session record — until then it is the only durable
/// copy of the sessions, so a failed record write leaves it untouched —
/// and stale-record eviction runs FIRST, so a later failure in the pass
/// cannot resurrect a deleted session. Residual: an SW reaped between the
/// fs removal and the eviction step resurrects that one session on next
/// boot — deletion metadata, never chat data.
///
/// There is no shell in a browser extension: [exec] answers with a clean
/// `shellUnavailable` error naming the sandbox — the `browser_*` tools are
/// the action surface.
final class ChromeStorageEnv implements ExecutionEnv {
  ChromeStorageEnv._(this._storage) : _delegate = MemoryExecutionEnv(cwd: '/');

  final MemoryExecutionEnv _delegate;

  /// The `chrome.storage.local` surface; null when the chrome global is
  /// unavailable (non-extension context) — the env then runs memory-only,
  /// same as the old blocked-storage clean start.
  final StorageApi? _storage;

  /// Envelope schema version. v2 moves session files out of the envelope
  /// into [sessionKeyPrefix] records (issue #228). v1 envelopes restore
  /// (migration); anything else is backed up under [backupKey], never
  /// silently discarded.
  static const snapshotVersion = 2;

  /// chrome.storage.local key holding the versioned JSON envelope.
  static const storageKey = 'faFs';

  /// Backup key an unreadable envelope is preserved under (issue #228).
  static const backupKey = 'faFs.bak';

  /// Per-session-file record key prefix: `faFs.session<path>` (issue #228).
  static const sessionKeyPrefix = 'faFs.session';

  /// Session files live at the fs root: the live `/session.jsonl` (see
  /// agent_host.dart) plus `/session-<id>.jsonl` archives (see
  /// session_reset.dart's sessionArchivePath). Keep in sync with both.
  static final _sessionPathPattern = RegExp(r'^/session(-.+)?\.jsonl$');

  static bool _isSessionPath(String path) => _sessionPathPattern.hasMatch(path);

  static const _persistDelay = Duration(milliseconds: 800);

  Timer? _timer;
  bool _dirty = false;
  bool _disposed = false;
  bool _booting = true;
  Future<void>? _saving;

  /// Session-record keys currently present in storage (seeded at restore,
  /// rewritten after each successful save). Saves remove ONLY keys whose
  /// session file the user deleted — never live session data (issue #228,
  /// eviction vector).
  Set<String> _knownSessionKeys = {};

  /// True while the stored envelope is still the pre-migration v1 (sessions
  /// inline): the only durable copy of the chat history until a save pass
  /// writes every session record and replaces it with v2 (issue #238 F1).
  bool _envelopeIsV1 = false;

  /// One console warning per failure burst; reset by the next successful
  /// save so a NEW outage is reported again.
  bool _persistErrorLogged = false;

  /// Creates the env and replays the stored snapshot into the memory tree.
  static Future<ChromeStorageEnv> restore({StorageApi? storage}) async {
    final env = ChromeStorageEnv._(storage);
    await env._restore();
    env._booting = false;
    return env;
  }

  Future<void> _restore() async {
    final storage = _storage;
    if (storage == null) return;
    Map<String, Object?> all;
    try {
      all = await storage.get();
    } on Object {
      return; // Storage unavailable (blocked, private mode) → clean start.
    }
    // 1. The envelope: the non-session tree. v1 (sessions inline) migrates;
    //    anything unreadable or newer-version is backed up BEFORE the first
    //    save could overwrite it — version bumps must never wipe (issue
    //    #228 vector 2).
    final raw = all[storageKey];
    if (raw is String && raw.isNotEmpty && !await _restoreEnvelope(raw)) {
      try {
        await storage.set({backupKey: raw});
      } on Object {
        // Backup failed (blocked storage): boot continues clean either way.
      }
    }
    // 2. Session records overlay the envelope: version-independent keys,
    //    newer-or-equal truth. A corrupt record costs one file, not boot.
    for (final entry in all.entries) {
      final path = _sessionPathOfKey(entry.key);
      if (path == null) continue;
      _knownSessionKeys.add(entry.key);
      final data = entry.value;
      if (data is! String) continue;
      try {
        await _delegate.writeBinaryFile(path, base64Decode(data));
      } on Object {
        // Torn record → skip this file only (the session layer's own
        // quarantine handles a broken JSONL from here).
      }
    }
  }

  /// Replays the envelope into the delegate. Returns false when the
  /// envelope is unreadable or carries an unhandled version — the caller
  /// then preserves it under [backupKey] instead of discarding it.
  Future<bool> _restoreEnvelope(String raw) async {
    Map<String, dynamic> decoded;
    try {
      final d = jsonDecode(raw);
      if (d is! Map<String, dynamic>) return false;
      decoded = d;
    } on Object {
      return false;
    }
    final version = decoded['version'];
    if (version != 1 && version != snapshotVersion) return false;
    try {
      // Parse and validate everything before touching the tree so a corrupt
      // snapshot cannot leave a half-restored filesystem.
      final dirs = <String>[
        for (final d in decoded['dirs'] as List) d as String,
      ];
      final files = <(String, Uint8List)>[
        for (final f in decoded['files'] as List)
          ((f as Map)['path'] as String, base64Decode(f['data'] as String)),
      ];
      for (final dir in dirs) {
        await _delegate.createDir(dir);
      }
      for (final (path, bytes) in files) {
        await _delegate.writeBinaryFile(path, bytes);
      }
      // A v1 envelope just came back to life: until a save pass has
      // written every session record and replaced it, it stays the only
      // durable copy of the sessions (issue #238 F1).
      _envelopeIsV1 = version == 1;
      return true;
    } on Object {
      // Corrupt snapshot → clean start, never crash boot.
      return false;
    }
  }

  /// Maps a storage key back to its session path, or null when the key is
  /// not a session record (validated against the session path shape so a
  /// foreign `faFs.session…`-ish key can't inject arbitrary paths).
  static String? _sessionPathOfKey(String key) {
    if (!key.startsWith(sessionKeyPrefix)) return null;
    final path = key.substring(sessionKeyPrefix.length);
    return _isSessionPath(path) ? path : null;
  }

  void _schedulePersist({bool session = false}) {
    if (_disposed || _booting || _storage == null) return;
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(_persistDelay, () => unawaited(_persistNow()));
    if (session) {
      // Session mutations skip the debounce (issue #228 vector 3): the SW
      // can be reaped at any moment and has no beforeunload — an 800 ms
      // pending window is exactly how the tail of a conversation vanished.
      // Saves serialize through _persistNow, so a burst of appends
      // coalesces into the in-flight loop's next pass; the timer above
      // stays armed as the backstop for the join-a-dying-save race.
      unawaited(_persistNow());
    }
  }

  /// True when mutations since the last completed save are still
  /// unpersisted (including a save that failed and armed the retry).
  bool get hasPendingChanges => _dirty;

  /// Persists immediately when changes are pending. Awaits any in-flight
  /// save (an eager session save may already hold the loop with [_dirty]
  /// cleared), so after [flush] returns all mutations so far are stored.
  /// Call after each agent run so a reaped SW never loses a turn.
  Future<void> flush() async {
    _timer?.cancel();
    if (_dirty) await _persistNow();
    final inFlight = _saving;
    if (inFlight != null) await inFlight;
  }

  /// Stops the debounce timer; pending unsaved changes are dropped.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }

  Future<void> _persistNow() {
    if (_disposed || _storage == null) return Future.value();
    return _saving ??= _persistLoop().whenComplete(() => _saving = null);
  }

  Future<void> _persistLoop() async {
    final storage = _storage;
    if (storage == null) return;
    while (_dirty && !_disposed) {
      _dirty = false;
      try {
        await _saveOnce(storage);
        _persistErrorLogged = false;
      } on Object catch (error) {
        // Save failed (quota, blocked storage): stay dirty so the next
        // mutation or flush retries; never break the sandbox over it.
        // Log once per failure burst — a silent permanent failure here is
        // how sessions "disappeared" (nothing ever reached the disk).
        if (!_persistErrorLogged) {
          _persistErrorLogged = true;
          // ignore: avoid_print
          print('[faFs] persist failed (sessions NOT saved): $error');
        }
        _dirty = true;
        return;
      }
    }
  }

  /// One save pass: eviction of records whose session file was deleted
  /// FIRST (issue #238 F2 — a later failure in the pass must not
  /// resurrect a deleted session), then session records (each its own
  /// storage item, so an over-quota session fails ALONE and
  /// previously-saved records are never touched), then the session-free
  /// envelope — but never while the stored envelope is still the v1
  /// migration source and a record write failed: until every session
  /// record is durable, that envelope is the only durable copy of the
  /// sessions (issue #238 F1). Throws when anything failed — the caller
  /// re-arms the retry.
  Future<void> _saveOnce(StorageApi storage) async {
    // Synchronous point-in-time export (issues #201/#228): the old async
    // walk yielded between entries, so a mid-walk append could persist a
    // tree that never existed.
    final snapshot = _delegate.exportSnapshot();
    final envelopeFiles = <Map<String, String>>[];
    final sessionRecords = <String, String>{};
    for (final file in snapshot.files.entries) {
      final encoded = base64Encode(file.value);
      if (_isSessionPath(file.key)) {
        sessionRecords['$sessionKeyPrefix${file.key}'] = encoded;
      } else {
        envelopeFiles.add({'path': file.key, 'data': encoded});
      }
    }
    var failed = false;
    // Evict ONLY records whose session file is gone from the tree (user
    // delete / session reset); live session data is never dropped. Runs
    // before the writes so nothing later in the pass can skip it.
    final stale = _knownSessionKeys.difference(sessionRecords.keys.toSet());
    if (stale.isNotEmpty) {
      try {
        await storage.remove(stale.toList());
        _knownSessionKeys.removeAll(stale);
      } on Object {
        failed = true; // retried by the next pass
      }
    }
    for (final record in sessionRecords.entries) {
      try {
        await storage.set({record.key: record.value});
      } on Object {
        failed = true; // This session stays dirty; the rest keep saving.
      }
    }
    if (failed && _envelopeIsV1) {
      // Migration ordering (issue #238 F1): overwriting the v1 envelope
      // with the session-stripped v2 shape while a record write failed
      // would destroy the only durable copy of the sessions. Already-v2
      // envelopes keep flowing below: their sessions live in their own
      // records, so a failed record costs at most that session's
      // unsaved tail (#228 vector 4).
      throw StateError(
        'a session record could not be saved (quota?); keeping the v1 '
        'envelope as the only durable copy of the sessions',
      );
    }
    await storage.set({
      storageKey: jsonEncode({
        'version': snapshotVersion,
        'dirs': snapshot.dirs,
        'files': envelopeFiles,
      }),
    });
    if (failed) {
      throw StateError('a session record could not be saved (quota?)');
    }
    _envelopeIsV1 = false;
    _knownSessionKeys = sessionRecords.keys.toSet();
  }

  /// No shell in the browser sandbox — say so, and point at browser_* tools.
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return Err(
      ExecutionError(
        ExecutionErrorCode.shellUnavailable,
        'no shell in the browser extension sandbox: bash is unavailable; '
        'use the browser_* tools to act on the web',
      ),
    );
  }

  @override
  String get cwd => _delegate.cwd;

  /// True when a mutation at [path] touches session data: the session
  /// files themselves, or the fs root (a recursive wipe takes the sessions
  /// with it). Session-affecting mutations persist eagerly.
  static bool _affectsSessions(String path) =>
      _isSessionPath(path) || path == '/' || path.isEmpty;

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) async {
    final result = await _delegate.writeBinaryFile(path, content);
    if (result.isOk) _schedulePersist(session: _affectsSessions(path));
    return result;
  }

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    final result = await _delegate.writeFile(path, content);
    if (result.isOk) _schedulePersist(session: _affectsSessions(path));
    return result;
  }

  @override
  Future<Result<void, FileError>> appendFile(
    String path,
    String content,
  ) async {
    final result = await _delegate.appendFile(path, content);
    if (result.isOk) _schedulePersist(session: _affectsSessions(path));
    return result;
  }

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) async {
    final result = await _delegate.createDir(path, recursive: recursive);
    if (result.isOk) _schedulePersist();
    return result;
  }

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) async {
    final result = await _delegate.remove(
      path,
      recursive: recursive,
      force: force,
    );
    if (result.isOk) _schedulePersist(session: _affectsSessions(path));
    return result;
  }

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _delegate.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _delegate.exists(path);
}
