/// Gh-2415 [ResourceReleaser] on the local shell job: the registry's
/// fd-pressure guard releases a job's pipes/handles through it — while
/// the job still runs (its subscriptions and stdin pipe go; the settle
/// path still completes on the process exit) and again after settle
/// (idempotent, never throws).
library;

import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:test/test.dart';

void main() {
  group('_LocalShellJob.releaseResources (gh-2415)', () {
    test('releases a running job and stays idempotent after settle', () async {
      final workspace = await Directory.systemTemp.createTemp('fah2415r-');
      addTearDown(() => workspace.delete(recursive: true));
      final env = LocalExecutionEnv(cwd: workspace.path);
      final started = await env.startShellJob(
        'echo hi; sleep 0.3',
        id: 'sh-1-rel',
        logPath: '${workspace.path}/sh-1-rel.log',
      );
      expect(started.isOk, isTrue);
      final job = started.valueOrNull!;
      expect(job, isA<ResourceReleaser>());
      // While running: the pipe/subscription release must not break the
      // settle that the process exit still drives.
      final releaser = job as ResourceReleaser;
      releaser.releaseResources();
      await job.settled;
      expect(job.isRunning, isFalse);
      // After settle (the settle path already cancelled everything): a
      // second release is a harmless no-op.
      releaser.releaseResources();
      await pumpEventQueue();
    });

    test('a job that already settled releases without effect', () async {
      final workspace = await Directory.systemTemp.createTemp('fah2415s-');
      addTearDown(() => workspace.delete(recursive: true));
      final env = LocalExecutionEnv(cwd: workspace.path);
      final started = await env.startShellJob(
        'echo done',
        id: 'sh-2-rel',
        logPath: '${workspace.path}/sh-2-rel.log',
      );
      final job = started.valueOrNull!;
      await job.settled;
      (job as ResourceReleaser).releaseResources();
      await pumpEventQueue();
      expect(job.isRunning, isFalse);
    });
  });
}
