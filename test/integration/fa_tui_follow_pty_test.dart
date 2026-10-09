// gh-1439 IT layer: the live-follow etiquette on the REAL glass — a PTY
// proves what the model-level suite (test/cli/fa_tui_follow_mode_test.dart)
// can only simulate. AC1's etiquette in one scenario:
//   (1) scrolling up mid-run detaches (the live-fold hint leaves the glass,
//       the held rule carries the position percent);
//   (2) late arrivals are COUNTED on the held rule (`· ● N new · End = live`);
//   (3) End returns to the live edge and the hint row leaves the glass.
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test(
    'PTY: scroll-up mid-run holds the fold, arrivals count, End returns live',
    () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_tui_1439_');
      final workspace = Directory('/tmp').createTempSync('fa1439ws');
      addTearDown(() => workspace.deleteSync(recursive: true));
      final server = await MockLlmServer.start()
        // Turn 1 seeds a transcript taller than the viewport (24 rows ->
        // ~19-row history window), so scrolling up has somewhere to go.
        ..enqueueText([
          for (var i = 1; i <= 30; i++) 'seed line $i',
        ].join('\n'))
        // Turn 2 keeps the agent BUSY while the user scrolls: three text
        // chunks spaced by 2s tool sleeps so each lands AFTER the detach
        // (the counted arrivals), then a sleep holds the run open for the
        // End press, then it settles.
        ..enqueueText('chunk one')
        ..enqueueToolCall('bash', '{"command": "sleep 2"}')
        ..enqueueText('chunk two')
        ..enqueueToolCall('bash', '{"command": "sleep 2"}')
        ..enqueueText('chunk three')
        ..enqueueToolCall('bash', '{"command": "sleep 8"}')
        ..enqueueText('turn two done');
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
tui:
  classic: true
''');

      final harness = await FaCliHarness.spawn(
        workingDirectory: workspace.path,
        extraEnv: {'HOME': tempHome.path},
        columns: 100,
        rows: 24,
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
      });

      await harness.waitForBoot();

      // Seed turn fills the transcript past the viewport height.
      harness.sendText('seed the transcript');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      harness.sendEnter();
      await harness.waitForText('seed line 30');
      // Let turn 1 fully settle so turn 2 goes through the busy path.
      await Future<void>.delayed(const Duration(milliseconds: 2000));

      // Probe submit starts the busy run.
      harness.sendText('stream while I scroll');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      harness.sendEnter();
      await harness.waitForText('· submit', timeout: const Duration(seconds: 20));

      // (1) Detach mid-run: PageUp parks the view above the live edge.
      // The held rule carries the position percent; the live-fold hint
      // (`… above fold - PgUp`) belongs to the FOLLOWING state and must
      // leave the glass once detached.
      harness.sendText('\x1b[5~'); // pgup

      // (2) Late arrivals count up on the held rule while live content
      // flows in BELOW the fold (`NN% · ● N new · End = live`).
      final counted = await harness.waitForScreen(
        RegExp(r'\d+% · ● 1 new'),
        timeout: const Duration(seconds: 20),
      );
      expect(counted, isNot(contains('above fold')),
          reason: 'detached: the live-fold hint belongs to following only');
      expect(counted, contains('End = live'),
          reason: 'the chip carries the one-action re-engage hint');
      await harness.waitForScreen(
        RegExp(r'\d+% · ● 2 new'),
        timeout: const Duration(seconds: 20),
      );
      await harness.waitForScreen(
        RegExp(r'\d+% · ● 3 new'),
        timeout: const Duration(seconds: 20),
      );

      // (3) End re-engages: the hint row leaves the glass and the newest
      // content is at the live edge.
      harness.sendText('\x1b[F'); // end
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final live = harness.screenText;
      expect(live, isNot(contains('above fold')),
          reason: 'the fold hint must not survive re-engage');
      expect(live, isNot(contains('● 3 new')),
          reason: 'the counter resets when the unseen tail is revealed');
      expect(live, contains('chunk three'),
          reason: 'the newest arrival is on the glass after re-engage');

      // Let the run settle before teardown (no detached-pty noise).
      await harness.waitForText('turn two done');
    },
  );
}
