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

  test('cancelling the caller run token does not stop a registry job', () async {
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
  });

  test(
    'a run-token cancel during foreground-as-job bash hands the running '
    'job back to the background instead of killing it',
    () async {
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
    },
  );
}
