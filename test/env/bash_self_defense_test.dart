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
  // The guard's shims and the setsid group dummies need POSIX tools; a
  // minimal container without procps provisions no shims (and no
  // `fa_sh_guard_` PATH entry), so the affected tests skip instead of
  // failing on hosts that never had pkill/pgrep to shadow.
  final bool hostHasPgrep =
      !Platform.isWindows &&
      Process.runSync('sh', <String>['-c', 'command -v pgrep']).exitCode == 0;
  final bool hostHasSetsid =
      !Platform.isWindows &&
      Process.runSync('sh', <String>['-c', 'command -v setsid']).exitCode == 0;

  /// Polls whether [pid] is still in the process table (~3s budget) so the
  /// assertions stay load-independent (signal delivery lags the killer).
  Future<bool> stillAlive(int pid, {Map<String, String>? env}) async {
    var alive = false;
    for (var i = 0; i < 30; i++) {
      final probe = await const LocalShell().exec(
        'if ps -o pid= -p $pid >/dev/null 2>&1; then echo alive; '
        'else echo dead; fi',
        options: env == null ? null : ShellExecOptions(env: env),
      );
      final out = probe.getOrThrow().stdout.trim();
      alive = out.contains('alive');
      if (!alive) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return alive;
  }

  final Object posixSkip = (Platform.isWindows || !hostHasPgrep)
      ? 'POSIX procps process semantics only'
      : false;

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
        // view) must be protected; the ancestor chain rides along when the
        // host process table is readable.
        expect(pids, contains('$pid'));
        final ps = Process.runSync('ps', <String>['-ax', '-o', 'pid=,ppid=']);
        if (ps.exitCode == 0) {
          expect(pids.length, greaterThan(1));
        }
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
          'pkill -f "sleep 1763"',
          options: ShellExecOptions(
            env: {'FA_PROTECTED_PIDS': '${protectedDummy.pid}'},
          ),
        );
        expect(result.getOrThrow().exitCode, 0);

        // Signal delivery lags the pkill return by a scheduler tick; poll
        // briefly so the assertions stay load-independent.
        var protectedAlive = false;
        var freeReaped = false;
        for (var i = 0; i < 30; i++) {
          final probe = await const LocalShell().exec(
            'if ps -o pid= -p ${protectedDummy.pid} >/dev/null 2>&1; then '
            'echo "protected_alive"; else echo "protected_dead"; fi; '
            'if ps -o pid= -p ${freeDummy.pid} >/dev/null 2>&1; then '
            'echo "free_alive"; else echo "free_reaped"; fi',
            options: ShellExecOptions(
              env: {'FA_PROTECTED_PIDS': '${protectedDummy.pid}'},
            ),
          );
          final out = probe.getOrThrow().stdout;
          protectedAlive = out.contains('protected_alive');
          freeReaped = out.contains('free_reaped');
          if (protectedAlive && freeReaped) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          protectedAlive,
          isTrue,
          reason: 'a pid on FA_PROTECTED_PIDS must never be signaled',
        );
        expect(
          freeReaped,
          isTrue,
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

  group('AC2b: review-rework kill/pkill shapes (gh-1763 threads)', () {
    test(
      'kill -- -PGID: a protected group target is never signaled',
      skip: Platform.isWindows || !hostHasSetsid
          ? 'POSIX setsid process semantics only'
          : false,
      () async {
        // A `setsid` dummy is its own process-group leader: its pid IS its
        // pgid, so `kill -TERM -<pid>` targets the whole group — the
        // spelling agents use to reap `setsid` background jobs
        // (`kill -- -$PID`).
        final dummy = await Process.start('setsid', <String>['sleep', '177']);
        addTearDown(dummy.kill);
        final env = {'FA_PROTECTED_PIDS': '${dummy.pid}'};
        final result = await const LocalShell().exec(
          'kill -TERM -${dummy.pid}; echo "rc=\$?"',
          options: ShellExecOptions(env: env),
        );
        final exec = result.getOrThrow();
        expect(exec.stdout.trim(), 'rc=0');
        expect(
          exec.stderr,
          contains('skipped protected'),
          reason: 'the guard must report the skipped protected group target',
        );
        final alive = await stillAlive(dummy.pid, env: env);
        expect(
          alive,
          isTrue,
          reason:
              'kill -TERM -<protected pgid> signaled the protected process '
              'group (pre-fix the -PGID branch kept/dropped the opposite '
              'of the positive-pid branch, so no arg set __fa_hit and the '
              'fast path passed the call through byte-identical)',
        );
      },
    );

    test(
      'kill -- -PGID: an unprotected group target is still reaped',
      skip: Platform.isWindows || !hostHasSetsid
          ? 'POSIX setsid process semantics only'
          : false,
      () async {
        final dummy = await Process.start('setsid', <String>['sleep', '177']);
        addTearDown(dummy.kill);
        const env = {'FA_PROTECTED_PIDS': '4242'};
        final result = await const LocalShell().exec(
          'kill -TERM -${dummy.pid}; echo "rc=\$?"',
          options: const ShellExecOptions(env: env),
        );
        expect(result.getOrThrow().stdout.trim(), 'rc=0');
        final alive = await stillAlive(dummy.pid, env: env);
        expect(
          alive,
          isFalse,
          reason:
              'an unprotected process-group kill was swallowed with rc=0 '
              'and a false "skipped protected pid(s)" message (pre-fix the '
              '-PGID branch marked the target as a hit without counting it '
              'toward __fa_pids_left, so the real kill never ran)',
        );
      },
    );

    test(
      'kill filters only the protected target from a mixed group kill',
      skip: Platform.isWindows || !hostHasSetsid
          ? 'POSIX setsid process semantics only'
          : false,
      () async {
        final grouped = await Process.start('setsid', <String>['sleep', '177']);
        addTearDown(grouped.kill);
        final free = await Process.start('sleep', const ['177']);
        addTearDown(free.kill);
        final env = {'FA_PROTECTED_PIDS': '${grouped.pid}'};
        final result = await const LocalShell().exec(
          'kill -9 -${grouped.pid} ${free.pid}; echo "rc=\$?"',
          options: ShellExecOptions(env: env),
        );
        expect(result.getOrThrow().stdout.trim(), 'rc=0');
        final groupAlive = await stillAlive(grouped.pid, env: env);
        final freeAlive = await stillAlive(free.pid, env: env);
        expect(
          groupAlive,
          isTrue,
          reason:
              'the protected group target must be filtered out of a '
              'mixed kill',
        );
        expect(
          freeAlive,
          isFalse,
          reason:
              'the unprotected pid in a mixed kill must still be signaled '
              'by the real kill',
        );
      },
    );

    test(
      'pkill -l defers to the real pkill (usage error) and signals nothing',
      skip: posixSkip,
      () async {
        final d1 = await Process.start('sleep', const ['177']);
        addTearDown(d1.kill);
        final d2 = await Process.start('sleep', const ['177']);
        addTearDown(d2.kill);
        final result = await const LocalShell().exec(
          'pkill -l -f "sleep 177"; echo "rc=\$?"',
        );
        final exec = result.getOrThrow();
        // Real pkill rejects -l (usage error, rc=2) and signals nothing.
        // Pre-fix the shim passed -l to pgrep, read the "pid name" rows as
        // a pid list and signaled EVERY match.
        expect(exec.stdout.trim(), 'rc=2');
        expect(
          await stillAlive(d1.pid),
          isTrue,
          reason: 'pkill -l is a usage error — it must not signal matches',
        );
        expect(
          await stillAlive(d2.pid),
          isTrue,
          reason: 'pkill -l is a usage error — it must not signal matches',
        );
      },
    );

    test(
      'pkill --count defers to the real pkill instead of reading the count '
      'as a pid',
      skip: posixSkip,
      () async {
        final d1 = await Process.start('sleep', const ['177']);
        addTearDown(d1.kill);
        final d2 = await Process.start('sleep', const ['177']);
        addTearDown(d2.kill);
        final result = await const LocalShell().exec(
          'pkill --count -f "sleep 177"; echo "rc=\$?"',
        );
        final exec = result.getOrThrow();
        // The real pkill decides: procps prints the bare match count.
        // Pre-fix `--count` rode into the pgrep selection, pgrep printed
        // the count and the shim read THAT number as a pid — signaling an
        // arbitrary unrelated process while the real matches stayed
        // un-signaled.
        final lines = exec.stdout.trim().split('\n');
        expect(
          lines,
          contains('2'),
          reason:
              'the real pkill --count prints the match count; the shim must '
              'not swallow that output as a pid list',
        );
        expect(lines.last, 'rc=0');
      },
    );

    test(
      'pkill -u <uid> split form runs the guarded path and honors the pid '
      'set',
      skip: posixSkip,
      () async {
        final protected = await Process.start('sleep', const ['177']);
        addTearDown(protected.kill);
        final free = await Process.start('sleep', const ['177']);
        addTearDown(free.kill);
        final env = {'FA_PROTECTED_PIDS': '${protected.pid}'};
        final result = await const LocalShell().exec(
          'pkill -u "\$(id -u)" -f "sleep 177"; echo "rc=\$?"',
          options: ShellExecOptions(env: env),
        );
        final exec = result.getOrThrow();
        expect(exec.stdout.trim(), 'rc=0');
        final protectedAlive = await stillAlive(protected.pid, env: env);
        final freeAlive = await stillAlive(free.pid, env: env);
        expect(
          protectedAlive,
          isTrue,
          reason:
              'split-form selection values fell through to the real, '
              'unshimed pkill — the original gh-1763 crash shape '
              '(pkill -u <uid> -f "dart ")',
        );
        expect(
          freeAlive,
          isFalse,
          reason:
              'the guarded path must still reap legitimate victims after '
              'consuming the split-form selection value',
        );
      },
    );
  });

  group('AC2d: review-rework-2 --signal + terminator shapes (gh-1763)', () {
    test(
      'pkill --signal=KILL -f reaps its victim (dash-less signal names '
      'normalized)',
      skip: posixSkip,
      () async {
        final victim = await Process.start('sleep', const ['271']);
        addTearDown(victim.kill);
        final result = await const LocalShell().exec(
          'pkill --signal=KILL -f "sleep 271"; echo "rc=\$?"',
        );
        expect(
          result.getOrThrow().stdout.trim(),
          'rc=0',
          reason: 'the real pkill reaps with rc=0; the shim must match',
        );
        final alive = await stillAlive(victim.pid);
        expect(
          alive,
          isFalse,
          reason:
              'the --signal arms stored the name WITHOUT the leading dash, '
              'so the victim loop ran `kill KILL <pid>` (dash: "Illegal '
              'number: KILL") — nothing was signaled and the caller got '
              'rc=1 ("no processes matched"): the E2 regression for this '
              'spelling',
        );
      },
    );

    test(
      'pkill --signal TERM (split form) reaps its victim',
      skip: posixSkip,
      () async {
        final victim = await Process.start('sleep', const ['271']);
        addTearDown(victim.kill);
        final result = await const LocalShell().exec(
          'pkill --signal TERM -f "sleep 271"; echo "rc=\$?"',
        );
        expect(result.getOrThrow().stdout.trim(), 'rc=0');
        expect(
          await stillAlive(victim.pid),
          isFalse,
          reason: 'the dash-less signal name must be normalized to -TERM',
        );
      },
    );

    test(
      'killall --signal TERM reaps its victim (unique comm name)',
      skip: Platform.isWindows || !hostHasPgrep
          ? 'POSIX procps process semantics only'
          : false,
      () async {
        // killall matches the comm name (15-char cap on Linux): give the
        // victim a unique name by copying the sleep binary.
        final binDir = Directory.systemTemp.createTempSync('fa-killall-');
        addTearDown(() => binDir.deleteSync(recursive: true));
        final sleepBin = Process.runSync(
          'sh',
          <String>['-c', 'command -v sleep'],
        ).stdout.trim();
        final victimPath = '${binDir.path}/fa_kl_271';
        File(sleepBin).copySync(victimPath);
        Process.runSync('chmod', <String>['755', victimPath]);
        final victim = await Process.start(victimPath, const ['271']);
        addTearDown(victim.kill);
        final result = await const LocalShell().exec(
          'killall --signal TERM fa_kl_271; echo "rc=\$?"',
        );
        expect(result.getOrThrow().stdout.trim(), 'rc=0');
        expect(
          await stillAlive(victim.pid),
          isFalse,
          reason:
              'the killall shim shares the pkill victim loop — the dash-less '
              'signal name must be normalized or the reap silently no-ops',
        );
      },
    );

    test(
      'pkill --signal / killall --signal (dangling, last arg) terminate '
      'under bash-as-sh instead of looping forever',
      skip: Platform.isWindows || !hostHasPgrep
          ? 'POSIX procps process semantics only'
          : false,
      () async {
        final provision = await provisionBashGuard();
        expect(provision?.shimDir, isNotNull);
        // bash-as-sh (macOS /bin/sh) never escapes the unguarded
        // `shift 2` with $# = 1 — the arm repeats forever (rc=124 under
        // timeout). dash exits 2; the fixed shape execs the real binary
        // for the honest usage error (rc=2) on every shell.
        for (final tool in <String>['pkill', 'killall']) {
          final r = await Process.run('timeout', <String>[
            '10',
            'bash',
            '${provision!.shimDir}/$tool',
            '--signal',
          ]);
          expect(
            r.exitCode,
            isNot(124),
            reason: '$tool --signal hung: the dangling --signal arm '
                'repeats `shift 2` forever under bash-as-sh',
          );
          // The honest outcome: whatever the real binary does with a
          // dangling --signal (pkill usage-errors rc=2, killall rc=1).
          final real = await Process.run('timeout', <String>[
            '10',
            tool,
            '--signal',
          ]);
          expect(
            r.exitCode,
            real.exitCode,
            reason: '$tool --signal (dangling) must exit like the real '
                'binary',
          );
        }
      },
    );

    test(
      'pkill -- -<dash-leading pattern> matches the real exit code '
      '(terminator re-emitted on the pgrep-reject fallback)',
      skip: posixSkip,
      () async {
        final result = await const LocalShell().exec(
          'pkill -- -zz_nope_1763; echo "rc=\$?"',
        );
        // Real pkill treats the operand after `--` as a pattern → no
        // match → rc=1. Pre-fix the shim consumed the terminator, pgrep
        // rejected the option-looking pattern (rc=2) and the fallback
        // execed the real pkill WITHOUT `--` → usage error rc=2.
        expect(result.getOrThrow().stdout.trim(), 'rc=1');
      },
    );
  });

  group('AC2c: guard provisioning hardening (gh-1763 review)', () {
    test(
      'a failing chmod degrades to a shimless provision instead of '
      'bricking pkill',
      skip: Platform.isWindows ? 'the guard is POSIX-only' : false,
      () async {
        // `false` exits 1: the shim file stays non-executable. The shim
        // must be dropped (degrade-to-null pathway) — handing the child a
        // non-executable `pkill` would turn every later pkill/killall
        // call into "Permission denied" instead of degrading to the real
        // binary. The pid set stays armed for the `kill()` prelude.
        final provision = await provisionBashGuard(chmodCommand: 'false');
        expect(
          provision,
          isNotNull,
          reason: 'the pid set must stay armed for the kill() prelude',
        );
        expect(provision!.protectedPids, contains(pid));
        expect(
          provision.shimDir,
          isNull,
          reason:
              'a shim the child cannot exec is worse than no shim — it '
              'must be dropped from the provision',
        );
      },
    );

    test(
      'a successful chmod keeps the shim dir provisioned',
      skip: Platform.isWindows || !hostHasPgrep
          ? 'the shims need procps (pgrep) on the host'
          : false,
      () async {
        final provision = await provisionBashGuard();
        expect(provision, isNotNull);
        expect(provision!.shimDir, isNotNull);
        expect(provision.protectedPids, contains(pid));
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
