import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

/// Issue #1408 AC1/AC2: bench/unattended runs must keep the harness's own
/// artifacts OUTSIDE the task workspace.
///
/// The autopsy (run 37736364517, sanitize-git-repo ×2) showed fa's
/// bash-job logs at `<task-cwd>/.fah/bash_jobs/` flipping
/// `test_no_other_files_changed`: the logs captured raw secret values, the
/// agent sanitized its own harness logs, and the extra modified files
/// failed the graded diff. A bench run therefore relocates the job-log
/// directory via `FAH_JOB_LOG_DIR` (the in-container twin of `$RUNNER_TEMP`)
/// — and a completed run leaves NO `.fah/` in the task dir.
void main() {
  group('jobLogDirOverride (FAH_JOB_LOG_DIR)', () {
    test('reads the env override', () {
      expect(
        jobLogDirOverride({'FAH_JOB_LOG_DIR': '/tmp/fa-harness/bash_jobs'}),
        '/tmp/fa-harness/bash_jobs',
      );
    });

    test('trims surrounding whitespace', () {
      expect(jobLogDirOverride(const {'FAH_JOB_LOG_DIR': ' /tmp/x '}), '/tmp/x');
    });

    test('null when unset or blank', () {
      expect(jobLogDirOverride(const {}), isNull);
      expect(jobLogDirOverride(const {'FAH_JOB_LOG_DIR': ''}), isNull);
      expect(jobLogDirOverride(const {'FAH_JOB_LOG_DIR': '   '}), isNull);
    });
  });

  group('ShellJobRegistry jobLogDir', () {
    late Directory taskDir;
    late Directory outsideDir;

    setUp(() {
      taskDir = Directory.systemTemp.createTempSync('fa-1408-task-');
      outsideDir = Directory.systemTemp.createTempSync('fa-1408-logs-');
    });

    tearDown(() {
      taskDir.deleteSync(recursive: true);
      outsideDir.deleteSync(recursive: true);
    });

    test('a run leaves no .fah/ in the task dir after completion', () async {
      final registry = ShellJobRegistry(
        env: LocalExecutionEnv(cwd: taskDir.path),
        jobLogDir: outsideDir.path,
      );
      final entry = await registry.start('echo bench-run-artifact');
      await entry.settled;

      expect(Directory('${taskDir.path}/.fah').existsSync(), isFalse);
      expect(
        File('${outsideDir.path}/${entry.id}.log').readAsStringSync(),
        contains('bench-run-artifact'),
      );
    });

    test('the default keeps <cwd>/.fah/bash_jobs (non-bench compat)', () async {
      final registry = ShellJobRegistry(
        env: LocalExecutionEnv(cwd: taskDir.path),
      );
      final entry = await registry.start('echo compat');
      await entry.settled;

      expect(
        File('${taskDir.path}/.fah/bash_jobs/${entry.id}.log').existsSync(),
        isTrue,
      );
    });
  });
}
