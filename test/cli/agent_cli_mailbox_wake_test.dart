// Wake-command and wake-launcher tests for `agent_cli_inbox.dart`, split
// out of `agent_cli_test.dart` (gh-1744 review): that suite sat 2 lines
// under the repo's 2800-line god-file ceiling on main, and the
// launchMailboxWake group pushed it over. Both groups exercise only
// public API (`mailboxWakeCommand`, `launchMailboxWake`,
// `MemoryExecutionEnv`, `ShellExecResult`), so they move to their own
// file — no part/privacy gymnastics needed. (`agent_cli_inbox_wake_test`
// was taken by the gh-1180 wake-lane suite.)

import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('mailboxWakeCommand', () {
    test('falls back to fa on PATH and the session id as the address', () {
      final c = mailboxWakeCommand(wakeExecutable: null, sessionId: 'abc-123');
      expect(c, startsWith("nohup 'fa' --session 'abc-123'"));
      expect(c, contains('& echo woken'));
    });

    test('prefers the configured executable and the session name', () {
      final c = mailboxWakeCommand(
        wakeExecutable: '/usr/local/bin/fa',
        sessionId: '01a06102',
        sessionName: 'jsr',
      );
      expect(c, contains("nohup '/usr/local/bin/fa' --session 'jsr'"));
    });

    test('single-quotes embedded apostrophes', () {
      final c = mailboxWakeCommand(
        wakeExecutable: "o'brien",
        sessionId: 's',
        sessionName: "jo'an",
      );
      expect(c, contains("nohup 'o'\\''brien'"));
      expect(c, contains("--session 'jo'\\''an'"));
    });

    test('embeds the wake prompt text', () {
      final c = mailboxWakeCommand(sessionId: 's');
      expect(c, contains(wakePromptText));
    });
  });

  group('launchMailboxWake', () {
    test('refuses a cwd that does not exist (gh-1744)', () async {
      final shell = _RecordingShell();
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      // The legacy lossy slug decode names a directory that is not there.
      final error = await launchMailboxWake(
        env: env,
        cwd: '/Users/y/_w/postal/nl',
        sessionId: 'sess-1',
        sessionName: 'postal-nl',
      );
      expect(error, contains('does not exist'));
      expect(error, contains('/Users/y/_w/postal/nl'));
      expect(shell.commands, isEmpty);
    });

    test('refuses a cwd that names a plain file (gh-1744)', () async {
      final shell = _RecordingShell();
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      (await env.writeFile('/work/a-file', 'x')).getOrThrow();
      final error = await launchMailboxWake(
        env: env,
        cwd: '/work/a-file',
        sessionId: 'sess-1',
      );
      expect(error, contains('does not exist'));
      expect(shell.commands, isEmpty);
    });

    test('spawns in the existing cwd', () async {
      final shell = _RecordingShell();
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      (await env.createDir('/Users/y/_w/postal-nl', recursive: true))
          .getOrThrow();
      final error = await launchMailboxWake(
        env: env,
        wakeExecutable: '/usr/local/bin/fa',
        cwd: '/Users/y/_w/postal-nl',
        sessionId: 'sess-1',
        sessionName: 'postal-nl',
      );
      expect(error, isNull);
      expect(shell.commands, hasLength(1));
      final record = shell.commands.single;
      expect(
        record.$1,
        contains("nohup '/usr/local/bin/fa' --session 'postal-nl'"),
      );
      expect(record.$2?.cwd, '/Users/y/_w/postal-nl');
    });

    test('spawns for a symlink-kind cwd (lstat-semantics backends)', () async {
      // gh-1744 review: no current backend produces FileKind.symlink here
      // (the real IO env stats through links, MemoryExecutionEnv has no
      // symlink model) — this pins the guard's explicit symlink allowance
      // for backends honoring pi's lstat contract: a symlink-kind path
      // naming an existing directory must still wake.
      final shell = _RecordingShell();
      final target = _SymlinkCwdEnv(
        MemoryExecutionEnv(cwd: '/work', shell: shell),
        symlinkPath: '/Users/y/_w/postal-nl',
      );
      (await target.inner.createDir('/Users/y/_w/postal-nl', recursive: true))
          .getOrThrow();
      final error = await launchMailboxWake(
        env: target,
        wakeExecutable: '/usr/local/bin/fa',
        cwd: '/Users/y/_w/postal-nl',
        sessionId: 'sess-1',
        sessionName: 'postal-nl',
      );
      expect(error, isNull);
      expect(shell.commands, hasLength(1));
      expect(shell.commands.single.$2?.cwd, '/Users/y/_w/postal-nl');
    });
  });
}

/// Records exec'd commands + options without spawning anything.
final class _RecordingShell implements Shell {
  final commands = <(String, ShellExecOptions?)>[];

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add((command, options));
    return const Ok(ShellExecResult(stdout: 'woken', stderr: '', exitCode: 0));
  }
}

/// Reports [FileKind.symlink] for [symlinkPath] (pi's documented lstat
/// semantics — "symlinks are not followed automatically") and delegates
/// everything else to [inner].
final class _SymlinkCwdEnv implements ExecutionEnv {
  _SymlinkCwdEnv(this.inner, {required this.symlinkPath});

  final ExecutionEnv inner;
  final String symlinkPath;

  @override
  String get cwd => inner.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      inner.absolutePath(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => inner.createDir(path, recursive: recursive);

  @override
  Future<Result<bool, FileError>> exists(String path) => inner.exists(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      inner.joinPath(parts);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      inner.listDir(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      inner.readBinaryFile(path);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      inner.readTextFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => inner.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => inner.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => inner.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      inner.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      inner.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) async {
    if (path == symlinkPath) {
      return Ok(
        FileInfo(
          name: symlinkPath.split('/').last,
          path: symlinkPath,
          kind: FileKind.symlink,
          size: 0,
          mtimeMs: 0,
        ),
      );
    }
    return inner.fileInfo(path);
  }

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => inner.exec(command, options: options);
}
