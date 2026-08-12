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
final class ExecutionEnvKbStorage implements KbStorage {
  ExecutionEnvKbStorage(this._env, this._baseDir);

  final ExecutionEnv _env;
  final String _baseDir;

  String _path(String type, String id) => '$_baseDir/$type/$id.md';
  String _filePath(String path) => '$_baseDir/$path';

  @override
  FutureOr<void> initialize({bool clean = false}) async {
    if (clean) {
      // Best-effort: list and delete everything under baseDir.
      try {
        final entries = await _env.listDirectory(_baseDir);
        for (final entry in entries) {
          if (entry.isDirectory) {
            await _env.deleteDirectory(entry.path, recursive: true);
          } else {
            await _env.deleteFile(entry.path);
          }
        }
      } on Object {
        // Directory may not exist yet — fine.
      }
    }
    // Ensure the base directory exists.
    try {
      await _env.createDirectory('$_baseDir/question');
      await _env.createDirectory('$_baseDir/answer');
      await _env.createDirectory('$_baseDir/note');
    } on Object {
      // May already exist — fine.
    }
  }

  @override
  FutureOr<KBContext> loadContext() {
    // KBContext is loaded lazily by KBMemoryStore; return empty.
    return KBContext();
  }

  @override
  FutureOr<String?> readEntity(String type, String id) async {
    final result = await _env.readTextFile(_path(type, id));
    return result.valueOrNull;
  }

  @override
  FutureOr<void> writeEntity(String type, String id, String content) {
    return _env.writeFile(_path(type, id), content);
  }

  @override
  FutureOr<void> deleteEntity(String type, String id) async {
    try {
      await _env.deleteFile(_path(type, id));
    } on Object {
      // Already gone — fine.
    }
  }

  @override
  FutureOr<List<String>> listEntityIds(String type) async {
    final dir = '$_baseDir/$type';
    try {
      final entries = await _env.listDirectory(dir);
      return [
        for (final entry in entries)
          if (!entry.isDirectory && entry.path.endsWith('.md'))
            entry.path.split('/').last.replaceAll('.md', ''),
      ];
    } on Object {
      return const [];
    }
  }

  @override
  FutureOr<String?> readFile(String path) async {
    final result = await _env.readTextFile(_filePath(path));
    return result.valueOrNull;
  }

  @override
  FutureOr<void> writeFile(String path, String content) {
    return _env.writeFile(_filePath(path), content);
  }

  @override
  FutureOr<List<String>> listFilePaths(String prefix) async {
    try {
      final entries = await _env.listDirectory(_filePath(prefix));
      return [for (final entry in entries) entry.path.replaceFirst('$_baseDir/', '')];
    } on Object {
      return const [];
    }
  }

  @override
  String describeLocation(String type, String id) => _path(type, id);
}
