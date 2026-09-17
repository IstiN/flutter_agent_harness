/// Integration tests for the visible-waiting wiring on a real [AgentCli]
/// (issue #450): the seam snapshot over the live registry + queue, the
/// heartbeat tick delivery path, and the headless `--wait-for-jobs` early
/// return when no waiters exist.
library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/waiting_heartbeat.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  setUp(() {
    env = MemoryExecutionEnv();
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  AgentCli cliFor(FakeStreamFunction fake, {JobsConfig? jobs}) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      jobs: jobs ?? const JobsConfig(),
    ),
    io: io,
    streamFunction: fake.call,
  );
  test(
    'boot sweep reaps a previous-run orphan group and warns '
    '(issue #517)',
    skip: LocalShell.jobsGetOwnProcessGroup
        ? null
        : 'needs setsid (group leadership)',
    () async {
      final workspace = await Directory.systemTemp.createTemp('fah517-cli-');
      addTearDown(() => workspace.delete(recursive: true));
      // Fabricate the crashed run: a job group whose leader is dead but
      // whose grandchild survived.
      final secs = '517.9${DateTime.now().microsecondsSinceEpoch % 100000}';
      final leader = await Process.start('setsid', [
        'sh',
        '-c',
        'sleep $secs & wait',
      ]);
      addTearDown(() => Process.run('pkill', ['-f', 'sleep $secs']));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      Process.killPid(leader.pid, ProcessSignal.sigkill);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final dir = workspace.path;
      final localEnv = LocalExecutionEnv(cwd: dir);
      final localIo = FakeCliIO();
      addTearDown(localIo.close);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: localEnv,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: localIo,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      await localEnv.createDir('$dir/.fah/bash_jobs');
      await localEnv.writeFile(
        '$dir/.fah/bash_jobs/running.json',
        jsonEncode([
          {
            'id': 'sh-dead',
            'command': 'sleep $secs & wait',
            'pid': '${leader.pid}',
          },
        ]),
      );

      await cli.waitingCaptureLostJobsForTest();
      expect(localIo.out.toString(), contains('reaped 1 orphaned job process'));
      final ps = await Process.run('ps', ['-ax', '-o', 'args=']);
      final survivors = ps.stdout
          .toString()
          .split('\n')
          .where((l) => l.contains('sleep $secs') && !l.contains('sh -c'))
          .toList();
      expect(survivors, isEmpty);
    },
  );

  test('snapshot seam aggregates an empty registry and queue', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
    final snap = await cli.waitersSnapshotForTest();
    expect(snap.jobs, isEmpty);
    expect(snap.timers, isEmpty);
    expect(snap.isEmpty, isTrue);
  });

  test(
    'captureLostJobs counts manifest entries left by the previous run',
    () async {
      final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
      final dir = env.cwd;
      await env.createDir('$dir/.fah/bash_jobs');
      await env.writeFile(
        '$dir/.fah/bash_jobs/running.json',
        '[{"id":"a","command":"sleep 90"},{"id":"b","command":"sleep 120"}]',
      );
      await cli.waitingCaptureLostJobsForTest();
      expect(cli.waitingLostJobsForTest, 2);
      final snap = await cli.waitersSnapshotForTest();
      expect(snap.lostJobs, 2);
    },
  );

  test('heartbeat tick with no waiters settles the chain quietly', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
    cli.waitingHeartbeatTickForTest();
    // No run started (the guard path) — nothing written to the terminal.
    expect(io.out, isEmpty);
  });

  test(
    'headless --wait-for-jobs with no waiters returns immediately',
    () async {
      final cli = cliFor(FakeStreamFunction([textTurn('done')]));
      final code = await cli.runHeadless('hi', waitForJobs: true);
      expect(code, 0);
    },
  );

  test('headless --wait-for-jobs rides a timer wake to resolution', () async {
    final cli = cliFor(
      FakeStreamFunction([textTurn('done'), textTurn('woke')]),
    );
    await cli.waitingScheduleTimerForTest(
      'check CI',
      Duration(milliseconds: 120),
    );
    final code = await cli.runHeadless('hi', waitForJobs: true);
    expect(code, 0);
    final out = io.out.toString();
    expect(out, contains('⏳ waiting:'));
    expect(out, contains('waiters resolved'));
  });

  test('a torn manifest counts zero lost jobs — never invented', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
    final dir = env.cwd;
    await env.createDir('$dir/.fah/bash_jobs');
    await env.writeFile('$dir/.fah/bash_jobs/running.json', 'not-json{');
    await cli.waitingCaptureLostJobsForTest();
    expect(cli.waitingLostJobsForTest, 0);
  });

  // -- Boot reconcile (issue #478) -------------------------------------------

  test('boot reconcile drops a dead-pid entry with a one-line notice '
      '(issue #478)', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
    // Empty process table: nothing from the previous run is alive.
    cli.waitingProcessTableForTest = () async =>
        (pids: <int>{}, starts: <int, String>{});
    final dir = env.cwd;
    await env.createDir('$dir/.fah/bash_jobs');
    await env.writeFile(
      '$dir/.fah/bash_jobs/running.json',
      jsonEncode([
        {
          'id': 'sh-1',
          'command': 'sleep 90',
          'pid': '424242',
          'startedAtMs': DateTime.now().millisecondsSinceEpoch,
        },
      ]),
    );

    await cli.waitingCaptureLostJobsForTest();
    expect(cli.waitingLostJobsForTest, 1);
    expect(
      (await env.readTextFile('$dir/.fah/bash_jobs/running.json')).valueOrNull,
      '[]',
      reason: 'the dead-pid entry must leave the registry',
    );
    expect(io.out.toString(), contains('1 stale job entry dropped'));
  });

  test('boot reconcile probes never ride the shell command stream '
      '(issue #478 CI)', () async {
    // A recording shell: anything the reconcile executes through the
    // environment's Shell lands here — CI run 35213198081 caught the
    // `ps` probes leaking into the recorded `!`-command history this
    // way. The probes read the process table straight from the OS.
    final shell = FakeShell();
    final shellEnv = MemoryExecutionEnv(cwd: '/work', shell: shell);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: shellEnv,
        sessionRoot: '/sessions',
        jobs: const JobsConfig(),
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
    // A previous run left one entry behind: verifying it needs the OS
    // table (read off-stream), and a pid nothing alive matches is
    // dropped — while the shell stream stays empty.
    const dir = '/work';
    await shellEnv.createDir('$dir/.fah/bash_jobs');
    await shellEnv.writeFile(
      '$dir/.fah/bash_jobs/running.json',
      jsonEncode([
        {
          'id': 'sh-ghost',
          'command': 'sleep 99 & wait',
          'pid': '424242',
          'startedAtMs': DateTime.now().millisecondsSinceEpoch,
        },
      ]),
    );

    await cli.waitingCaptureLostJobsForTest();
    expect(cli.waitingLostJobsForTest, 1);
    expect(shell.commands, isEmpty);
  });

  test('boot reconcile keeps a live-pid entry (issue #478)', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
    cli.waitingProcessTableForTest = () async =>
        (pids: {42}, starts: <int, String>{});
    final dir = env.cwd;
    await env.createDir('$dir/.fah/bash_jobs');
    await env.writeFile(
      '$dir/.fah/bash_jobs/running.json',
      jsonEncode([
        {'id': 'sh-1', 'command': 'sleep 90', 'pid': '42'},
      ]),
    );

    await cli.waitingCaptureLostJobsForTest();
    expect(cli.waitingLostJobsForTest, 0);
    expect(
      (await env.readTextFile('$dir/.fah/bash_jobs/running.json')).valueOrNull,
      contains('sh-1'),
      reason: 'a live detached job is genuinely running, never a ghost',
    );
    expect(io.out.toString(), isNot(contains('stale job')));
  });

  test('boot reconcile drops a recycled pid via the start-time mismatch '
      '(issue #478)', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
    cli.waitingProcessTableForTest = () async =>
        (pids: {42}, starts: {42: 'Mon Sep 17 10:00:00 2026'});
    final dir = env.cwd;
    await env.createDir('$dir/.fah/bash_jobs');
    await env.writeFile(
      '$dir/.fah/bash_jobs/running.json',
      jsonEncode([
        {
          'id': 'sh-1',
          'command': 'sleep 90',
          'pid': '42',
          'pidStart': 'Sun Sep 16 09:00:00 2026',
        },
      ]),
    );

    await cli.waitingCaptureLostJobsForTest();
    expect(cli.waitingLostJobsForTest, 1);
    expect(
      (await env.readTextFile('$dir/.fah/bash_jobs/running.json')).valueOrNull,
      '[]',
    );
  });

  test('boot reconcile drops a past-staleHours entry even with a live pid '
      '(issue #478)', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
    cli.waitingProcessTableForTest = () async =>
        (pids: {42}, starts: {42: 'start'});
    final dir = env.cwd;
    await env.createDir('$dir/.fah/bash_jobs');
    await env.writeFile(
      '$dir/.fah/bash_jobs/running.json',
      jsonEncode([
        {
          'id': 'sh-1',
          'command': 'sleep 9000',
          'pid': '42',
          'startedAtMs': DateTime.now()
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
        },
      ]),
    );

    await cli.waitingCaptureLostJobsForTest();
    expect(cli.waitingLostJobsForTest, 1);
    expect(
      (await env.readTextFile('$dir/.fah/bash_jobs/running.json')).valueOrNull,
      '[]',
    );
    expect(io.out.toString(), contains('1 stale job entr'));
  });

  test('a corrupt manifest is quarantined as .bad and rebuilt empty '
      '(issue #478)', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
    final dir = env.cwd;
    await env.createDir('$dir/.fah/bash_jobs');
    await env.writeFile('$dir/.fah/bash_jobs/running.json', '{"id":"x"');

    await cli.waitingCaptureLostJobsForTest();
    expect(cli.waitingLostJobsForTest, 0);
    expect(
      (await env.exists('$dir/.fah/bash_jobs/running.json.bad')).valueOrNull,
      isTrue,
    );
    expect(
      (await env.readTextFile('$dir/.fah/bash_jobs/running.json')).valueOrNull,
      '[]',
      reason: 'rebuilt empty, never double-counted',
    );
    expect(io.out.toString(), contains('quarantined'));
  });

  test('duplicate manifest entries are counted once (issue #478)', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
    final dir = env.cwd;
    await env.createDir('$dir/.fah/bash_jobs');
    await env.writeFile(
      '$dir/.fah/bash_jobs/running.json',
      jsonEncode([
        {'id': 'a', 'command': 'sleep 1'},
        {'id': 'a', 'command': 'sleep 1'},
        {'id': 'b', 'command': 'sleep 2'},
      ]),
    );

    await cli.waitingCaptureLostJobsForTest();
    expect(cli.waitingLostJobsForTest, 2);
  });

  test('boot log GC prunes old job logs, keeps fresh, retention 0 disables '
      '(issue #478)', () async {
    final workspace = await Directory.systemTemp.createTemp('fah478-logs-');
    addTearDown(() => workspace.delete(recursive: true));
    final dir = workspace.path;
    final localEnv = LocalExecutionEnv(cwd: dir);
    final logs = '$dir/.fah/bash_jobs';
    await localEnv.createDir(logs);
    final old = File('$logs/sh-1-abc.log');
    await old.writeAsString('old output');
    await old.setLastModified(DateTime.now().subtract(const Duration(days: 5)));
    await File('$logs/sh-2-def.log').writeAsString('fresh output');

    AgentCli localCliWith(JobsConfig jobs) => AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: localEnv,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        jobs: jobs,
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );

    await localCliWith(const JobsConfig()).waitingCaptureLostJobsForTest();
    expect(
      old.existsSync(),
      isFalse,
      reason: 'a 5-day-old log exceeds the default 3-day retention',
    );
    expect(File('$logs/sh-2-def.log').existsSync(), isTrue);
    expect(io.out.toString(), contains('old job log'));

    // retention 0 disables the GC entirely.
    final ancient = File('$logs/sh-3-ghi.log');
    await ancient.writeAsString('ancient output');
    await ancient.setLastModified(
      DateTime.now().subtract(const Duration(days: 30)),
    );
    await localCliWith(
      const JobsConfig(logRetentionDays: 0),
    ).waitingCaptureLostJobsForTest();
    expect(ancient.existsSync(), isTrue);
  });

  // -- Registry lock branches (issue #478 CRAP gate) -------------------------

  /// A local-FS CLI: the lock's contended branches need a real
  /// filesystem — the exclusive create only fails when a regular FILE
  /// occupies the lock path, which no memory env can express (its
  /// createDir always succeeds).
  Future<AgentCli> lockCli(
    LocalExecutionEnv localEnv,
    FakeCliIO localIo,
  ) async {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: localEnv,
        sessionRoot: '/sessions',
      ),
      io: localIo,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
    // Nothing from the seeded registry is alive; the probe seam keeps
    // the reconcile off the real process table.
    cli.waitingProcessTableForTest = () async => null;
    return cli;
  }

  /// The shared fixture: workspace, seeded registry (one dead entry —
  /// the lost-jobs count is the proof the locked body actually ran),
  /// and a foreign lock held by a regular file.
  Future<(AgentCli, String)> lockFixture() async {
    final workspace = await Directory.systemTemp.createTemp('fah478-lock-');
    addTearDown(() => workspace.delete(recursive: true));
    final dir = workspace.path;
    final localEnv = LocalExecutionEnv(cwd: dir);
    final localIo = FakeCliIO();
    addTearDown(localIo.close);
    final logs = '$dir/.fah/bash_jobs';
    await localEnv.createDir(logs);
    await localEnv.writeFile(
      '$logs/running.json',
      '[{"id":"sh-dead","command":"sleep 90"}]',
    );
    File('$logs/running.json.lock').writeAsStringSync('held');
    return (await lockCli(localEnv, localIo), logs);
  }

  test(
    'a freshly held lock times out and the mutation degrades to an '
    'unlocked write (issue #478)',
    () async {
      final (cli, logs) = await lockFixture();

      await cli.waitingCaptureLostJobsForTest();

      expect(
        cli.waitingLostJobsForTest,
        1,
        reason: 'the bounded wait gives up and the write proceeds unlocked',
      );
      expect(
        File('$logs/running.json.lock').existsSync(),
        isTrue,
        reason: "a timed-out contender never removes someone else's lock",
      );
    },
  );

  test(
    'a stale lock is stolen and released after the mutation (issue #478)',
    () async {
      final (cli, logs) = await lockFixture();
      final lock = File('$logs/running.json.lock');
      // The holder crashed: nothing refreshes the lock past the 60s
      // staleness bound.
      lock.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 2)),
      );

      await cli.waitingCaptureLostJobsForTest();

      expect(cli.waitingLostJobsForTest, 1);
      expect(
        lock.existsSync(),
        isFalse,
        reason: 'stale lock stolen, then released',
      );
    },
  );

  test(
    'a lock released during the wait is acquired on retry and released '
    '(issue #478)',
    () async {
      final (cli, logs) = await lockFixture();
      final lock = File('$logs/running.json.lock');
      // The holder finishes 50ms in — well inside the 300ms wait bound.
      Timer(const Duration(milliseconds: 50), () {
        if (lock.existsSync()) lock.deleteSync();
      });

      await cli.waitingCaptureLostJobsForTest();

      expect(
        cli.waitingLostJobsForTest,
        1,
        reason: 'acquired on a retry inside the bound — not degraded',
      );
      expect(
        lock.existsSync(),
        isFalse,
        reason: 'the winner releases in the finally',
      );
    },
  );
}
