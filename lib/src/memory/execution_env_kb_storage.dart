/// A [KbStorage] backed by an [ExecutionEnv] under [baseDir].
///
/// This is the integration seam between `flutter_agent_memory` and the
/// harness: every file read/write goes through the env abstraction, so it
/// works identically on CLI (real filesystem), the Flutter app (sandbox),
/// and tests (MemoryExecutionEnv).
///
/// Implements [KbTombstoneCapable] (flutter_agent_memory 0.2.3): deletions
/// through the library (`KBMemoryStore.deleteRecord` →
/// `MemoryDeletionService`) rewrite the entity file in place as a tombstone
/// instead of unlinking it, so two agents in different git branches can
/// delete and modify the same record and a rebase/merge completes with zero
/// manual conflict resolution. [readEntity] reports tombstones as absent —
/// including tombstones written by a CLI agent or another tool on the same
/// shared store — so a deleted record never surfaces as a live one.
library;

import 'dart:async';

import 'package:flutter_agent_memory/flutter_agent_memory.dart';

import '../env/execution_env.dart';

/// A [KbStorage] backed by an [ExecutionEnv] under [baseDir].
final class ExecutionEnvKbStorage
    with KbStorageContextMixin
    implements KbStorage, KbAppendCapable, KbTombstoneCapable {
  ExecutionEnvKbStorage(this._env, this._baseDir);

  final ExecutionEnv _env;
  final String _baseDir;

  /// The entity types, in canonical order.
  static const _entityTypes = ['question', 'answer', 'note'];

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
  FutureOr<String?> readEntity(String type, String id) async {
    final content = (await _env.readTextFile(_path(type, id))).valueOrNull;
    if (content == null) return null;
    // Tombstoned files stay on disk for conflict-free git merges; readers
    // must see the entity as absent — whoever wrote the tombstone (this
    // harness, a CLI agent, an older/newer tool on the same store).
    return FileKbStorage.isTombstoneContent(content) ? null : content;
  }

  @override
  FutureOr<void> writeEntity(String type, String id, String content) =>
      _env.writeFile(_path(type, id), content);

  @override
  FutureOr<void> deleteEntity(String type, String id) =>
      _env.remove(_path(type, id), force: true);

  @override
  FutureOr<void> tombstoneEntity(String type, String id) => writeEntity(
    type,
    id,
    // The marker format is the package's public API — never re-implement
    // it here (a divergent marker would read as a live record).
    FileKbStorage.tombstoneContentFor(id, currentUtcTimestamp()),
  );

  /// Physically removes tombstoned entity files and returns the sorted
  /// purged ids. Re-introduces deletions into git history — run only in
  /// maintenance windows (quiet, no concurrent writer); the harness wires
  /// no automatic purge (E3: opt-in manual/CLI use only). The ledger and
  /// `deleted/` records keep the deletion history, so purging loses
  /// nothing.
  ///
  /// Scope note for the second-tier gc card: this adapter backs BOTH the
  /// project store (git-committed, where tombstones buy conflict-free
  /// merges) and the user store (machine-local, never committed —
  /// tombstones bring no merge benefit yet still accumulate on disk until
  /// an opt-in purge). The gc card's scope must cover both stores.
  @override
  FutureOr<List<String>> purgeTombstones() async {
    final removed = <String>[];
    for (final type in _entityTypes) {
      for (final id in await listEntityIds(type)) {
        final content = (await _env.readTextFile(_path(type, id))).valueOrNull;
        if (content == null || !FileKbStorage.isTombstoneContent(content)) {
          continue;
        }
        await _env.remove(_path(type, id), force: true);
        removed.add(id);
      }
    }
    return removed..sort();
  }

  /// Deletes the entity file physically across all entity types. Returns
  /// whether a file was removed (false = unknown id in this storage).
  ///
  /// Harness-local helper — NOT the library deletion path. Library
  /// deletions must go through `KBMemoryStore.deleteRecord` (as
  /// `MemoryController.delete` already does): that is what tombstones the
  /// file, records the `deleted/` entry and keeps git merges conflict-free.
  @Deprecated(
    'Physical unlink reintroduces delete/modify git conflicts. Use '
    'MemoryController.delete (KBMemoryStore.deleteRecord → tombstone) '
    'instead; this helper stays only for harness-local teardown paths.',
  )
  Future<bool> deleteEntityById(String id) async {
    for (final type in _entityTypes) {
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
