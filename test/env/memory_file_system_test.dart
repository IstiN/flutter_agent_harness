import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('Result', () {
    test('ok exposes value', () {
      const result = Ok<String, FileError>('hi');
      expect(result.isOk, isTrue);
      expect(result.isErr, isFalse);
      expect(result.valueOrNull, 'hi');
      expect(result.errorOrNull, isNull);
      expect(result.getOrThrow(), 'hi');
    });

    test('err exposes error and getOrThrow throws it', () {
      final result = Err<String, FileError>(
        FileError(FileErrorCode.notFound, 'missing'),
      );
      expect(result.isOk, isFalse);
      expect(result.isErr, isTrue);
      expect(result.valueOrNull, isNull);
      expect(result.errorOrNull?.code, FileErrorCode.notFound);
      expect(result.getOrThrow, throwsA(isA<FileError>()));
    });
  });

  group('MemoryFileSystem', () {
    late MemoryFileSystem fs;

    setUp(() {
      fs = MemoryFileSystem(cwd: '/work');
    });

    test('write then read round-trips, creating parent dirs', () async {
      final write = await fs.writeFile('a/b/c.txt', 'hello');
      expect(write.isOk, isTrue);
      final read = await fs.readTextFile('/work/a/b/c.txt');
      expect(read.valueOrNull, 'hello');
    });

    test('binary write/read round-trips', () async {
      final bytes = Uint8List.fromList([0, 1, 2, 255]);
      expect((await fs.writeBinaryFile('/work/bin.dat', bytes)).isOk, isTrue);
      final read = await fs.readBinaryFile('/work/bin.dat');
      expect(read.valueOrNull, bytes);
    });

    test('read of missing file returns not_found', () async {
      final result = await fs.readTextFile('nope.txt');
      expect(result.errorOrNull?.code, FileErrorCode.notFound);
    });

    test('read of a directory returns is_directory', () async {
      await fs.createDir('/work/dir');
      final result = await fs.readTextFile('/work/dir');
      expect(result.errorOrNull?.code, FileErrorCode.isDirectory);
    });

    test('appendFile appends and creates the file when missing', () async {
      await fs.appendFile('/work/log.txt', 'one\n');
      await fs.appendFile('/work/log.txt', 'two\n');
      expect(
        (await fs.readTextFile('/work/log.txt')).valueOrNull,
        'one\ntwo\n',
      );
    });

    test('writeFile overwrites existing content', () async {
      await fs.writeFile('/work/f.txt', 'first');
      await fs.writeFile('/work/f.txt', 'second');
      expect((await fs.readTextFile('/work/f.txt')).valueOrNull, 'second');
    });

    test(
      'exists is false for missing paths, true for files and dirs',
      () async {
        expect((await fs.exists('/work/x')).valueOrNull, isFalse);
        await fs.writeFile('/work/x/y.txt', 'y');
        expect((await fs.exists('/work/x')).valueOrNull, isTrue);
        expect((await fs.exists('/work/x/y.txt')).valueOrNull, isTrue);
      },
    );

    test('listDir returns direct children with kinds', () async {
      await fs.writeFile('/work/d/file.txt', 'data');
      await fs.createDir('/work/d/sub');
      final result = await fs.listDir('/work/d');
      final infos = result.getOrThrow();
      expect(infos, hasLength(2));
      final byName = {for (final info in infos) info.name: info};
      expect(byName['file.txt']?.kind, FileKind.file);
      expect(byName['file.txt']?.path, '/work/d/file.txt');
      expect(byName['file.txt']?.size, 4);
      expect(byName['sub']?.kind, FileKind.directory);
    });

    test('listDir on missing dir returns not_found', () async {
      final result = await fs.listDir('/work/ghost');
      expect(result.errorOrNull?.code, FileErrorCode.notFound);
    });

    test('listDir on a file returns not_directory', () async {
      await fs.writeFile('/work/f.txt', 'x');
      final result = await fs.listDir('/work/f.txt');
      expect(result.errorOrNull?.code, FileErrorCode.notDirectory);
    });

    test('createDir non-recursive fails when parent is missing', () async {
      final result = await fs.createDir('/work/no/parent', recursive: false);
      expect(result.errorOrNull?.code, FileErrorCode.notFound);
    });

    test('remove deletes files and, recursively, directories', () async {
      await fs.writeFile('/work/d/f.txt', 'x');
      final notRecursive = await fs.remove('/work/d');
      expect(notRecursive.errorOrNull?.code, FileErrorCode.invalid);
      await fs.remove('/work/d', recursive: true);
      expect((await fs.exists('/work/d')).valueOrNull, isFalse);
    });

    test('remove of a missing path fails unless force', () async {
      final result = await fs.remove('/work/ghost');
      expect(result.errorOrNull?.code, FileErrorCode.notFound);
      expect((await fs.remove('/work/ghost', force: true)).isOk, isTrue);
    });

    test('readTextLines splits lines and honors maxLines', () async {
      await fs.writeFile('/work/l.txt', 'a\nb\nc\n');
      expect((await fs.readTextLines('/work/l.txt')).getOrThrow(), [
        'a',
        'b',
        'c',
      ]);
      expect(
        (await fs.readTextLines('/work/l.txt', maxLines: 2)).getOrThrow(),
        ['a', 'b'],
      );
      expect(
        (await fs.readTextLines('/work/l.txt', maxLines: 0)).getOrThrow(),
        isEmpty,
      );
    });

    test(
      'absolutePath resolves relatives against cwd and normalizes',
      () async {
        expect(
          (await fs.absolutePath('x/../y.txt')).getOrThrow(),
          '/work/y.txt',
        );
        expect(
          (await fs.absolutePath('/abs/p.txt')).getOrThrow(),
          '/abs/p.txt',
        );
      },
    );

    test('joinPath joins segments in the fs namespace', () async {
      expect(
        (await fs.joinPath(['/root', 'a', 'b.txt'])).getOrThrow(),
        '/root/a/b.txt',
      );
    });

    test('fileInfo reports size and mtime', () async {
      await fs.writeFile('/work/f.txt', 'hello');
      final info = (await fs.fileInfo('/work/f.txt')).getOrThrow();
      expect(info.kind, FileKind.file);
      expect(info.size, 5);
      expect(info.mtimeMs, greaterThan(0));
    });
  });

  group('MemoryFileSystem.exportSnapshot', () {
    test('exports an empty tree', () {
      final fs = MemoryFileSystem(cwd: '/');
      final snapshot = fs.exportSnapshot();
      expect(snapshot.dirs, isEmpty);
      expect(snapshot.files, isEmpty);
    });

    test('exports the subtree below cwd, deep-first and name-sorted',
        () async {
      final fs = MemoryFileSystem(cwd: '/work');
      await fs.writeFile('/work/b/2.txt', 'two');
      await fs.writeFile('/work/a.txt', 'a');
      await fs.writeFile('/work/b/1.txt', 'one');
      await fs.createDir('/work/c/empty');
      await fs.writeFile('/elsewhere/outside.txt', 'out');

      final snapshot = fs.exportSnapshot();
      expect(snapshot.dirs, ['/work/b', '/work/c', '/work/c/empty']);
      expect(snapshot.files.keys, [
        '/work/a.txt',
        '/work/b/1.txt',
        '/work/b/2.txt',
      ]);
      expect(
        snapshot.files.entries.map((e) => utf8.decode(e.value)),
        ['a', 'one', 'two'],
      );
    });

    test('deep-copies file bytes (later writes cannot mutate the export)',
        () async {
      final fs = MemoryFileSystem(cwd: '/');
      // writeBinaryFile stores the caller's buffer BY REFERENCE, so a
      // shallow export would observe this later mutation.
      final bytes = Uint8List.fromList(utf8.encode('before'));
      await fs.writeBinaryFile('/f.bin', bytes);
      final snapshot = fs.exportSnapshot();
      bytes[0] = 'X'.codeUnitAt(0);
      await fs.appendFile('/f.bin', '!');
      expect(utf8.decode(snapshot.files['/f.bin']!), 'before');
    });

    test('export order matches an async listDir walk', () async {
      final fs = MemoryFileSystem(cwd: '/');
      await fs.writeFile('/x/y/z.txt', 'z');
      await fs.writeFile('/x/a.txt', 'a');
      await fs.createDir('/x/empty');

      final walkedDirs = <String>[];
      final walkedFiles = <String>[];
      Future<void> walk(String dir) async {
        for (final entry in (await fs.listDir(dir)).getOrThrow()) {
          if (entry.kind == FileKind.directory) {
            walkedDirs.add(entry.path);
            await walk(entry.path);
          } else {
            walkedFiles.add(entry.path);
          }
        }
      }

      await walk('/');
      final snapshot = fs.exportSnapshot();
      expect(snapshot.dirs, walkedDirs);
      expect(snapshot.files.keys.toList(), walkedFiles);
    });
  });

  group('MemoryExecutionEnv', () {
    test('is an ExecutionEnv with an unavailable shell by default', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('/tmp/x.txt', 'x');
      expect((await env.readTextFile('/tmp/x.txt')).valueOrNull, 'x');
      final result = await env.exec('echo hi');
      expect(result.errorOrNull?.code, ExecutionErrorCode.shellUnavailable);
    });

    test('accepts a custom shell', () async {
      final env = MemoryExecutionEnv(shell: _FakeShell());
      final result = await env.exec('anything');
      expect(result.getOrThrow().stdout, 'fake');
    });
  });
}

final class _FakeShell implements Shell {
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return const Ok(ShellExecResult(stdout: 'fake', stderr: '', exitCode: 0));
  }
}
