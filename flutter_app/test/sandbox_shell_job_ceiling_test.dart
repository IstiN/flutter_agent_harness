// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/sandbox/memory_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Issue #919 (IT-1): the sandbox job path bounds runaway background-job
  // logs through the shared ceiling policy, driven end to end through
  // MemoryShell (the web host; WasiSandboxShell shares SandboxShellJob).
  group('SandboxShellJob log ceiling (issue #919)', () {
    Future<ShellJob> startJob(
      MemoryExecutionEnv env,
      String command, {
      required String id,
      ShellExecOptions? options,
    }) async {
      final started = await env.startShellJob(
        command,
        id: id,
        logPath: '/.fah/bash_jobs/$id.log',
        options: options,
      );
      expect(started.isOk, isTrue, reason: '${started.errorOrNull}');
      return started.valueOrNull!;
    }

    test(
      'a runaway job log is bounded, marked once, and keeps a live tail',
      () async {
        final shell = MemoryShell();
        final env = MemoryExecutionEnv(cwd: '/', shell: shell);
        shell.attach(env);
        await env.createDir('/.fah/bash_jobs');

        const maxBytes = 8192;
        const total = 9000; // under the interpreter's runaway guard
        final words = List.generate(total, (i) => 'w$i').join(' ');
        final job = await startJob(
          env,
          'for w in $words; do echo pad-\$w; done',
          id: 'ceiling-runaway',
          options: const ShellExecOptions(jobLogMaxBytes: maxBytes),
        );
        await job.settled;
        expect(job.exitCode, 0);

        final log = (await env.readTextFile(job.logPath)).valueOrNull!;
        // Bounded: head + marker + rolling tail stays far below the produced
        // ~90 KB and under the ceiling plus one patch's worth of slack.
        expect(
          utf8.encode(log).length,
          lessThan(maxBytes + jobLogTruncationMarker(1).length * 2),
        );
        // Exactly one truncation marker line (patches overwrite it in place).
        final markers = RegExp(
          '… log truncated: (\\d+) bytes dropped …',
        ).allMatches(log).toList();
        expect(markers, hasLength(1));
        // The tail is live: the job's LAST emitted line survived (E4).
        expect(log, contains('pad-w${total - 1}'));
      },
    );

    test('a job under the ceiling produces byte-identical logs', () async {
      final shell = MemoryShell();
      final env = MemoryExecutionEnv(cwd: '/', shell: shell);
      shell.attach(env);
      await env.createDir('/.fah/bash_jobs');

      final job = await startJob(
        env,
        'for i in a b c; do echo \$i; done',
        id: 'ceiling-under',
      );
      await job.settled;
      expect(job.exitCode, 0);

      // Regression pin: below the ceiling the sandbox path must append
      // exactly what the script produced — no marker, no rewriting.
      final log = (await env.readTextFile(job.logPath)).valueOrNull!;
      expect(log, 'a\nb\nc\n');
    });
  });
}
