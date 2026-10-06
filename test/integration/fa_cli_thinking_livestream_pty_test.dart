@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'package:test/test.dart';

import 'fa_cli_fixtures.dart';
import 'pty_harness.dart';

/// Live thinking in the TUI (issue #1323): a reasoning model's thinking
/// deltas must RENDER while the reasoning phase is still running — dimmed,
/// before the first text delta — not sit in the transient-retry attempt
/// buffer until the answer starts (#964's silent «Working…», then one bulk
/// dump). Driven through the REAL binary over a PTY against a slow local
/// OpenAI-compatible mock, the same rig as the thinking-abort suite.
void main() {
  group('Fa CLI thinking live-stream', () {
    test(
      'reasoning deltas render before the first text delta (issue #1323)',
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

        harness.sendText('hello');
        await harness.waitForOutput(settleMs: 200);
        harness.sendEnter();
        // The busy row is the TUI's marker for the in-flight run; the mock
        // starts streaming reasoning deltas immediately after.
        await harness.waitForText(
          'Working',
          timeout: const Duration(seconds: 30),
        );

        // The mock streams `t0 t1 …` reasoning deltas one per 150ms; live
        // thinking puts several on screen within seconds — while the answer
        // text (`done`, ~15s out) cannot exist yet.
        var streamed = harness.screenText.contains('t5');
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!streamed && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          streamed = harness.screenText.contains('t5');
        }
        expect(
          streamed,
          isTrue,
          reason:
              'thinking deltas never rendered live — the retry buffer '
              'is still withholding the reasoning (issue #1323)',
        );
        expect(
          harness.screenText.contains('done'),
          isFalse,
          reason: 'the answer must not precede the streamed reasoning',
        );

        // End the run early: the mock would keep streaming for ~13s more.
        harness.sendText('\x1b\x1b');
        final abortDeadline = DateTime.now().add(const Duration(seconds: 10));
        var aborted = false;
        while (!aborted && DateTime.now().isBefore(abortDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          aborted = !harness.screenText.contains('Working');
        }
        expect(aborted, isTrue, reason: 'the run kept streaming after Esc Esc');
      },
    );
  });
}
