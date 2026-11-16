/// gh-2208 regression probe: `shutdownPty` must GUARANTEE the PTY child is
/// reaped before returning — SIGKILL escalation when the child ignores the
/// cooperative SIGTERM/SIGHUP, and a loud failure when even SIGKILL cannot
/// reap it.
///
/// Why this exists: pty2's blocking `_waitForExitCode` isolate cannot die
/// while the child lives (native `waitpid`, no safepoint), so a leaked
/// child wedges the Dart VM's exit handshake forever
/// (`Attempt:N waiting for isolate _waitForExitCode to check in`) — CI
/// run 43835937617 (v1.0.735) burned 39 idle minutes and blocked the
/// release publish; run 43151400571 (PR #2121) wedged the same way with
/// ALL tests green. Tracker: #2122. The old teardown semantics
/// (`pty.kill()` + `exitCode.timeout(5s, onTimeout: -1)` silent give-up,
/// or a fire-and-forget `pty.kill()` in tearDown) are exactly the leak
/// this pin forbids.
///
/// POSIX-only: the trap semantics and `kill -0` probe are shell-level.
@TestOn('vm')
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:pty2/pty2.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

/// Whether [pid] is alive (`kill -0` exit status 0). Portable across the
/// linux + macos PTY legs (no /proc dependency).
bool _pidAlive(int pid) =>
    Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

/// A child that traps BOTH cooperative signals — the shape that used to
/// leak through every old teardown path (a `dart run` dartdev teardown is
/// the real-world slow-death twin of this test double).
String _termProofScript(String pidFile) =>
    'echo \$\$ > $pidFile; trap "" TERM; trap "" HUP; while :; do sleep 0.1; done';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fa_gh2208_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test(
    'shutdownPty escalates to SIGKILL when the child ignores SIGTERM+HUP',
    () async {
      final pidFile = File('${tmp.path}/child.pid');
      final pty = PseudoTerminal.start('sh', [
        '-c',
        _termProofScript(pidFile.path),
      ], raw: true);
      try {
        // The child writes its own pid before arming the traps; poll the
        // file instead of sleeping (anchored-poll convention, #533/#550).
        final pid = int.parse(
          await pollUntil(
            matched: () => pidFile.existsSync(),
            onHit: () => pidFile.readAsStringSync().trim(),
            screenText: () => '',
            rawTail: () => '',
            what: 'the child pid file',
            timeout: const Duration(seconds: 10),
          ),
        );
        expect(_pidAlive(pid), isTrue, reason: 'test double must boot');

        // The contract: shutdownPty returns only once the child is REAPED
        // (the pty2 exitCode future completes on waitpid) — and it
        // escalates past the cooperative signals this double ignores.
        await shutdownPty(pty, budgetScale: 1.0);

        expect(
          _pidAlive(pid),
          isFalse,
          reason:
              'shutdownPty must SIGKILL-escalate past trapped SIGTERM/HUP — '
              'a surviving child wedges the VM exit handshake (gh-2208).',
        );
      } finally {
        // Belt-and-braces so a RED run cannot leak the double into the
        // next suite on this machine (the assertion above is the proof).
        Process.killPid(pty.pid, ProcessSignal.sigkill);
      }
    },
  );

  test('shutdownPty hard=true kills a trapping child immediately', () async {
    final pidFile = File('${tmp.path}/child_hard.pid');
    final pty = PseudoTerminal.start('sh', [
      '-c',
      _termProofScript(pidFile.path),
    ], raw: true);
    try {
      final pid = int.parse(
        await pollUntil(
          matched: () => pidFile.existsSync(),
          onHit: () => pidFile.readAsStringSync().trim(),
          screenText: () => '',
          rawTail: () => '',
          what: 'the child pid file (hard path)',
          timeout: const Duration(seconds: 10),
        ),
      );
      await shutdownPty(pty, hard: true, budgetScale: 1.0);
      expect(
        _pidAlive(pid),
        isFalse,
        reason: 'hard=true starts at SIGKILL — no cooperative grace.',
      );
    } finally {
      Process.killPid(pty.pid, ProcessSignal.sigkill);
    }
  });

  test('shutdownPty returns promptly when the child honors SIGTERM', () async {
    // No traps: the cooperative signal reaps the child instantly, so the
    // fast path must NOT pay the grace window (the escalation is for the
    // pathological path only).
    final pty = PseudoTerminal.start('sh', [
      '-c',
      'while :; do sleep 0.5; done',
    ], raw: true);
    final watch = Stopwatch()..start();
    await shutdownPty(pty, budgetScale: 1.0);
    watch.stop();
    expect(
      watch.elapsed,
      lessThan(ptyShutdownGrace),
      reason:
          'a SIGTERM-honoring child must be reaped on the fast path — '
          'paying the full grace would inflate every suite teardown.',
    );
  });

  test('close()/hardKill() release resources on the loud path too', () {
    // gh-2208 review thread: shutdownPty's terminal StateError (child
    // survived even SIGKILL — D-state) must not skip close()'s doc
    // contract (cancel the output subscription — an open stream keeps
    // the runner's event loop alive — and release the owned temp CWD +
    // transcript buffers). The loud path is not reproducible on POSIX
    // (SIGKILL cannot be trapped), so this pin guards the STRUCTURE:
    // shutdownPty inside try, all three releases inside finally.
    final src = File('test/integration/pty_harness.dart').readAsStringSync();
    const releases = [
      '_outputSub?.cancel()',
      '_releaseOwnedCwd()',
      '_releaseTranscript()',
    ];
    for (final signature in [
      'Future<void> close() async',
      'Future<void> hardKill() async',
    ]) {
      final body = _methodBody(src, signature);
      expect(body, contains('try {'), reason: '$signature wraps in try');
      expect(body, contains('} finally {'), reason: '$signature has finally');
      final tryPart = body.substring(0, body.indexOf('} finally {'));
      final finallyPart = body.substring(body.indexOf('} finally {'));
      expect(
        tryPart,
        contains('shutdownPty'),
        reason: '$signature: the kill must run inside try',
      );
      for (final release in releases) {
        expect(
          finallyPart,
          contains(release),
          reason:
              '$signature: `$release` must run in finally — a thrown '
              'StateError must not leak the harness resources',
        );
        expect(
          tryPart,
          isNot(contains(release)),
          reason: '$signature: `$release` belongs in finally only',
        );
      }
    }
  });
}

/// The balanced-brace body of the method whose signature is [signature].
String _methodBody(String src, String signature) {
  final start = src.indexOf(signature);
  if (start < 0) fail('signature not found in pty_harness.dart: $signature');
  final open = src.indexOf('{', start);
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  fail('unbalanced braces after $signature');
}
