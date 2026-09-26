// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:fa/sandbox/shell_job.dart';
import 'package:fa/sandbox/wasm_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasm_run/wasm_run.dart';

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

    test('failed exec results map to exit code and stop reason', () async {
      final aborted = SandboxShellJob(
        id: 'sh-3',
        command: 'x',
        logPath: '/nonexistent/x.log',
        logWriter: (_) {},
      );
      await aborted.completeWith(
        const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted')),
      );
      await aborted.settled;
      expect(aborted.exitCode, 143);
      expect(aborted.stopReason, 'cancelled');
      // First completion wins: a second completeWith is a no-op.
      await aborted.completeWith(
        const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0)),
      );
      expect(aborted.exitCode, 143);

      final timedOut = SandboxShellJob(
        id: 'sh-4',
        command: 'x',
        logPath: '/nonexistent/x.log',
        logWriter: (_) {},
      );
      await timedOut.completeWith(
        const Err(ExecutionError(ExecutionErrorCode.timeout, 'timeout')),
      );
      expect(timedOut.exitCode, 124);
      expect(timedOut.stopReason, 'timeout');

      final failed = SandboxShellJob(
        id: 'sh-5',
        command: 'x',
        logPath: '/nonexistent/x.log',
        logWriter: (_) {},
      );
      await failed.completeWith(
        const Err(
          ExecutionError(ExecutionErrorCode.spawnError, 'spawn failed'),
        ),
      );
      expect(failed.exitCode, 1);
      expect(failed.stopReason, isNull);
    });
  });

  // flutter_test runs on a host VM where dart:io is fully available, so the
  // WASI shell's guarded eager open (`_openJobLog`) is pinned by the same
  // host-VM regression as the local shell's.
  group('WasiSandboxShell job log open (issue #925)', () {
    test('an unwritable WASI job log fails cleanly (issue #925)', () async {
      final dir = Directory.systemTemp.createTempSync('wasi-925');
      addTearDown(() => dir.deleteSync(recursive: true));
      // The log path's parent is a regular file, so the open fails with
      // ENOTDIR — the same FileSystemException class as the ticket's ENOSPC.
      final blocker = File('${dir.path}/bash_jobs')
        ..writeAsStringSync('not a directory\n');
      WasiSandboxShell shell() => WasiSandboxShell(
        coreutils: _UnusedModule(),
        rg: _UnusedModule(),
        find: _UnusedModule(),
        sed: _UnusedModule(),
        awk: _UnusedModule(),
        tar: _UnusedModule(),
        gzip: _UnusedModule(),
        zip: _UnusedModule(),
      );
      Object? zoneError;
      await runZonedGuarded(
        () async {
          final started = await shell().startShellJob(
            'echo hi',
            id: 'wasi-925',
            logPath: '${blocker.path}/wasi-925.log',
          );
          expect(started.isErr, isTrue);
          expect(
            started.errorOrNull!.message,
            contains('cannot open job log file'),
          );
        },
        (Object error, StackTrace _) {
          // A failing expect() throws TestFailure inside the zone: surface
          // it through the normal test channel instead of the
          // 'unhandled zone error escaped' label.
          if (error is TestFailure) throw error;
          zoneError = error;
        },
      );
      // An escaping error still needs an event-loop turn to surface.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (zoneError != null) {
        fail('unhandled zone error escaped: $zoneError');
      }
    });
  });
}

/// Never used: startShellJob fails at the guarded log open before any
/// module is touched.
class _UnusedModule extends Fake implements WasmModule {}
