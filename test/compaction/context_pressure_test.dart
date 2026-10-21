// gh-1742 — observed context pressure: the pure reconciliation layer
// between the chars/4 estimate and the provider-reported usage
// (`input + cacheRead`) that every completed request already carries.
//
// UT-1 (AC1): reconciliation is max(estimate, observed) — monotone in
// both channels, no regression when observed < estimate, and a synthetic
// corpus whose observed usage exceeds the estimate by >=10% flips
// `shouldCompact` through the assessed pressure.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _assistant({
  required int input,
  int cacheRead = 0,
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: const [],
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage(
      input: input,
      output: 0,
      cacheRead: cacheRead,
      cacheWrite: 0,
      totalTokens: input + cacheRead,
      cost: const UsageCost(),
    ),
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

void main() {
  group('observedContextTokens', () {
    test(
      'is input + cacheRead — the accepted request size, not the response',
      () {
        // gh-1742 invariant 1: the observation of one completed request is
        // what the provider counted of the CONTEXT (input + cacheRead).
        // Output and cache-write are the response side and must not inflate
        // the pressure; totalTokens mixes both.
        final usage = Usage(
          input: 1000,
          output: 500,
          cacheRead: 2000,
          cacheWrite: 300,
          totalTokens: 3800,
          cost: const UsageCost(),
        );
        expect(observedContextTokens(usage), 3000);
      },
    );
  });

  group('lastObservedContextTokens', () {
    test('returns null without any usage-bearing assistant message', () {
      expect(lastObservedContextTokens(const []), isNull);
      expect(lastObservedContextTokens([UserMessage.text('hi')]), isNull);
      // Usage.zero reports no context — not an observation (E1).
      expect(lastObservedContextTokens([_assistant(input: 0)]), isNull);
    });

    test('returns the MOST RECENT observation (E3: resume rebuild)', () {
      final messages = [
        _assistant(input: 1000),
        UserMessage.text('grow'),
        _assistant(input: 5000, cacheRead: 500),
      ];
      expect(lastObservedContextTokens(messages), 5500);
    });

    test('skips errored/aborted assistant messages', () {
      final messages = [
        _assistant(input: 4000),
        _assistant(input: 999999, stopReason: StopReason.error),
        _assistant(input: 888888, stopReason: StopReason.aborted),
      ];
      expect(lastObservedContextTokens(messages), 4000);
    });
  });

  group('hasAnyReportedUsage (E1 degradation)', () {
    test('false for a transcript of usage-less assistant messages', () {
      expect(hasAnyReportedUsage([_assistant(input: 0)]), isFalse);
      expect(hasAnyReportedUsage(const []), isFalse);
    });

    test('true once any assistant message reports context', () {
      expect(
        hasAnyReportedUsage([_assistant(input: 0), _assistant(input: 10)]),
        isTrue,
      );
    });
  });

  group('reconcileContextTokens (UT-1)', () {
    test('observed wins when it exceeds the estimate', () {
      expect(
        reconcileContextTokens(estimatedTokens: 1000, observedTokens: 5000),
        5000,
      );
    });

    test('estimate stands when observed is smaller (no regression)', () {
      expect(
        reconcileContextTokens(estimatedTokens: 5000, observedTokens: 1000),
        5000,
      );
    });

    test('null/zero observation degrades to estimate-only', () {
      expect(reconcileContextTokens(estimatedTokens: 1234), 1234);
      expect(
        reconcileContextTokens(estimatedTokens: 1234, observedTokens: 0),
        1234,
      );
    });

    test('property: monotone in both channels, never below either', () {
      const estimates = [0, 1000, 50000, 200000];
      const observed = [null, 0, 1000, 60000, 300000];
      for (final e in estimates) {
        for (final o in observed) {
          final pressure = reconcileContextTokens(
            estimatedTokens: e,
            observedTokens: o,
          );
          expect(pressure, greaterThanOrEqualTo(e));
          if (o != null && o > 0) expect(pressure, greaterThanOrEqualTo(o));
          // Monotone in the estimate with the observation fixed.
          if (e > 0) {
            expect(
              reconcileContextTokens(estimatedTokens: e - 1, observedTokens: o),
              lessThanOrEqualTo(pressure),
            );
          }
        }
      }
    });
  });

  group('assessContextPressure (AC1/AC5)', () {
    final settings = CompactionSettings.forWindow(200000);
    // 200k window: reserve 16384 (the legacy-parity value) → trigger
    // 183616 — exactly the legacy line.
    test('estimate alone under the trigger stays quiet', () {
      final decision = assessContextPressure(
        estimatedTokens: 100000,
        contextWindow: 200000,
        settings: settings,
      );
      expect(decision.triggered, isFalse);
      expect(decision.needsForce, isFalse);
    });

    test(
      'AC1: observed > estimate by >=10% flips the trigger when it crosses',
      () {
        // Estimate just under the trigger, observed 10% over the estimate
        // and past the line: the reconciled pressure must fire.
        final decision = assessContextPressure(
          estimatedTokens: 180000,
          observedTokens: 198000,
          contextWindow: 200000,
          settings: settings,
        );
        expect(decision.triggered, isTrue);
        expect(decision.pressureTokens, 198000);
      },
    );

    test('AC5: observed over the line with the estimate under needs force', () {
      final decision = assessContextPressure(
        estimatedTokens: 100000,
        observedTokens: 190000,
        contextWindow: 200000,
        settings: settings,
      );
      expect(decision.triggered, isTrue);
      expect(decision.needsForce, isTrue);
    });

    test('estimate over the line without an observation is not forced', () {
      final decision = assessContextPressure(
        estimatedTokens: 190000,
        contextWindow: 200000,
        settings: settings,
      );
      expect(decision.triggered, isTrue);
      expect(decision.needsForce, isFalse);
    });

    test('observation at the line (== trigger) does not fire', () {
      // shouldCompact is strictly-greater (pi semantics) — the observed
      // channel follows the same edge.
      final decision = assessContextPressure(
        estimatedTokens: 0,
        observedTokens: 200000 - settings.reserveTokens,
        contextWindow: 200000,
        settings: settings,
      );
      expect(decision.triggered, isFalse);
      expect(decision.needsForce, isFalse);
    });

    test(
      'REG-1 gh_1122 shape: at <=200k windows the reconciled trigger fires '
      'no later than legacy',
      () {
        // The real child timeline: est 189,596 → observed 199,098 on a
        // 204,800 window. Legacy (est-only, reserve 16,384) fired at
        // 188,416; the new channel must not fire later than that.
        final decision = assessContextPressure(
          estimatedTokens: 189596,
          observedTokens: 199098,
          contextWindow: 204800,
          settings: CompactionSettings.forWindow(204800),
        );
        expect(decision.triggered, isTrue);
        // forWindow(204800).reserveTokens == 16,384 — the legacy value
        // exactly (204,800 sits inside the parity band), so the
        // reconciled line (188,416) IS the legacy line and the firing
        // boundary can never be later than before.
        expect(decision.pressureTokens, 199098);
      },
    );

    test(
      'REG-1 kimi shape: a −5% estimate drift on a 1M window cannot delay '
      'the observed channel (legacy rode real input for hours)',
      () {
        // The real failure: real context 983.5k, estimate 5% under →
        // 934,325. Legacy (trigger = 1M − 16,384 = 1,032,192) saw 934k
        // and stayed quiet until the estimate caught up — real input
        // ~1,035k, 13k from the hard window. The observed channel fires
        // at window − 65,536 = 983,040: this very boundary.
        final decision = assessContextPressure(
          estimatedTokens: 934325,
          observedTokens: 983500,
          contextWindow: 1048576,
          settings: CompactionSettings.forWindow(1048576),
        );
        expect(decision.triggered, isTrue);
        expect(decision.needsForce, isTrue);
        // The estimate channel alone stays quiet here — the observation
        // is the only thing that fired (the regression pin).
        final estimateOnly = assessContextPressure(
          estimatedTokens: 934325,
          contextWindow: 1048576,
          settings: CompactionSettings.forWindow(1048576),
        );
        expect(estimateOnly.triggered, isFalse);
      },
    );
  });
}
