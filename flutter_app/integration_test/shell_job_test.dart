// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration test for background shell jobs (the [BackgroundShell]
/// capability): a detached job writes its log and settles; a long-running
/// job stops mid-run.
///
/// On desktop hosts this exercises the local shell; on iOS/Android the WASI
/// sandbox shell — the job runs on a job-local interpreter clone with its own
/// cwd/env/output state.
///
/// Run: `flutter test integration_test/shell_job_test.dart`
library;

import 'package:fa/sandbox/env_factory.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// The platform env plus its job-capable view, or a null [bg] when the
  /// platform cannot run background jobs (nothing to test there).
  Future<({ExecutionEnv env, BackgroundShell? bg})> makeEnv() async {
    final env = await createPlatformEnv();
    if (env case final BackgroundShell bg) {
      if (bg.backgroundJobsSupported) return (env: env, bg: bg);
    }
    return (env: env, bg: null);
  }

  testWidgets('background shell job writes its log and settles', (
    tester,
  ) async {
    final (:env, :bg) = await makeEnv();
    if (bg == null) return;
    await env.createDir('${env.cwd}/.fah/bash_jobs');

    final started = await bg.startShellJob(
      'echo hello-from-job',
      id: 'it-1',
      logPath: '${env.cwd}/.fah/bash_jobs/it-1.log',
    );
    expect(started.isOk, isTrue, reason: '${started.errorOrNull}');
    final job = started.valueOrNull!;
    await job.settled;
    expect(job.exitCode, 0);
    final log = await env.readTextFile(job.logPath);
    expect(log.valueOrNull, contains('hello-from-job'));
  });

  testWidgets('stop terminates a long background job mid-run', (tester) async {
    final (:env, :bg) = await makeEnv();
    if (bg == null) return;
    await env.createDir('${env.cwd}/.fah/bash_jobs');

    final started = await bg.startShellJob(
      'sleep 30',
      id: 'it-2',
      logPath: '${env.cwd}/.fah/bash_jobs/it-2.log',
    );
    final job = started.valueOrNull!;
    expect(job.isRunning, isTrue);
    await job.stop();
    await job.settled;
    expect(job.isRunning, isFalse);
    expect(job.exitCode, isNot(0));
  });
}
