import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Controllable fake background job + jobs-capable env (same shape as
/// test/tools/shell_jobs_test.dart).
final class _FakeShellJob implements ShellJob {
  _FakeShellJob(this.id, this.command, this.logPath, this._env);

  final MemoryExecutionEnv _env;
  final _output = StreamController<String>.broadcast();
  final _settled = Completer<void>();
  int? _exitCode;
  String? _stopReason;
  var stopCalls = 0;

  @override
  final String id;

  @override
  final String command;

  @override
  final String logPath;
  @override
  int? get pid => null;

  @override
  bool get isRunning => _exitCode == null;

  @override
  int? get exitCode => _exitCode;

  @override
  String? get stopReason => _stopReason;

  @override
  Future<void> get settled => _settled.future;

  Future<void> writeLog(String text) {
    _output.add(text);
    return _env.appendFile(logPath, text);
  }

  @override
  Stream<String> get output => _output.stream;

  @override
  bool writeStdin(String data) => true;

  void complete(int code, {String? reason}) {
    if (_exitCode != null) return;
    _stopReason = reason;
    _exitCode = code;
    _settled.complete();
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _stopReason = 'stopped';
    complete(143);
  }
}

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
  Future<Result<bool, FileError>> exists(String path) =>
      _delegate.exists(path);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _delegate.exec(command, options: options);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Map<String, dynamic> _args(
  String action, {
  String? id,
  int? lines,
  bool? all,
}) => {
  'action': action,
  'id': ?id,
  'lines': ?lines,
  'all': ?all,
};

Future<void> _pumpSettles() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String _text(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join('\n');

void main() {
  late _FakeBackgroundEnv env;
  late ShellJobRegistry registry;
  late AgentTool tool;

  setUp(() {
    env = _FakeBackgroundEnv(MemoryExecutionEnv(cwd: '/work'));
    registry = ShellJobRegistry(env: env);
    tool = bashJobTool(registry);
  });

  group('AC1 — near-miss output resolves a unique same-n job', () {
    test('exited job: tail + corrected id + stop-polling note', () async {
      final entry = await registry.start('make all');
      await env.jobs.single.writeLog('built ok\n');
      env.jobs.single.complete(0);
      await _pumpSettles();
      final stale = '${entry.id.substring(0, entry.id.length - 2)}zz';
      final result = await tool.execute(
        _args('output', id: stale),
        null,
        null,
      );
      final text = _text(result);
      expect(text, contains('built ok'));
      expect(text, contains(entry.id));
      expect(text, contains('already exited'));
      expect(text, contains('stop polling the stale id'));
    });

    test('running job: tail + corrected id, no exit claim (E4)', () async {
      final entry = await registry.start('make all');
      await env.jobs.single.writeLog('halfway\n');
      final stale = '${entry.id.substring(0, entry.id.length - 2)}zz';
      final result = await tool.execute(
        _args('output', id: stale),
        null,
        null,
      );
      final text = _text(result);
      expect(text, contains('halfway'));
      expect(text, contains(entry.id));
      expect(text, contains('still running'));
      expect(text, isNot(contains('already exited')));
    });

    test('status acts on the resolved near-miss too', () async {
      final entry = await registry.start('make all');
      env.jobs.single.complete(0);
      await _pumpSettles();
      final stale = '${entry.id.substring(0, entry.id.length - 2)}zz';
      final result = await tool.execute(
        _args('status', id: stale),
        null,
        null,
      );
      final text = _text(result);
      expect(text, contains(entry.id));
      expect(text, contains('make all'));
      expect(text, contains('stop polling the stale id'));
    });
  });

  group('AC2 — unresolvable unknown ids answer plain results', () {
    test('non-error result with the closest retained ids', () async {
      final a = await registry.start('one');
      final b = await registry.start('two');
      final result = await tool.execute(
        _args('output', id: 'sh-9-nope'),
        null,
        null,
      );
      final text = _text(result);
      expect(text, contains('never registered'));
      expect(text, contains('do not retry'));
      expect(text, contains(a.id));
      expect(text, contains(b.id));
    });

    test('status mirrors the plain-result shape', () async {
      await registry.start('one');
      final result = await tool.execute(
        _args('status', id: 'sh-9-nope'),
        null,
        null,
      );
      expect(_text(result), contains('never registered'));
    });

    test('no retained jobs still answers gracefully', () async {
      final result = await tool.execute(
        _args('output', id: 'sh-9-nope'),
        null,
        null,
      );
      final text = _text(result);
      expect(text, contains('never registered'));
      expect(text, contains('No jobs are retained'));
    });

    test('the hint lists at most 3 ids', () async {
      final registry = ShellJobRegistry(
        env: env,
        maxRetainedExitedJobs: 1000,
      );
      final tool = bashJobTool(registry);
      for (var i = 0; i < 5; i++) {
        await registry.start('job $i');
        env.jobs[i].complete(0);
      }
      await _pumpSettles();
      final result = await tool.execute(
        _args('output', id: 'sh-9-nope'),
        null,
        null,
      );
      final text = _text(result);
      expect(text, contains('never registered'));
      // The hint is bounded: exactly 3 candidate rows regardless of the
      // retained-job count.
      expect(
        text.split('\n').where((line) => line.startsWith('- ')),
        hasLength(3),
      );
    });
  });

  group('AC3 — status without id stays bounded', () {
    Future<int> statusLineCount(int exitedCount, {bool all = false}) async {
      final localEnv = _FakeBackgroundEnv(MemoryExecutionEnv(cwd: '/work'));
      final localRegistry = ShellJobRegistry(
        env: localEnv,
        maxRetainedExitedJobs: exitedCount + 10,
      );
      final localTool = bashJobTool(localRegistry);
      await localRegistry.start('runner');
      await localRegistry.start('runner2');
      for (var i = 0; i < exitedCount; i++) {
        await localRegistry.start('job $i');
        localEnv.jobs[i + 2].complete(0);
      }
      await _pumpSettles();
      final result = await localTool.execute(
        _args('status', all: all),
        null,
        null,
      );
      return _text(result).split('\n').length;
    }

    test('line count = running + min(exited, 20) + summary', () async {
      expect(await statusLineCount(0), 2);
      expect(await statusLineCount(5), 2 + 5);
      expect(await statusLineCount(20), 2 + 20);
      expect(await statusLineCount(100), 2 + 20 + 1);
      expect(await statusLineCount(10000), 2 + 20 + 1);
    });

    test('all: true restores the full dump', () async {
      expect(await statusLineCount(25, all: true), 2 + 25);
    });
  });

  group('AC4 — post-GC exact-id output falls back to the on-disk log', () {
    test('pruned id still tails from disk', () async {
      final localRegistry = ShellJobRegistry(env: env, maxRetainedExitedJobs: 1);
      final localTool = bashJobTool(localRegistry);
      final pruned = await localRegistry.start('first');
      await env.jobs[0].writeLog('from disk\n');
      await localRegistry.start('second');
      env.jobs[0].complete(0);
      await _pumpSettles();
      env.jobs[1].complete(0);
      await _pumpSettles();
      expect(localRegistry.jobs.map((j) => j.id), isNot(contains(pruned.id)));
      final result = await localTool.execute(
        _args('output', id: pruned.id),
        null,
        null,
      );
      final text = _text(result);
      expect(text, contains('from disk'));
      expect(text, contains('already exited'));
    });

    test('deleted log degrades to the clean unknown-id error (E2)', () async {
      final localRegistry = ShellJobRegistry(env: env, maxRetainedExitedJobs: 1);
      final localTool = bashJobTool(localRegistry);
      final pruned = await localRegistry.start('first');
      await env.jobs[0].writeLog('from disk\n');
      await localRegistry.start('second');
      env.jobs[0].complete(0);
      await _pumpSettles();
      env.jobs[1].complete(0);
      await _pumpSettles();
      await env.remove(pruned.logPath, force: true);
      await expectLater(
        localTool.execute(_args('output', id: pruned.id), null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'unknown background job: ${pruned.id}',
          ),
        ),
      );
    });

    test('status names the compacted log without tailing', () async {
      final localRegistry = ShellJobRegistry(env: env, maxRetainedExitedJobs: 1);
      final localTool = bashJobTool(localRegistry);
      final pruned = await localRegistry.start('first');
      await env.jobs[0].writeLog('from disk\n');
      await localRegistry.start('second');
      env.jobs[0].complete(0);
      await _pumpSettles();
      env.jobs[1].complete(0);
      await _pumpSettles();
      final result = await localTool.execute(
        _args('status', id: pruned.id),
        null,
        null,
      );
      final text = _text(result);
      expect(text, contains('already exited'));
      expect(text, contains('compacted'));
      expect(text, isNot(contains('from disk')));
    });
  });

  group('AC5 — stop never acts on a resolved id', () {
    test('near-miss stop returns a hint and kills nothing', () async {
      final entry = await registry.start('long build');
      final stale = '${entry.id.substring(0, entry.id.length - 2)}zz';
      final result = await tool.execute(_args('stop', id: stale), null, null);
      final text = _text(result);
      expect(text, contains('exact job id'));
      expect(text, contains(entry.id));
      expect(env.jobs.single.stopCalls, 0);
      expect(env.jobs.single.isRunning, isTrue);
    });

    test('unknown stop hints the closest ids without resolving', () async {
      final a = await registry.start('one');
      final result = await tool.execute(
        _args('stop', id: 'sh-9-nope'),
        null,
        null,
      );
      final text = _text(result);
      expect(text, contains('exact job id'));
      expect(text, contains(a.id));
    });

    test('stop of a GCd id reports there is nothing to stop', () async {
      final localRegistry = ShellJobRegistry(env: env, maxRetainedExitedJobs: 1);
      final localTool = bashJobTool(localRegistry);
      final pruned = await localRegistry.start('first');
      await localRegistry.start('second');
      env.jobs[0].complete(0);
      await _pumpSettles();
      env.jobs[1].complete(0);
      await _pumpSettles();
      final result = await localTool.execute(
        _args('stop', id: pruned.id),
        null,
        null,
      );
      expect(_text(result), contains('nothing to stop'));
    });
  });

  group('E3 — malformed ids skip resolution', () {
    test('every action answers the shortest error', () async {
      for (final id in ['sh-99', 'garbage', '']) {
        await expectLater(
          tool.execute(_args('output', id: id), null, null),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          tool.execute(_args('status', id: id), null, null),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          tool.execute(_args('stop', id: id), null, null),
          throwsA(isA<StateError>()),
        );
      }
    });
  });

  group('exact ids keep today\u2019s results plus exited context', () {
    test('output of an exited exact id gains the exited context', () async {
      final entry = await registry.start('x');
      await env.jobs.single.writeLog('done\n');
      env.jobs.single.complete(0);
      await _pumpSettles();
      final result = await tool.execute(
        _args('output', id: entry.id),
        null,
        null,
      );
      final text = _text(result);
      expect(text, contains('done'));
      expect(text, contains('already exited (exit code 0,'));
    });

    test('output of a running exact id is unchanged', () async {
      final entry = await registry.start('x');
      await env.jobs.single.writeLog('live\n');
      final result = await tool.execute(
        _args('output', id: entry.id),
        null,
        null,
      );
      expect(_text(result), 'live');
    });

    test('status of an exited exact id gains the ago suffix', () async {
      final entry = await registry.start('x');
      env.jobs.single.complete(0);
      await _pumpSettles();
      final result = await tool.execute(
        _args('status', id: entry.id),
        null,
        null,
      );
      final text = _text(result);
      expect(text, contains('${entry.id}: exited(0)'));
      expect(text, contains('just now'));
    });
  });
}
