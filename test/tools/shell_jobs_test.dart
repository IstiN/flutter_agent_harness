import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A controllable fake background job over the in-memory fs: tests write log
/// lines and settle/stop it by hand.
final class _FakeShellJob implements ShellJob {
  _FakeShellJob(this.id, this.command, this.logPath, this._env);

  final MemoryExecutionEnv _env;
  final _settled = Completer<void>();
  int? _exitCode;
  String? _stopReason;

  @override
  final String id;

  @override
  final String command;

  @override
  final String logPath;

  @override
  bool get isRunning => _exitCode == null;

  @override
  int? get exitCode => _exitCode;

  @override
  String? get stopReason => _stopReason;

  @override
  Future<void> get settled => _settled.future;

  Future<void> writeLog(String text) => _env.appendFile(logPath, text);

  void complete(int code, {String? reason}) {
    if (_exitCode != null) return;
    _stopReason = reason;
    _exitCode = code;
    _settled.complete();
  }

  @override
  Future<void> stop() async {
    _stopReason = 'stopped';
    complete(143);
  }
}

/// MemoryExecutionEnv wrapper with the [BackgroundShell] capability; members
/// the registry/tools actually use are delegated explicitly.
final class _FakeBackgroundEnv implements ExecutionEnv, BackgroundShell {
  _FakeBackgroundEnv(this._delegate);

  final MemoryExecutionEnv _delegate;
  final jobs = <_FakeShellJob>[];

  @override
  bool get backgroundJobsSupported => true;
  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = _FakeShellJob(id, command, logPath, _delegate);
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
}

Map<String, dynamic> _args(String action, {String? id, int? lines}) => {
  'action': action,
  'id': ?id,
  'lines': ?lines,
};

