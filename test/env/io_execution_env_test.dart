import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late LocalFileSystem fs;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('harness-io-test-');
    fs = LocalFileSystem(cwd: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('LocalFileSystem', () {
    test('write/append/read round-trip on real disk', () async {
      expect((await fs.writeFile('a/b.txt', 'one\n')).isOk, isTrue);
      expect((await fs.appendFile('a/b.txt', 'two\n')).isOk, isTrue);
      expect((await fs.readTextFile('a/b.txt')).valueOrNull, 'one\ntwo\n');
      expect(File('${tempDir.path}/a/b.txt').readAsStringSync(), 'one\ntwo\n');
    });

    test('binary write/read round-trip on real disk', () async {
      final bytes = Uint8List.fromList([0, 1, 2, 255]);
      expect((await fs.writeBinaryFile('bin.dat', bytes)).isOk, isTrue);
      final read = await fs.readBinaryFile('bin.dat');
      expect(read.valueOrNull, bytes);
      expect(File('${tempDir.path}/bin.dat').readAsBytesSync(), bytes);
    });

    test('exists, listDir, createDir, remove against real disk', () async {
      await fs.createDir('d/sub');
      await fs.writeFile('d/f.txt', 'data');
      expect((await fs.exists('d')).valueOrNull, isTrue);
      expect((await fs.exists('d/missing')).valueOrNull, isFalse);

      final infos = (await fs.listDir('d')).getOrThrow();
      expect(infos.map((i) => i.name), containsAll(['sub', 'f.txt']));
      expect(infos.firstWhere((i) => i.name == 'sub').kind, FileKind.directory);

      await fs.remove('d', recursive: true);
      expect((await fs.exists('d')).valueOrNull, isFalse);
    });

    test('readTextLines and missing-file errors', () async {
      await fs.writeFile('l.txt', 'a\nb\n');
      expect((await fs.readTextLines('l.txt')).getOrThrow(), ['a', 'b']);
      final missing = await fs.readTextFile('nope.txt');
      expect(missing.errorOrNull?.code, FileErrorCode.notFound);
    });

    test('readTextLines with maxLines truncates the output', () async {
      await fs.writeFile('many.txt', 'a\nb\nc\nd\n');
      expect((await fs.readTextLines('many.txt', maxLines: 2)).getOrThrow(), [
        'a',
        'b',
      ]);
    });

    test(
      'readTextLines with maxLines above the line count reads all',
      () async {
        await fs.writeFile('few.txt', 'a\nb\n');
        expect((await fs.readTextLines('few.txt', maxLines: 10)).getOrThrow(), [
          'a',
          'b',
        ]);
      },
    );

    test('readTextLines with non-positive maxLines returns empty', () async {
      await fs.writeFile('z.txt', 'a\nb\n');
      expect(
        (await fs.readTextLines('z.txt', maxLines: 0)).getOrThrow(),
        isEmpty,
      );
      expect(
        (await fs.readTextLines('z.txt', maxLines: -3)).getOrThrow(),
        isEmpty,
      );
    });

    test('readTextLines on a missing file maps to notFound', () async {
      final result = await fs.readTextLines('nope.txt');
      expect(result.errorOrNull?.code, FileErrorCode.notFound);
      expect(result.errorOrNull?.path, '${tempDir.path}/nope.txt');
    });

    test('absolutePath resolves relatives against cwd', () async {
      expect(
        (await fs.absolutePath('x.txt')).getOrThrow(),
        '${tempDir.path}/x.txt',
      );
    });

    test('fileInfo reports real size', () async {
      await fs.writeFile('s.txt', 'hello');
      final info = (await fs.fileInfo('s.txt')).getOrThrow();
      expect(info.size, 5);
      expect(info.kind, FileKind.file);
    });

    group('error mapping', () {
      test('missing file maps to notFound', () async {
        final missing = await fs.readTextFile('nope.txt');
        final error = missing.errorOrNull;
        expect(error?.code, FileErrorCode.notFound);
        expect(error?.path, '${tempDir.path}/nope.txt');
      });

      test('reading a directory maps to isDirectory', () async {
        await fs.createDir('a-dir');
        expect(
          (await fs.readTextFile('a-dir')).errorOrNull?.code,
          FileErrorCode.isDirectory,
        );
        expect(
          (await fs.readBinaryFile('a-dir')).errorOrNull?.code,
          FileErrorCode.isDirectory,
        );
      });

      test('unreadable file maps to permissionDenied', () async {
        await fs.writeFile('locked.txt', 'secret');
        final locked = '${tempDir.path}/locked.txt';
        Process.runSync('chmod', ['000', locked]);
        try {
          final result = await fs.readTextFile('locked.txt');
          expect(result.errorOrNull?.code, FileErrorCode.permissionDenied);
        } finally {
          Process.runSync('chmod', ['644', locked]);
        }
      }, skip: Platform.isWindows ? 'POSIX chmod semantics only' : false);

      test('path through a regular file maps to notDirectory', () async {
        await fs.writeFile('plain.txt', 'data');
        final result = await fs.listDir('plain.txt/child');
        expect(result.errorOrNull?.code, FileErrorCode.notDirectory);
      });

      test('a symlink loop maps to unknown', () async {
        Link('${tempDir.path}/loop-a').createSync('loop-b');
        Link('${tempDir.path}/loop-b').createSync('loop-a');
        final result = await fs.readTextFile('loop-a');
        expect(result.errorOrNull?.code, FileErrorCode.unknown);
      }, skip: Platform.isWindows ? 'POSIX symlink semantics only' : false);
    });

    group('remove', () {
      test('removes a file', () async {
        await fs.writeFile('gone.txt', 'data');
        expect((await fs.remove('gone.txt')).isOk, isTrue);
        expect((await fs.exists('gone.txt')).valueOrNull, isFalse);
      });

      test('removes an empty directory non-recursively', () async {
        await fs.createDir('empty-dir');
        expect((await fs.remove('empty-dir')).isOk, isTrue);
        expect((await fs.exists('empty-dir')).valueOrNull, isFalse);
      });

      test('missing path without force maps to notFound', () async {
        final result = await fs.remove('missing.txt');
        expect(result.errorOrNull?.code, FileErrorCode.notFound);
      });

      test('missing path with force succeeds', () async {
        expect((await fs.remove('missing.txt', force: true)).isOk, isTrue);
      });

      test('non-empty directory without recursive maps to invalid', () async {
        await fs.writeFile('full-dir/f.txt', 'data');
        final result = await fs.remove('full-dir');
        expect(result.errorOrNull?.code, FileErrorCode.invalid);
        expect((await fs.exists('full-dir')).valueOrNull, isTrue);
      }, skip: Platform.isWindows ? 'POSIX delete semantics only' : false);

      test('non-empty directory with recursive succeeds', () async {
        await fs.writeFile('tree/sub/f.txt', 'data');
        expect((await fs.remove('tree', recursive: true)).isOk, isTrue);
        expect((await fs.exists('tree')).valueOrNull, isFalse);
      });
    });
  });

  group('LocalShell', () {
    test('exec captures stdout and exit code', () async {
      const shell = LocalShell();
      final result = await shell.exec('echo hello');
      final exec = result.getOrThrow();
      expect(exec.stdout.trim(), 'hello');
      expect(exec.exitCode, 0);
    });

    test('exec reports non-zero exit codes without throwing', () async {
      const shell = LocalShell();
      final result = await shell.exec('exit 3');
      expect(result.getOrThrow().exitCode, 3);
    });

    test('exec honors timeout', () async {
      const shell = LocalShell();
      final result = await shell.exec(
        'sleep 5',
        options: const ShellExecOptions(timeout: Duration(milliseconds: 200)),
      );
      expect(result.errorOrNull?.code, ExecutionErrorCode.timeout);
    });

    test('exec supports env overrides', () async {
      const shell = LocalShell();
      final result = await shell.exec(
        'echo \$HARNESS_TEST_VAR',
        options: const ShellExecOptions(env: {'HARNESS_TEST_VAR': 'injected'}),
      );
      expect(result.getOrThrow().stdout.trim(), 'injected');
    });

    test('exec PATH gains common tool directories (Homebrew)', () async {
      const shell = LocalShell();
      final result = await shell.exec(r'echo "$PATH"');
      final path = result.getOrThrow().stdout.trim();
      for (final dir in const ['/opt/homebrew/bin', '/usr/local/bin']) {
        if (Directory(dir).existsSync()) {
          expect(path.split(':'), contains(dir));
        }
      }
    });

    test('an explicit env PATH is preserved, not replaced', () async {
      const shell = LocalShell();
      final result = await shell.exec(
        r'echo "$PATH"',
        options: const ShellExecOptions(env: {'PATH': '/bin'}),
      );
      final path = result.getOrThrow().stdout.trim();
      expect(path.split(':').first, '/bin');
    });

    test('env overrides merge over the host environment', () async {
      // Injected vars (secrets, FAH_SESSION_*) must not strip the inherited
      // environment — the doc contract is "values override the defaults".
      final result = await const LocalShell().exec(
        'echo "\$HOME|\$HARNESS_TEST_VAR"',
        options: ShellExecOptions(env: const {'HARNESS_TEST_VAR': 'injected'}),
      );
      final out = result.getOrThrow().stdout.trim();
      if (Platform.environment.containsKey('HOME')) {
        expect(out.split('|').first, Platform.environment['HOME']);
      }
      expect(out.split('|').last, 'injected');
    });

    test('exec closes stdin so commands like ripgrep do not hang '
        'when no path is given', () async {
      const shell = LocalShell();
      final result = await shell.exec('read line; echo "x\${line}x"');
      final exec = result.getOrThrow();
      expect(exec.stdout.trim(), 'xx');
    });
  });

  group('LocalExecutionEnv custom shell', () {
    test('uses the provided shell instead of LocalShell', () async {
      final captured = <String>[];
      final fakeShell = _FakeShell((command, {options}) async {
        captured.add(command);
        return const Ok(
          ShellExecResult(stdout: 'fake', stderr: '', exitCode: 42),
        );
      });
      final env = LocalExecutionEnv(cwd: tempDir.path, shell: fakeShell);
      final result = await env.exec('hello');
      expect(result.getOrThrow().exitCode, 42);
      expect(captured, ['hello']);
    });
  });
}

class _FakeShell implements Shell {
  _FakeShell(this._handler);

  final Future<Result<ShellExecResult, ExecutionError>> Function(
    String command, {
    ShellExecOptions? options,
  })
  _handler;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _handler(command, options: options);
}
