import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('SigintPolicy (issue #830 double-press contract)', () {
    late int clockMs;
    late DateTime Function() clock;

    setUp(() {
      clockMs = 0;
      clock = () => DateTime.fromMillisecondsSinceEpoch(clockMs);
    });

    test('headless exits immediately on every press — no window', () {
      final policy = SigintPolicy(now: clock);
      expect(policy.press(headless: true), SigintAction.exitHeadless);
      expect(policy.press(headless: true), SigintAction.exitHeadless);
      expect(policy.armed, isFalse, reason: 'headless bypasses the window');
    });

    test('press 1 stays; press 2 within the window exits', () {
      final policy = SigintPolicy(now: clock);
      expect(policy.press(headless: false), SigintAction.interruptAndStay);
      expect(policy.armed, isTrue);
      clockMs = 2999; // still inside the 3 s window
      expect(policy.press(headless: false), SigintAction.exitInteractive);
    });

    test('a press past the window is a fresh press 1 (ACX.3)', () {
      final policy = SigintPolicy(
        window: const Duration(seconds: 3),
        now: clock,
      );
      expect(policy.press(headless: false), SigintAction.interruptAndStay);
      clockMs = 3001; // window expired
      expect(policy.press(headless: false), SigintAction.interruptAndStay);
      clockMs = 4500; // press again inside the NEW window
      expect(policy.press(headless: false), SigintAction.exitInteractive);
    });

    test('any other input resets the window (ACX.5 reset-on-input)', () {
      final policy = SigintPolicy(now: clock);
      expect(policy.press(headless: false), SigintAction.interruptAndStay);
      clockMs = 2000;
      policy.noteOtherInput(); // the user typed something in between
      expect(policy.armed, isFalse);
      expect(
        policy.press(headless: false),
        SigintAction.interruptAndStay,
        reason: 'fresh press 1, not an exit',
      );
      clockMs = 4000;
      expect(policy.press(headless: false), SigintAction.exitInteractive);
    });

    test('the hint wording is shared by every surface', () {
      expect(kCtrlCExitHint, 'press ctrl+c again to exit');
    });
  });
}
