/// Integration tests for the visible-waiting wiring on a real [AgentCli]
/// (issue #450): the seam snapshot over the live registry + queue, the
/// heartbeat tick delivery path, and the headless `--wait-for-jobs` early
/// return when no waiters exist.
library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:flutter_agent_harness/src/cli/waiting_heartbeat.dart';
import 'package:flutter_agent_harness/src/env/process_probe_io.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() async {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  setUp(() {
    env = MemoryExecutionEnv();
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  // Whether the host lets this process run `ps` (hardened/sandboxed test
  // hosts deny it; CI Linux runs the real process-table paths).
  final psAvailable = await Process.run('ps', [
    '-ax',
    '-o',
    'pid=',
  ]).then((p) => p.exitCode == 0).catchError((Object _) => false);

  AgentCli cliForStream(
    AssistantMessageEventStream Function(
      Model,
      Context, {
      CancelToken? cancelToken,
    })
    streamFunction, {
    JobsConfig? jobs,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      // Full run boot (session persistence) needs a concrete provider
      // kind — the bare testModel alone never writes a session file.
      providerKind: 'openai-completions',
      jobs: jobs ?? const JobsConfig(),
    ),
    io: io,
    streamFunction: streamFunction,
  );
  AgentCli cliFor(FakeStreamFunction fake, {JobsConfig? jobs}) =>
      cliForStream(fake.call, jobs: jobs);
  test(
    'boot sweep reaps a previous-run orphan group and warns '
    '(issue #517)',
    skip: LocalShell.ownProcessGroupAvailable
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

  test(
    'bash_job stop on an adopted setsid job kills the whole group and '
    'clears the manifest (issue #2260 AC1)',
    skip: !LocalShell.ownProcessGroupAvailable || !psAvailable
        ? 'needs setsid (group leadership) with ps access'
        : null,
    () async {
      final workspace = await Directory.systemTemp.createTemp('fah2260a-');
      addTearDown(() => workspace.delete(recursive: true));
      // A live setsid group: leader sh + a two-sleep pipeline, all one
      // group (pgid == leader pid) — the issue's exact burn-CPU shape.
      final micros = DateTime.now().microsecondsSinceEpoch % 1000000;
      final s1 = '31$micros';
      final s2 = '32$micros';
      final leader = await Process.start('setsid', [
        'sh',
        '-c',
        'sleep $s1 | sleep $s2',
      ]);
      addTearDown(() => Process.killPid(leader.pid, ProcessSignal.sigkill));
      addTearDown(() => Process.run('pkill', ['-f', 'sleep $s1']));
      addTearDown(() => Process.run('pkill', ['-f', 'sleep $s2']));
      // The group must be table-visible before the boot, and the record
      // needs the real #478 start tag or the reconcile drops it.
      var startTag = '';
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        startTag = await pidStartSnapshot(leader.pid) ?? '';
        final detail = await processDetailTableSnapshot();
        final members = [
          if (detail != null)
            for (final row in detail)
              if (row.pgid == leader.pid) row.pid,
        ];
        if (startTag.isNotEmpty && members.length >= 3) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(startTag, isNotEmpty);

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
      final manifest = '$dir/.fah/bash_jobs/running.json';
      await localEnv.createDir('$dir/.fah/bash_jobs');
      await localEnv.writeFile(
        manifest,
        jsonEncode([
          {
            'id': 'sh-2260-prev',
            'command': 'sleep $s1 | sleep $s2',
            'pid': '${leader.pid}',
            'pidStart': startTag,
          },
        ]),
      );

      // Boot: the live entry re-adopts as a real registry job.
      await cli.waitingCaptureLostJobsForTest();
      final entry = cli.shellJobsRegistryForTest.jobs
          .where((job) => job.id == 'sh-2260-prev')
          .single;
      expect(entry.isAdopted, isTrue);
      expect(entry.isRunning, isTrue);
      entry.suppressSettleNotification();

      // bash_job action:stop drives the same stop path.
      await entry.stop();
      await pumpEventQueue();

      expect(entry.isRunning, isFalse);
      expect(entry.stopAttempted, isTrue);
      expect(entry.stopSurvivors, isEmpty, reason: 'the group verified gone');
      // AC1: NO live process carries the leader's pgid.
      final after = await processDetailTableSnapshot();
      expect([
        if (after != null)
          for (final row in after)
            if (row.pgid == leader.pid &&
                !(row.command?.contains('defunct') ?? false))
              row.pid,
      ], isEmpty);
      final ps = await Process.run('ps', ['-ax', '-o', 'args=']);
      expect(ps.stdout.toString(), isNot(contains('sleep $s1')));
      expect(ps.stdout.toString(), isNot(contains('sleep $s2')));
      // AC1: running.json no longer lists the id (verified-gone stop).
      final recorded =
          (await localEnv.readTextFile(manifest)).valueOrNull ?? '';
      expect(recorded, isNot(contains('sh-2260-prev')));
    },
  );

  test(
    'stop of a non-group-leader adopted job keeps the manifest record '
    '(issue #2260 AC2)',
    skip: !psAvailable ? 'needs POSIX with ps access' : null,
    () async {
      final workspace = await Directory.systemTemp.createTemp('fah2260b-');
      addTearDown(() => workspace.delete(recursive: true));
      // No setsid: the child sits in OUR group — the harness can never
      // prove the group is gone, so the stop must keep the record.
      final micros = DateTime.now().microsecondsSinceEpoch % 1000000;
      final child = await Process.start('sleep', ['30$micros']);
      addTearDown(() => Process.killPid(child.pid, ProcessSignal.sigkill));
      final startTag = await pidStartSnapshot(child.pid);
      expect(startTag, isNotNull);

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
      final manifest = '$dir/.fah/bash_jobs/running.json';
      await localEnv.createDir('$dir/.fah/bash_jobs');
      await localEnv.writeFile(
        manifest,
        jsonEncode([
          {
            'id': 'sh-2260-live',
            'command': 'sleep 30$micros',
            'pid': '${child.pid}',
            'pidStart': startTag,
          },
        ]),
      );
      await cli.waitingCaptureLostJobsForTest();
      final entry = cli.shellJobsRegistryForTest.jobs
          .where((job) => job.id == 'sh-2260-live')
          .single;
      entry.suppressSettleNotification();

      await entry.stop();
      await pumpEventQueue();

      expect(entry.isRunning, isFalse);
      expect(entry.stopAttempted, isTrue);
      expect(entry.stopSurvivors, isNull, reason: 'group unverifiable');
      final recorded =
          (await localEnv.readTextFile(manifest)).valueOrNull ?? '';
      expect(
        recorded,
        contains('sh-2260-live'),
        reason: 'the boot sweep reaps the group through this record',
      );
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

  test('waiting heartbeat beat drives the idle status round', () async {
    final fake = FakeStreamFunction([
      textTurn('first answer'),
      textTurn('still waiting: CI red'),
    ]);
    final cli = cliFor(fake);
    await cli.waitingScheduleTimerForTest('check CI', const Duration(hours: 1));
    final run = cli.run();
    // A real run's settle edge pushes the waiting row state, which arms
    // the heartbeat chain while the timer waiter is pending (issue #450).
    io.sendLine('hello');
    await waitForIt(
      () => fake.calls == 1 && !cli.isBusy,
      reason: 'run 1 settled (the settle edge armed the chain)',
    );
    // The beat fires the idle status round through the same self-wake
    // channel as the scheduled-message deliveries: a second run.
    cli.waitingHeartbeatTickForTest();
    await waitForIt(
      () => fake.calls == 2,
      reason: 'the beat started the status round',
    );
    expect(fake.calls, 2, reason: 'the beat ran the idle status round');
    await waitForIt(() => !cli.isBusy, reason: 'the status round settled');
    io.sendLine('/exit');
    await run;
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
    // gh-1446 AC8: the pending glyph resolves through the symbol table.
    expect(
      out,
      contains('${FaThemeController.instance.sym('status.pending')} waiting:'),
    );
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

  test('boot reconcile KEEPS a past-staleHours entry whose pid is '
      'verified alive (issue #2267)', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
    cli.waitingProcessTableForTest = () async =>
        (pids: {42}, starts: {42: 'Mon Sep 16 09:00:00 2026'});
    final dir = env.cwd;
    await env.createDir('$dir/.fah/bash_jobs');
    await env.writeFile(
      '$dir/.fah/bash_jobs/running.json',
      jsonEncode([
        {
          'id': 'sh-1',
          'command': 'sleep 9000',
          'pid': '42',
          'pidStart': 'Mon Sep 16 09:00:00 2026',
          'startedAtMs': DateTime.now()
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
        },
      ]),
    );

    await cli.waitingCaptureLostJobsForTest();
    // The age belt never claims a verified-alive entry: not lost, still
    // registered, no stale-job warning (AC1/AC3).
    expect(cli.waitingLostJobsForTest, 0);
    expect(
      (await env.readTextFile('$dir/.fah/bash_jobs/running.json')).valueOrNull,
      contains('sh-1'),
      reason: 'a live detached job outranks the age belt',
    );
    expect(io.out.toString(), isNot(contains('stale job')));
    // And it adopts like any live entry — visible, manageable (AC1).
    final adopted = cli.shellJobsRegistryForTest.job('sh-1');
    expect(adopted, isNotNull);
    expect(adopted!.isAdopted, isTrue);
    expect(adopted.pid, 42);
  });

  test('boot reconcile drops a past-staleHours RECYCLED pid regardless of '
      'age (issue #2267)', () async {
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
          'command': 'sleep 9000',
          'pid': '42',
          'pidStart': 'Mon Sep 16 09:00:00 2026',
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
      reason: 'the impersonation guard outranks liveness and the belt alike',
    );
  });

  test('boot reconcile drops a past-staleHours entry when the platform '
      'could not verify — the belt stays the only guard there '
      '(issue #2267)', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
    cli.waitingProcessTableForTest = () async => null;
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
      reason: 'unverifiable entries still age out — no immortal ghosts',
    );
  });

  test('jobs.staleHours 0 border unchanged: unverifiable aged entries '
      'still drop (issue #2267)', () async {
    final cli = cliFor(
      FakeStreamFunction([textTurn('ok')]),
      jobs: const JobsConfig(staleHours: 0),
    );
    cli.waitingProcessTableForTest = () async => null;
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
              .subtract(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        },
      ]),
    );

    await cli.waitingCaptureLostJobsForTest();
    expect(cli.waitingLostJobsForTest, 1);
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
  /// filesystem — only an exclusive-create backend refuses the claim
  /// when the lock path is occupied, which no memory env can express
  /// (its createDir always succeeds; issue #2266).
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

  test('a freshly held lock exhausts the bound into a NAMED failure — '
      'the mutation never proceeds unlocked (issue #2266)', () async {
    final (cli, logs) = await lockFixture();
    // The real bound sits above the stale-steal threshold; shrink it so
    // the test exercises the exhaustion, not a 70s wait.
    cli.waitingLockWaitBoundForTest = const Duration(milliseconds: 300);

    await cli.waitingCaptureLostJobsForTest();

    expect(
      cli.waitingLostJobsForTest,
      0,
      reason: 'the reconcile was skipped — never raced unlocked',
    );
    expect(
      cli.waitingRegistryNoticeForTest,
      contains('registry update skipped to avoid an unlocked write'),
      reason: 'the named failure surfaces, never vanishes',
    );
    expect(
      File('$logs/running.json.lock').existsSync(),
      isTrue,
      reason: "a timed-out contender never removes someone else's lock",
    );
    expect(
      File('$logs/running.json').readAsStringSync(),
      contains('sh-dead'),
      reason: 'the manifest is untouched — no unlocked rewrite',
    );
  });

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

  test('a lock released during the wait is acquired on retry and released '
      '(issue #478)', () async {
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
  });

  test(
    'boot re-adoption: a live manifest entry becomes a registry job '
    'while lostJobs keeps counting only the gone (issue #2201 AC5)',
    () async {
      final cli = cliFor(FakeStreamFunction([textTurn('ok')]));
      final now = DateTime.now().millisecondsSinceEpoch;
      // Fabricated pidStart data (AC5's UT shape): one verifiably live pid,
      // one dead pid, one entry past the staleHours age belt.
      cli.waitingProcessTableForTest = () async =>
          (pids: {424242}, starts: {424242: 'Mon Nov 16 10:00:00 2026'});
      final dir = env.cwd;
      await env.createDir('$dir/.fah/bash_jobs');
      await env.writeFile(
        '$dir/.fah/bash_jobs/running.json',
        jsonEncode([
          {
            'id': 'sh-live',
            'command': 'watch.sh',
            'pid': '424242',
            'pidStart': 'Mon Nov 16 10:00:00 2026',
            'startedAtMs': now,
          },
          {
            'id': 'sh-dead',
            'command': 'gone.sh',
            'pid': '999999',
            'pidStart': 'Mon Nov 16 10:00:00 2026',
            'startedAtMs': now,
          },
          {
            'id': 'sh-aged',
            'command': 'ancient.sh',
            'pid': '424243',
            'pidStart': 'Mon Nov 16 10:00:00 2026',
            'startedAtMs': now - const Duration(hours: 48).inMilliseconds,
          },
        ]),
      );

      await cli.waitingCaptureLostJobsForTest();
      // The dead + aged entries count as lost; the live one does not.
      expect(cli.waitingLostJobsForTest, 2);
      // The live entry was adopted as a real registry job.
      final adopted = cli.shellJobsRegistryForTest.job('sh-live');
      expect(adopted, isNotNull);
      expect(adopted!.isAdopted, isTrue);
      expect(adopted.isRunning, isTrue);
      expect(adopted.pid, 424242);
      expect(adopted.exitCode, isNull);
      // The waiting row shows it as an adopted waiter.
      final snap = await cli.waitersSnapshotForTest();
      expect(
        snap.jobs.where(
          (j) => j.startsWith('adopted: ') && j.contains('sh-live'),
        ),
        hasLength(1),
      );
      // The manifest was not duplicated by the adoption's bookkeeping.
      final manifest = (await env.readTextFile(
        '$dir/.fah/bash_jobs/running.json',
      )).valueOrNull!;
      expect('sh-live'.allMatches(manifest), hasLength(1));
    },
  );

  // Issue #2201 r4 (CRAP gate): scoped coverage for the notice-delivery
  // helpers the refactor extracted (_deliverJobNotice /
  // _steerAdoptedLiveness), driven through the real registry wiring.

  test(
    'adopted survivors: dim line always, fresh reaction run when idle '
    '(issue #2201)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // Session persistence roots under the project cwd: bind /work
      // so waitForSessions probes the root the boot writes.
      env = MemoryExecutionEnv(cwd: '/work');
      final stream = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(stream);
      final run = cli.run();
      await waitForSessions(env);
      // Pin the registry poll table: the fake pid stays verifiably alive
      // on every host (a real probe would drop it on Linux and the
      // settle path would muddy the assertions).
      cli.shellJobsRegistryForTest.livenessTableOverride = () async =>
          (pids: {4242}, starts: {4242: 'Mon Nov 16 10:00:00 2026'});

      await cli.shellJobsRegistryForTest
          .adoptSurvivors('nohup backtest &', const [
            ShellSurvivor(
              pid: 4242,
              startTag: 'Mon Nov 16 10:00:00 2026',
              command: 'sleep 300',
            ),
          ]);
      await waitForIt(
        () => stream.calls >= 1,
        reason: 'the idle adoption starts a fresh reaction run',
      );
      await waitForIt(() => !cli.isBusy);
      expect(io.out.toString(), contains('adopted 1 background process'));
      final delivered = [
        for (final message in stream.contexts[0].messages)
          if (message is UserMessage) messageText(message),
      ].join('\n');
      expect(delivered, contains('<system-notice>'));
      expect(delivered, contains('adopted as tracked jobs'));
      expect(delivered, contains('pid 4242'));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'adopted survivors: steered into a live run, never a second stream '
    '(issue #2201)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // Session persistence roots under the project cwd: bind /work
      // so waitForSessions probes the root the boot writes.
      env = MemoryExecutionEnv(cwd: '/work');
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('steered answer'),
      ], gateOnCall: 1);
      final cli = cliForStream(stream.call);
      final run = cli.run();
      await waitForSessions(env);
      cli.shellJobsRegistryForTest.livenessTableOverride = () async =>
          (pids: {4242}, starts: {4242: 'Mon Nov 16 10:00:00 2026'});

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      await cli.shellJobsRegistryForTest
          .adoptSurvivors('nohup migrate &', const [
            ShellSurvivor(
              pid: 4243,
              startTag: 'Mon Nov 16 10:00:00 2026',
              command: 'sleep 300',
            ),
          ]);
      expect(io.out.toString(), contains('adopted 1 background process'));
      stream.gate.complete();
      await waitForIt(() => stream.calls >= 2, reason: 'notice steers a turn');
      await waitForIt(() => !cli.isBusy);
      final delivered = [
        for (final message in stream.contexts[1].messages)
          if (message is UserMessage) messageText(message),
      ].join('\n');
      expect(delivered, contains('<system-notice>'));
      expect(delivered, contains('adopted as tracked jobs'));

      io.sendLine('/exit');
      await run;
    },
  );

  test('adopted liveness reminder: dim line idle, never starts a run '
      '(issue #2201 AC4)', () async {
    // Session persistence roots under the project cwd: bind /work
    // so waitForSessions probes the root the boot writes.
    env = MemoryExecutionEnv(cwd: '/work');
    const cadence = JobsConfig(
      adopted: AdoptedJobsConfig(livenessNoticeMinutes: 10),
    );
    final stream = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(stream, jobs: cadence);
    final run = cli.run();
    await waitForSessions(env);
    cli.shellJobsRegistryForTest.livenessTableOverride = () async =>
        (pids: {4242}, starts: {4242: 'Mon Nov 16 10:00:00 2026'});
    // Boot re-adoption with an OLD start: the 10-minute cadence is due
    // on the very first poll tick.
    cli.shellJobsRegistryForTest.adoptRunningEntry(
      id: 'sh-live-r4',
      command: 'watch.sh',
      pid: 4242,
      pidStart: 'Mon Nov 16 10:00:00 2026',
      startedAtMs:
          DateTime.now().millisecondsSinceEpoch -
          const Duration(minutes: 11).inMilliseconds,
    );

    await cli.shellJobsRegistryForTest.adoptedPollTickForTest();
    await pumpEventQueue();
    expect(io.out.toString(), contains('still running after 11 min'));
    expect(stream.calls, 0, reason: 'an idle reminder never starts a run');

    io.sendLine('/exit');
    await run;
  });

  test(
    'adopted liveness reminder: steers a live run (issue #2201 AC4)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // Session persistence roots under the project cwd: bind /work
      // so waitForSessions probes the root the boot writes.
      env = MemoryExecutionEnv(cwd: '/work');
      const cadence = JobsConfig(
        adopted: AdoptedJobsConfig(livenessNoticeMinutes: 10),
      );
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('steered answer'),
      ], gateOnCall: 1);
      final cli = cliForStream(stream.call, jobs: cadence);
      final run = cli.run();
      await waitForSessions(env);
      cli.shellJobsRegistryForTest.livenessTableOverride = () async =>
          (pids: {4242}, starts: {4242: 'Mon Nov 16 10:00:00 2026'});
      cli.shellJobsRegistryForTest.adoptRunningEntry(
        id: 'sh-live-r4b',
        command: 'watch.sh',
        pid: 4242,
        pidStart: 'Mon Nov 16 10:00:00 2026',
        startedAtMs:
            DateTime.now().millisecondsSinceEpoch -
            const Duration(minutes: 11).inMilliseconds,
      );
      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      await cli.shellJobsRegistryForTest.adoptedPollTickForTest();
      stream.gate.complete();
      await waitForIt(() => stream.calls >= 2, reason: 'reminder steers');
      await waitForIt(() => !cli.isBusy);
      final delivered = [
        for (final message in stream.contexts[1].messages)
          if (message is UserMessage) messageText(message),
      ].join('\n');
      expect(delivered, contains('<system-notice>'));
      expect(delivered, contains('still running after 11 min'));

      io.sendLine('/exit');
      await run;
    },
  );
}

/// Boot-completion wait: the session persisted (copied from the busy
/// steering harness — the same deterministic boot edge).
Future<void> waitForSessions(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  for (var i = 0; i < 5000; i++) {
    if ((await repo.list(cwd: '/work')).isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: session persisted');
}

/// A stream function that blocks one chosen call on a gate (copied from
/// the busy-gate test): the deterministic way to hold a run open while
/// the test drives mid-run registry callbacks.
class _GatedStream {
  _GatedStream(this.turns, {required this.gateOnCall});

  final List<List<AssistantMessageEvent>> turns;
  final int gateOnCall;
  final gate = Completer<void>();
  final contexts = <Context>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    void emit(List<AssistantMessageEvent> events) {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }

    if (calls == gateOnCall) {
      unawaited(gate.future.then((_) => emit(turns.removeAt(0))));
    } else {
      emit(turns.removeAt(0));
    }
    return stream;
  }
}
