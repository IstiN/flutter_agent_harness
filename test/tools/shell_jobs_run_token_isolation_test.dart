import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

/// gh-1455: a background shell job must own its lifecycle. The run's cancel
/// token (Agent.abort, the run-idle watchdog, steering teardown) used to be
/// forwarded into the job's ShellExecOptions, so an aborted run tore down
/// every live job — and `bash_job stop` from inside the dying batch then
/// cancelled the whole run on top of the abort.
///
/// The contract pinned here: caller cancel tokens NEVER reach job space
/// (the registry firewalls them), and the foreground-as-job bash path
/// unwinds on a run cancel by handing the still-running job back to the
/// background — never by killing it.
void main() {
  late Directory tempDir;
  late LocalExecutionEnv env;
  late ShellJobRegistry registry;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('gh1455-job-test-');
    env = LocalExecutionEnv(cwd: tempDir.path);
    registry = ShellJobRegistry(env: env);
  });

  tearDown(() async {
    for (final entry in registry.jobs) {
      if (entry.isRunning) await entry.stop();
    }
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<ShellJobEntry> waitForJob() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (registry.jobs.isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('job never started');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return registry.jobs.single;
  }

  test(
    'cancelling the caller run token does not stop a registry job',
    () async {
      final runTokenSource = CancelTokenSource();
      final entry = await registry.start(
        'sleep 60',
        options: ShellExecOptions(cancelToken: runTokenSource.token),
      );
      expect(entry.isRunning, isTrue);
      runTokenSource.cancel('run aborted');
      // Give a forwarded token one event-loop turn to tear the job down.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        entry.isRunning,
        isTrue,
        reason: 'a job owns its lifecycle, not the run that started it',
      );
      await entry.stop();
      await entry.settled;
      expect(entry.isRunning, isFalse);
      expect(entry.exitCode, isNot(0));
      expect(entry.stopReason, 'stopped');
    },
  );

  test('a run-token cancel during foreground-as-job bash hands the running '
      'job back to the background instead of killing it', () async {
    final runTokenSource = CancelTokenSource();
    final yieldSource = CancelTokenSource();
    final tool = shellTool(env, jobs: registry);
    final resultFuture = runZoned(
      () => tool.execute({'command': 'sleep 60'}, runTokenSource.token, null),
      zoneValues: {yieldTokenZoneKey: yieldSource.token},
    );
    final entry = await waitForJob();
    expect(entry.isRunning, isTrue);

    // The "run" aborts mid-call.
    runTokenSource.cancel('run aborted');
    final result = await resultFuture;
    final text = (result.content.single as TextContent).text;
    expect(text, contains('background job ${entry.id}'));
    expect(text, contains('NOT killed'));

    expect(
      entry.isRunning,
      isTrue,
      reason: 'aborting the run must not kill a running job',
    );
    await entry.stop();
    await entry.settled;
    expect(entry.stopReason, 'stopped');
  });

  test('a supervisor cancel-retry (StuckCallFollowUp on the call token) fails '
      'the call with Command aborted but keeps the job running', () async {
    final runTokenSource = CancelTokenSource();
    final yieldSource = CancelTokenSource();
    final tool = shellTool(env, jobs: registry);
    final resultFuture = runZoned(
      () => tool.execute({'command': 'sleep 60'}, runTokenSource.token, null),
      zoneValues: {yieldTokenZoneKey: yieldSource.token},
    );
    final entry = await waitForJob();
    expect(entry.isRunning, isTrue);

    // The stuck-call supervisor's cancel_retry cancels the CALL token
    // with a StuckCallFollowUp reason: the attempt fails like the
    // pre-gh-1455 token-kill, but the job is NOT killed.
    runTokenSource.cancel(const StuckCallFollowUp('cancel_retry: stuck'));
    await expectLater(
      resultFuture,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Command aborted'),
        ),
      ),
    );
    expect(
      entry.isRunning,
      isTrue,
      reason: 'the supervisor retry must not kill the job either',
    );
    await entry.stop();
    await entry.settled;
    expect(entry.stopReason, 'stopped');
  });

  test('a supervisor cancel-retry on a log-heavy hung command tail-truncates '
      'the thrown log and keeps the rewrite notice (review, gh-1455)',
      () async {
    final runTokenSource = CancelTokenSource();
    final yieldSource = CancelTokenSource();
    final tool = shellTool(env, jobs: registry);
    // A GitHub-token shape forces a command rewrite (so the rewrite
    // notice must ride on the supervisor-abort error); the loop
    // accumulates a log far beyond the 50 KiB tool budget before the
    // command parks on sleep — exactly the hung, log-heavy case the
    // stuck-call supervisor targets.
    final token = 'ghp_${'A' * 36}';
    final command = 'export GH_TOKEN=$token; '
        'i=0; while [ \$i -lt 4000 ]; do echo "line-\$i-padding"; '
        'i=\$((i+1)); done; sleep 60';
    final resultFuture = runZoned(
      () => tool.execute({'command': command}, runTokenSource.token, null),
      zoneValues: {yieldTokenZoneKey: yieldSource.token},
    );
    final entry = await waitForJob();
    expect(entry.isRunning, isTrue);

    // Let the log grow past the tool budget before the supervisor fires.
    final logFile = File(entry.logPath);
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!logFile.existsSync() || logFile.lengthSync() < 60 * 1024) {
      if (DateTime.now().isAfter(deadline)) {
        fail('job log never reached the tool budget');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    runTokenSource.cancel(const StuckCallFollowUp('cancel_retry: stuck'));
    Object? error;
    try {
      await resultFuture;
    } on StateError catch (e) {
      error = e;
    }
    expect(
      error,
      isA<StateError>(),
      reason: 'the supervisor retry must still fail the call',
    );
    final message = (error! as StateError).message!;
    expect(message, contains('Command aborted'));
    // gh-1455 review: the whole log must NOT be thrown into the model's
    // context — the supervisor-abort error carries the same tail-
    // truncation shaping as the settled inline path.
    expect(message, contains('[Showing lines'));
    expect(
      message,
      isNot(contains('line-0-')),
      reason: 'the head of the log is cut',
    );
    expect(
      message,
      contains('line-3999-'),
      reason: 'the tail of the log survives',
    );
    expect(
      message.length,
      lessThan(200 * 1024),
      reason: 'the thrown message stays inside the tool budget',
    );
    // The rewrite notice ("secret-shaped value" prefix) is dropped by the
    // untruncated branch — it must ride here exactly like on the settled
    // path.
    expect(message, contains('secret-shaped value'));

    expect(
      entry.isRunning,
      isTrue,
      reason: 'the supervisor retry must not kill the job either',
    );
    await entry.stop();
    await entry.settled;
    expect(entry.stopReason, 'stopped');
  });
}
