import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

String _text(ToolExecutionResult result) {
  return result.content.whereType<TextContent>().map((b) => b.text).join();
}

Archive _fixtureArchive() {
  final archive = Archive();
  archive.addFile(ArchiveFile.string('hello.txt', 'one\ntwo\nthree\nfour'));
  archive.addFile(ArchiveFile.string('dir/nested.txt', 'nested\ncontent'));
  archive.addFile(ArchiveFile('dir/', 0, const <int>[])..isFile = false);
  archive.addFile(
    ArchiveFile('bin.dat', 4, Uint8List.fromList(const [0, 1, 2, 3])),
  );
  return archive;
}

Uint8List _zipBytes() => ZipEncoder().encodeBytes(_fixtureArchive());

Uint8List _tarBytes() => TarEncoder().encodeBytes(_fixtureArchive());

Uint8List _tgzBytes() => GZipEncoder().encodeBytes(_tarBytes());

void main() {
  group('parseArchivePathCandidates', () {
    test('splits archive from inner path', () {
      final candidates = parseArchivePathCandidates('a.zip:inner/file');
      expect(candidates, hasLength(1));
      expect(candidates.single.archivePath, 'a.zip');
      expect(candidates.single.subPath, 'inner/file');
    });

    test('bare archive path yields an empty subPath', () {
      final candidates = parseArchivePathCandidates('a.zip');
      expect(candidates.single.subPath, '');
    });

    test('handles every recognized extension', () {
      for (final path in ['a.zip', 'a.tar', 'a.tar.gz', 'a.tgz:x']) {
        expect(parseArchivePathCandidates(path), isNotEmpty, reason: path);
      }
      expect(parseArchivePathCandidates('a.gz'), isEmpty);
      expect(parseArchivePathCandidates('a.zipx'), isEmpty);
    });

    test('prefers the longest archive prefix on nested extensions', () {
      final candidates = parseArchivePathCandidates('a.zip:b.tar:c');
      expect(candidates.first.archivePath, 'a.zip:b.tar');
      expect(candidates.first.subPath, 'c');
      expect(candidates.last.archivePath, 'a.zip');
      expect(candidates.last.subPath, 'b.tar:c');
    });

    test('.tar.gz wins over .tar at the same position', () {
      final candidates = parseArchivePathCandidates('a.tar.gz');
      expect(candidates, hasLength(1));
      expect(candidates.single.archivePath, 'a.tar.gz');
    });

    test('is case-insensitive on the extension', () {
      final candidates = parseArchivePathCandidates('A.ZIP:x');
      expect(candidates.single.archivePath, 'A.ZIP');
    });
  });

  group('normalizeArchiveLookupPath', () {
    test('normalizes separators and dot segments', () {
      expect(normalizeArchiveLookupPath('a/./b//c'), 'a/b/c');
      expect(normalizeArchiveLookupPath(r'a\b\c'), 'a/b/c');
      expect(normalizeArchiveLookupPath(''), '');
      expect(normalizeArchiveLookupPath(null), '');
    });

    test('rejects parent traversal', () {
      expect(normalizeArchiveLookupPath('..'), isNull);
      expect(normalizeArchiveLookupPath('a/../b'), isNull);
    });
  });

  group('decodeUtf8Text', () {
    test('decodes valid UTF-8', () {
      expect(
        decodeUtf8Text(Uint8List.fromList(utf8.encode('héllo\n'))),
        'héllo\n',
      );
    });

    test('rejects NUL bytes and malformed UTF-8', () {
      expect(decodeUtf8Text(Uint8List.fromList(const [97, 0, 98])), isNull);
      expect(
        decodeUtf8Text(Uint8List.fromList(const [0xFF, 0xFE, 0xFD])),
        isNull,
      );
    });
  });

  group('ArchiveReader', () {
    test('indexes entries with synthesized parent directories', () {
      final reader = ArchiveReader.decode(_zipBytes(), ArchiveFormat.zip);
      expect(reader.getNode('')!.isDirectory, isTrue);
      expect(reader.getNode('dir')!.isDirectory, isTrue);
      expect(reader.getNode('hello.txt')!.isDirectory, isFalse);
      expect(reader.getNode('hello.txt')!.size, 18);
      expect(reader.getNode('missing'), isNull);
    });

    test('lists immediate children only', () {
      final reader = ArchiveReader.decode(_zipBytes(), ArchiveFormat.zip);
      final root = reader.listDirectory('');
      expect(
        root.map((e) => e.name),
        containsAll(['hello.txt', 'dir', 'bin.dat']),
      );
      final dir = reader.listDirectory('dir');
      expect(dir.map((e) => e.name), ['nested.txt']);
    });

    test('listing errors match omp', () {
      final reader = ArchiveReader.decode(_zipBytes(), ArchiveFormat.zip);
      expect(
        () => reader.listDirectory('..'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            "Archive path cannot contain '..'",
          ),
        ),
      );
      expect(
        () => reader.listDirectory('nope'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            "Archive path 'nope' not found",
          ),
        ),
      );
      expect(
        () => reader.listDirectory('hello.txt'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            "Archive path 'hello.txt' is not a directory",
          ),
        ),
      );
    });

    test('reads member bytes across zip, tar, and tar.gz', () {
      for (final (bytes, format) in [
        (_zipBytes(), ArchiveFormat.zip),
        (_tarBytes(), ArchiveFormat.tar),
        (_tgzBytes(), ArchiveFormat.tarGz),
      ]) {
        final reader = ArchiveReader.decode(bytes, format);
        expect(
          utf8.decode(reader.readFileBytes('hello.txt')),
          'one\ntwo\nthree\nfour',
          reason: '$format',
        );
      }
    });

    test('member read errors match omp', () {
      final reader = ArchiveReader.decode(_zipBytes(), ArchiveFormat.zip);
      expect(
        () => reader.readFileBytes('nope'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            "Archive path 'nope' not found",
          ),
        ),
      );
      expect(
        () => reader.readFileBytes('dir'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            "Archive path 'dir' is a directory",
          ),
        ),
      );
    });

    test('a corrupt archive fails with a clear error', () {
      expect(
        () => ArchiveReader.decode(
          Uint8List.fromList(utf8.encode('not an archive')),
          ArchiveFormat.zip,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot read archive'),
          ),
        ),
      );
    });
  });

  group('readFileTool archive targets', () {
    late MemoryExecutionEnv env;
    late AgentTool tool;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      tool = readFileTool(env);
    });

    test('a bare archive path lists the root', () async {
      await env.writeBinaryFile('a.zip', _zipBytes());
      final result = await tool.execute({'path': 'a.zip'}, null, null);
      final lines = _text(result).split('\n');
      expect(lines, containsAll(['dir/', 'bin.dat (4B)', 'hello.txt (18B)']));
    });

    test('an inner directory lists its children', () async {
      await env.writeBinaryFile('a.zip', _zipBytes());
      final result = await tool.execute({'path': 'a.zip:dir'}, null, null);
      expect(_text(result), 'nested.txt (14B)');
    });

    test('reads an inner text member', () async {
      await env.writeBinaryFile('a.zip', _zipBytes());
      final result = await tool.execute(
        {'path': 'a.zip:hello.txt'},
        null,
        null,
      );
      expect(_text(result), 'one\ntwo\nthree\nfour');
    });

    test('applies line selectors after extraction', () async {
      await env.writeBinaryFile('a.zip', _zipBytes());
      final result = await tool.execute(
        {'path': 'a.zip:hello.txt:2-3'},
        null,
        null,
      );
      expect(
        _text(result),
        'two\nthree\n\n[1 more lines in archive entry. Use offset=4 to '
        'continue.]',
      );
    });

    test('applies multi-range selectors to members', () async {
      await env.writeBinaryFile('a.zip', _zipBytes());
      final result = await tool.execute(
        {'path': 'a.zip:hello.txt:1-1,4-4'},
        null,
        null,
      );
      expect(_text(result), 'one\n\n…\n\nfour');
    });

    test('a member range past EOF gets the graceful note', () async {
      await env.writeBinaryFile('a.zip', _zipBytes());
      final result = await tool.execute(
        {'path': 'a.zip:hello.txt:9'},
        null,
        null,
      );
      expect(
        _text(result),
        'Line 9 is beyond end of archive entry (4 lines total). Use :1 to '
        'read from the start, or :4 to read the last line.',
      );
    });

    test('binary members return a note instead of bytes', () async {
      await env.writeBinaryFile('a.zip', _zipBytes());
      final result = await tool.execute({'path': 'a.zip:bin.dat'}, null, null);
      expect(
        _text(result),
        "[Cannot read binary archive entry 'bin.dat' (4B)]",
      );
    });

    test('missing members throw a not-found-inside-archive error', () async {
      await env.writeBinaryFile('a.zip', _zipBytes());
      expect(
        tool.execute({'path': 'a.zip:nope.txt'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains("Path 'a.zip:nope.txt' not found inside archive"),
          ),
        ),
      );
    });

    test('a selector on the archive root offsets the listing', () async {
      await env.writeBinaryFile('a.zip', _zipBytes());
      final result = await tool.execute({'path': 'a.zip:500'}, null, null);
      expect(_text(result), '(empty archive directory)');
    });

    test('multi-range selectors are rejected for listings', () async {
      await env.writeBinaryFile('a.zip', _zipBytes());
      expect(
        tool.execute({'path': 'a.zip:1-2,5-6'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not supported for archive directory listings'),
          ),
        ),
      );
    });

    test('reads tar and tar.gz members too', () async {
      await env.writeBinaryFile('a.tar', _tarBytes());
      expect(
        _text(await tool.execute({'path': 'a.tar:hello.txt:2'}, null, null)),
        'two\nthree\nfour',
      );
      await env.writeBinaryFile('a.tgz', _tgzBytes());
      expect(
        _text(await tool.execute({'path': 'a.tgz:hello.txt:1-2'}, null, null)),
        'one\ntwo\n\n[2 more lines in archive entry. Use offset=3 to '
        'continue.]',
      );
      await env.writeBinaryFile('b.tar.gz', _tgzBytes());
      expect(
        _text(await tool.execute({'path': 'b.tar.gz:dir'}, null, null)),
        'nested.txt (14B)',
      );
    });

    test('a missing archive falls through to a file not-found error', () async {
      expect(
        tool.execute({'path': 'missing.zip:inner.txt'}, null, null),
        throwsA(isA<StateError>()),
      );
    });
  });
}
