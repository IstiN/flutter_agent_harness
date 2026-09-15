import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A controllable fake background job: tests drive [output] chunks and
/// settle it by hand; [stdinWrites] records what the tool pushed through
/// [ShellJob.writeStdin].
final class _FakeShellJob implements ShellJob {
  final _output = StreamController<String>.broadcast();
  final _settled = Completer<void>();
  int? _exitCode;
  String? _stopReason;

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;

  _FakeShellJob(this.id, this.command, this.logPath, this._env);

  final _FakeBackgroundEnv _env;

  /// Chunks written to the RUNNING process's stdin (issue #367).
  final stdinWrites = <String>[];

  /// Mirrors a live output chunk: stream + log file, like the real job.
  void emit(String chunk) {
    _output.add(chunk);
    unawaited(_env._delegate.appendFile(logPath, chunk));
  }

  void complete(int code, {String? reason}) {
    if (_exitCode != null) return;
    _stopReason = reason;
    _exitCode = code;
    _settled.complete();
  }

  @override
  Stream<String> get output => _output.stream;

  @override
  bool writeStdin(String data) {
    stdinWrites.add(data);
    return true;
  }

  @override
  bool get isRunning => _exitCode == null;
  @override
  int? get exitCode => _exitCode;
  @override
  String? get stopReason => _stopReason;
  @override
  Future<void> get settled => _settled.future;

  @override
  Future<void> stop() async {
    _stopReason = 'stopped';
    complete(143);
  }
}

/// Minimal [ExecutionEnv] + [BackgroundShell] over one in-memory file: only
/// what the registry and the bash tool's job path touch.
final class _FakeBackgroundEnv implements ExecutionEnv, BackgroundShell {
  final MemoryExecutionEnv _delegate;
  final jobs = <_FakeShellJob>[];

  _FakeBackgroundEnv() : _delegate = MemoryExecutionEnv(cwd: '/work');

  @override
  bool get backgroundJobsSupported => true;
  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = _FakeShellJob(id, command, logPath, this);
    // The real shell binds the channel to the process's stdin.
    options?.liveStdin?.bind(job.writeStdin);
    jobs.add(job);
    return Ok(job);
  }

  @override
  String get cwd => _delegate.cwd;
  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);
  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);
  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _delegate.exec(command, options: options);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  /// The job's log text so far.
  Future<String> logText() async =>
      (await _delegate.readTextFile(jobs.single.logPath)).valueOrNull ?? '';
}

Future<_FakeShellJob> _waitForJob(_FakeBackgroundEnv env) async {
  for (var i = 0; i < 100 && env.jobs.isEmpty; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return env.jobs.single;
}

String _text(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join('\n');

void main() {
  group('bash tool password flow (issue #367)', () {
    test('a password ask fires the host callback and the answer reaches '
        'the running job through live stdin', () async {
      final env = _FakeBackgroundEnv();
      final jobs = ShellJobRegistry(env: env);
      final prompts = <String>[];
      final tool = shellTool(
        env,
        jobs: jobs,
        onPasswordPrompt: (prompt) async {
          prompts.add(prompt);
          return 'hunter2';
        },
        passwordQuiet: const Duration(milliseconds: 5),
      );

      final token = CancelTokenSource();
      final done = runZoned(
        () => tool.execute({'command': 'sudo apt install'}, null, null),
        zoneValues: {yieldTokenZoneKey: token.token},
      );
      final job = await _waitForJob(env);
      // The prompt arrives mid-run WITHOUT a trailing newline: sudo is
      // still waiting for the password.
      job.emit('[sudo] password for user:');
      // Wait past the quiet window; the detector asks the host.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(prompts, ['[sudo] password for user:']);
      expect(job.stdinWrites, ['hunter2\n']);
      // The answer never lands in the job log (no persistence).
      expect(await env.logText(), isNot(contains('hunter2')));

      job.complete(0);
      final result = await done;
      // The transcript carries the prompt, never the password.
      expect(_text(result), contains('[sudo] password for user:'));
      expect(_text(result), isNot(contains('hunter2')));
    });

    test(
      'declining writes a bare newline so the command fails on its own',
      () async {
        final env = _FakeBackgroundEnv();
        final jobs = ShellJobRegistry(env: env);
        final tool = shellTool(
          env,
          jobs: jobs,
          onPasswordPrompt: (_) async => null,
          passwordQuiet: const Duration(milliseconds: 5),
        );

        final token = CancelTokenSource();
        final done = runZoned(
          () => tool.execute({'command': 'sudo apt'}, null, null),
          zoneValues: {yieldTokenZoneKey: token.token},
        );
        final job = await _waitForJob(env);
        job.emit('Password:');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(job.stdinWrites, ['\n']);
        job.complete(0);
        await done;
      },
    );

    test('without a host callback no stdin channel is attached', () async {
      final env = _FakeBackgroundEnv();
      final jobs = ShellJobRegistry(env: env);
      final tool = shellTool(env, jobs: jobs);

      final token = CancelTokenSource();
      final done = runZoned(
        () => tool.execute({'command': 'echo Password:'}, null, null),
        zoneValues: {yieldTokenZoneKey: token.token},
      );
      final job = await _waitForJob(env);
      job.emit('Password:');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(job.stdinWrites, isEmpty);
      job.complete(0);
      await done;
    });
  });
}
