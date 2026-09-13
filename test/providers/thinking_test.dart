import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Unit tests for the pi thinking-budget contract
/// (`lib/src/providers/thinking.dart`, issue #273). Table values are pi's
/// exact numbers — this pins pi-parity, so they must not be "fixed".
void main() {
  group('clampThinkingLevel', () {
    test('folds xhigh and max to high', () {
      expect(clampThinkingLevel('xhigh'), 'high');
      expect(clampThinkingLevel('max'), 'high');
    });

    test('passes known levels through unchanged', () {
      expect(clampThinkingLevel('minimal'), 'minimal');
      expect(clampThinkingLevel('low'), 'low');
      expect(clampThinkingLevel('medium'), 'medium');
      expect(clampThinkingLevel('high'), 'high');
    });

    test('leaves unknown strings alone', () {
      expect(clampThinkingLevel('bogus'), 'bogus');
    });

    test('null stays null', () {
      expect(clampThinkingLevel(null), isNull);
    });
  });

  group('thinkingBudgetForLevel', () {
    test('ladder values are exact', () {
      expect(thinkingBudgetForLevel('minimal'), 1024);
      expect(thinkingBudgetForLevel('low'), 2048);
      expect(thinkingBudgetForLevel('medium'), 8192);
      expect(thinkingBudgetForLevel('high'), 16384);
    });

    test('xhigh and max ride the top rung', () {
      expect(thinkingBudgetForLevel('xhigh'), 16384);
      expect(thinkingBudgetForLevel('max'), 16384);
    });

    test('null level budgets nothing', () {
      expect(thinkingBudgetForLevel(null), 0);
    });

    test('unknown level throws ArgumentError', () {
      expect(() => thinkingBudgetForLevel('bogus'), throwsArgumentError);
    });

    test('custom budgets override only their rung', () {
      expect(thinkingBudgetForLevel('high', {'high': 999}), 999);
      // Unmentioned rungs keep their defaults.
      expect(thinkingBudgetForLevel('low', {'high': 999}), 2048);
    });
  });

  group('clampThinkingBudgetToAnswerRoom', () {
    test('clamps to ceiling minus the answer floor', () {
      expect(clampThinkingBudgetToAnswerRoom(16384, 8192), 7168);
      expect(clampThinkingBudgetToAnswerRoom(16384, 100000), 16384);
      expect(clampThinkingBudgetToAnswerRoom(16384, 512), 0);
    });
  });

  group('adjustMaxTokensForThinking', () {
    test('pi parity rows', () {
      // (baseMaxTokens, modelMaxTokens, level, wantMaxTokens, wantBudget)
      const rows = [
        (null, 64000, 'high', 64000, 16384),
        (4096, 64000, 'high', 20480, 16384),
        (4096, 8192, 'high', 8192, 7168),
        (64000, 64000, 'high', 64000, 16384),
        (null, 64000, null, 64000, 0),
        (512, 8192, null, 512, 0),
      ];
      for (final (base, cap, level, wantMax, wantBudget) in rows) {
        final got = adjustMaxTokensForThinking(
          baseMaxTokens: base,
          modelMaxTokens: cap,
          level: level,
        );
        expect(got.maxTokens, wantMax, reason: 'base=$base cap=$cap level=$level');
        expect(
          got.thinkingBudget,
          wantBudget,
          reason: 'base=$base cap=$cap level=$level',
        );
      }
    });
  });
}
