import 'package:flutter_agent_harness/src/cli/sigint_action.dart';
import 'package:test/test.dart';

void main() {
  group('sigintAction', () {
    test('busy interactive press aborts the run', () {
      expect(sigintAction(busy: true, headless: false), SigintAction.abortRun);
    });

    test('idle interactive press exits 130', () {
      expect(sigintAction(busy: false, headless: false), SigintAction.exitIdle);
    });

    test('headless always exits regardless of busy', () {
      expect(
        sigintAction(busy: true, headless: true),
        SigintAction.exitHeadless,
      );
      expect(
        sigintAction(busy: false, headless: true),
        SigintAction.exitHeadless,
      );
    });

    test('the busy hint names the second-press exit', () {
      // Regression guard: without this line a mid-stream Ctrl+C abort
      // looks like a hang (the PTY repro shipped it as one).
      expect(busySigintHint, contains('again'));
      expect(busySigintHint, contains('exit'));
    });
  });
}
