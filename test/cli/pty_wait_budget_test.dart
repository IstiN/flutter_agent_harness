// Unit tests for the load-aware PTY wait-budget seam (issue #1391).
//
// The PTY/CLI integration shards and the Terminal-visual leg pin their
// wait budgets for a quiet runner. When the SM dispatches several
// validations in one wave (refresh waves supersede heads mid-run), the
// hosted-arm pool runs 2+ CI runs concurrently and every spawn /
// mock-LLM round-trip / compaction pass stretches — single tests then
// pop their 30 s budgets inside otherwise-green shards (four drilled
// runs, all single-test TimeoutException or raced-capture reds). The
// seam lets the two merge-blocking legs stretch every harness wait by
// a scale factor WITHOUT touching any test's own budget literals.
//
// Pure functions — no PTY, no process spawn (same convention as
// `maskedValueRow` / `pollUntil` in the PTY harness).
@Timeout(Duration(minutes: 2))
library;

import 'package:flutter_agent_harness/src/cli/pty_wait_budget.dart';
import 'package:test/test.dart';

void main() {
  group('resolvePtyWaitBudgetScale', () {
    test('unset / blank reads as 1.0 (no stretch)', () {
      expect(resolvePtyWaitBudgetScale(envValue: null), 1.0);
      expect(resolvePtyWaitBudgetScale(envValue: ''), 1.0);
      expect(resolvePtyWaitBudgetScale(envValue: '   '), 1.0);
    });

    test('garbage reads as 1.0 — a bad env never reds a leg', () {
      expect(resolvePtyWaitBudgetScale(envValue: 'two'), 1.0);
      expect(resolvePtyWaitBudgetScale(envValue: '1.5x'), 1.0);
      expect(resolvePtyWaitBudgetScale(envValue: 'NaN'), 1.0);
    });

    test('a valid value parses (integer and decimal forms)', () {
      expect(resolvePtyWaitBudgetScale(envValue: '2'), 2.0);
      expect(resolvePtyWaitBudgetScale(envValue: ' 2.5 '), 2.5);
    });

    test('values below 1 clamp UP to 1.0 — the scale never shrinks a budget',
        () {
      expect(resolvePtyWaitBudgetScale(envValue: '0.25'), 1.0);
      expect(resolvePtyWaitBudgetScale(envValue: '-3'), 1.0);
      expect(resolvePtyWaitBudgetScale(envValue: '0'), 1.0);
    });

    test('values above the ceiling clamp DOWN to 10.0 — bounded stretch', () {
      expect(resolvePtyWaitBudgetScale(envValue: '50'), 10.0);
    });
  });

  group('scalePtyWaitBudget', () {
    test('scale 1.0 returns the budget unchanged (identity)', () {
      final budget = Duration(seconds: 30);
      expect(scalePtyWaitBudget(budget, 1.0), budget);
    });

    test('a 2x scale doubles the budget', () {
      expect(
        scalePtyWaitBudget(const Duration(seconds: 30), 2.0),
        const Duration(seconds: 60),
      );
    });

    test('fractional scales round to whole microseconds without losing money',
        () {
      // 300 ms at 2.5x = 750 ms exactly.
      expect(
        scalePtyWaitBudget(const Duration(milliseconds: 300), 2.5),
        const Duration(milliseconds: 750),
      );
    });

    test('defensive: a sub-1.0 scale never shortens a budget', () {
      final budget = Duration(seconds: 30);
      expect(scalePtyWaitBudget(budget, 0.5), budget);
    });

    test('the ceiling scale stays overflow-safe (90 s boot budget at 10x)',
        () {
      expect(
        scalePtyWaitBudget(const Duration(seconds: 90), 10.0),
        const Duration(minutes: 15),
      );
    });
  });
}
