// Issue #562 (RED first): the all-time job board's Running count grew
// forever — every inline-settled foreground bash left its card stuck in
// `running` because `suppressSettleNotification()` gated the registry's
// whole `onSettled`, and that callback is the ONLY driver of the board's
// terminal transition.
//
// Contract proven here over the REAL headless TUI with a scripted LLM
// (MockLlmServer, no network): a turn of >3 instant foreground bash jobs
// (every one settles inline and consumes its own result — the owner's
// exact "green rows but the counter never drains" shape) must drain the
// board: the settled collapsed turn prints ONE terminal summary card with
// `0 running`, and no live `N running` (N > 0) segment ever remains.
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

/// Any live `N running` board segment with N > 0 — forbidden once every
/// job of the turn has settled.
final _stuckRunning = RegExp(r'[1-9]\d* running');

void main() {
  test(
    'inline-settled bash jobs drain the board to 0 running (#562)',
    () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_tui_562_');
      final workspace = Directory.systemTemp.createTempSync('fa562ws_');
      addTearDown(() => workspace.deleteSync(recursive: true));
      final server = await MockLlmServer.start()
        // Turn 1: four instant foreground bash jobs — a collapsed board turn
        // (>3 jobs); each settles inline and consumes its own result.
        ..enqueueToolCall('bash', '{"command": "true"}')
        ..enqueueToolCall('bash', '{"command": "true"}')
        ..enqueueToolCall('bash', '{"command": "true"}')
        ..enqueueToolCall('bash', '{"command": "true"}')
        ..enqueueText('seeds done');
      addTearDown(server.stop);
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
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });

      await harness.waitForBoot();

      harness.sendText('seed the job board');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      harness.sendEnter();
      await harness.waitForText(
        'seeds done',
        timeout: const Duration(seconds: 40),
      );

      // THE CONTRACT: the turn's jobs all settled — the board must drain.
      // Post-fix the collapsed settled turn emits the terminal summary card
      // whose running segment reads `0 running`; pre-fix every card stayed
      // `running` forever and this never appeared.
      await harness.waitForScreen(
        '0 running',
        timeout: const Duration(seconds: 15),
      );

      // Baseline restored: let the frame settle (≤200ms window), then the
      // screen must hold no live running count at all.
      await harness.waitForOutput(
        settleMs: 200,
        timeout: const Duration(seconds: 10),
      );
      final screen = harness.viewportLines.join('\n');
      expect(
        screen,
        isNot(contains(_stuckRunning)),
        reason:
            'no live job remains — the Running count must return to '
            'zero after the jobs settle:\n$screen',
      );
    },
  );
}
