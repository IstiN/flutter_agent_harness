// The taskpane [ExecutionEnv] (issue #89): the twin of the extension's
// ChromeStorageEnv with persistence INJECTED — [read]/[write] closures over
// whatever the host wires up (localStorage in office_main.dart, a plain map
// in VM tests). Wraps a MemoryExecutionEnv (whole fs in memory,
// never-throw invariant) and mirrors every mutation into a debounced
// (~800ms) whole-tree snapshot — at this sandbox scale a full snapshot per
// debounce beats journaling, and a single replaced record keeps storage
// bounded. A missing or corrupt snapshot yields a clean filesystem:
// persistence problems never crash boot, and post-boot save failures are
// swallowed (the next mutation or flush retries).
//
// There is no shell in an Office taskpane: [exec] answers with a clean
// error naming the sandbox — the outlook.* tools are the action surface.
//
// Pure Dart: no dart:io, no js_interop — VM-testable, dart2js-compileable.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';

final class OfficeStorageEnv implements ExecutionEnv {
  /// Creates the env and replays the stored snapshot into the memory tree.
  /// [read]/[write] are synchronous so the whole restore happens in the
  /// constructor — no mutation can ever race it (single-threaded isolate).
  OfficeStorageEnv({
    required this._read,
    required this._write,
    this.storageKey = 'faOfficeFs',
  }) : _delegate = MemoryExecutionEnv(cwd: '/') {
    _restore();
  }

  final MemoryExecutionEnv _delegate;
  final String? Function(String key) _read;
  final void Function(String key, String value) _write;

  /// Snapshot schema version. Different version → ignored, clean start.
  static const snapshotVersion = 1;

  /// Storage key holding the versioned JSON envelope.
  final String storageKey;

  static const _persistDelay = Duration(milliseconds: 800);

  Timer? _timer;
  bool _dirty = false;
  bool _disposed = false;
  Future<void>? _saving;

  void _restore() {
    final String? raw;
    try {
      raw = _read(storageKey);
    } on Object {
      return; // Storage unavailable (privacy mode, blocked) → clean start.
    }
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['version'] != snapshotVersion) return;
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
        _delegate.createDir(dir);
      }
      for (final (path, bytes) in files) {
        _delegate.writeBinaryFile(path, bytes);
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
  /// save; call after each agent run so a reloaded taskpane never loses a
  /// turn.
  Future<void> flush() async {
    _timer?.cancel();
    if (_dirty) await _persistNow();
  }

  /// Stops the debounce timer; pending unsaved changes are dropped.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }

  Future<void> _persistNow() {
    if (_disposed) return Future.value();
    return _saving ??= _persistLoop().whenComplete(() => _saving = null);
  }

  Future<void> _persistLoop() async {
    while (_dirty && !_disposed) {
      _dirty = false;
      try {
        _write(storageKey, await _snapshot());
      } on Object {
        // Save failed (quota, blocked storage): stay dirty so the next
        // mutation or flush retries; never break the sandbox over it.
        _dirty = true;
        return;
      }
    }
  }

  /// No shell in the Office taskpane — say so, and point at outlook.*.
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return Err(
      ExecutionError(
        ExecutionErrorCode.shellUnavailable,
        'shell unavailable in the Office taskpane sandbox: bash is '
        'unavailable; use the outlook.* tools to act on the mailbox',
      ),
    );
  }

  @override
  String get cwd => _delegate.cwd;

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
