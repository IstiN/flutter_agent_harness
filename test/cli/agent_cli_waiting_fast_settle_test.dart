/// The fast-settle manifest race (issue #2275): `jobStarted`'s pid
/// probe used to run BEFORE the manifest lock, so an immediately
/// exiting background job's settle chain landed its remove inside the
/// probe's gap — and the late add then recorded an EXITED job as
/// running until the next boot (spurious stale warning + stale pid
/// into the orphan sweep). The probe now runs inside the locked add,
/// so the settle's remove always queues behind (and lands after) it.
/// Local-FS like the #2266 contention tests: only a real
/// exclusive-create backend serializes the two unawaited chains — a
/// memory env's lock degrades to an always-succeeding claim.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  Future<(AgentCli, LocalExecutionEnv, FakeCliIO, String)> settleCli(
    String tag, {
    required Future<String?> Function(int pid) pidStart,
  }) async {
    final workspace = await Directory.systemTemp.createTemp('fah2275-$tag-');
    addTearDown(() => workspace.delete(recursive: true));
    final dir = workspace.path;
    final env = LocalExecutionEnv(cwd: dir);
    final io = FakeCliIO();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
    // Keep the boot reconcile off the real ps table — these tests race
    // the pid START probe against the settle chain, nothing else.
    cli.waitingProcessTableForTest = () async =>
        (pids: <int>{}, starts: <int, String>{});
    cli.waitingPidStartProbeForTest = pidStart;
    return (cli, env, io, '$dir/.fah/bash_jobs/running.json');
  }

  List<dynamic> manifestEntries(String? text) =>
      jsonDecode(text ?? '[]') as List;

  test('AC1: an immediately-settled job leaves no running.json ghost '
      'behind the slow pid probe (issue #2275)', () async {
    final (cli, env, io, manifest) = await settleCli(
      'ac1',
      pidStart: (pid) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return 'slow probe';
      },
    );
    final job = cli.shellJobsRegistryForTest.adoptRunningEntry(
      id: 'sh-2275',
      command: 'true',
      pid: 4242,
    );
    // Production fires both chains unawaited, and the settle chain
    // lags by the child's exec+exit time — a fast job still needs a
    // few ms of process lifetime, while jobStarted's lock claim lands
    // immediately at spawn. 10ms models that floor (still ≪ the 100ms
    // probe): pre-fix the remove wins the empty gap before the late
    // add; post-fix the add holds the lock through the probe.
    final started = cli.waitingJobStartedForTest(job);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final settled = cli.waitingJobSettledForTest(job);
    await Future.wait([started, settled]);

    expect(
      manifestEntries((await env.readTextFile(manifest)).valueOrNull),
      isEmpty,
      reason: 'an exited job must not stay recorded as running',
    );
  });

  test('AC2: a long-lived job still records its pidStart liveness tag '
      '(issue #2275 regression)', () async {
    const startTag = 'Thu Nov 20 10:00:00 2026';
    final (cli, env, io, manifest) = await settleCli(
      'ac2',
      pidStart: (pid) async => startTag,
    );
    final job = cli.shellJobsRegistryForTest.adoptRunningEntry(
      id: 'sh-2275-live',
      command: 'sleep 90',
      pid: 4243,
    );
    await cli.waitingJobStartedForTest(job);

    final entries = manifestEntries(
      (await env.readTextFile(manifest)).valueOrNull,
    );
    expect(entries, hasLength(1));
    expect(entries.single['id'], 'sh-2275-live');
    expect(entries.single['pidStart'], startTag);
    expect(entries.single['pid'], '4243');
  });
}
