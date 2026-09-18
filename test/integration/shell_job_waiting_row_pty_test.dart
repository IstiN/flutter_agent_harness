// Issue #615 (RED first): the `⏳ waiting` row never cleared after its
// background job settled — the waiting coordinator swallowed the empty
// push (`snap.isEmpty && lostJobs == 0 → return`), which is exactly the
// row's leave event. The last waiter's settle left the row painted above
// the composer forever, permanently reserving its bottom-zone slot while
// the job board honestly said `0 running`.
//
// Contract proven here over the REAL headless TUI with a scripted LLM
// (MockLlmServer, no network) and real background shell jobs, mirroring
// the #562 PTY precedent for the same settle-wiring bug family: a job
// starts → the idle frame shows the waiting row → the job settles and its
// notice turn answers → the very next idle screen must have NO waiting
// row, and with two waiters the row must follow the outstanding one and
// die with the last.
//
// Waits are anchored polling only (#533/#550/#557 deflake precedent) —
// no fixed sleeps beyond the 200ms output-settle window.
@TestOn('vm')
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

/// Boots the CLI against [server] in a fresh temp workspace and waits for
/// the TUI to come up.
Future<(FaCliHarness, Directory)> _boot(MockLlmServer server) async {
  final tempHome = Directory.systemTemp.createTempSync('fa_tui_615_');
  final workspace = Directory.systemTemp.createTempSync('fa615ws_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: mock-model
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
allowedTools: []
''');
  final harness = await FaCliHarness.spawn(
    workingDirectory: workspace.path,
    extraEnv: {'HOME': tempHome.path},
    columns: 80,
    rows: 24,
  );
  await harness.waitForBoot();
  return (harness, tempHome);
}

/// Lets the last frame settle (the ≤200ms repaint window), then returns
/// the painted viewport as one string.
Future<String> _settledScreen(FaCliHarness harness) async {
  await harness.waitForOutput(settleMs: 200, timeout: const Duration(seconds: 10));
  return harness.viewportLines.join('\n');
}

void main() {
  test(
    'a settled background job drops the waiting row from the next idle '
    'screen (#615)',
    () async {
      final server = await MockLlmServer.start()
        // Turn 1: one background job; the tool result returns and the turn
        // answers, leaving the agent idle with the job still running.
        ..enqueueToolCall('bash', '{"command": "sleep 2", "background": true}')
        ..enqueueText('noted')
        // Turn 2: the settle notice re-enters as a fresh turn.
        ..enqueueText('all quiet now');
      addTearDown(server.stop);

      final (harness, tempHome) = await _boot(server);
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });

      harness.sendText('go');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      harness.sendEnter();

      // Baseline: once idle with the job running, the row is on screen.
      await harness.waitForScreen(
        '⏳ waiting',
        timeout: const Duration(seconds: 20),
      );

      // The job settles (sleep 2) and the notice turn answers. THE
      // CONTRACT: the next idle screen is rowless — the composer regains
      // its full height. Pre-fix the swallowed empty push left the stale
      // row painted above the composer forever.
      await harness.waitForText(
        'all quiet now',
        timeout: const Duration(seconds: 20),
      );
      final screen = await _settledScreen(harness);
      expect(
        screen,
        isNot(contains('⏳ waiting')),
        reason:
            'the job settled and the board says 0 running — the waiting '
            'row must be gone from the idle screen:\n$screen',
      );
      // Sanity: the screen is live and idle, not frozen mid-turn.
      expect(screen, contains('>_Fa'));
    },
  );

  test(
    'the waiting row follows the outstanding waiter and dies with the '
    'last one (#615 AC3)',
    () async {
      final server = await MockLlmServer.start()
        ..enqueueToolCall('bash', '{"command": "sleep 2", "background": true}')
        ..enqueueToolCall('bash', '{"command": "sleep 4", "background": true}')
        ..enqueueText('noted')
        ..enqueueText('first gone')
        ..enqueueText('second gone');
      addTearDown(server.stop);

      final (harness, tempHome) = await _boot(server);
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });

      harness.sendText('go');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      harness.sendEnter();

      // Both waiters show in the headline.
      await harness.waitForScreen(
        '2 jobs',
        timeout: const Duration(seconds: 20),
      );

      // First settle: the row re-points at the remaining waiter.
      await harness.waitForText(
        'first gone',
        timeout: const Duration(seconds: 20),
      );
      var screen = await _settledScreen(harness);
      expect(screen, contains('⏳ waiting · sleep 4'),
          reason: 'the row follows the outstanding waiter:\n$screen');
      expect(
        screen,
        isNot(contains('⏳ waiting · sleep 2')),
        reason: 'the settled waiter leaves the row:\n$screen',
      );

      // Last settle: the row dies with it.
      await harness.waitForText(
        'second gone',
        timeout: const Duration(seconds: 20),
      );
      screen = await _settledScreen(harness);
      expect(
        screen,
        isNot(contains('⏳ waiting')),
        reason: 'the row dies with the last waiter:\n$screen',
      );
    },
  );
}
