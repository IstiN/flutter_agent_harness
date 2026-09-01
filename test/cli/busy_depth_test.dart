import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:test/test.dart';

void main() {
  group('BusyDepth', () {
    test('single bracket signals both edges', () {
      final depth = BusyDepth();
      expect(depth.record(true), isTrue, reason: '0→1 signals the model');
      expect(depth.depth, 1);
      expect(depth.record(false), isTrue, reason: '1→0 signals the model');
      expect(depth.depth, 0);
    });

    test('nested brackets collapse to one edge pair', () {
      final depth = BusyDepth();
      // The TUI submit bracket around the run's own _startRun bracket.
      expect(depth.record(true), isTrue); // submit acquire: 0→1
      expect(depth.record(true), isFalse, reason: 'nested acquire: no edge');
      expect(depth.record(false), isFalse, reason: 'inner release: no edge');
      expect(depth.record(false), isTrue); // submit release: 1→0
      expect(depth.depth, 0);
    });

    test('an unpaired release clamps at zero', () {
      final depth = BusyDepth();
      expect(depth.record(false), isFalse, reason: 'no edge at the clamp');
      expect(depth.depth, 0);
      expect(depth.record(true), isTrue, reason: 'later acquire still works');
    });

    test('the inbox-wake scenario: wake bracket inside a submit bracket', () {
      final depth = BusyDepth();
      // Submit acquires, its run settles (release), an inbox wake acquires
      // and settles BEFORE the submit's finally release: the spinner must
      // stay on throughout and switch off exactly once.
      expect(depth.record(true), isTrue); // submit: on
      expect(depth.record(true), isFalse); // run: nested
      expect(depth.record(false), isFalse); // run settles: still busy
      expect(depth.record(true), isFalse); // wake: nested
      expect(depth.record(false), isFalse); // wake settles: still busy
      expect(depth.record(false), isTrue); // submit finally: off
      expect(depth.depth, 0);
    });
  });
}