/// Pumps the event loop until the tool call has created its job.
Future<_FakeShellJob> _waitForJob(_FakeBackgroundEnv env) async {
  for (var i = 0; i < 100 && env.jobs.isEmpty; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return env.jobs.single;
}

String _text(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join('\n');

void main() {
  group('ShellJobRegistry', () {
    test('isSupported mirrors the BackgroundShell capability', () {
      expect(
        ShellJobRegistry(env: MemoryExecutionEnv(cwd: '/w')).isSupported,
        isFalse,
      );
      expect(
        ShellJobRegistry(
          env: _FakeBackgroundEnv(MemoryExecutionEnv()),
        ).isSupported,
        isTrue,
      );
    });

    test('start rejects unsupported environments with a clean note', () {
      final registry = ShellJobRegistry(env: MemoryExecutionEnv(cwd: '/w'));
      expect(
        registry.start('sleep 1'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not supported'),
          ),
        ),
      );
    });

    test(
      'start allocates sequential ids and logs under .fah/bash_jobs',
      () async {
        final env = _FakeBackgroundEnv(MemoryExecutionEnv(cwd: '/work'));
        final registry = ShellJobRegistry(env: env);
        final a = await registry.start('echo a');
        final b = await registry.start('echo b');
        expect(a.id, 'sh-1');
        expect(b.id, 'sh-2');
        expect(a.logPath, '/work/.fah/bash_jobs/sh-1.log');
        expect(registry.jobs.map((j) => j.id), ['sh-1', 'sh-2']);
      },
    );

    test('onSettled fires on completion unless suppressed', () async {
      final env = _FakeBackgroundEnv(MemoryExecutionEnv(cwd: '/work'));
      final settled = <String>[];
      final registry = ShellJobRegistry(
        env: env,
        onSettled: (job) => settled.add(job.id),
      );
      final a = await registry.start('echo a');
      final b = await registry.start('echo b');
      b.suppressSettleNotification();
      env.jobs[0].complete(0);
      env.jobs[1].complete(0);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(settled, ['sh-1']);
      expect(a.exitCode, 0);
    });

    test('tail reads the job log through the env', () async {
      final env = _FakeBackgroundEnv(MemoryExecutionEnv(cwd: '/work'));
      final registry = ShellJobRegistry(env: env);
      final entry = await registry.start('x');
      await env.jobs.single.writeLog('l1\nl2\nl3\n');
      expect(await registry.tail(entry.id, maxLines: 2), 'l2\nl3');
    });
  });

  group('bash background', () {
    late _FakeBackgroundEnv env;
    late List<String> settleNotifications;
    late ShellJobRegistry registry;
    late AgentTool tool;

    setUp(() {
      env = _FakeBackgroundEnv(MemoryExecutionEnv(cwd: '/work'));
      settleNotifications = [];
      registry = ShellJobRegistry(
        env: env,
        onSettled: (job) => settleNotifications.add(job.id),
      );
      tool = shellTool(env, jobs: registry);
    });

    test('background: true returns the job id immediately', () async {
      final result = await tool.execute(
        {'command': 'make', 'background': true},
        null,
        null,
      );
      expect(_text(result), contains('Started background job sh-1'));
      expect(env.jobs.single.isRunning, isTrue);
    });

    test('background on an unsupported env answers a clean note', () async {
      final plainEnv = MemoryExecutionEnv(cwd: '/work');
      final plainRegistry = ShellJobRegistry(env: plainEnv);
      final plainTool = shellTool(plainEnv, jobs: plainRegistry);
      final result = await plainTool.execute(
        {'command': 'make', 'background': true},
        null,
        null,
      );
      expect(_text(result), contains('not supported'));
    });

    test('a settled job yields the classic inline result', () async {
      final resultFuture = runZoned(
        () => tool.execute({'command': 'make'}, null, null),
        zoneValues: {yieldTokenZoneKey: CancelTokenSource().token},
      );
      // The job settles before any yield: inline result, notification
      // suppressed.
      final job = await _waitForJob(env);
      await job.writeLog('built\n');
      job.complete(0);
      final result = await resultFuture;
      expect(_text(result), 'built');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(settleNotifications, isEmpty);
    });

    test(
      'a mid-run yield moves the command to the background untouched',
      () async {
        final yieldSource = CancelTokenSource();
        final resultFuture = runZoned(
          () => tool.execute({'command': 'make'}, null, null),
          zoneValues: {yieldTokenZoneKey: yieldSource.token},
        );
        final job = await _waitForJob(env);
        await job.writeLog('half\n');
        yieldSource.cancel();
        final result = await resultFuture;
        final text = _text(result);
        expect(text, contains('background job sh-1'));
        expect(text, contains('NOT killed'));
        expect(text, contains('Partial output so far:\nhalf'));
        // The process keeps running…
        expect(env.jobs.single.isRunning, isTrue);
        // …and its later settle notifies the registry (not suppressed).
        env.jobs.single.complete(0);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(settleNotifications, ['sh-1']);
      },
    );

    test('a non-zero exit in job mode reports the exit code', () async {
      final resultFuture = runZoned(
        () => tool.execute({'command': 'make'}, null, null),
        zoneValues: {yieldTokenZoneKey: CancelTokenSource().token},
      );
      final job = await _waitForJob(env);
      job.complete(124);
      await expectLater(
        resultFuture,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('exited with code 124'),
          ),
        ),
      );
    });

    test('a timeout stop reason reports the timeout message', () async {
      final resultFuture = runZoned(
        () => tool.execute({'command': 'make', 'timeout': 5}, null, null),
        zoneValues: {yieldTokenZoneKey: CancelTokenSource().token},
      );
      final job = await _waitForJob(env);
      job.complete(143, reason: 'timeout');
      await expectLater(
        resultFuture,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('timed out after 5 seconds'),
          ),
        ),
      );
    });
  });

  group('bash_job', () {
    late _FakeBackgroundEnv env;
    late ShellJobRegistry registry;
    late AgentTool tool;

    setUp(() {
      env = _FakeBackgroundEnv(MemoryExecutionEnv(cwd: '/work'));
      registry = ShellJobRegistry(env: env);
      tool = bashJobTool(registry);
    });

    test('status lists all jobs with state and log path', () async {
      await registry.start('make all');
      env.jobs[0].complete(0);
      await registry.start('make test');
      final result = await tool.execute(_args('status'), null, null);
      // Ids are globally unique (process-safe), so match them off the jobs.
      expect(_text(result), contains('${env.jobs[0].id}: exited(0) — make all'));
      expect(_text(result), contains('${env.jobs[1].id}: running — make test'));
    });

    test('job ids and log paths are unique across registries', () async {
      // Two fa processes in one workspace share `.fah/bash_jobs/` — their
      // per-process counters both start at 1, so ids must be disambiguated
      // beyond the counter or one process's output lands in the other's
      // log file.
      final otherEnv = _FakeBackgroundEnv(MemoryExecutionEnv(cwd: '/work'));
      final otherRegistry = ShellJobRegistry(env: otherEnv);
      final a = await registry.start('a');
      await registry.start('b');
      final c = await otherRegistry.start('c');

      final allJobs = [...registry.jobs, ...otherRegistry.jobs];
      expect({for (final j in allJobs) j.id}, hasLength(3));
      expect(a.id, isNot(c.id));
      expect(
        {for (final j in allJobs) j.logPath},
        hasLength(3),
        reason: 'shared `.fah/bash_jobs/` dir must not collide',
      );
    });

    test('status without jobs says so', () async {
      final result = await tool.execute(_args('status'), null, null);
      expect(_text(result), contains('No background jobs'));
    });

    test('output tails the log', () async {
      final entry = await registry.start('x');
      await env.jobs.single.writeLog('a\nb\n');
      final result = await tool.execute(
        _args('output', id: entry.id),
        null,
        null,
      );
      expect(_text(result), 'a\nb');
    });

    test('stop terminates a running job', () async {
      final entry = await registry.start('x');
      final result = await tool.execute(
        _args('stop', id: entry.id),
        null,
        null,
      );
      expect(_text(result), 'Stopped sh-1');
      expect(env.jobs.single.isRunning, isFalse);
    });

    test('stop on a finished job reports its state', () async {
      final entry = await registry.start('x');
      env.jobs.single.complete(0);
      final result = await tool.execute(
        _args('stop', id: entry.id),
        null,
        null,
      );
      expect(_text(result), contains('already finished'));
    });

    test('unknown ids are clean errors', () async {
      expect(
        tool.execute(_args('output', id: 'sh-99'), null, null),
        throwsA(isA<StateError>()),
      );
      expect(
        tool.execute(_args('status', id: 'sh-99'), null, null),
        throwsA(isA<StateError>()),
      );
      expect(
        tool.execute(_args('stop', id: 'sh-99'), null, null),
        throwsA(isA<StateError>()),
      );
    });
  });
}
