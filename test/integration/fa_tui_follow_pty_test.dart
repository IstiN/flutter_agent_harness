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
        ..enqueueText([for (var i = 1; i <= 30; i++) 'seed line $i'].join('\n'))
        // Turn 2 keeps the agent BUSY while the user scrolls. The mock
        // protocol chains a run across TOOL segments only — a pure-text
        // segment ENDS the run — so the post-detach arrivals are spaced
        // bash tools (each paints rows = counted OutputMsgs), one long
        // sleep holds the run open for the End press, and a final text
        // segment settles it.
        ..enqueueToolCall('bash', '{"command": "sleep 1"}')
        ..enqueueToolCall('bash', '{"command": "sleep 1"}')
        ..enqueueToolCall('bash', '{"command": "sleep 1"}')
        ..enqueueToolCall('bash', '{"command": "sleep 1"}')
        ..enqueueToolCall('bash', '{"command": "sleep 1"}')
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
      await harness.waitForText(
        '· submit',
        timeout: const Duration(seconds: 20),
      );

      // (1) Detach mid-run: PageUp parks the view above the live edge.
      // The held rule carries the position percent; the live-fold hint
      // (`… above fold - PgUp`) belongs to the FOLLOWING state and must
      // leave the glass once detached.
      harness.sendText('\x1b[5~'); // pgup

      // (2) Late arrivals count up on the held rule while live content
      // flows in BELOW the fold (`NN% · ● N new · End = live`). The bash
      // tools run as background jobs, so arrivals land in bursts — anchor
      // on ANY counted rule, then prove the counter GROWS (monotonic
      // unseen accounting), not on one exact sample.
      final counted = await harness.waitForScreen(
        RegExp(r'\d+% · ● \d+ new'),
        timeout: const Duration(seconds: 30),
      );
      expect(
        counted,
        contains('End = live'),
        reason: 'the chip carries the one-action re-engage hint',
      );
      final firstCount = int.parse(
        RegExp(r'● (\d+) new').firstMatch(counted)!.group(1)!,
      );
      final grown = await _waitCounterGrows(harness, firstCount);
      // Absence assertions need a SETTLED screen: the cell-diff paint path
      // repaints only changed cells, so the pre-detach live-fold hint row
      // can linger one frame after the detach (#550/#557 family).
      await harness.waitForOutput(settleMs: 400);
      final settled = harness.screenText;
      expect(
        settled,
        isNot(contains('above fold')),
        reason: 'detached: the live-fold hint belongs to following only',
      );
      expect(
        grown,
        greaterThan(firstCount),
        reason: 'unseen arrivals keep counting while held',
      );

      // (3) End re-engages: the held rule (percent + counter) is replaced
      // by the live-fold hint (the #827 "N lines above fold" announce for
      // the following state) and the newest content is at the live edge.
      harness.sendText('\x1b[F'); // end
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final live = harness.screenText;
      expect(
        live,
        isNot(contains(RegExp(r'● \d+ new'))),
        reason: 'the counter resets when the unseen tail is revealed',
      );
      expect(
        live,
        isNot(contains(RegExp(r'\d+% · '))),
        reason: 'the held percent rule leaves the glass on re-engage',
      );
      expect(
        live,
        contains('above fold'),
        reason:
            'back to FOLLOWING: the live-fold hint replaces the '
            'held rule (the #827 etiquette)',
      );
      expect(
        live,
        contains('Background jobs'),
        reason:
            're-engage lands on the LIVE edge: the busy tail is on '
            'the glass, not the parked view',
      );

      // Let the run settle before teardown (no detached-pty noise): the
      // last sleep tool still has up to 8s to drain — and its completion
      // text is the newest arrival, painted at the live edge.
      await harness.waitForText(
        'turn two done',
        timeout: const Duration(seconds: 30),
      );
      await harness.waitForOutput(settleMs: 400);
      expect(
        harness.screenText,
        contains('turn two done'),
        reason: 'the newest arrival rides the live edge after re-engage',
      );
    },
  );
}

/// Polls the SCREEN until the held-rule counter exceeds [from]; returns the
/// parsed count. Screen-side (not raw) — the contract is the glass.
Future<int> _waitCounterGrows(FaCliHarness harness, int from) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final match = RegExp(r'● (\d+) new').firstMatch(harness.screenText);
    if (match != null && int.parse(match.group(1)!) > from) {
      return int.parse(match.group(1)!);
    }
  }
  fail('held counter never grew past $from');
}
