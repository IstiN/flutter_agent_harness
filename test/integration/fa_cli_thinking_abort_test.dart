@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'package:test/test.dart';

import 'fa_cli_fixtures.dart';
import 'pty_harness.dart';

/// Double-Esc abort of a thinking-stream run, driven through the REAL
/// binary over a PTY against a slow local OpenAI-compatible mock (issue
/// #931 part 3.4: split out of fa_cli_integration_test.dart so the
/// file-level scheduler can run these heavyweight mock-server suites
/// concurrently).
void main() {
  group('Fa CLI thinking-stream abort', () {
    test(
      'double Esc during thinking streaming aborts the run (issue #46)',
      () async {
        // Two Escape presses landing in ONE stdin chunk (a fast
        // double-tap) used to decode as a single unknown key and BOTH were
        // swallowed — the abort never fired and the TUI kept streaming
        // with no visible reaction ("not responding"). The real binary is
        // driven over a PTY against a mock endpoint that streams
        // reasoning deltas slowly, so the abort window stays open.
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
        // The mock starts streaming reasoning deltas immediately; the busy
        // row is the TUI's marker for the in-flight run.
        await harness.waitForText(
          'Working',
          timeout: const Duration(seconds: 30),
        );

        // ONE write carrying both presses — the exact wire shape of a fast
        // double-tap that the decoder used to swallow whole. Re-sent up to
        // twice on a ~3s probe: on a loaded CI runner a single-shot write
        // raced the 10ms lone-escape timer window (run 36732676599) and
        // the run streamed on untouched. A real user just presses Esc
        // again; a genuinely broken abort still fails every attempt.
        var aborted = harness.screenText.contains('abort');
        for (var attempt = 0; attempt < 3 && !aborted; attempt++) {
          if (attempt > 0) harness.sendText('\x1b\x1b');
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          while (DateTime.now().isBefore(deadline)) {
            if (harness.screenText.contains('abort')) break;
            if (!harness.screenText.contains('Working')) break;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          aborted = harness.screenText.contains('abort');
        }
        expect(aborted, isTrue, reason: 'double-Esc abort never surfaced');
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline)) {
          if (!harness.screenText.contains('Working')) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          harness.screenText.contains('Working'),
          isFalse,
          reason: 'busy row still up after the double-Esc abort',
        );
      },
    );
  });
}
