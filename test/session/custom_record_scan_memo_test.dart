import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:test/test.dart';

/// The `readCustomRecordsOfType` scan memo (gh-1734): the boot/switch
/// path scans the session chain for tail records (obligations ledger,
/// orphan reports, subagent registry, steering) on EVERY open/switch —
/// a 95MB-tail read on a marathon file each time. The repo memoizes the
/// scan result per (path, params, size, mtime): an unchanged file is
/// served from the memo, any append invalidates it.
void main() {
  late CountingRangeFs fs;
  late JsonlSessionRepo repo;
  late Session session;
  late SessionMetadata metadata;

  setUp(() async {
    fs = CountingRangeFs();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
    session = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await session.appendSessionName('scan-memo');
    await session.appendCustomEntry(customType: 'a_type', data: {'n': 1});
    metadata = await session.getMetadata();
    fs.rangeCalls.clear();
  });

  test('an unchanged file is scanned once — the repeat call is memoized',
      () async {
    final first = await repo.readCustomRecordsOfType(metadata, {'a_type'});
    expect(first, hasLength(1));
    final callsAfterFirst = fs.rangeCalls.length;
    expect(callsAfterFirst, greaterThan(0));

    final second = await repo.readCustomRecordsOfType(metadata, {'a_type'});
    expect(second, hasLength(1));
    expect(second.single.id, first.single.id);
    expect(
      fs.rangeCalls.length,
      callsAfterFirst,
      reason: 'the second scan must be served from the memo, not re-read',
    );
  });

  test('an append invalidates the memo — the new record is seen', () async {
    await repo.readCustomRecordsOfType(metadata, {'a_type'});
    final callsAfterFirst = fs.rangeCalls.length;

    await session.appendCustomEntry(customType: 'a_type', data: {'n': 2});
    final freshMetadata = await session.getMetadata();

    final second = await repo.readCustomRecordsOfType(
      freshMetadata,
      {'a_type'},
    );
    expect(second, hasLength(2));
    expect(
      fs.rangeCalls.length,
      greaterThan(callsAfterFirst),
      reason: 'a changed file must be re-scanned',
    );
  });

  test('records of another type are invisible to the memo entry', () async {
    await repo.readCustomRecordsOfType(metadata, {'a_type'});
    final other = await repo.readCustomRecordsOfType(metadata, {'b_type'});
    expect(other, isEmpty);
  });

  test('a multi-type scan memoizes independently of a single-type scan',
      () async {
    await repo.readCustomRecordsOfType(metadata, {'a_type'});
    final callsAfterSingle = fs.rangeCalls.length;
    final both = await repo.readCustomRecordsOfType(metadata, {
      'a_type',
      'b_type',
    });
    expect(both, hasLength(1));
    expect(
      fs.rangeCalls.length,
      greaterThan(callsAfterSingle),
      reason: 'a different type set is a different memo key',
    );
  });

  test('lastSegmentOnly scans are memoized under their own key', () async {
    await repo.readCustomRecordsOfType(metadata, {'a_type'});
    final callsAfterWhole = fs.rangeCalls.length;
    final lastOnly = await repo.readCustomRecordsOfType(
      metadata,
      {'a_type'},
      lastSegmentOnly: true,
    );
    expect(lastOnly, hasLength(1));
    expect(
      fs.rangeCalls.length,
      greaterThan(callsAfterWhole),
      reason: 'a different segment scope is a different memo key',
    );
    // And a repeat of the lastSegmentOnly shape hits ITS memo.
    final callsAfterLastOnly = fs.rangeCalls.length;
    await repo.readCustomRecordsOfType(
      metadata,
      {'a_type'},
      lastSegmentOnly: true,
    );
    expect(fs.rangeCalls.length, callsAfterLastOnly);
  });

  test('a memo hit returns records that decode identically', () async {
    final first = await repo.readCustomRecordsOfType(metadata, {'a_type'});
    final second = await repo.readCustomRecordsOfType(metadata, {'a_type'});
    expect(second.single.customType, first.single.customType);
    expect(second.single.data, first.single.data);
  });

  test('an explicit tail-cap change is a different memo key', () async {
    await repo.readCustomRecordsOfType(metadata, {'a_type'});
    final callsAfterDefault = fs.rangeCalls.length;
    final uncapped = await repo.readCustomRecordsOfType(
      metadata,
      {'a_type'},
      tailCapBytes: null,
    );
    expect(uncapped, hasLength(1));
    expect(
      fs.rangeCalls.length,
      greaterThan(callsAfterDefault),
      reason: 'uncapped scans must never be served by a capped memo entry',
    );
  });
}

/// A [FileSystem] counting ranged reads per path — the streamed
/// custom-record scan is the read path the memo must collapse.
final class CountingRangeFs implements FileSystem, RangedReadFileSystem {
  CountingRangeFs() : _delegate = MemoryFileSystem();

  final MemoryFileSystem _delegate;

  final rangeCalls = <String>[];

  @override
  String get cwd => _delegate.cwd;

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
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _delegate.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) =>
      _delegate.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) {
    rangeCalls.add(path);
    return _delegate.readRange(path, start, end);
  }
}
