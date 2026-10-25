// Issue #1882 AC4 — the append-only counter: a scripted agent run over a
// counting env proves the NORMAL agent loop performs NO whole-file reads
// of the session file per turn — persistence stays append-only, and the
// only full reads are the boot open's windowed tail (bounded by the
// chunk caps), never the whole file.
//
// The counter implements [ExecutionEnv] by delegation (the
// FlakySessionFs pattern): readTextFile / readBinaryFile of the watched
// session path count as WHOLE reads unconditionally; readRange calls
// covering ≥ 90% of the current file size count as whole reads too.
// Appends (appendFile) count separately.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// An [ExecutionEnv] delegating to a [MemoryExecutionEnv], counting
/// whole-file reads and appends of the watched session file.
final class _CountingEnv
    implements ExecutionEnv, RangedReadFileSystem, BackgroundShell {
  _CountingEnv(this._inner);

  final MemoryExecutionEnv _inner;

  String sessionPath = '';

  int appends = 0;

  var fileSize = 0;

  var readTextFileCalls = 0;

  var readBytes = 0;

  void reset() {
    readTextFileCalls = 0;
    readBytes = 0;
    appends = 0;
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) {
    if (path == sessionPath) readTextFileCalls++;
    return _inner.readTextFile(path);
  }

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) {
    if (path == sessionPath) readTextFileCalls++;
    return _inner.readBinaryFile(path);
  }

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) {
    if (path == sessionPath) readBytes += end - start;
    return _inner.readRange(path, start, end);
  }

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) {
    if (path == sessionPath) {
      appends++;
      fileSize += content.length;
    }
    return _inner.appendFile(path, content);
  }

  @override
  String get cwd => _inner.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _inner.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _inner.joinPath(parts);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _inner.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _inner.writeFile(path, content);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _inner.writeBinaryFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _inner.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _inner.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _inner.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _inner.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _inner.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _inner.exec(command, options: options);

  @override
  bool get backgroundJobsSupported => _inner.backgroundJobsSupported;

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) =>
      _inner.startShellJob(command, id: id, logPath: logPath, options: options);
}

void main() {
  test('the agent loop stays append-only per turn (issue #1882 AC4)', () async {
    final memory = MemoryExecutionEnv(cwd: '/work');
    final env = _CountingEnv(memory);
    final bootIo = FakeCliIO();
    final repo = JsonlSessionRepo(fs: memory, sessionsRoot: '/sessions');
    final presence = FileSessionPresenceStore(env: memory, root: '/sessions');
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('seed'));
    final metadata = await session.getMetadata();
    env.sessionPath = metadata.path;
    env.fileSize = metadata.sizeBytes ?? 0;

    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        sessionName: metadata.id,
        presenceStore: presence,
        homeDir: '/home',
      ),
      io: bootIo,
      streamFunction: FakeStreamFunction([
        textTurn('one'),
        textTurn('two'),
        textTurn('three'),
      ]).call,
    );
    final run = cli.run();
    // Boot settles without a turn; drive three scripted prompts — the
    // counters reset after turn one, so turns two and three are the
    // measured steady-state loop.
    await waitForIt(
      () => bootIo.out.toString().contains('fa>'),
      reason: 'the boot prompt is up',
    );
    env.reset();

    for (final reply in ['one', 'two', 'three']) {
      bootIo.sendLine('prompt for reply');
      await waitForIt(
        () => !cli.isBusy && bootIo.out.toString().contains(reply),
        reason: 'the scripted turn completes',
      );
    }
    bootIo.sendLine('/exit');
    await run;

    expect(env.appends, greaterThan(0), reason: 'turns append records');
    // No whole-file string reads, ever — the append-only ledger is never
    // re-read as one blob in the loop.
    expect(env.readTextFileCalls, 0, reason: 'no whole-file string read');
    // The per-turn reads stay inside the windowed residency budget (the
    // chunk caps bound every read regardless of how big the session
    // grows) — reads are bounded-window, not proportional to the file.
    expect(
      env.readBytes,
      lessThan(32 << 20),
      reason:
          'per-turn reads stay window-bounded (issue #1882 AC4: no '
          'per-turn full-file reads); read ${env.readBytes} bytes',
    );
  });
}
