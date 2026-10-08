import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
// LocalExecutionEnv is a VM-only surface (dart:io-backed) — it ships via
// the io.dart barrel, not the platform-neutral one.
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Issue #1408 AC1 at the CLI wiring level (review 5456649624 🚨#3): the
/// cross-run job registry bookkeeping — `running.json`, its lock, the
/// retention prune — must follow [AgentCliConfig.jobLogDir] exactly like
/// the log files do. The registry-level UT (`shell_jobs_isolation_test`)
/// passes even when the CLI bookkeeping hardcodes `<cwd>/.fah/bash_jobs`,
/// because it never boots the CLI; this test boots the real [AgentCli],
/// runs a background bash job to settle, and asserts the graded task dir
/// stays free of harness job artifacts.
///
/// Scope note: the assertion targets `.fah/bash_jobs` — the job-artifact
/// subtree this AC owns. Other `.fah/` subtrees (memory maintenance) are
/// separate surfaces with their own session-root scoping.
void main() {
  late Directory taskDir;
  late Directory artifactsDir;

  setUp(() async {
    taskDir = await Directory.systemTemp.createTemp('fa_bookkeeping_task');
    artifactsDir = await Directory.systemTemp.createTemp('fa_bookkeeping_art');
  });

  tearDown(() async {
    await taskDir.delete(recursive: true);
    await artifactsDir.delete(recursive: true);
  });

  test(
    'boot + background bash + settle leaves no job artifacts in the task '
    'dir when jobLogDir is set',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: LocalExecutionEnv(cwd: taskDir.path),
          sessionRoot: '${artifactsDir.path}/sessions',
          approvalMode: ApprovalMode.yolo,
          jobLogDir: '${artifactsDir.path}/bash_jobs',
        ),
        io: io,
        streamFunction: FakeStreamFunction([
          toolTurn(const [
            ToolCall(
              id: 'c1',
              name: 'bash',
              arguments: {
                'command': 'echo bookkeeping-probe',
                'background': true,
              },
            ),
          ]),
          textTurn('started the background job'),
          // The instant `echo` settles while the run is still live, so the
          // settle notice injects a third model turn before headless exit —
          // the script must cover it (leftover turns are simply unused).
          textTurn('noted the background settle'),
        ]).call,
      );

      final exit = await cli.runHeadless('start a background echo job');
      expect(
        exit,
        0,
        reason: 'the run completes with the job detached\n'
            '--- captured CLI output ---\n${io.out}',
      );

      // The job's artifacts land OUTSIDE the task workspace.
      await waitForIt(
        () => Directory(
          '${artifactsDir.path}/bash_jobs',
        ).listSync().any((entry) => entry.path.endsWith('.log')),
        reason: 'the job log is written under the override dir',
      );

      // ...and the cross-run bookkeeping follows: boot reconcile
      // (captureLostJobs) and the settle mutation both took the override —
      // no `.fah/bash_jobs` may appear in the graded task dir.
      expect(
        Directory('${taskDir.path}/.fah/bash_jobs').existsSync(),
        isFalse,
        reason: 'the registry manifest/lock must not live in the task dir',
      );
    },
  );
}
