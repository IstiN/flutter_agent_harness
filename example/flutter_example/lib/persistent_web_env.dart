// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'fs_persistence.dart';

/// An [ExecutionEnv] wrapper that mirrors the delegate's filesystem into an
/// [FsSnapshotStore] so the web sandbox (an in-memory FS) survives page
/// reloads.
///
/// Mutations (`write*`, `appendFile`, `createDir`, `remove`) and every
/// [exec] — the shell operates on the delegate's memory FS directly, so any
/// command may have changed the tree — schedule a debounced full-tree
/// snapshot. At this sandbox scale a full snapshot per debounce is simpler
/// and more robust than per-operation journaling, and a single replaced
/// record keeps storage bounded.
///
/// Restore happens in [restore], awaited by `createPlatformEnv` before the
/// `AgentService` is built. A missing, unreadable, or corrupt snapshot
/// yields a clean filesystem — persistence problems must never crash boot.
/// Persistence errors after boot are swallowed the same way: the sandbox
/// keeps working in memory and the next mutation retries the save.
final class PersistentWebExecutionEnv implements ExecutionEnv {
  PersistentWebExecutionEnv._(this._delegate, this._store, this._persistDelay);

  /// Schema version of the JSON snapshot envelope. Snapshots with a
  /// different version are ignored (clean start) rather than migrated.
  static const snapshotVersion = 1;

  final ExecutionEnv _delegate;
  final FsSnapshotStore _store;
  final Duration _persistDelay;

  Timer? _timer;
  bool _dirty = false;
  bool _disposed = false;
  Future<void>? _saving;

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
    String? raw;
    try {
      raw = await _store.load();
    } on Object {
      return; // Storage unavailable (blocked, private mode) → clean start.
    }
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['version'] != snapshotVersion) return;
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
    } on Object {
      // Corrupt or incompatible snapshot → clean start, never crash boot.
    }
  }

  Future<String> _snapshot() async {
    final dirs = <String>[];
    final files = <Map<String, String>>[];
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
          if (bytes != null) {
            files.add({'path': entry.path, 'data': base64Encode(bytes)});
          }
        }
      }
    }

    await walk(_delegate.cwd);
    return jsonEncode({
      'version': snapshotVersion,
      'dirs': dirs,
      'files': files,
    });
  }

  void _schedulePersist() {
    if (_disposed) return;
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(_persistDelay, () => unawaited(_persistNow()));
  }

  /// Persists immediately when changes are pending. Awaits any in-flight
  /// save, so after [flush] returns all mutations so far are stored.
  Future<void> flush() async {
    _timer?.cancel();
    if (_dirty) await _persistNow();
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
        await _store.save(await _snapshot());
      } on Object {
        // Save failed (quota, blocked storage): stay dirty so the next
        // mutation or flush retries; never break the sandbox over it.
        _dirty = true;
        return;
      }
    }
  }

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

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) async {
    final result = await _delegate.writeBinaryFile(path, content);
    if (result.isOk) _schedulePersist();
    return result;
  }

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    final result = await _delegate.writeFile(path, content);
    if (result.isOk) _schedulePersist();
    return result;
  }

  @override
  Future<Result<void, FileError>> appendFile(
    String path,
    String content,
  ) async {
    final result = await _delegate.appendFile(path, content);
    if (result.isOk) _schedulePersist();
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
    if (result.isOk) _schedulePersist();
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
