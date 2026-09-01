/// ExecutionEnv-backed [KbStorage] — maps the memory package's CRUD + file
/// operations onto `ExecutionEnv` under a base directory (`.fah/memory/`).
///
/// This is the integration seam between `flutter_agent_memory` and the
/// harness: every file read/write goes through the env abstraction, so it
/// works identically on CLI (real filesystem), the Flutter app (sandbox),
/// and tests (MemoryExecutionEnv).
library;

import 'dart:async';

import 'package:flutter_agent_memory/flutter_agent_memory.dart';

import '../env/execution_env.dart';

/// A [KbStorage] backed by an [ExecutionEnv] under [baseDir].
final class ExecutionEnvKbStorage
    with KbStorageContextMixin
    implements KbStorage, KbAppendCapable {
  ExecutionEnvKbStorage(this._env, this._baseDir);

  final ExecutionEnv _env;
  final String _baseDir;

  String _path(String type, String id) => '$_baseDir/$type/$id.md';
  String _filePath(String path) => '$_baseDir/$path';

  @override
  FutureOr<void> initialize({bool clean = false}) async {
    if (clean) {
      await _env.remove(_baseDir, recursive: true, force: true);
    }
    await _env.createDir('$_baseDir/question');
    await _env.createDir('$_baseDir/answer');
    await _env.createDir('$_baseDir/note');
  }

  @override
  FutureOr<String?> readEntity(String type, String id) async =>
      (await _env.readTextFile(_path(type, id))).valueOrNull;

  @override
  FutureOr<void> writeEntity(String type, String id, String content) =>
      _env.writeFile(_path(type, id), content);

  @override
  FutureOr<void> deleteEntity(String type, String id) =>
      _env.remove(_path(type, id), force: true);

  /// Deletes the entity with [id] across all entity types. Returns whether
  /// a file was removed (false = unknown id in this storage).
  Future<bool> deleteEntityById(String id) async {
    for (final type in const ['question', 'answer', 'note']) {
      final path = _path(type, id);
      if ((await _env.exists(path)).valueOrNull != true) continue;
      await _env.remove(path, force: true);
      return true;
    }
    return false;
  }

  @override
  FutureOr<List<String>> listEntityIds(String type) async {
    final result = await _env.listDir('$_baseDir/$type');
    final entries = result.valueOrNull ?? const [];
    return [
      for (final entry in entries)
        if (entry.kind != FileKind.directory && entry.path.endsWith('.md'))
          entry.path.split('/').last.replaceAll('.md', ''),
    ];
  }

  @override
  FutureOr<String?> readFile(String path) async =>
      (await _env.readTextFile(_filePath(path))).valueOrNull;

  @override
  FutureOr<void> writeFile(String path, String content) =>
      _env.writeFile(_filePath(path), content);

  /// Native append (flutter_agent_memory 0.2.1): the deletion ledger is
  /// append-only, so racing deletes must both land — the read-modify-write
  /// fallback would re-open the last-writer-wins hole that clobbered a
  /// 144-entry ledger in production.
  @override
  FutureOr<void> appendFile(String path, String content) =>
      _env.appendFile(_filePath(path), content);

  @override
  FutureOr<List<String>> listFilePaths(String prefix) async {
    final result = await _env.listDir(_filePath(prefix));
    final entries = result.valueOrNull ?? const [];
    return [
      for (final entry in entries) entry.path.replaceFirst('$_baseDir/', ''),
    ];
  }

  @override
  String describeLocation(String type, String id) => _path(type, id);
}
