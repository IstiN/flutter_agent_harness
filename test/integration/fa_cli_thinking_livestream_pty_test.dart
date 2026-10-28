@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'package:test/test.dart';

import 'fa_cli_fixtures.dart';
import 'pty_harness.dart';

/// Thinking on the TUI face (issue #1323 + gh-1933 AC4): the run must stay
/// LIVE while a reasoning model streams — the busy row keeps ticking (no
/// dead air, gh-1197 AC1) — and the reasoning must reach the GLASS, never
/// sit in a transient-retry buffer until teardown (#964's silent
/// «Working…» then one bulk dump). Since gh-1933 the default face renders
/// the window COLLAPSED (`> Thought for Ns`, the deltas buffered — the
/// per-delta dim stream is gone); `/transcript expand all` unfolds the
/// persisted text under the label (AC5), so the reasoning is still one
/// command away and lands BEFORE the answer, not at teardown. Driven
/// through the REAL binary over a PTY against a slow local
/// OpenAI-compatible mock, the same rig as the thinking-abort suite.
void main() {
  group('Fa CLI thinking live-stream', () {
    test('collapsed default: the run stays live while thinking buffers, '
        'and the reasoning text stays folded (gh-1933 AC4)', () async {
      final mock = SlowThinkingMockServer();
      await mock.start();
      final tempHome = makeTempHomeForMock(mock.port);
      final harness = await FaCliHarness.spawn(
        extraEnv: {'HOME': tempHome.path},
      );
      addTearDown(() async {
        await harness.close();
        tempHome.deleteSync(recursive: true);
        await mock.close();
      });
      await harness.waitForBoot();

      harness.sendText('hello');
      await harness.waitForOutput(settleMs: 200);
      harness.sendEnter();
      // The busy row is the TUI's marker for the in-flight run; the mock
      // starts streaming reasoning deltas immediately after.
      await harness.waitForText(
        'Working',
        timeout: const Duration(seconds: 30),
      );

      // LIVENESS (gh-1197 AC1): the thinking window buffers the raw
      // deltas on the TUI chrome face (gh-1933 AC4) but the frame
      // pipeline keeps painting — the busy-row heartbeat advances the
      // raw output stream within seconds (its bound is 8s; sample well
      // inside it). A silent stretch here would be the gh-1197 freeze
      // shape again, buffering or not.
      final bytesAtStart = harness.rawOutput.length;
      var live = false;
      final livenessDeadline = DateTime.now().add(const Duration(seconds: 6));
      while (DateTime.now().isBefore(livenessDeadline)) {
        if (harness.rawOutput.length != bytesAtStart) {
          live = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        live,
        isTrue,
        reason:
            'the frame pipeline went silent during the thinking window '
            '— the gh-1197 freeze shape (the busy row must keep '
            'repainting while the deltas buffer)',
      );

      // COLLAPSED (gh-1933 AC4): the reasoning deltas stay folded into
      // the window — no raw text on the glass while the phase streams.
      expect(
        harness.screenText.contains('t5'),
        isFalse,
        reason:
            'the reasoning text leaked onto the collapsed transcript '
            '(the deltas must buffer into the `> Thought for Ns` window)',
      );

      // End the run early: the mock would keep streaming for ~13s more.
      // Re-sent up to twice on a ~5s probe per attempt (the sibling
      // thinking-abort suite's hardening): on a loaded CI runner a
      // single-shot write raced the 10ms lone-escape timer window
      // (run 36732676599) and the run streamed on untouched.
      harness.sendText('\x1b\x1b');
      var aborted = !harness.screenText.contains('Working');
      for (var attempt = 0; attempt < 3 && !aborted; attempt++) {
        if (attempt > 0) harness.sendText('\x1b\x1b');
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          if (!harness.screenText.contains('Working')) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        aborted = !harness.screenText.contains('Working');
      }
      expect(aborted, isTrue, reason: 'the run kept streaming after Esc Esc');
    });

    test(
      'expand all: the persisted reasoning reaches the glass BEFORE the '
      'answer, never as a teardown burst (issue #1323 + gh-1933 AC5)',
      () async {
        final mock = SlowThinkingMockServer();
        await mock.start();
        final tempHome = makeTempHomeForMock(mock.port);
        final harness = await FaCliHarness.spawn(
          extraEnv: {'HOME': tempHome.path},
        );
        addTearDown(() async {
          await harness.close();
          tempHome.deleteSync(recursive: true);
          await mock.close();
        });
        await harness.waitForBoot();

        // The expansion state is set BEFORE the run: the window emits its
        // row + the full persisted text when it closes (the first answer
        // delta), so the reasoning lands with the turn, not at teardown.
        harness.sendText('/transcript expand all');
        harness.sendEnter();
        await harness.waitForText(
          'transcript: expanded',
          timeout: const Duration(seconds: 10),
        );

        harness.sendText('hello');
        await harness.waitForOutput(settleMs: 200);
        harness.sendEnter();
        await harness.waitForText(
          'Working',
          timeout: const Duration(seconds: 30),
        );

        // The mock streams `t0 t1 …` reasoning deltas one per 150ms and
        // holds the answer (`done`) until ~15s in; the window closes on
        // the first answer delta, unfolding the persisted reasoning —
        // `t5` must be ON THE GLASS by then (the #1323 contract: the
        // reasoning reaches the transcript within the run, not after it).
        var streamed = harness.screenText.contains('t5');
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!streamed && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          streamed = harness.screenText.contains('t5');
        }
        expect(
          streamed,
          isTrue,
          reason:
              'the persisted reasoning never reached the glass — the '
              'expanded window withheld it past the answer (issue #1323)',
        );

        // The answer follows the reasoning, in the same turn — and the
        // folded label row is on the glass with them (AC4's row grammar).
        await harness.waitForText('done', timeout: const Duration(seconds: 15));
        final screen = harness.screenText;
        expect(screen, contains('Thought for'));
        expect(
          screen.indexOf('Thought for'),
          lessThan(screen.indexOf('done')),
          reason:
              'the thought row must paint BEFORE the answer '
              '(transcript order):\n$screen',
        );
      },
    );
  });
}
