/// The cross-run manifest lock's contention contract (issue #2266),
/// unit-tested through the seam surface: a contender QUEUES behind a
/// held lock and its mutation lands — it never degrades into an
/// unlocked read-modify-write that can erase a live job's running.json
/// entry, and exhaustion past the bound fails LOUDLY by name. The
/// ps-real process legs live in agent_cli_waiting_integration_test.dart
/// (CI-Linux gated); everything here runs on any host.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  /// A local-FS CLI over [dir]: the lock's contention needs a real
  /// filesystem — only an exclusive-create backend refuses createDir on
  /// an existing entry (a memory env's createDir always succeeds).
  Future<(AgentCli, LocalExecutionEnv, FakeCliIO)> lockCli(String dir) async {
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
    // Nothing from a seeded registry is alive; the process-table seam
    // keeps the reconcile off the real ps table (these tests exercise
    // the lock, not the probe).
    cli.waitingProcessTableForTest = () async =>
        (pids: <int>{}, starts: <int, String>{});
    return (cli, env, io);
  }

  /// The shared fixture: a workspace whose manifest holds one rival
  /// entry (sh-x) and whose lock path is occupied by a held lock file.
  Future<(AgentCli, LocalExecutionEnv, FakeCliIO, String, File)> lockFixture(
    String tag,
  ) async {
    final workspace = await Directory.systemTemp.createTemp('fah2266-$tag-');
    addTearDown(() => workspace.delete(recursive: true));
    final dir = workspace.path;
    final (cli, env, io) = await lockCli(dir);
    final logs = '$dir/.fah/bash_jobs';
    await env.createDir(logs);
    await env.writeFile(
      '$logs/running.json',
      jsonEncode([
        {'id': 'sh-x', 'command': 'watch.sh', 'pid': '999999'},
      ]),
    );
    // The lock is an exclusive-created FILE (issue #2266) — a rival
    // holding it is a file at the lock path.
    final lock = File('$logs/running.json.lock');
    lock.writeAsStringSync('held');
    return (cli, env, io, logs, lock);
  }

  List<String> manifestIds(String? text) => [
    for (final entry in jsonDecode(text!) as List) (entry as Map)['id'],
  ];

  test('AC1: jobStarted queues behind a held lock — the holder\'s '
      'concurrent remove of another entry survives (issue #2266)', () async {
    final (cli, env, io, logs, lock) = await lockFixture('ac1');

    // Rival A holds the lock 400ms — past the old 300ms degrade bound —
    // then removes sh-x under its own lock and releases.
    final holder = () async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await env.writeFile('$logs/running.json', '[]');
      await lock.delete();
    }();
    // B queues behind A: its jobStarted must wait for the lock. At the
    // old 300ms bound it proceeded unlocked and its read-modify-write
    // raced A's remove — one of the two updates was always lost.
    final job = cli.shellJobsRegistryForTest.adoptRunningEntry(
      id: 'sh-b',
      command: 'watch.sh',
      pid: 424242,
    );
    await cli.waitingJobStartedForTest(job);
    await holder;

    final ids = manifestIds(
      (await env.readTextFile('$logs/running.json')).valueOrNull,
    );
    expect(ids, contains('sh-b'), reason: 'no lost update — B queued');
    expect(ids, isNot(contains('sh-x')), reason: "A's remove survived");
    expect(cli.waitingRegistryNoticeForTest, isNull, reason: 'no failure');
    expect(io.out.toString(), isNot(contains('#2266')));
  });

  test('AC2: bound exhaustion fails LOUDLY — mutation skipped, never run '
      'unlocked (issue #2266)', () async {
    final (cli, env, io, logs, lock) = await lockFixture('ac2');
    // The holder never releases and the lock is fresh (no stale steal);
    // the shrunken bound turns the exhaustion into the named failure.
    cli.waitingLockWaitBoundForTest = const Duration(milliseconds: 150);

    final job = cli.shellJobsRegistryForTest.adoptRunningEntry(
      id: 'sh-b',
      command: 'watch.sh',
      pid: 424242,
    );
    await cli.waitingJobStartedForTest(job);

    final ids = manifestIds(
      (await env.readTextFile('$logs/running.json')).valueOrNull,
    );
    expect(ids, ['sh-x'], reason: 'the mutation was skipped, not raced');
    expect(io.out.toString(), contains('manifest lock still held after 150ms'));
    expect(
      io.out.toString(),
      contains('registry update skipped to avoid an unlocked write'),
      reason: 'the named failure surfaces',
    );
    expect(cli.waitingRegistryNoticeForTest, isNotNull);
    expect(
      lock.existsSync(),
      isTrue,
      reason: "never steal a live holder's lock",
    );
  });

  test('AC2: a successful mutation clears the surfaced notice '
      '(issue #2266)', () async {
    final (cli, env, io, logs, lock) = await lockFixture('ac2b');
    cli.waitingLockWaitBoundForTest = const Duration(milliseconds: 150);
    final job = cli.shellJobsRegistryForTest.adoptRunningEntry(
      id: 'sh-b',
      command: 'watch.sh',
      pid: 424242,
    );
    await cli.waitingJobStartedForTest(job);
    expect(cli.waitingRegistryNoticeForTest, isNotNull);

    // The holder releases; the next mutation runs under the lock and
    // clears the notice.
    await lock.delete();
    final settleJob = cli.shellJobsRegistryForTest.adoptRunningEntry(
      id: 'sh-c',
      command: 'probe.sh',
      pid: 424243,
    );
    await cli.waitingJobStartedForTest(settleJob);

    expect(cli.waitingRegistryNoticeForTest, isNull);
    final ids = manifestIds(
      (await env.readTextFile('$logs/running.json')).valueOrNull,
    );
    expect(ids, contains('sh-c'));
  });

  test('REG: a non-occupancy lock refusal surfaces its real fs cause '
      'without contention retries', () async {
    final delegate = MemoryExecutionEnv(cwd: '/ws');
    final env = _PermissionDeniedLockEnv(delegate);
    final io = FakeCliIO();
    addTearDown(io.close);
    const manifestPath = '/ws/.fah/bash_jobs/running.json';
    const manifest = '[{"id":"sh-x","command":"watch.sh","pid":"999999"}]';
    await delegate.createDir('/ws/.fah/bash_jobs');
    await delegate.writeFile(manifestPath, manifest);
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
    cli.waitingProcessTableForTest = () async =>
        (pids: <int>{}, starts: <int, String>{});
    // Keep the failing-first run quick: the old code retries this refusal
    // as phantom contention until the bound and then reports a rival.
    cli.waitingLockWaitBoundForTest = const Duration(milliseconds: 150);

    await cli.waitingCaptureLostJobsForTest();

    expect(cli.waitingRegistryNoticeForTest, contains('permissionDenied'));
    expect(
      cli.waitingRegistryNoticeForTest,
      contains('errno 13: Permission denied'),
    );
    expect(
      cli.waitingRegistryNoticeForTest,
      contains('/ws/.fah/bash_jobs/running.json.lock'),
    );
    expect(
      cli.waitingRegistryNoticeForTest,
      isNot(contains('manifest lock still held')),
      reason: 'no phantom rival when the lock path is not occupied',
    );
    expect(env.claimAttempts, 1, reason: 'a broken fs is not retried for 70s');

    final job = cli.shellJobsRegistryForTest.adoptRunningEntry(
      id: 'sh-b',
      command: 'watch.sh',
      pid: 424242,
    );
    await cli.waitingJobStartedForTest(job);

    expect(cli.waitingRegistryNoticeForTest, contains('permissionDenied'));
    expect(
      cli.waitingRegistryNoticeForTest,
      isNot(startsWith('boot reconcile skipped:')),
      reason: 'the ordinary mutation reports its own refused claim',
    );
    expect(io.out.toString(), contains('errno 13: Permission denied'));
    expect(io.out.toString(), isNot(contains('manifest lock still held')));
    expect(
      (await delegate.readTextFile(manifestPath)).valueOrNull,
      manifest,
      reason: 'both failed claims skip their mutations fail-safe',
    );
  });

  test('AC3 REG: an exclusive-create-less backend keeps the documented '
      'degraded mode (issue #2266)', () async {
    // Memory's createDir always succeeds — no exclusivity, the lock is a
    // no-op, and mutations run unlocked. That degraded mode must survive
    // the #2266 rework: decided by the observed capability, never by a
    // timeout (which this backend can never even reach).
    final env = MemoryExecutionEnv(cwd: '/ws');
    final io = FakeCliIO();
    addTearDown(io.close);
    await env.createDir('/ws/.fah/bash_jobs');
    await env.writeFile(
      '/ws/.fah/bash_jobs/running.json',
      jsonEncode([
        {'id': 'sh-x', 'command': 'watch.sh', 'pid': '999999'},
      ]),
    );
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
    cli.waitingProcessTableForTest = () async =>
        (pids: <int>{}, starts: <int, String>{});

    await cli.waitingCaptureLostJobsForTest();
    expect(cli.waitingLostJobsForTest, 1, reason: 'the mutation proceeded');
    expect(
      (await env.readTextFile('/ws/.fah/bash_jobs/running.json')).valueOrNull,
      '[]',
    );

    final job = cli.shellJobsRegistryForTest.adoptRunningEntry(
      id: 'sh-b',
      command: 'watch.sh',
      pid: 424242,
    );
    await cli.waitingJobStartedForTest(job);
    expect(
      manifestIds(
        (await env.readTextFile('/ws/.fah/bash_jobs/running.json')).valueOrNull,
      ),
      ['sh-b'],
    );
    expect(cli.waitingRegistryNoticeForTest, isNull);
    expect(io.out.toString(), isNot(contains('#2266')));
  });
}

/// An exclusive-create backend whose lock claim is refused by the fs, not
/// by an occupant. The delegate's missing lock path makes the distinction
/// observable to the coordinator's subsequent fileInfo probe.
final class _PermissionDeniedLockEnv extends ForwardingFs
    implements ExclusiveCreateFileSystem {
  _PermissionDeniedLockEnv(super.delegate);

  int claimAttempts = 0;

  @override
  Future<Result<void, FileError>> createFileExclusive(String path) async {
    claimAttempts++;
    return Err(
      FileError(
        FileErrorCode.permissionDenied,
        'Cannot create file (errno 13: Permission denied)',
        path: path,
      ),
    );
  }
}
