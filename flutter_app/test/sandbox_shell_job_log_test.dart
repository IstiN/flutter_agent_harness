// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/sandbox/shell_job.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Issue #925: a broken job log must never kill the host or hang the
  // job — the settle invariant belongs to completeWith itself.
  group('SandboxShellJob broken log (issue #925)', () {
    test('write and close failures never break settle', () async {
      final job = SandboxShellJob(
        id: 'sh-1',
        command: 'x',
        logPath: '/nonexistent/x.log',
        logWriter: (chunk) => throw StateError('writer broken'),
        closeLog: () async => throw StateError('close broken'),
      );
      job.writeLog('a');
      job.writeLog('b');
      await job.completeWith(
        const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0)),
      );
      await job.settled;
      expect(job.isRunning, isFalse);
      expect(job.exitCode, 0);
    });

    test('a broken log stops receiving writes', () async {
      var calls = 0;
      final job = SandboxShellJob(
        id: 'sh-2',
        command: 'x',
        logPath: '/nonexistent/x.log',
        logWriter: (chunk) async {
          calls++;
          throw StateError('disk full');
        },
      );
      job.writeLog('a');
      await job.completeWith(
        const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0)),
      );
      await job.settled;
      expect(job.exitCode, 0);
      expect(calls, 1);
      job.writeLog('c');
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1, reason: 'broken log stops receiving writes');
    });
  });
}
