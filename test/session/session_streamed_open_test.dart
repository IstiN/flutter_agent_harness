import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_record.dart';
import 'package:flutter_agent_harness/src/session/session_storage.dart';
import 'package:test/test.dart';

/// A [FileSystem] decorator that counts `readTextFile` calls — gh-1073's
/// crash was `readTextFile` materializing a 12 GiB session as one String.
final class CountingFileSystem implements FileSystem {
  CountingFileSystem(this._delegate);

  final FileSystem _delegate;
  int readTextFileCalls = 0;
  int readRangeCalls = 0;

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    readTextFileCalls++;
    return _delegate.readTextFile(path);
  }

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) async {
    readRangeCalls++;
    return _delegate.readRange(path, start, end);
  }

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
  const path = '/sessions/stream.jsonl';

  setUp(() {
    fs = MemoryFileSystem();
  });

  Future<void> writeLines(List<String> lines) async {
    await fs.writeFile(path, '${lines.join('\n')}\n');
  }

  String headerLine() => jsonEncode({
    'type': 'session',
    'version': 3,
    'id': 'gh-1073',
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

  /// A `custom` record whose `data` payload is [padChars] long — the
  /// canonical writer field order (`customType` before `data`) so the
  /// shallow-parse header extraction applies.
  String giantCustomLine(
    String id, {
    required String customType,
    String? parentId,
    int padChars = 128 * 1024,
    Object? data,
  }) => jsonEncode({
    'type': 'custom',
    'id': id,
    if (parentId != null) 'parentId': parentId,
    'timestamp': '2026-09-07T00:00:02.000Z',
    'customType': customType,
    'data': data ?? 'p' * padChars,
  });

  group('gh-1073: streamed full open', () {
    test('never materializes the file through readTextFile', () async {
      await writeLines([
        headerLine(),
        messageLine('m1'),
        giantCustomLine('c1', customType: 'model_request_summary'),
        messageLine('m2', parentId: 'm1'),
      ]);
      final counting = CountingFileSystem(fs);
      final storage = await JsonlSessionStorage.open(counting, path);
      expect(counting.readTextFileCalls, 0,
          reason: 'a range-capable filesystem must stream, never '
              'readTextFile the whole session');
      expect(counting.readRangeCalls, greaterThan(0));
      expect((await storage.getEntries()).map((e) => e.id),
          ['m1', 'c1', 'm2']);
      expect(await storage.getLeafId(), 'm2');
    });

    test('giant custom records load shallow; the LATEST per customType '
        'keeps full data', () async {
      await writeLines([
        headerLine(),
        giantCustomLine('c1', customType: 'shell_job_registry', data: {
          'generation': 1,
        }),
        giantCustomLine('c2', customType: 'shell_job_registry', data: {
          'generation': 2,
        }),
        giantCustomLine(
          'c3',
          customType: 'model_request_summary',
          data: {'messageCount': 5},
        ),
      ]);
      final storage = await JsonlSessionStorage.open(fs, path);
      final entries = await storage.getEntries();
      final byId = {for (final e in entries) e.id: e};
      final c1 = byId['c1']! as CustomRecord;
      final c2 = byId['c2']! as CustomRecord;
      final c3 = byId['c3']! as CustomRecord;
      // Chain integrity survives the stubbing: ids, parents, timestamps.
      expect(c1.customType, 'shell_job_registry');
      expect(c2.customType, 'shell_job_registry');
      // Superseded giants are stubbed — holding all their payloads is
      // what grew the ledger to 12 GiB.
      expect(c1.data, isNull, reason: 'superseded giant payload is dropped');
      // The LATEST giant per customType keeps full data so resume-time
      // rehydration (job board, subagent registry) still sees the truth.
      expect(c2.data, {'generation': 2});
      expect(c3.data, {'messageCount': 5});
    });

    test('giant NON-custom records keep full fidelity', () async {
      final big = 'x' * (128 * 1024);
      await writeLines([
        headerLine(),
        messageLine('m1', text: big),
      ]);
      final storage = await JsonlSessionStorage.open(fs, path);
      final entry = (await storage.getEntries()).single as MessageRecord;
      expect((entry.message as dynamic).content, big);
    });

    test('open above the size backstop refuses with a repair hint',
        () async {
      await writeLines([
        headerLine(),
        messageLine('m1'),
      ]);
      final info = (await fs.fileInfo(path)).getOrThrow();
      final storage = await JsonlSessionStorage.open(
        fs,
        path,
        maxFullOpenBytes: info.size - 1,
      );
      expect(await storage.getEntries(), isNotEmpty,
          reason: 'at the bound exactly still opens');
      await expectLater(
        JsonlSessionStorage.open(fs, path, maxFullOpenBytes: info.size - 2),
        throwsA(
          isA<SessionException>()
              .having((e) => e.code, 'code', SessionErrorCode.tooLarge)
              .having(
                (e) => e.message,
                'message',
                contains('fa session repair'),
              ),
        ),
      );
    });

    test('torn writes heal through the streamed path byte-identically',
        () async {
      final good = [
        headerLine(),
        messageLine('m1'),
        messageLine('m2', parentId: 'm1'),
      ];
      await fs.writeFile(
        path,
        '${good.join('\n')}\n{"type":"message","id":"to', // torn write
      );
      final storage = await JsonlSessionStorage.open(fs, path);
      expect(storage.quarantinedEntries, 1);
      expect((await storage.getEntries()).map((e) => e.id), ['m1', 'm2']);
      // The file is rewritten from the surviving records so later opens
      // see whole JSONL.
      final healed = (await fs.readTextFile(path)).getOrThrow();
      expect(jsonDecode(healed.split('\n').last), isNull,
          reason: 'sanity: last split piece after trailing newline is empty');
      final lines = healed.trim().split('\n');
      expect(lines.length, 3);
      expect(jsonDecode(lines[2]), isA<Map<String, dynamic>>());
      expect((jsonDecode(lines[2]) as Map)['id'], 'm2');
      // Quarantine sidecar holds the torn bytes.
      final corrupt = (await fs.readTextFile('$path.corrupt')).getOrThrow();
      expect(corrupt, contains('"to'));
    });

    test('blank lines are skipped without breaking spans', () async {
      await fs.writeFile(
        path,
        '${headerLine()}\n\n${messageLine('m1')}\n\n',
      );
      final counting = CountingFileSystem(fs);
      final storage = await JsonlSessionStorage.open(counting, path);
      expect((await storage.getEntries()).map((e) => e.id), ['m1']);
      expect(counting.readTextFileCalls, 0);
      // No torn lines: the file is not rewritten.
      expect((await fs.exists('$path.corrupt')).getOrThrow(), isFalse);
    });
  });
}
