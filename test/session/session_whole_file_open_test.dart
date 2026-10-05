import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:flutter_agent_harness/src/session/session_storage.dart';
import 'package:test/test.dart';

/// gh-1073 coverage regression: the streamed open became the default on
/// every [RangedReadFileSystem], leaving the legacy whole-file open
/// (`JsonlSessionStorage._openWholeFileLocked` + `_collectSegmentRecords`
/// — the fallback for pure web stores without byte-range reads) at 0%
/// unit coverage. The CRAP ratchet (threshold 12.0, coverage-aware)
/// failed the head at CRAP 90/42 for those two functions. These tests
/// stand in for the web store: a [FileSystem]-only decorator hides the
/// range-read capability, so `open` must take the whole-file path.
final class NonRangedFileSystem implements FileSystem {
  NonRangedFileSystem(this._delegate);

  final FileSystem _delegate;

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
}

void main() {
  late MemoryFileSystem fs;
  const path = '/sessions/whole.jsonl';

  setUp(() {
    fs = MemoryFileSystem();
  });

  String headerLine() => jsonEncode({
    'type': 'session',
    'version': 3,
    'id': 'gh-1073-whole',
    'timestamp': '2026-09-07T00:00:00.000Z',
    'cwd': '/work',
  });

  String messageLine(String id, {String? parentId, String text = 'hi'}) =>
      jsonEncode({
        'type': 'message',
        'id': id,
        if (parentId != null) 'parentId': parentId,
        'timestamp': '2026-09-07T00:00:01.000Z',
        'message': {'role': 'user', 'content': text},
      });

  group('gh-1073: whole-file open (non-ranged filesystem)', () {
    test('opens header + messages and tracks the leaf', () async {
      await fs.writeFile(path, '${[
        headerLine(),
        messageLine('m1'),
        messageLine('m2', parentId: 'm1'),
      ].join('\n')}\n');
      final storage = await JsonlSessionStorage.open(
        NonRangedFileSystem(fs),
        path,
      );
      expect((await storage.getEntries()).map((e) => e.id), ['m1', 'm2']);
      expect(await storage.getLeafId(), 'm2');
      expect(storage.quarantinedEntries, 0);
    });

    test('merges rotated parts, dedupes the restore leftover', () async {
      // A failed-rotation restore left part-0001 as an exact copy of the
      // primary: the open must keep the first copy of every record id
      // (the segment rewrite scrubs the duplicated lines too).
      await fs.writeFile('$path.part-0001', '${[
        headerLine(),
        messageLine('e1'),
      ].join('\n')}\n');
      await fs.writeFile(path, '${[
        headerLine(),
        messageLine('e1'),
        messageLine('e2', parentId: 'e1'),
      ].join('\n')}\n');
      final warnings = <String>[];
      final oldWarn = JsonlSessionStorage.onRotationWarning;
      JsonlSessionStorage.onRotationWarning = warnings.add;
      try {
        final storage = await JsonlSessionStorage.open(
          NonRangedFileSystem(fs),
          path,
        );
        expect((await storage.getEntries()).map((e) => e.id), ['e1', 'e2']);
        expect(
          (await storage.getPathToRoot('e2')).map((e) => e.id),
          ['e1', 'e2'],
        );
        expect(
          warnings.where((w) => w.contains('duplicated')),
          isNotEmpty,
          reason: 'the duplicate drop is surfaced, not silent',
        );
      } finally {
        JsonlSessionStorage.onRotationWarning = oldWarn;
      }
    });

    test('quarantines a torn line and rewrites the segment', () async {
      await fs.writeFile(
        path,
        '${headerLine()}\n${messageLine('m1')}\n{"type":"message","id":"to',
      );
      final storage = await JsonlSessionStorage.open(
        NonRangedFileSystem(fs),
        path,
      );
      expect(storage.quarantinedEntries, 1);
      expect((await storage.getEntries()).map((e) => e.id), ['m1']);
      // Forensics sidecar + clean rewrite so the next open is torn-free.
      final corrupt = (await fs.readTextFile('$path.corrupt')).getOrThrow();
      expect(corrupt, contains('"to'));
      final reopened = await JsonlSessionStorage.open(
        NonRangedFileSystem(fs),
        path,
      );
      expect(reopened.quarantinedEntries, 0);
      expect((await reopened.getEntries()).map((e) => e.id), ['m1']);
    });

    test('fails closed on a missing session file', () async {
      await expectLater(
        JsonlSessionStorage.open(NonRangedFileSystem(fs), path),
        throwsA(isA<SessionException>()),
      );
    });

    test('wholeFileOnly opens through bulk reads on a ranged fs', () async {
      // gh-1073 regression (flutter shard 1/2, agent_service_windowed):
      // the default full open STREAMS over ranged reads, so an
      // error-recovery retry on a filesystem whose ranged reads just
      // failed would fail identically. `wholeFileOnly` forces the
      // classic whole-file read: a ranged fs with a dead readRange
      // still opens, while the default dispatch dies on it.
      final deadRange = DeadRangeFileSystem(fs);
      await fs.writeFile(path, '${[
        headerLine(),
        messageLine('m1'),
        messageLine('m2', parentId: 'm1'),
      ].join('\n')}\n');

      await expectLater(
        JsonlSessionStorage.open(deadRange, path),
        throwsA(isA<SessionException>()),
        reason: 'the default streamed open rides ranged reads',
      );

      final storage = await JsonlSessionStorage.open(
        deadRange,
        path,
        wholeFileOnly: true,
      );
      expect((await storage.getEntries()).map((e) => e.id), ['m1', 'm2']);
      expect(storage.quarantinedEntries, 0);
    });
  });
}

/// A [FileSystem] that advertises the ranged-read capability (like the
/// app's IO filesystem) but fails every [readRange] — the production
/// shape behind "the ranged path just died", where an error-recovery
/// retry must not ride that capability again.
final class DeadRangeFileSystem implements FileSystem, RangedReadFileSystem {
  DeadRangeFileSystem(this._delegate);

  final FileSystem _delegate;

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
  ) async => Err(
        FileError(
          FileErrorCode.notSupported,
          'ranged reads unavailable',
          path: path,
        ),
      );
}
