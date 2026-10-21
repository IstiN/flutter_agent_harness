// gh-1763: bash tool self-signal immunity.
//
// A `bash` tool command running a broad process kill (`pkill -f`,
// `killall`, `kill`) used to match its own `setsid sh -c '<command>'`
// wrapper (the raw script rode the wrapper argv) and could signal the
// harness/ancestor chain. These tests pin the mechanical self-defense:
//
// - AC1: `pkill -f <unique>` inside a bash call cannot kill its own shell
//   (the wrapper argv never carries the script body).
// - AC2: harness/ancestor pids are exported and honored — a protected pid
//   is skipped by `pkill`/`killall`/`kill` while an unprotected process
//   matching the same pattern is still reaped.
// - E3: `$0`, `$#`/`"$@"`, exit codes and `set -e` behave exactly like the
//   old `sh -c` delivery.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fa-self-defense-');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('AC1: pkill/pgrep self-match immunity (gh-1763)', () {
    test(
      'pkill -f does not kill its own bash tool shell (foreground)',
      skip: Platform.isWindows ? 'POSIX process semantics only' : false,
      () async {
        final result = await const LocalShell().exec(
          'pkill -f fa_self_match_tok_1763; echo survived',
        );
        final exec = result.getOrThrow();
        // Pre-fix the wrapper `sh -c 'pkill -f …'` matched its own cmdline
        // and died by SIGTERM (exit -15) before `echo survived` ran.
        expect(
          exec.exitCode,
          0,
          reason:
              'the shell wrapper was signaled by its own pkill '
              '(exit $exec); the script body must never ride the wrapper '
              'argv',
        );
        expect(exec.stdout, contains('survived'));
      },
    );

    test(
      'pgrep -f does not list its own bash tool shell',
      skip: Platform.isWindows ? 'POSIX process semantics only' : false,
      () async {
        final result = await const LocalShell().exec(
          'pgrep -f fa_self_match_tok_1763 >/dev/null; echo "matched=\$?"',
        );
        final exec = result.getOrThrow();
        expect(exec.exitCode, 0);
        // Pre-fix the wrapper's own cmdline matched the pattern (matched=0).
        expect(exec.stdout.trim(), 'matched=1');
      },
    );

    test(
      'pkill -f does not kill its own bash tool shell (background job)',
      skip: Platform.isWindows ? 'POSIX process semantics only' : false,
      () async {
        final shell = const LocalShell();
        final jobResult = await shell.startShellJob(
          'pkill -f fa_self_match_tok_1763; echo survived',
          id: 'sh-1763-a',
          logPath: '${tempDir.path}/sh-1763-a.log',
        );
        final job = jobResult.getOrThrow();
        await job.settled;
        // Pre-fix the job's own wrapper died by SIGTERM (exit -15).
        expect(job.exitCode, 0, reason: 'background job shell self-killed');
        expect(File(job.logPath).readAsStringSync(), contains('survived'));
      },
    );

    test(
      'pkill -f through the bash tool survives end to end',
      skip: Platform.isWindows ? 'POSIX process semantics only' : false,
      () async {
        final env = LocalExecutionEnv(cwd: tempDir.path);
        final jobs = ShellJobRegistry(env: env);
        final tool = shellTool(env, jobs: jobs);
        final result = await tool.execute(
          {'command': 'pkill -f fa_self_match_tok_1763; echo survived'},
          null,
          null,
        );
        final text = result.content
            .whereType<TextContent>()
            .map((c) => c.text)
            .join('\n');
        expect(text, contains('survived'));
        expect(text, isNot(contains('-15')));
      },
    );
  });

  group('AC2: harness/ancestor pid immunity (gh-1763)', () {
    test(
      'the harness pid chain is exported to bash tool calls',
      skip: Platform.isWindows ? 'POSIX process semantics only' : false,
      () async {
        final result = await const LocalShell().exec(
          r'echo "$FA_PROTECTED_PIDS"',
        );
        final pids = result.getOrThrow().stdout.trim().split(RegExp(r'\s+'));
        // The current process (the "harness" from the shell's point of
        // view) and at least one ancestor must be protected.
        expect(pids, contains('$pid'));
        expect(pids.length, greaterThan(1));
      },
    );

    test(
      'pkill skips a pid on FA_PROTECTED_PIDS and still reaps the rest',
      skip: Platform.isWindows ? 'POSIX process semantics only' : false,
      () async {
        // Two dummy processes whose cmdlines match the pattern. The dummy
        // IS the matching process (no `sh -c` wrapper — a wrapper would
        // exit on its own the moment its only child is signaled).
        final protectedDummy = await Process.start('sleep', ['1763']);
        addTearDown(protectedDummy.kill);
        final freeDummy = await Process.start('sleep', ['1763']);
        addTearDown(freeDummy.kill);

        final result = await const LocalShell().exec(
          'pkill -f "sleep 1763"; '
          'if ps -o pid= -p ${protectedDummy.pid} >/dev/null 2>&1; then '
          'echo "protected_alive"; else echo "protected_dead"; fi; '
          'if ps -o pid= -p ${freeDummy.pid} >/dev/null 2>&1; then '
          'echo "free_alive"; else echo "free_reaped"; fi',
          options: ShellExecOptions(
            env: {'FA_PROTECTED_PIDS': '${protectedDummy.pid}'},
          ),
        );
        final stdout = result.getOrThrow().stdout;
        expect(
          stdout,
          contains('protected_alive'),
          reason: 'a pid on FA_PROTECTED_PIDS must never be signaled',
        );
        expect(
          stdout,
          contains('free_reaped'),
          reason:
              'an unprotected process matching the pattern must still '
              'be terminated (edge case E2)',
        );
      },
    );

    test(
      'kill filters a pid on FA_PROTECTED_PIDS',
      skip: Platform.isWindows ? 'POSIX process semantics only' : false,
      () async {
        final result = await const LocalShell().exec(
          'kill -9 424242; echo "rc=\$?"',
          options: const ShellExecOptions(env: {'FA_PROTECTED_PIDS': '424242'}),
        );
        final exec = result.getOrThrow();
        // Pre-fix `kill -9 424242` fails (rc=1, no such process); the guard
        // suppresses the signal entirely so the call reads as success.
        expect(exec.exitCode, 0);
        expect(exec.stdout.trim(), 'rc=0');
      },
    );

    test(
      'kill without a protected hit is passed through unchanged',
      skip: Platform.isWindows ? 'POSIX process semantics only' : false,
      () async {
        final result = await const LocalShell().exec(
          'kill -0 999999 2>/dev/null; echo "rc=\$?"',
          options: const ShellExecOptions(env: {'FA_PROTECTED_PIDS': '424242'}),
        );
        // 999999 is not protected: the real kill semantics apply (rc=1).
        expect(result.getOrThrow().stdout.trim(), 'rc=1');
      },
    );
  });

  group('E3: sh -c delivery parity (gh-1763)', () {
    test('dollar-zero, arg count and args match sh -c', () async {
      final result = await const LocalShell().exec(r'echo "$0|$#|$@"');
      expect(result.getOrThrow().stdout.trim(), 'sh|0|');
    });

    test('exit codes propagate', () async {
      final result = await const LocalShell().exec('exit 7');
      expect(result.getOrThrow().exitCode, 7);
    });

    test('set -e aborts on failure', () async {
      final result = await const LocalShell().exec(
        'set -e\nfalse\necho unreachable',
      );
      final exec = result.getOrThrow();
      expect(exec.exitCode, 1);
      expect(exec.stdout, isNot(contains('unreachable')));
    });

    test('multi-line scripts and heredocs work', () async {
      final result = await const LocalShell().exec(
        "cat <<'EOF'\nhello-1763\nEOF",
      );
      expect(result.getOrThrow().stdout, contains('hello-1763'));
    });

    test('cwd is honored', () async {
      final result = await const LocalShell().exec(
        'pwd',
        options: ShellExecOptions(cwd: tempDir.path),
      );
      expect(result.getOrThrow().stdout.trim(), tempDir.path);
    });
  });
}
