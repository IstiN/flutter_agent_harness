/// Integration tests for the visible-waiting wiring on a real [AgentCli]
/// (issue #450): the seam snapshot over the live registry + queue, the
/// heartbeat tick delivery path, and the headless `--wait-for-jobs` early
/// return when no waiters exist.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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

  AgentCli cliFor(FakeStreamFunction fake) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
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
}
