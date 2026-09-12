// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/sandbox/fs_persistence.dart';

/// An [ExecutionEnv] wrapper that mirrors the delegate's filesystem into an
/// [FsRecordStore] so the web sandbox (an in-memory FS) survives page
/// reloads.
///
/// Mutations (`write*`, `appendFile`, `createDir`, `remove`) and every
/// [exec] — the shell operates on the delegate's memory FS directly, so any
/// command may have changed the tree — schedule a debounced persist. The
/// tree is mirrored into two storage shapes (issue #237, mirroring the
/// extension fix #228/#236):
///
///  * the versioned JSON envelope under [storageKey] — the whole tree
///    EXCEPT session files, so it stays small and an oversized session can
///    never take unrelated saves down with it (quota isolation);
///  * one record per session file under [sessionKeyPrefix] — the live
///    `/sessions/*.jsonl` logs. Session records are version-independent
///    (an envelope schema bump can no longer wipe chat history), are
///    written EAGERLY on mutation (mobile browsers may never fire
///    `beforeunload`, so the #201 unload hook is not guaranteed), and fail
///    one-at-a-time: a torn or over-quota record damages at most that
///    session.
///
/// A v1 envelope (sessions inline) is migrated on restore, never wiped; an
/// unreadable or newer-version envelope is copied to [backupKey] before any
/// save may overwrite it. Snapshots encode from [FsSnapshotExporter]'s
/// synchronous point-in-time export when the delegate supports it (issue
/// #201), so a saved record is never a torn mid-walk view.
///
/// Restore happens in [restore], awaited by `createPlatformEnv` before the
/// `AgentService` is built. A missing, unreadable, or corrupt snapshot
/// yields a clean filesystem — persistence problems must never crash boot.
/// Persistence errors after boot are swallowed the same way: the sandbox
/// keeps working in memory and the next mutation retries the save.
final class PersistentWebExecutionEnv
    implements ExecutionEnv, BackgroundShell, RangedReadFileSystem {
  PersistentWebExecutionEnv._(this._delegate, this._store, this._persistDelay);

  /// Schema version of the JSON snapshot envelope. v2 moves session files
  /// out of the envelope into [sessionKeyPrefix] records (issue #237). v1
  /// envelopes restore (migration); anything else is backed up under
  /// [backupKey], never silently discarded.
  static const snapshotVersion = 2;

  /// Storage key holding the versioned JSON envelope. Kept as `sandbox`
  /// (the pre-#237 IndexedDB key) so existing stored v1 data migrates in
  /// place instead of being abandoned.
  static const storageKey = 'sandbox';

  /// Backup key an unreadable envelope is preserved under (issue #237).
  static const backupKey = 'sandbox.bak';

  /// Per-session-file record key prefix: `sandbox.session<path>`
  /// (issue #237).
  static const sessionKeyPrefix = 'sandbox.session';

  /// Session files in the web sandbox: the `/sessions/*.jsonl` logs the
  /// app's JsonlSessionRepo writes (the web sessions root is `/sessions`,
  /// see sessions_root.dart) plus the extension-shaped root-level
  /// `/session(-id).jsonl` for parity with #236. Keep in sync with both.
  static final _sessionPathPattern = RegExp(
    r'^/sessions/.+\.jsonl$|^/session(-.+)?\.jsonl$',
  );

  static bool _isSessionPath(String path) =>
      _sessionPathPattern.hasMatch(path);

  final ExecutionEnv _delegate;
  final FsRecordStore _store;
  final Duration _persistDelay;

  Timer? _timer;
  bool _dirty = false;
  bool _disposed = false;
  Future<void>? _saving;

  /// Session-record keys currently present in storage (seeded at restore,
  /// rewritten after each successful save). Saves remove ONLY keys whose
  /// session file the user deleted — never live session data (issue #237,
  /// eviction vector).
  Set<String> _knownSessionKeys = {};

  /// One debug log per failure burst; reset by the next successful save so
  /// a NEW outage is reported again.
  bool _persistErrorLogged = false;

  /// Creates the wrapper and replays the stored snapshot into [delegate].
  static Future<PersistentWebExecutionEnv> restore(
    ExecutionEnv delegate,
    FsRecordStore store, {
    Duration persistDelay = const Duration(milliseconds: 800),
  }) async {
    final env = PersistentWebExecutionEnv._(delegate, store, persistDelay);
    await env._restore();
    return env;
  }

  Future<void> _restore() async {
    Map<String, String> all;
    try {
      all = await _store.loadAll();
    } on Object {
      return; // Storage unavailable (blocked, private mode) → clean start.
    }
    // 1. The envelope: the non-session tree. v1 (sessions inline) migrates;
    //    anything unreadable or newer-version is backed up BEFORE the first
    //    save could overwrite it — version bumps must never wipe (issue
    //    #237 vector 2).
    final raw = all[storageKey];
    if (raw != null && raw.isNotEmpty && !await _restoreEnvelope(raw)) {
      try {
        await _store.save(backupKey, raw);
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
      try {
        await _delegate.writeBinaryFile(path, base64Decode(entry.value));
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
      // Parse and validate everything before touching the FS so a corrupt
      // snapshot cannot leave a half-restored tree.
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
      return true;
    } on Object {
      // Corrupt snapshot → clean start, never crash boot.
      return false;
    }
  }

  /// Maps a storage key back to its session path, or null when the key is
  /// not a session record (validated against the session path shape so a
  /// foreign `sandbox.session…`-ish key can't inject arbitrary paths).
  static String? _sessionPathOfKey(String key) {
    if (!key.startsWith(sessionKeyPrefix)) return null;
    final path = key.substring(sessionKeyPrefix.length);
    return _isSessionPath(path) ? path : null;
  }

  /// True when a mutation at [path] touches session data: the session
  /// files themselves, the sessions directory, or the fs root (a recursive
  /// wipe takes the sessions with it). Session-affecting mutations persist
  /// eagerly.
  static bool _affectsSessions(String path) =>
      _isSessionPath(path) ||
      path == '/' ||
      path.isEmpty ||
      path == '/sessions';

  void _schedulePersist({bool session = false}) {
    if (_disposed) return;
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(_persistDelay, () => unawaited(_persistNow()));
    if (session) {
      // Session mutations skip the debounce (issue #237): mobile browsers
      // may never fire beforeunload, so the #201 unload hook cannot be the
      // only safety net for the tail of a conversation. Saves serialize
      // through _persistNow, so a burst of appends coalesces into the
      // in-flight loop's next pass; the timer above stays armed as the
      // backstop for the join-a-dying-save race.
      unawaited(_persistNow());
    }
  }

  /// Persists immediately when changes are pending. Awaits any in-flight
  /// save (an eager session save may already hold the loop with [_dirty]
  /// cleared), so after [flush] returns all mutations so far are stored.
  Future<void> flush() async {
    _timer?.cancel();
    if (_dirty) await _persistNow();
    final inFlight = _saving;
    if (inFlight != null) await inFlight;
  }

  /// Serializes saves: concurrent callers share one in-flight loop.
  Future<void> _persistNow() {
    if (_disposed) return Future.value();
    return _saving ??= _persistLoop().whenComplete(() => _saving = null);
  }

  Future<void> _persistLoop() async {
    while (_dirty && !_disposed) {
      _dirty = false;
      try {
        await _saveOnce();
        _persistErrorLogged = false;
      } on Object catch (error) {
        // Save failed (quota, blocked storage): stay dirty so the next
        // mutation or flush retries; never break the sandbox over it.
        // Log once per failure burst — a silent permanent failure here is
        // how sessions "disappeared" (nothing ever reached the disk).
        if (!_persistErrorLogged) {
          _persistErrorLogged = true;
          // ignore: avoid_print
          print('[fahFs] persist failed (sessions NOT saved): $error');
        }
        _dirty = true;
        return;
      }
    }
  }

  /// One save pass: session records first (each its own storage record, so
  /// an over-quota session fails ALONE and previously-saved records are
  /// never touched), then the session-free envelope, then removal of
  /// records whose session file was deleted. Throws when anything failed —
  /// the caller re-arms the retry.
  Future<void> _saveOnce() async {
    // Point-in-time export (issue #201): encode from a synchronous deep
    // copy when the delegate supports it — the async walk below yields to
    // the event loop between entries, so a concurrent write could
    // interleave mid-walk and persist a torn tree.
    final (dirs, files) = await _exportTree();
    final envelopeFiles = <Map<String, String>>[];
    final sessionRecords = <String, String>{};
    for (final file in files.entries) {
      final encoded = base64Encode(file.value);
      if (_isSessionPath(file.key)) {
        sessionRecords['$sessionKeyPrefix${file.key}'] = encoded;
      } else {
        envelopeFiles.add({'path': file.key, 'data': encoded});
      }
    }
    var failed = false;
    for (final record in sessionRecords.entries) {
      try {
        await _store.save(record.key, record.value);
      } on Object {
        failed = true; // This session stays dirty; the rest keep saving.
      }
    }
    await _store.save(
      storageKey,
      jsonEncode({
        'version': snapshotVersion,
        'dirs': dirs,
        'files': envelopeFiles,
      }),
    );
    if (failed) {
      throw StateError('a session record could not be saved (quota?)');
    }
    // Evict ONLY records whose session file is gone from the tree (user
    // delete / session reset); live session data is never dropped.
    final stale = _knownSessionKeys.difference(sessionRecords.keys.toSet());
    if (stale.isNotEmpty) await _store.remove(stale.toList());
    _knownSessionKeys = sessionRecords.keys.toSet();
  }

  /// The whole tree as (dirs, files): the synchronous point-in-time export
  /// (issue #201) when the delegate is an [FsSnapshotExporter], otherwise
  /// the historical async walk.
  Future<(List<String>, Map<String, Uint8List>)> _exportTree() async {
    final delegate = _delegate;
    if (delegate case final FsSnapshotExporter exporter) {
      final snapshot = exporter.exportSnapshot();
      return (snapshot.dirs, snapshot.files);
    }
    // Fallback for non-memory delegates: the historical async walk.
    final dirs = <String>[];
    final files = <String, Uint8List>{};
    Future<void> walk(String dir) async {
      final entries = (await _delegate.listDir(dir)).valueOrNull;
      if (entries == null) return;
      for (final entry in entries) {
        if (entry.kind == FileKind.directory) {
          dirs.add(entry.path);
          await walk(entry.path);
        } else {
          final bytes = (await _delegate.readBinaryFile(
            entry.path,
          )).valueOrNull;
          if (bytes != null) files[entry.path] = bytes;
        }
      }
    }

    await walk(_delegate.cwd);
    return (dirs, files);
  }

  /// True when mutations since the last completed save are still
  /// unpersisted (including a save that failed and armed the retry).
  bool get hasPendingChanges => _dirty;

  /// Best-effort persistence for page unload: the web bootstrap binds this
  /// to `beforeunload` and `visibilitychange(hidden)` (see
  /// `bindUnloadFlush` in `unload_flush.dart`). Without it, a panel unload
  /// inside the 800 ms debounce window silently dropped the last mutations
  /// (issue #201 — and the extension side panel unloads on every close).
  /// Sessions are part of every save pass (their own records, issue #237),
  /// so a session mutation flushed here reaches storage too.
  /// Returns the flush future so tests can await it; browser event
  /// handlers fire-and-forget it.
  Future<void> onPageUnload() => flush();

  /// Stops the debounce timer. Pending unsaved changes are dropped; call
  /// [flush] first when they matter.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    final result = await _delegate.exec(command, options: options);
    // The shell works on the delegate's memory FS directly (it was attached
    // before this wrapper existed), so any command may have mutated the
    // tree — schedule a snapshot regardless of the exit status.
    _schedulePersist();
    return result;
  }

  // Background shell jobs: forwarded to the delegate (the web MemoryShell
  // supports them). A job's log writes land in the delegate's memory FS
  // directly, so they join the next scheduled snapshot rather than
  // triggering one per chunk — jobs are session-lifetime anyway.

  @override
  bool get backgroundJobsSupported {
    final delegate = _delegate;
    if (delegate case final BackgroundShell bg) {
      return bg.backgroundJobsSupported;
    }
    return false;
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) {
    final delegate = _delegate;
    if (delegate case final BackgroundShell bg) {
      return bg.startShellJob(
        command,
        id: id,
        logPath: logPath,
        options: options,
      );
    }
    return Future.value(
      const Err(
        ExecutionError(
          ExecutionErrorCode.shellUnavailable,
          'background shell jobs are not supported by this shell',
        ),
      ),
    );
  }

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
    if (result.isOk) _schedulePersist(session: path == '/sessions');
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
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) {
    final delegate = _delegate;
    if (delegate case final RangedReadFileSystem ranged) {
      return ranged.readRange(path, start, end);
    }
    return Future.value(
      Err(
        FileError(
          FileErrorCode.notSupported,
          'readRange not supported by $delegate',
          path: path,
        ),
      ),
    );
  }

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
