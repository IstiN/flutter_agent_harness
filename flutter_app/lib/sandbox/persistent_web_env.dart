// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/sandbox/fs_persistence.dart';

/// An [ExecutionEnv] wrapper that mirrors the delegate's filesystem into an
/// [FsSnapshotStore] so the web sandbox (an in-memory FS) survives page
/// reloads.
///
/// Mutations (`write*`, `appendFile`, `createDir`, `remove`) and every
/// [exec] — the shell operates on the delegate's memory FS directly, so any
/// command may have changed the tree — schedule a debounced full-tree
/// snapshot. At this sandbox scale a full snapshot per debounce is simpler
/// and more robust than per-operation journaling, and replaced records
/// keep storage bounded.
///
/// Mirroring the extension twin's #228/#236 fix, the store is a record map,
/// not one blob (issue #237):
///
///  * the versioned JSON envelope under [storageKey] holds the whole tree
///    EXCEPT session files, so it stays small and an oversized session can
///    never take unrelated saves down with it (quota isolation);
///  * one record per session file under [sessionKeyPrefix] — the
///    `JsonlSessionRepo` transcripts under `/sessions/`. Session records
///    are version-independent (an envelope schema bump can no longer wipe
///    chat history) and fail one-at-a-time: a torn or over-quota record
///    damages at most that session.
///
/// A v1 envelope (sessions inline) is migrated on restore, never wiped; an
/// unreadable or newer-version envelope is copied to [backupKey] before
/// any save may overwrite it. Snapshots still encode from the synchronous
/// point-in-time export (#201 — the session path rides that fix), and the
/// unload flush carries session records like everything else. Persistence
/// problems never crash boot; post-boot save failures stay dirty and retry
/// on the next mutation or [flush].
///
/// Restore happens in [restore], awaited by `createPlatformEnv` before the
/// `AgentService` is built.
///
/// Two ordering guarantees pin the migration promise (issue #238, ported
/// with #240): the v1 envelope is replaced by the session-stripped v2
/// shape only in a pass that wrote EVERY session record — until then it
/// is the only durable copy of the sessions, so a failed record write
/// leaves it untouched — and stale-record eviction runs FIRST, so a later
/// failure in the pass cannot resurrect a deleted session. Residual: a
/// crash between the fs removal and the eviction step resurrects that
/// one session on next boot — deletion metadata, never chat data.
final class PersistentWebExecutionEnv
    implements ExecutionEnv, BackgroundShell, RangedReadFileSystem {
  PersistentWebExecutionEnv._(this._delegate, this._store, this._persistDelay);

  /// Store key holding the versioned JSON envelope (the whole tree EXCEPT
  /// session files).
  static const storageKey = 'sandbox';

  /// Store key an unreadable envelope is preserved under (issue #237).
  static const backupKey = '$storageKey.bak';

  /// Per-session-file record key prefix: `sandbox.session<path>` (issue
  /// #237, mirroring the extension twin's `faFs.session`).
  static const sessionKeyPrefix = '$storageKey.session';

  /// Envelope schema version. v2 moves session files out of the envelope
  /// into [sessionKeyPrefix] records (issue #237). v1 envelopes restore
  /// (migration); anything else is backed up under [backupKey], never
  /// silently discarded.
  static const snapshotVersion = 2;

  /// Session files under the app's sessions root (see `sessions_root.dart`
  /// + `JsonlSessionRepo`: `/sessions/<encoded-cwd>/<ts>_<id>.jsonl`).
  /// Keep in sync with that layout.
  static final _sessionPathPattern = RegExp(r'^/sessions/.+\.jsonl$');

  static bool _isSessionPath(String path) => _sessionPathPattern.hasMatch(path);

  /// True when a mutation at [path] touches session data: the session
  /// files themselves, the sessions root (a recursive wipe takes the
  /// sessions with it), or the fs root. Session-affecting mutations
  /// persist eagerly (skip the debounce).
  static bool _affectsSessions(String path) =>
      _isSessionPath(path) ||
      path == '/' ||
      path.isEmpty ||
      path == '/sessions';

  /// Maps a store key back to its session path, or null when the key is
  /// not a session record (validated against the session path shape so a
  /// foreign `sandbox.session…`-ish key can't inject arbitrary paths).
  static String? _sessionPathOfKey(String key) {
    if (!key.startsWith(sessionKeyPrefix)) return null;
    final path = key.substring(sessionKeyPrefix.length);
    return _isSessionPath(path) ? path : null;
  }

  final ExecutionEnv _delegate;
  final FsSnapshotStore _store;
  final Duration _persistDelay;

  Timer? _timer;
  bool _dirty = false;
  bool _disposed = false;
  Future<void>? _saving;

  /// Session-record keys currently present in the store (seeded at
  /// restore, rewritten after each successful save). Saves remove ONLY
  /// keys whose session file the user deleted — never live session data
  /// (issue #237, eviction vector).
  Set<String> _knownSessionKeys = {};

  /// True while the stored envelope is still the pre-migration v1
  /// (sessions inline): the only durable copy of the chat history until a
  /// save pass writes every session record and replaces it with v2
  /// (issue #238 F1, ported with #240).
  bool _envelopeIsV1 = false;

  /// One console warning per failure burst; reset by the next successful
  /// save so a NEW outage is reported again.
  bool _persistErrorLogged = false;

  /// Creates the wrapper and replays the stored snapshot into [delegate].
  static Future<PersistentWebExecutionEnv> restore(
    ExecutionEnv delegate,
    FsSnapshotStore store, {
    Duration persistDelay = const Duration(milliseconds: 800),
  }) async {
    final env = PersistentWebExecutionEnv._(delegate, store, persistDelay);
    await env._restore();
    return env;
  }

  Future<void> _restore() async {
    Map<String, String> all;
    try {
      all = await _store.load();
    } on Object {
      return; // Storage unavailable (blocked, private mode) → clean start.
    }
    // 1. The envelope: the non-session tree. v1 (sessions inline)
    //    migrates; anything unreadable or newer-version is backed up
    //    BEFORE the first save could overwrite it — version bumps must
    //    never wipe (issue #237 vector 2).
    final raw = all[storageKey];
    if (raw != null && raw.isNotEmpty && !await _restoreEnvelope(raw)) {
      try {
        await _store.save({backupKey: raw});
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
        // Torn record → skip this file only; the session layer's own
        // quarantine handles a broken JSONL from here.
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

  /// Point-in-time copy of the delegate tree: dirs and file bytes. Memory
  /// delegates go through [FsSnapshotExporter.exportSnapshot] — a
  /// synchronous deep copy with no yield points (#201); anything else
  /// keeps the historical async walk.
  Future<(List<String>, List<(String, Uint8List)>)> _exportTree() async {
    final delegate = _delegate;
    if (delegate case final FsSnapshotExporter exporter) {
      final snapshot = exporter.exportSnapshot();
      return (
        snapshot.dirs,
        [for (final file in snapshot.files.entries) (file.key, file.value)],
      );
    }
    final dirs = <String>[];
    final files = <(String, Uint8List)>[];
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
          if (bytes != null) files.add((entry.path, bytes));
        }
      }
    }

    await walk(_delegate.cwd);
    return (dirs, files);
  }

  void _schedulePersist({bool session = false}) {
    if (_disposed) return;
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(_persistDelay, () => unawaited(_persistNow()));
    if (session) {
      // Session mutations skip the debounce (issue #228 vector 3, ported
      // with #240): the page can crash at any moment and
      // beforeunload/visibilitychange only cover graceful unloads — a
      // pending window is how a transcript tail vanishes. Saves serialize
      // through _persistNow, so a burst of appends coalesces into the
      // in-flight loop's next pass; the timer stays armed as the
      // backstop for the join-a-dying-save race.
      unawaited(_persistNow());
    }
  }

  /// Persists immediately when changes are pending. Awaits any in-flight
  /// save (an eager session save may already hold the loop with [_dirty]
  /// cleared) — and since a mutation racing that pass re-arms [_dirty],
  /// gives the re-armed pass one turn too, so after [flush] returns all
  /// mutations so far are stored (a failed pass stays dirty for the next
  /// mutation or flush retry).
  Future<void> flush() async {
    _timer?.cancel();
    if (_dirty) {
      final joined = _saving;
      if (joined != null) {
        await joined;
        if (_dirty) {
          _timer?.cancel();
          await _persistNow();
        }
      } else {
        await _persistNow();
      }
    }
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
        // how sessions "disappeared" (nothing ever reached storage).
        if (!_persistErrorLogged) {
          _persistErrorLogged = true;
          // ignore: avoid_print
          print('[fah] sandbox persist failed (changes NOT saved): $error');
        }
        _dirty = true;
        return;
      }
    }
  }

  /// One save pass: eviction of records whose session file was deleted
  /// FIRST (issue #238 F2 — a later failure in the pass must not
  /// resurrect a deleted session), then session records (each its own
  /// store record, so an over-quota session fails ALONE and
  /// previously-saved records are never touched), then the session-free
  /// envelope — but never while the stored envelope is still the v1
  /// migration source and a record write failed: until every session
  /// record is durable, that envelope is the only durable copy of the
  /// sessions (issue #237 vector 2 × #238 F1). Throws when anything
  /// failed — the caller re-arms the retry.
  Future<void> _saveOnce() async {
    final (dirs, treeFiles) = await _exportTree();
    final envelopeFiles = <Map<String, String>>[];
    final sessionRecords = <String, String>{};
    for (final (path, bytes) in treeFiles) {
      final encoded = base64Encode(bytes);
      if (_isSessionPath(path)) {
        sessionRecords['$sessionKeyPrefix$path'] = encoded;
      } else {
        envelopeFiles.add({'path': path, 'data': encoded});
      }
    }
    var failed = false;
    // Evict ONLY records whose session file is gone from the tree (user
    // delete / session reset); live session data is never dropped (issue
    // #237 vector 1). Runs before the writes so nothing later in the
    // pass can skip it.
    final stale = _knownSessionKeys.difference(sessionRecords.keys.toSet());
    if (stale.isNotEmpty) {
      try {
        await _store.remove(stale);
        _knownSessionKeys.removeAll(stale);
      } on Object {
        failed = true; // retried by the next pass
      }
    }
    for (final record in sessionRecords.entries) {
      try {
        await _store.save({record.key: record.value});
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
      // unsaved tail.
      throw StateError(
        'a session record could not be saved (quota?); keeping the v1 '
        'envelope as the only durable copy of the sessions',
      );
    }
    await _store.save({
      storageKey: jsonEncode({
        'version': snapshotVersion,
        'dirs': dirs,
        'files': envelopeFiles,
      }),
    });
    if (failed) {
      throw StateError('a session record could not be saved (quota?)');
    }
    _envelopeIsV1 = false;
    _knownSessionKeys = sessionRecords.keys.toSet();
  }

  /// True when mutations since the last completed save are still
  /// unpersisted (including a save that failed and armed the retry).
  bool get hasPendingChanges => _dirty;

  /// Best-effort persistence for page unload: the web bootstrap binds this
  /// to `beforeunload` and `visibilitychange(hidden)` (see
  /// `bindUnloadFlush` in `unload_flush.dart`). Without it, a panel unload
  /// inside the 800 ms debounce window silently dropped the last mutations
  /// (issue #201 — and the extension side panel unloads on every close).
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
    if (result.isOk) _schedulePersist(session: _affectsSessions(path));
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
