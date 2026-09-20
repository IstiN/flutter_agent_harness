@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// Issue #735 E2E: a child re-enables tty IXON mid-session, so Ctrl+S
/// (0x13) is eaten by the line discipline as XOFF — output freezes until
/// any key (IXANY) and steering never reaches fa. The TermiosGuard must
/// re-assert the raw-mode input flags after every foreground tool phase,
/// keeping the Ctrl+S steer path alive.
///
/// Repro recipe (issue #735, deterministic):
/// 1. a bash tool call runs `stty ixon ixany < /dev/tty` — the exact
///    corruption a pager/ssh/curses child performs on the shared tty;
/// 2. a long second tool call holds the run open;
/// 3. a queued message + Ctrl+S must reach the agent (pending → delivered
///    → the model's STEERED-ACK), and the guard's drift note must name
///    the flags the child re-enabled.
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test(
    'Ctrl+S still steers after a child re-enables IXON mid-session '
    '(issue #735)',
    timeout: const Timeout(Duration(minutes: 4)),
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
      // Turn 1 corrupts the tty exactly like a real child would (a pager,
      // ssh, or a curses app restoring its own saved termios on exit).
      // Turn 2 holds the step open so the steer lands mid-run. Turn 3
      // proves the steered text reached the model.
      server.enqueueToolCall(
        'bash',
        '{"command": "stty ixon ixany < /dev/tty; sleep 1"}',
      );
      server.enqueueToolCall('bash', '{"command": "sleep 8"}');
      server.enqueueText('STEERED-ACK done');

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
      // The second tool call rendering proves the FIRST (corrupting) call
      // finished — i.e. the after-tool boundary where the guard must have
      // re-asserted the input flags already ran.
      await harness.waitForText(
        'sleep 8',
        timeout: const Duration(seconds: 60),
      );

      // Observability contract: the guard names the drift it cleared.
      await harness.waitForText(
        're-enabled by a child',
        timeout: const Duration(seconds: 30),
      );

      // The steer gesture itself: with IXON back on (pre-fix), this byte
      // is swallowed by the tty as XOFF — output freezes and the pending
      // panel never appears (any-key release = IXANY). Post-fix the guard
      // already re-cleared the flags, so 0x13 reaches fa (#647: accept
      // panel within seconds).
      harness.sendText('steer me please');
      final sw = Stopwatch()..start();
      harness.sendCtrlS();
      await harness.waitForText(
        'steering from you · pending',
        timeout: const Duration(seconds: 30),
      );
      // ignore: avoid_print
      print('STEER-ACCEPT-LATENCY ${sw.elapsedMilliseconds}ms');

      // Delivery at the step boundary (sleep 8 ends) + the model turn
      // proving the steered text was injected mid-run.
      await harness.waitForText(
        '[btw] steering from you → delivered',
        timeout: const Duration(seconds: 120),
      );
      await harness.waitForText(
        'STEERED-ACK',
        timeout: const Duration(seconds: 60),
      );

      await harness.runSlashCommand('/exit');
      await harness.close();
    },
  );
}
