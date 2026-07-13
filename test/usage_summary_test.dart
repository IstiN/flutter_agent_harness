/// Tests for [UsageAccumulator].
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('UsageAccumulator', () {
    test('starts at zero usage with zero turns', () {
      final accumulator = UsageAccumulator();
      expect(accumulator.turns, 0);
      expect(accumulator.total.input, 0);
      expect(accumulator.total.output, 0);
      expect(accumulator.total.cost.total, 0);
      expect(accumulator.total.reasoning, isNull);
      expect(accumulator.total.cacheWrite1h, isNull);
    });

    test('sums token and cost fields across turns', () {
      final accumulator = UsageAccumulator()
        ..add(
          const Usage(
            input: 100,
            output: 50,
            cacheRead: 20,
            cacheWrite: 10,
            totalTokens: 180,
            cost: UsageCost(input: 0.1, output: 0.2, total: 0.3),
          ),
        )
        ..add(
          const Usage(
            input: 200,
            output: 70,
            cacheRead: 30,
            cacheWrite: 5,
            totalTokens: 305,
            cost: UsageCost(
              input: 0.4,
              output: 0.5,
              cacheRead: 0.01,
              cacheWrite: 0.02,
              total: 0.93,
            ),
          ),
        );

      expect(accumulator.turns, 2);
      final total = accumulator.total;
      expect(total.input, 300);
      expect(total.output, 120);
      expect(total.cacheRead, 50);
      expect(total.cacheWrite, 15);
      expect(total.totalTokens, 485);
      expect(total.cost.input, closeTo(0.5, 1e-9));
      expect(total.cost.output, closeTo(0.7, 1e-9));
      expect(total.cost.cacheRead, closeTo(0.01, 1e-9));
      expect(total.cost.cacheWrite, closeTo(0.02, 1e-9));
      expect(total.cost.total, closeTo(1.23, 1e-9));
    });

    test('optional fields stay null when never reported', () {
      final accumulator = UsageAccumulator()
        ..add(
          const Usage(
            input: 10,
            output: 5,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 15,
            cost: UsageCost(),
          ),
        );
      expect(accumulator.total.reasoning, isNull);
      expect(accumulator.total.cacheWrite1h, isNull);
    });

    test('sums reasoning and cacheWrite1h once any usage reports them', () {
      final accumulator = UsageAccumulator()
        ..add(
          const Usage(
            input: 10,
            output: 5,
            cacheRead: 0,
            cacheWrite: 4,
            cacheWrite1h: 2,
            reasoning: 3,
            totalTokens: 15,
            cost: UsageCost(),
          ),
        )
        ..add(
          const Usage(
            input: 10,
            output: 5,
            cacheRead: 0,
            cacheWrite: 6,
            reasoning: 1,
            totalTokens: 15,
            cost: UsageCost(),
          ),
        );
      expect(accumulator.total.reasoning, 4);
      expect(accumulator.total.cacheWrite1h, 2);
    });
  });
}
