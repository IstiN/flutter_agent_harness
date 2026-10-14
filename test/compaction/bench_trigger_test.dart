// gh-1604 items 2+3 — the bench-profile auto-compaction trigger.
//
// `FAH_COMPACT_TRIGGER_TOKENS` lowers the auto-compaction trigger to an
// absolute context size for bench/unattended runs: summarization fires
// when the estimated context exceeds the trigger, long before the
// window-minus-reserve default, keeping the task text + a rolling summary
// instead of letting the model-visible stream accrete for a whole
// 30-minute trial.
//
// AC3 (mechanism): the trigger is pure, clamped, and byte-identical when
// the env is unset.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('benchCompactionTriggerTokens', () {
    test('unset env → null (byte-identical legacy behavior)', () {
      expect(benchCompactionTriggerTokens({}), isNull);
      expect(
        benchCompactionTriggerTokens({'FAH_COMPACT_TRIGGER_TOKENS': ''}),
        isNull,
      );
      expect(
        benchCompactionTriggerTokens({'FAH_COMPACT_TRIGGER_TOKENS': '   '}),
        isNull,
      );
    });

    test('a positive integer parses', () {
      expect(
        benchCompactionTriggerTokens({'FAH_COMPACT_TRIGGER_TOKENS': '80000'}),
        80000,
      );
      expect(
        benchCompactionTriggerTokens({'FAH_COMPACT_TRIGGER_TOKENS': ' 6000 '}),
        6000,
      );
    });

    test('junk, zero and negative values are ignored (null)', () {
      for (final value in ['abc', '0', '-5', '8.000', '80 000']) {
        expect(
          benchCompactionTriggerTokens({'FAH_COMPACT_TRIGGER_TOKENS': value}),
          isNull,
          reason: value,
        );
      }
    });
  });

  group('withCompactionTriggerTokens', () {
    const window = 200000;
    final base = CompactionSettings.forWindow(window);

    test('a trigger below the default threshold raises the reserve so the '
        'trigger becomes the firing point', () {
      final settings = withCompactionTriggerTokens(
        base,
        window: window,
        triggerTokens: 80000,
      );
      expect(shouldCompact(80000, window, settings), isFalse);
      expect(shouldCompact(80001, window, settings), isTrue);
      // The kept region never eats more than half the trigger: a pass
      // always frees tokens.
      expect(
        settings.keepRecentTokens,
        lessThanOrEqualTo(settings.reserveTokens),
      );
      expect(settings.enabled, isTrue);
    });

    test('the default 20k keep budget yields to the trigger cap', () {
      final settings = withCompactionTriggerTokens(
        base,
        window: window,
        triggerTokens: 6000,
      );
      expect(settings.keepRecentTokens, lessThanOrEqualTo(3000));
      expect(shouldCompact(6000, window, settings), isFalse);
      expect(shouldCompact(6001, window, settings), isTrue);
    });
    test('a trigger of 1 clamps the keep to 1 instead of throwing '
        '(gh-1604 rework: clamp(1, 0) ArgumentError)', () {
      // `FAH_COMPACT_TRIGGER_TOKENS=1` is parse-valid (any positive
      // integer), and `clamped ~/ 2 == 0` made `int.clamp` throw an
      // ArgumentError — outside every compaction gate's try/catch, so
      // the whole bench run/boot died instead of degrading the way junk
      // env does.
      final settings = withCompactionTriggerTokens(
        base,
        window: window,
        triggerTokens: 1,
      );
      expect(settings.enabled, isTrue);
      expect(settings.keepRecentTokens, 1);
      expect(
        settings.keepRecentTokens,
        lessThanOrEqualTo(settings.reserveTokens),
      );
      // The trigger stays the firing point.
      expect(shouldCompact(1, window, settings), isFalse);
      expect(shouldCompact(2, window, settings), isTrue);
    });

    test('a trigger at/above the default threshold is a no-op', () {
      final defaultTrigger = window - base.reserveTokens;
      final settings = withCompactionTriggerTokens(
        base,
        window: window,
        triggerTokens: defaultTrigger,
      );
      expect(settings.reserveTokens, base.reserveTokens);
      expect(settings.keepRecentTokens, base.keepRecentTokens);
    });

    test('out-of-range triggers never RAISE the threshold', () {
      // At/above the window the knob clamps into the no-op guard: a bench
      // trigger can only lower the firing point, never raise it past the
      // settings' own default.
      final high = withCompactionTriggerTokens(
        base,
        window: window,
        triggerTokens: window * 2,
      );
      expect(high.reserveTokens, base.reserveTokens);
      expect(high.keepRecentTokens, base.keepRecentTokens);
      expect(shouldCompact(window - base.reserveTokens, window, high), isFalse);
      expect(
        shouldCompact(window - base.reserveTokens + 1, window, high),
        isTrue,
      );
    });
  });

  group('resolveBenchCompactionSettings', () {
    test('env unset → the base settings, byte-identical', () {
      final base = CompactionSettings.forWindow(200000);
      expect(
        resolveBenchCompactionSettings(base, window: 200000, env: {}),
        same(base),
      );
    });

    test('env set → the trigger-applied settings', () {
      final settings = resolveBenchCompactionSettings(
        CompactionSettings.forWindow(200000),
        window: 200000,
        env: {'FAH_COMPACT_TRIGGER_TOKENS': '64000'},
      );
      expect(shouldCompact(64000, 200000, settings), isFalse);
      expect(shouldCompact(64001, 200000, settings), isTrue);
    });
    test('env trigger 1 resolves without throwing (gh-1604 rework)', () {
      // Every spelling that parses to 1 rides the same guarded clamp.
      const window = 200000;
      final base = CompactionSettings.forWindow(window);
      for (final value in ['1', '+1', ' 1 ']) {
        final settings = resolveBenchCompactionSettings(
          base,
          window: window,
          env: {'FAH_COMPACT_TRIGGER_TOKENS': value},
        );
        expect(settings.enabled, isTrue, reason: value);
        expect(settings.keepRecentTokens, 1, reason: value);
      }
    });
  });
}
