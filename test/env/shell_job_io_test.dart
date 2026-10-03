import 'dart:async';
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

    test('an unwritable job log fails cleanly instead of crashing with an '
        'unhandled error (issue #925)', () async {
      // The log path's parent is a regular file, so the open fails with
      // ENOTDIR — the same FileSystemException class as the ticket's
      // ENOSPC. Pre-fix the open ran unowned inside `File.openWrite` and
      // the error escaped to the root-zone handler (fatal for fa) while
      // the job never settled.
      final blocker = File('${tempDir.path}/bash_jobs')
        ..writeAsStringSync('not a directory\n');
      Object? zoneError;
      await runZonedGuarded(
        () async {
          final started = await env.startShellJob(
            'echo hi',
            id: 'sh-7',
            logPath: '${blocker.path}/sh-7.log',
          );
          expect(started.isErr, isTrue);
          expect(
            started.errorOrNull!.message,
            contains('cannot open job log file'),
          );
        },
        (Object error, StackTrace _) {
          // A failing expect() throws TestFailure inside the zone: surface
          // it through the normal test channel instead of the
          // 'unhandled zone error escaped' label.
          if (error is TestFailure) throw error;
          zoneError = error;
        },
      );
      // An escaping error still needs an event-loop turn to surface.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (zoneError != null) {
        fail('unhandled zone error escaped: $zoneError');
      }
    });
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
      skip: LocalShell.ownProcessGroupAvailable
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

  // Platform-independent unit coverage for the boot sweep via the
  // process-table seam: the setsid-dependent scenarios above skip on
  // hosts without group leadership (e.g. macOS), which would leave
  // reapOrphanJobGroups below the CRAP coverage bar.
  group('reapOrphanJobGroups (process-table seam, no setsid)', () {
    test('a null process table yields a zero sweep and no warning', () async {
      final warns = <String>[];
      final reaped = await reapOrphanJobGroups(
        env: env,
        candidatePids: [4242],
        onWarn: warns.add,
        groupTableOverride: () async => null,
      );
      expect(reaped, (groups: 0, processes: 0));
      expect(warns, isEmpty);
    });

    test('pids ≤ 1 are filtered before the table is even read', () async {
      var tableReads = 0;
      final reaped = await reapOrphanJobGroups(
        env: env,
        candidatePids: [-5, 0, 1],
        groupTableOverride: () async {
          tableReads++;
          return '';
        },
      );
      expect(reaped, (groups: 0, processes: 0));
      expect(tableReads, 0);
    });

    test('malformed table lines are skipped; a dead leader with no '
        'members reaps nothing', () async {
      final warns = <String>[];
      final reaped = await reapOrphanJobGroups(
        env: env,
        candidatePids: [4242],
        onWarn: warns.add,
        groupTableOverride: () async =>
            '\n'
            'onlyonecol\n'
            'x y\n'
            '5 zzz\n'
            '777 999\n',
      );
      expect(reaped, (groups: 0, processes: 0));
      expect(warns, isEmpty);
    });

    test('a live leader is never reaped — no kill is issued', () async {
      final shell = _RecordingShell(
        const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0)),
      );
      final fakeEnv = MemoryExecutionEnv(cwd: tempDir.path, shell: shell);
      final warns = <String>[];
      final reaped = await reapOrphanJobGroups(
        env: fakeEnv,
        candidatePids: [100],
        onWarn: warns.add,
        groupTableOverride: () async => '100 100\n101 100\n',
      );
      expect(reaped, (groups: 0, processes: 0));
      expect(warns, isEmpty);
      expect(shell.commands, isEmpty);
    });

    test("a dead leader's whole group is killed and warned once", () async {
      final shell = _RecordingShell(
        const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0)),
      );
      final fakeEnv = MemoryExecutionEnv(cwd: tempDir.path, shell: shell);
      final warns = <String>[];
      final reaped = await reapOrphanJobGroups(
        env: fakeEnv,
        candidatePids: [200],
        onWarn: warns.add,
        groupTableOverride: () async => '201 200\n202 200\n300 300\n',
      );
      expect(reaped, (groups: 1, processes: 2));
      expect(shell.commands, ['kill -9 201 202']);
      expect(warns, hasLength(1));
      expect(
        warns.single,
        contains('reaped 1 orphaned job process group(s) (2 processes)'),
      );
    });

    test('a failing kill leaves the group unreaped and silent', () async {
      final shell = _RecordingShell(
        const Err(ExecutionError(ExecutionErrorCode.shellUnavailable, 'nope')),
      );
      final fakeEnv = MemoryExecutionEnv(cwd: tempDir.path, shell: shell);
      final warns = <String>[];
      final reaped = await reapOrphanJobGroups(
        env: fakeEnv,
        candidatePids: [200],
        onWarn: warns.add,
        groupTableOverride: () async => '201 200\n',
      );
      expect(reaped, (groups: 0, processes: 0));
      expect(warns, isEmpty);
    });
  });

  group('bounded job logs (issue #919)', () {
    test('UT-1/E4: a runaway job stays bounded, keeps running, and paging '
        'reads the marker as content', () async {
      // ~1.7 KiB of output into a 512-byte ceiling; the registry passes the
      // ceiling through to every start (the shared seam).
      final registry = ShellJobRegistry(env: env, jobLogMaxBytes: 512);
      final entry = await registry.start(
        'i=0; while [ \$i -lt 200 ]; do printf "line-\$i\\n"; i=\$((i+1)); done',
      );
      await entry.settled;
      // The job itself is never killed — only capture degrades.
      expect(entry.exitCode, 0);
      expect(entry.stopReason, isNull);

      final log = File(entry.logPath).readAsStringSync();
      // Bounded ≈ ceiling: head + marker + tail ≤ maxBytes + marker slack.
      expect(log.length, lessThan(512 + jobLogTruncationMarker(1).length * 2));
      expect('[… log truncated:'.allMatches(log), hasLength(1));
      // The tail is live: the last produced line survives verbatim.
      expect(log.endsWith('line-199\n'), isTrue);

      // E4: paging treats the marker line as ordinary content.
      final paged = await registry.tail(entry.id);
      expect(paged, contains('log truncated:'));
      expect(paged, contains('line-199'));
    });

    test(
      'UT-2: output under the ceiling lands in the file byte-identically',
      () async {
        final started = await env.startShellJob(
          "printf 'a\nb\n'",
          id: 'sh-919b',
          logPath: '${tempDir.path}/sh-919b.log',
          options: const ShellExecOptions(jobLogMaxBytes: 512),
        );
        final job = started.valueOrNull!;
        await job.settled;
        expect(job.exitCode, 0);
        expect(File(job.logPath).readAsStringSync(), 'a\nb\n');
      },
    );

    test(
      'UT-4: a low-disk probe stops log writes and warns exactly once',
      () async {
        final warnings = <String>[];
        final guardedEnv = LocalExecutionEnv(
          cwd: tempDir.path,
          diskFreeProbe: (_) async => 1024, // below the 1 GB threshold
        );
        final started = await guardedEnv.startShellJob(
          'echo hi; sleep 0.2; echo bye2',
          id: 'sh-919c',
          logPath: '${tempDir.path}/sh-919c.log',
          options: ShellExecOptions(onJobLogWarning: warnings.add),
        );
        final job = started.valueOrNull!;
        await job.settled;
        // The job runs to completion; its log stays empty.
        expect(job.exitCode, 0);
        expect(job.stopReason, isNull);
        expect(File(job.logPath).readAsStringSync(), isEmpty);
        expect(warnings, hasLength(1));
        expect(warnings.single, contains('background job'));

        // Control: a healthy probe lets the log fill normally.
        final healthyEnv = LocalExecutionEnv(
          cwd: tempDir.path,
          diskFreeProbe: (_) async => 1 << 40,
        );
        final control = await healthyEnv.startShellJob(
          'echo hi',
          id: 'sh-919d',
          logPath: '${tempDir.path}/sh-919d.log',
        );
        await control.valueOrNull!.settled;
        expect(
          File('${tempDir.path}/sh-919d.log').readAsStringSync(),
          contains('hi'),
        );
      },
    );

    test('a bad ceiling fails as a clean Err before anything spawns '
        '(review round 2)', () async {
      final logPath = '${tempDir.path}/sh-919bad.log';
      final started = await env.startShellJob(
        'echo hi',
        id: 'sh-919bad',
        logPath: logPath,
        options: const ShellExecOptions(jobLogMaxBytes: 0),
      );
      expect(started.isErr, isTrue);
      expect(started.errorOrNull!.message, contains('jobLogMaxBytes'));
      // Nothing was spawned or opened: the eager log open (issue #925)
      // would have created the file before the old post-spawn validation
      // threw, stranding the child and leaking the fd.
      expect(File(logPath).existsSync(), isFalse);
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

/// Records every [exec] command and replies with a canned [Result] — the
/// boot-sweep unit tests assert on the exact `kill` line without spawning
/// real processes.
final class _RecordingShell implements Shell {
  _RecordingShell(this._result);

  final Result<ShellExecResult, ExecutionError> _result;
  final commands = <String>[];

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    return _result;
  }
}
