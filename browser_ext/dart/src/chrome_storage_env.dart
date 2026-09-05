// ponytail: small extension twin of flutter_app/lib/sandbox/persistent_web_env.dart.
// MemoryExecutionEnv is `final` (can't extend outside lib/), so this wraps it —
// same shape as the Flutter sandbox's wrapper.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';

@JS('chrome.storage.local.get')
external JSPromise<JSAny?> _storageGet(JSAny? keys);

@JS('chrome.storage.local.set')
external JSPromise<JSAny?> _storageSet(JSObject items);

/// [ExecutionEnv] persisted into `chrome.storage.local` under [storageKey].
///
/// Wraps a [MemoryExecutionEnv] (whole fs in memory, never-throw invariant)
/// and mirrors every mutation into a debounced (~800ms) whole-tree snapshot
/// — at this sandbox scale a full snapshot per debounce beats journaling,
/// and a single replaced record keeps storage bounded (same trade as the
/// Flutter web sandbox). A missing or corrupt snapshot yields a clean
/// filesystem: persistence problems never crash boot, and post-boot save
/// failures are swallowed (next mutation retries).
///
/// There is no shell in a browser extension: [exec] answers with a clean
/// `shellUnavailable` error naming the sandbox — the `browser_*` tools are
/// the action surface.
final class ChromeStorageEnv implements ExecutionEnv {
  ChromeStorageEnv._() : _delegate = MemoryExecutionEnv(cwd: '/');

  final MemoryExecutionEnv _delegate;

  /// Snapshot schema version. Different version → ignored, clean start.
  static const snapshotVersion = 1;

  /// chrome.storage.local key holding the versioned JSON envelope.
  static const storageKey = 'faFs';

  static const _persistDelay = Duration(milliseconds: 800);

  Timer? _timer;
  bool _dirty = false;
  bool _disposed = false;
  bool _booting = true;
  Future<void>? _saving;

  /// Creates the env and replays the stored snapshot into the memory tree.
  static Future<ChromeStorageEnv> restore() async {
    final env = ChromeStorageEnv._();
    await env._restore();
    env._booting = false;
    return env;
  }

  Future<void> _restore() async {
    String? raw;
    try {
      final result = await _storageGet(storageKey.toJS).toDart;
      if (result == null) return;
      final stored = (result as JSObject).dartify() as Map<Object?, Object?>;
      raw = stored[storageKey] as String?;
    } on Object {
      return; // Storage unavailable (blocked, private mode) → clean start.
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
    if (_disposed || _booting) return;
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(_persistDelay, () => unawaited(_persistNow()));
  }

  /// Persists immediately when changes are pending. Awaits any in-flight
  /// save; call after each agent run so a reaped SW never loses a turn.
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
        await _storageSet(
          <String, dynamic>{storageKey: await _snapshot()}.jsify() as JSObject,
        ).toDart;
      } on Object {
        // Save failed (quota, blocked storage): stay dirty so the next
        // mutation or flush retries; never break the sandbox over it.
        _dirty = true;
        return;
      }
    }
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
