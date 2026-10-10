import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The boot marker in the shared diagnostics log: every wedge post-mortem
/// starts with "which BUILD held the busy row?" — parallel fa processes
/// share `~/.fah/logs/fa.log`, so the first lifecycle line must name the
/// version next to the session id.
void main() {
  test('boot writes version + session id to the diagnostics log', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: fake.call,
      version: '9.9.9-test',
    );
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    io.sendLine('/exit');
    await run;

    final result = await env.readTextFile('/home/.fah/logs/fa.log');
    final log = result.valueOrNull ?? '';
    final boot = log
        .split('\n')
        .where((line) => line.contains('fa boot'))
        .toList();
    expect(boot, hasLength(1), reason: 'exactly one boot line per process');
    expect(boot.single, contains('version=9.9.9-test'));
    expect(
      boot.single,
      contains(RegExp(r'sid=[0-9a-f]{8}')),
      reason: 'the boot line names its session like every lifecycle line',
    );
  });

  test('an oversized diagnostics log is rotated on the first write of a '
      'process', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    await env.createDir('/home/.fah/logs', recursive: true);
    // Seed fa.log beyond the cap (the memory print sink can now append
    // prompt-sized lines per memory op, so unbounded growth is real).
    await env.writeFile(
      '/home/.fah/logs/fa.log',
      'x' * (AgentCli.diagnosticLogMaxBytes + 1),
    );
    final io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: fake.call,
      version: '9.9.9-test',
    );
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    io.sendLine('/exit');
    await run;

    final result = await env.readTextFile('/home/.fah/logs/fa.log');
    final log = result.valueOrNull ?? '';
    expect(
      log.length,
      lessThan(AgentCli.diagnosticLogMaxBytes),
      reason: 'the oversized log must not survive rotation',
    );
    expect(log, isNot(contains('xxxx')));
    expect(log, contains('fa boot'));
  });

  test('a diagnostics log under the cap is not rotated', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    await env.createDir('/home/.fah/logs', recursive: true);
    await env.writeFile('/home/.fah/logs/fa.log', 'precious prior line\n');
    final io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: fake.call,
      version: '9.9.9-test',
    );
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    io.sendLine('/exit');
    await run;

    final result = await env.readTextFile('/home/.fah/logs/fa.log');
    final log = result.valueOrNull ?? '';
    expect(log, contains('precious prior line'));
    expect(log, contains('fa boot'));
  });

  test('rotation on a renamable filesystem preserves the prior log as '
      'fa.log.1', () async {
    final env = _RenamingMemoryEnv();
    await env.createDir('/home/.fah/logs', recursive: true);
    await env.writeFile('/home/.fah/logs/fa.log', 'precious prior line\n');
    // Push the file over the cap without losing the marker line.
    final over = await env.readTextFile('/home/.fah/logs/fa.log');
    await env.writeFile(
      '/home/.fah/logs/fa.log',
      '${over.valueOrNull}${'y' * (AgentCli.diagnosticLogMaxBytes + 1)}',
    );
    final io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: fake.call,
      version: '9.9.9-test',
    );
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    io.sendLine('/exit');
    await run;

    final rotated = await env.readTextFile('/home/.fah/logs/fa.log.1');
    expect(rotated.valueOrNull, contains('precious prior line'));
    final fresh = await env.readTextFile('/home/.fah/logs/fa.log');
    final log = fresh.valueOrNull ?? '';
    expect(log, contains('fa boot'));
    expect(log, isNot(contains('precious prior line')));
  });
}

/// [ExecutionEnv] decorator adding the rename capability on top of a
/// [MemoryExecutionEnv]: exercises the rotation path the production env
/// (LocalExecutionEnv) takes, where the oversized log moves to `fa.log.1`
/// instead of being truncated.
final class _RenamingMemoryEnv implements ExecutionEnv, RenamableFileSystem {
  _RenamingMemoryEnv() : _delegate = MemoryExecutionEnv(cwd: '/work');

  final MemoryExecutionEnv _delegate;

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
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _delegate.exec(command, options: options);

  @override
  Future<Result<void, FileError>> renamePath(String from, String to) async {
    final content = await _delegate.readBinaryFile(from);
    final bytes = content.valueOrNull;
    if (bytes == null) {
      return Err(
        FileError(FileErrorCode.notFound, 'no such file', path: from),
      );
    }
    final written = await _delegate.writeBinaryFile(to, bytes);
    if (written.isErr) {
      return Err(
        written.errorOrNull ??
            const FileError(FileErrorCode.unknown, 'write failed'),
      );
    }
    await _delegate.remove(from);
    return const Ok(null);
  }
}
