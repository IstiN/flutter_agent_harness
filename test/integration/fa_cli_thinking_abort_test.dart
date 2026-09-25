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
        // double-tap that the decoder used to swallow whole.
        harness.sendText('\x1b\x1b');

        // The run must abort promptly: the provider surfaces the abort and
        // the CLI prints the aborted turn, retiring the busy row.
        await harness.waitForText(
          'abort',
          timeout: const Duration(seconds: 15),
        );
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
