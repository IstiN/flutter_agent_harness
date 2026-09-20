@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// Issue #735 E2E: a child re-enables tty IXON mid-session, so Ctrl+S
/// (0x13) is eaten by the line discipline as XOFF — output freezes until
/// any key (IXANY) and steering never reaches fa. The TermiosGuard must
/// re-assert the raw-mode input flags after every foreground tool phase,
/// keeping the Ctrl+S steer path alive.
///
/// Deterministic recipe (CI-stable redesign after the first leg flaked —
/// the bash tool yields slow commands to background, so probe timing
/// must never race a still-running child):
/// 1. a FAST bash tool call corrupts the tty and echoes its own success
///    (`CORRUPT-OK`) — it completes inside the foreground grace, so the
///    after-tool boundary (the guard's probe) is strictly AFTER the
///    corruption; the echo doubles as a fail-fast diagnostic if the CI
///    job spawns without a controlling terminal;
/// 2. the drift note names the flags the guard cleared;
/// 3. after the turn settles, a typed message + Ctrl+S (0x13) steers as
///    an idle wake turn — proving the byte reached fa post-corruption
///    (pre-fix it freezes output instead) and was interpreted as
///    steering, not a plain submit.
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test(
    'Ctrl+S still steers after a child re-enables IXON mid-session '
    '(issue #735)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_xoff_pty_');
      final projectDir = '${tempHome.path}/project';
      Directory(projectDir).createSync(recursive: true);
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
provider: openai-completions
model: mock-model
mode: code
approvalMode: yolo
allowedTools: []
''');
      addTearDown(() => tempHome.deleteSync(recursive: true));

      final server = await MockLlmServer.start();
      addTearDown(server.stop);
      // Turn 1: corrupt the tty exactly like a real child would (a pager,
      // ssh, or a curses app restoring its saved termios on exit). The
      // command is FAST — it completes before the tool's yield grace, so
      // the guard's after-tool probe lands strictly after it. The echo is
      // the corruption's own receipt (and the diagnostic if the CI shell
      // runs without a controlling terminal). Turn 2 settles the run.
      // Turn 3 answers the idle-steer wake.
      server.enqueueToolCall(
        'bash',
        '{"command": "stty ixon ixany < /dev/tty && echo CORRUPT-OK '
            '|| echo CORRUPT-FAIL"}',
      );
      server.enqueueText('TURN-SETTLED');
      server.enqueueText('IDLE-STEER-ACK');

      final harness = await FaCliHarness.spawn(
        workingDirectory: projectDir,
        extraEnv: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'mock'},
        args: [
          '--provider',
          'openai-completions',
          '--base-url',
          server.baseUrl,
          '--model',
          'mock-model',
          '--session',
          'xoff-pty',
        ],
      );
      addTearDown(harness.close);
      await harness.waitForBoot(timeout: const Duration(seconds: 300));

      await harness.runSlashCommand('run the tool please');
      // The corruption's own receipt — and a fail-fast diagnostic: if the
      // CI job runs without a controlling terminal, CORRUPT-FAIL names
      // the environment gap instead of leaving a mystery timeout.
      await harness.waitForText(
        'CORRUPT-OK',
        timeout: const Duration(seconds: 60),
      );
      expect(
        harness.rawOutput.contains('CORRUPT-FAIL'),
        isFalse,
        reason: 'the corrupting child could not open /dev/tty — the CI '
            'shell job spawns without a controlling terminal',
      );

      // Observability contract: the guard names the drift it cleared
      // (the probe ran at the after-tool boundary, strictly after the
      // child finished corrupting).
      await harness.waitForText(
        're-enabled by a child',
        timeout: const Duration(seconds: 30),
      );

      // Let the turn settle — the idle-steer wake below starts a fresh
      // turn (deterministic: no mid-run race against the yield grace).
      await harness.waitForText(
        'TURN-SETTLED',
        timeout: const Duration(seconds: 60),
      );

      // The steer gesture itself: with IXON back on (pre-fix), this byte
      // is swallowed by the tty as XOFF — output freezes and nothing
      // reaches fa. Post-fix the guard already re-cleared the flags, so
      // 0x13 arrives, is interpreted as STEERING (not a plain submit),
      // and the idle wake turn answers.
      harness.sendText('steer me please');
      final sw = Stopwatch()..start();
      harness.sendCtrlS();
      await harness.waitForText(
        'IDLE-STEER-ACK',
        timeout: const Duration(seconds: 60),
      );
      // ignore: avoid_print
      print('STEER-ROUNDTRIP ${sw.elapsedMilliseconds}ms');

      await harness.runSlashCommand('/exit');
      await harness.close();
    },
  );
}
