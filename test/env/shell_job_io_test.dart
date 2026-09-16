import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late LocalExecutionEnv env;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('shell-job-test-');
    env = LocalExecutionEnv(cwd: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('BackgroundShell (local)', () {
    test('a job runs detached, writes its log, and settles', () async {
      final started = await env.startShellJob(
        'echo hello && echo err >&2',
        id: 'sh-1',
        logPath: '${tempDir.path}/sh-1.log',
      );
      expect(started.isOk, isTrue);
      final job = started.valueOrNull!;
      expect(job.isRunning, isTrue);
      await job.settled;
      expect(job.exitCode, 0);
      expect(job.stopReason, isNull);
      final log = File(job.logPath).readAsStringSync();
      expect(log, contains('hello'));
      expect(log, contains('err'));
    });

    test('stop terminates a long-running job', () async {
      final started = await env.startShellJob(
        'sleep 60',
        id: 'sh-2',
        logPath: '${tempDir.path}/sh-2.log',
      );
      final job = started.valueOrNull!;
      expect(job.isRunning, isTrue);
      await job.stop();
      await job.settled;
      expect(job.isRunning, isFalse);
      expect(job.exitCode, isNot(0));
      expect(job.stopReason, 'stopped');
    });

    test('the timeout kills the job and records the reason', () async {
      final started = await env.startShellJob(
        'sleep 60',
        id: 'sh-3',
        logPath: '${tempDir.path}/sh-3.log',
        options: const ShellExecOptions(timeout: Duration(milliseconds: 300)),
      );
      final job = started.valueOrNull!;
      await job.settled;
      expect(job.isRunning, isFalse);
      expect(job.stopReason, 'timeout');
    });

    test('the cancel token kills the job and records the reason', () async {
      final source = CancelTokenSource();
      final started = await env.startShellJob(
        'sleep 60',
        id: 'sh-4',
        logPath: '${tempDir.path}/sh-4.log',
        options: ShellExecOptions(cancelToken: source.token),
      );
      final job = started.valueOrNull!;
      source.cancel();
      await job.settled;
      expect(job.stopReason, 'cancelled');
    });

    test('live stdin: the pipe stays open until the process ends and a '
        'write reaches it (issue #367)', () async {
      final channel = LiveStdinChannel();
      final started = await env.startShellJob(
        'read line; echo "got:\$line"',
        id: 'sh-5',
        logPath: '${tempDir.path}/sh-5.log',
        options: ShellExecOptions(liveStdin: channel),
      );
      final job = started.valueOrNull!;
      expect(channel.isBound, isTrue);
      // The pipe is still open: the stdin-reader has not seen EOF and
      // keeps waiting for the answer.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(job.isRunning, isTrue);
      expect(channel.write('s3cret\n'), isTrue);
      await job.settled;
      expect(job.exitCode, 0);
      final log = File(job.logPath).readAsStringSync();
      expect(log, contains('got:s3cret'));
      // The process is gone: a late write fails cleanly, never throws.
      expect(channel.write('late\n'), isFalse);
    });

    test(
      'without a live channel stdin closes at start (ripgrep safety)',
      () async {
        final started = await env.startShellJob(
          'read line; echo "got:\$line"',
          id: 'sh-6',
          logPath: '${tempDir.path}/sh-6.log',
        );
        final job = started.valueOrNull!;
        await job.settled;
        expect(job.exitCode, 0);
      },
    );
  });
  group('job stop kills the whole process tree (issue #517)', () {
    // Per-run fractional seconds keep the ps scan unique to this run, and
    // a force-reap teardown keeps even a RED run from leaking sleepers.
    String token(int n) =>
        '517.$n${DateTime.now().microsecondsSinceEpoch % 100000}';

    test('stop kills a grandchild forked by the job (AC1)', () async {
      final secs = token(1);
      addTearDown(() => Process.run('pkill', ['-f', 'sleep $secs']));
      final started = await env.startShellJob(
        'sleep $secs & wait',
        id: 'sh-517a',
        logPath: '${tempDir.path}/sh-517a.log',
      );
      final job = started.valueOrNull!;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Fixture sanity: the grandchild is alive before the stop.
      expect(await _liveProcesses('sleep $secs'), hasLength(1));
      await job.stop();
      await job.settled;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(await _liveProcesses('sleep $secs'), isEmpty);
    });

    test('stop leaves zero toolchain children of a flutter-test-shaped '
        'job (AC2)', () async {
      final secsA = token(2);
      final secsB = token(3);
      addTearDown(() async {
        await Process.run('pkill', ['-f', 'sleep $secsA']);
        await Process.run('pkill', ['-f', 'sleep $secsB']);
      });
      final started = await env.startShellJob(
        'sh -c "sleep $secsA" & sh -c "exec sleep $secsB" & wait',
        id: 'sh-517b',
        logPath: '${tempDir.path}/sh-517b.log',
      );
      final job = started.valueOrNull!;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await _liveProcesses('sleep $secsA'), hasLength(1));
      expect(await _liveProcesses('sleep $secsB'), hasLength(1));
      await job.stop();
      await job.settled;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(await _liveProcesses('sleep $secsA'), isEmpty);
      expect(await _liveProcesses('sleep $secsB'), isEmpty);
    });

    test(
      'boot sweep reaps a dead-leader group and warns once (AC3)',
      skip: LocalShell.jobsGetOwnProcessGroup
          ? null
          : 'needs setsid (group leadership)',
      () async {
        final secs = token(4);
        addTearDown(() => Process.run('pkill', ['-f', 'sleep $secs']));
        final started = await env.startShellJob(
          'sleep $secs & wait',
          id: 'sh-517c',
          logPath: '${tempDir.path}/sh-517c.log',
        );
        final job = started.valueOrNull!;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        // Fabricate the crash: kill ONLY the group leader — the grandchild
        // survives, orphaned but still carrying the job's pgid.
        Process.killPid(job.pid!, ProcessSignal.sigkill);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(await _liveProcesses('sleep $secs'), hasLength(1));
        final warns = <String>[];
        final reaped = await reapOrphanJobGroups(
          env: env,
          candidatePids: [job.pid!],
          onWarn: warns.add,
        );
        expect(reaped.groups, 1);
        expect(reaped.processes, 1);
        expect(warns, hasLength(1));
        expect(await _liveProcesses('sleep $secs'), isEmpty);
      },
    );

    test('without group leadership stop still walks the live tree', () async {
      final secs = token(5);
      addTearDown(() => Process.run('pkill', ['-f', 'sleep $secs']));
      LocalShell.ownProcessGroupOverride = false;
      addTearDown(() => LocalShell.ownProcessGroupOverride = null);
      final started = await env.startShellJob(
        'sleep $secs & wait',
        id: 'sh-517d',
        logPath: '${tempDir.path}/sh-517d.log',
      );
      final job = started.valueOrNull!;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await _liveProcesses('sleep $secs'), hasLength(1));
      await job.stop();
      await job.settled;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(await _liveProcesses('sleep $secs'), isEmpty);
    });
  });
}

/// Live `ps` rows matching [needle]; zombies and the scanner itself
/// excluded — the process-scan assertion surface of the #517 tests.
Future<List<String>> _liveProcesses(String needle) async {
  final ps = await Process.run('ps', ['-ax', '-o', 'pid=,pgid=,stat=,args=']);
  return ps.stdout
      .toString()
      .split('\n')
      .where(
        (line) =>
            line.contains(needle) &&
            !line.contains('<defunct>') &&
            // Wrapper/intermediate shells carry the token in their args;
            // only the actual sleeper processes assert the tree's fate.
            !line.contains('sh -c') &&
            !line.contains(' ps -ax'),
      )
      .map((line) => line.trim())
      .toList();
}
