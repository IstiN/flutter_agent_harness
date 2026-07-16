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
