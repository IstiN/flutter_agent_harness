// ponytail: small extension twin of flutter_app/lib/sandbox/persistent_web_env.dart.
// MemoryExecutionEnv is `final` (can't extend outside lib/), so this wraps it —
// same shape as the Flutter sandbox's wrapper.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/src/env/delegating_execution_env.dart';
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
final class ChromeStorageEnv extends ForwardingFs {
  ChromeStorageEnv._(this._storage, MemoryExecutionEnv mem)
    : _mem = mem,
      super(mem);

  /// The in-memory tree under the forwarding view; typed access for the
  /// synchronous snapshot export ([FsSnapshotExporter]).
  final MemoryExecutionEnv _mem;

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
    final env = ChromeStorageEnv._(storage, MemoryExecutionEnv(cwd: '/'));
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
    if (raw is String && raw.isNotEmpty) {
      final restoredV1 = await restoreSnapshotEnvelope(
        delegate,
        raw,
        snapshotVersion,
      );
      if (restoredV1 == null) {
        try {
          await storage.set({backupKey: raw});
        } on Object {
          // Backup failed (blocked storage): boot continues clean either
          // way.
        }
      } else {
        // A v1 envelope just came back to life: until a save pass has
        // written every session record and replaced it, it stays the only
        // durable copy of the sessions (issue #238 F1).
        _envelopeIsV1 = restoredV1;
      }
    }
    // 2. Session records overlay the envelope (version-independent keys,
    //    newer-or-equal truth) and seed the eviction set (#228).
    _knownSessionKeys.addAll(
      await restoreSessionRecords(delegate, all, _sessionPathOfKey),
    );
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
    final snapshot = _mem.exportSnapshot();
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

  /// True when a mutation at [path] touches session data: the session
  /// files themselves, or the fs root (a recursive wipe takes the sessions
  /// with it). Session-affecting mutations persist eagerly.
  static bool _affectsSessions(String path) =>
      _isSessionPath(path) || path == '/' || path.isEmpty;

  /// Mirrors every successful mutation into storage; session-affecting
  /// ones persist eagerly. `createDir` stays debounced-only (pre-#1996
  /// behavior — only file/session mutations skip the debounce).
  @override
  void afterMutation(String path) {
    _schedulePersist(session: _affectsSessions(path));
  }

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) async {
    final result = await delegate.createDir(path, recursive: recursive);
    if (result.isOk) _schedulePersist();
    return result;
  }
}
