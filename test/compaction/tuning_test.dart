// gh-2098 — user-facing compaction trigger tuning: the `compaction:`
// yaml keys (`triggerRatio`, `reserveTokens`, `keepRecentTokens`)
// override the gh-1742 `CompactionSettings.forWindow` curves; absent
// keys keep the shipped behavior byte-identically.
//
// UT map:
// - parsing/validation: strict ConfigExceptions with named keys
//   (issue #541's parseJudgeBudgetSeconds pattern);
// - golden: absent keys → the forWindow curves, instance-identical;
// - application: the ratio pins the trigger line at r × window
//   (reserve = window − floor(r·window)); degenerate guards mirror
//   forWindow so a pass always frees tokens;
// - merge: per-key deepest scope wins (global < project).
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('CompactionTuning.fromSection', () {
    test('null node → null (section absent)', () {
      expect(CompactionTuning.fromSection(null, label: 'test'), isNull);
    });

    test('non-map node is a strict config error', () {
      expect(
        () => CompactionTuning.fromSection('structured', label: 'test'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('compaction must be a map'),
          ),
        ),
      );
    });

    test('an empty map parses to an empty tuning (engine-only sections '
        'keep working)', () {
      final tuning = CompactionTuning.fromSection({
        'engine': 'structured',
      }, label: 'test');
      expect(tuning, isNotNull);
      expect(tuning!.isEmpty, isTrue);
    });

    test('parses triggerRatio as a double', () {
      final tuning = CompactionTuning.fromSection({
        'triggerRatio': 0.75,
      }, label: 'test');
      expect(tuning!.triggerRatio, 0.75);
      expect(tuning.reserveTokens, isNull);
      expect(tuning.keepRecentTokens, isNull);
    });

    test('parses the token budgets as ints', () {
      final tuning = CompactionTuning.fromSection(const {
        'reserveTokens': 50000,
        'keepRecentTokens': 80000,
      }, label: 'test');
      expect(tuning!.triggerRatio, isNull);
      expect(tuning.reserveTokens, 50000);
      expect(tuning.keepRecentTokens, 80000);
    });

    test('a non-numeric triggerRatio is a strict config error', () {
      expect(
        () => CompactionTuning.fromSection({
          'triggerRatio': 'most',
        }, label: 'my-config'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            'my-config: compaction.triggerRatio must be a number strictly '
                'between 0 and 1, got: most',
          ),
        ),
      );
    });

    test('a boolean triggerRatio is a strict config error', () {
      expect(
        () =>
            CompactionTuning.fromSection({'triggerRatio': true}, label: 'test'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('triggerRatio bounds are exclusive (0 and 1 are errors)', () {
      for (final bad in [0, 1, 1.0, 1.5, -0.5, 100]) {
        expect(
          () => CompactionTuning.fromSection({
            'triggerRatio': bad,
          }, label: 'test'),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains(
                'compaction.triggerRatio must be strictly between 0 and 1',
              ),
            ),
          ),
          reason: 'triggerRatio: $bad must be rejected',
        );
      }
    });

    test('a non-int reserveTokens is a strict config error', () {
      expect(
        () => CompactionTuning.fromSection({
          'reserveTokens': 1.5,
        }, label: 'my-config'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            'my-config: compaction.reserveTokens must be a positive int, '
                'got: 1.5',
          ),
        ),
      );
      expect(
        () => CompactionTuning.fromSection({
          'reserveTokens': 'big',
        }, label: 'test'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('a non-positive reserveTokens is a strict config error', () {
      for (final bad in [0, -5]) {
        expect(
          () => CompactionTuning.fromSection({
            'reserveTokens': bad,
          }, label: 'test'),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('compaction.reserveTokens must be positive'),
            ),
          ),
          reason: 'reserveTokens: $bad must be rejected',
        );
      }
    });

    test('a non-positive keepRecentTokens is a strict config error', () {
      expect(
        () => CompactionTuning.fromSection({
          'keepRecentTokens': 0,
        }, label: 'my-config'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            'my-config: compaction.keepRecentTokens must be positive, '
                'got: 0',
          ),
        ),
      );
    });

    test('triggerRatio and reserveTokens are mutually exclusive', () {
      expect(
        () => CompactionTuning.fromSection({
          'triggerRatio': 0.75,
          'reserveTokens': 50000,
        }, label: 'my-config'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            'my-config: compaction.triggerRatio and compaction.reserveTokens '
                'are mutually exclusive — the ratio already fixes the trigger '
                'line; configure one of them',
          ),
        ),
      );
    });
  });

  group('forWindow golden curves (gh-1742, byte-identical)', () {
    // The acceptance criterion: absent keys → the gh-1742 curves
    // byte-identical. These are the EXACT shipped numbers, pinned so any
    // drift in the scaling rule fails here first.
    final golden = {
      // Degenerate-window band: both guards clamp.
      200: (reserve: 128, keep: 256),
      128000: (reserve: 16384, keep: 20000),
      262144: (reserve: 16384, keep: 32768),
      400000: (reserve: 25000, keep: 50000),
      1048576: (reserve: 65536, keep: 131072),
    };
    golden.forEach((window, expected) {
      test('forWindow($window) → reserve ${expected.reserve}, keep '
          '${expected.keep}', () {
        final settings = CompactionSettings.forWindow(window);
        expect(settings.reserveTokens, expected.reserve);
        expect(settings.keepRecentTokens, expected.keep);
        expect(settings.enabled, isTrue);
        // The no-tuning application is the IDENTICAL instance — not a
        // rebuilt copy (unset config = byte-for-byte legacy).
        expect(
          applyCompactionTuning(settings, window: window, tuning: null),
          same(settings),
        );
        expect(
          applyCompactionTuning(
            settings,
            window: window,
            tuning: const CompactionTuning(),
          ),
          same(settings),
        );
      });
    });

    test('the legacy trigger line is 0.9375 × window above 262144 '
        '(the ticket correction baseline)', () {
      // gh-1742: 6.25% headroom → the legacy fires at 93.75% of the
      // window on the proportional band (before the 64Ki clamp).
      final settings = CompactionSettings.forWindow(400000);
      final trigger = 400000 - settings.reserveTokens;
      expect(trigger, 375000);
    });
  });

  group('applyCompactionTuning', () {
    test('triggerRatio 0.75 pins the trigger at 75% of the window', () {
      final base = CompactionSettings.forWindow(400000);
      final tuned = applyCompactionTuning(
        base,
        window: 400000,
        tuning: const CompactionTuning(triggerRatio: 0.75),
      );
      // reserve = window − floor(r × window) = 400000 − 300000 = 100000.
      expect(tuned.reserveTokens, 100000);
      // The retention curve is untouched by the ratio.
      expect(tuned.keepRecentTokens, base.keepRecentTokens);
      expect(tuned.enabled, isTrue);
      // Both channels fire at the same line: the estimate channel via
      // shouldCompact (strict legacy `>`), the observed channel through
      // the reconciled pressure.
      expect(shouldCompact(299999, 400000, tuned), isFalse);
      expect(shouldCompact(300001, 400000, tuned), isTrue);
      // The anchored (observed) channel agrees — gh-1742's anchor
      // priority: the provider's own number fires the pass.
      final decision = assessContextPressure(
        estimatedTokens: 290000,
        observedTokens: 300001,
        contextWindow: 400000,
        settings: tuned,
      );
      expect(decision.triggered, isTrue);
      expect(decision.observedTriggered, isTrue);
    });

    test('triggerRatio 0.80 fires at 80% of the window', () {
      final tuned = applyCompactionTuning(
        CompactionSettings.forWindow(400000),
        window: 400000,
        tuning: const CompactionTuning(triggerRatio: 0.80),
      );
      expect(400000 - tuned.reserveTokens, 320000);
      expect(shouldCompact(319999, 400000, tuned), isFalse);
      expect(shouldCompact(320001, 400000, tuned), isTrue);
    });

    test('the ratio line never fires later than configured (modulo the '
        'double-multiplication epsilon)', () {
      // The line is window − floor(window × ratio) in double
      // arithmetic: never ABOVE r × window except by the sub-1
      // rounding artifact of the product itself. Pin the bound across
      // the industry band.
      const window = 100000;
      for (final ratio in const [0.6, 2 / 3, 0.75, 0.8, 0.9]) {
        final tuned = applyCompactionTuning(
          CompactionSettings.forWindow(window),
          window: window,
          tuning: CompactionTuning(triggerRatio: ratio),
        );
        final line = window - tuned.reserveTokens;
        expect(
          line,
          lessThanOrEqualTo(ratio * window + 1),
          reason:
              'ratio $ratio: line $line must not exceed '
              '${ratio * window} (+1 epsilon)',
        );
        // Fires at the line, never below it: one token under stays put.
        expect(shouldCompact(line - 1, window, tuned), isFalse);
        expect(shouldCompact(line + 1, window, tuned), isTrue);
      }
    });

    test('reserveTokens overrides the curve directly', () {
      final tuned = applyCompactionTuning(
        CompactionSettings.forWindow(400000),
        window: 400000,
        tuning: const CompactionTuning(reserveTokens: 50000),
      );
      expect(tuned.reserveTokens, 50000);
      expect(
        tuned.keepRecentTokens,
        CompactionSettings.forWindow(400000).keepRecentTokens,
      );
    });

    test('keepRecentTokens overrides the curve directly', () {
      final tuned = applyCompactionTuning(
        CompactionSettings.forWindow(400000),
        window: 400000,
        tuning: const CompactionTuning(keepRecentTokens: 80000),
      );
      expect(
        tuned.reserveTokens,
        CompactionSettings.forWindow(400000).reserveTokens,
      );
      expect(tuned.keepRecentTokens, 80000);
    });

    test('ratio + keep compose (the ratio fixes the line, keep overrides '
        'retention)', () {
      final tuned = applyCompactionTuning(
        CompactionSettings.forWindow(400000),
        window: 400000,
        tuning: const CompactionTuning(
          triggerRatio: 0.75,
          keepRecentTokens: 80000,
        ),
      );
      expect(tuned.reserveTokens, 100000);
      expect(tuned.keepRecentTokens, 80000);
    });

    test('a reserve over half the window clamps like forWindow (a pass '
        'must free tokens)', () {
      // ratio 0.25 → reserve 300000 on a 400000 window; the degenerate
      // guard clamps to window ~/ 4.
      final tuned = applyCompactionTuning(
        CompactionSettings.forWindow(400000),
        window: 400000,
        tuning: const CompactionTuning(triggerRatio: 0.25),
      );
      expect(tuned.reserveTokens, 100000);
    });

    test('a keep over the window clamps like forWindow', () {
      final tuned = applyCompactionTuning(
        CompactionSettings.forWindow(400000),
        window: 400000,
        tuning: const CompactionTuning(keepRecentTokens: 500000),
      );
      // max(256, window ~/ 2) = 200000.
      expect(tuned.keepRecentTokens, 200000);
    });

    test('a degenerate zero window stays forWindow-shaped', () {
      final tuned = applyCompactionTuning(
        CompactionSettings.forWindow(0),
        window: 0,
        tuning: const CompactionTuning(triggerRatio: 0.75),
      );
      expect(
        tuned.reserveTokens,
        CompactionSettings.forWindow(0).reserveTokens,
      );
      expect(
        tuned.keepRecentTokens,
        CompactionSettings.forWindow(0).keepRecentTokens,
      );
    });

    test('a disabled base stays disabled (tuning never re-enables)', () {
      const base = CompactionSettings(
        enabled: false,
        reserveTokens: 16384,
        keepRecentTokens: 20000,
      );
      final tuned = applyCompactionTuning(
        base,
        window: 400000,
        tuning: const CompactionTuning(triggerRatio: 0.75),
      );
      expect(tuned.enabled, isFalse);
    });
  });

  group('loadProjectCompactionTuning', () {
    test('absent file → null; valid section parses; invalid throws '
        '(strict)', () {
      final dir = Directory.systemTemp.createTempSync('fa_tuning_');
      try {
        expect(loadProjectCompactionTuning(dir.path), isNull);

        final file = File('${dir.path}/.fah/config.yaml')
          ..createSync(recursive: true);
        file.writeAsStringSync('compaction:\n  triggerRatio: 0.75\n');
        expect(loadProjectCompactionTuning(dir.path)!.triggerRatio, 0.75);

        file.writeAsStringSync('compaction:\n  triggerRatio: 2\n');
        expect(
          () => loadProjectCompactionTuning(dir.path),
          throwsA(isA<ConfigException>()),
        );

        // A compaction section without tuning keys parses to an empty
        // tuning (engine-only project sections keep working).
        file.writeAsStringSync('compaction:\n  engine: structured\n');
        expect(loadProjectCompactionTuning(dir.path)!.isEmpty, isTrue);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('mergeCompactionTuning', () {
    test('both absent → null', () {
      expect(mergeCompactionTuning(global: null, project: null), isNull);
    });

    test('project wins per key; the other scope fills the gaps', () {
      final merged = mergeCompactionTuning(
        global: const CompactionTuning(triggerRatio: 0.75),
        project: const CompactionTuning(keepRecentTokens: 12000),
      );
      expect(merged!.triggerRatio, 0.75);
      expect(merged.keepRecentTokens, 12000);
      expect(merged.reserveTokens, isNull);
    });

    test('a conflicting merged pair is a strict config error', () {
      expect(
        () => mergeCompactionTuning(
          global: const CompactionTuning(triggerRatio: 0.75),
          project: const CompactionTuning(reserveTokens: 50000),
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('mutually exclusive'),
          ),
        ),
      );
    });

    test('a merged empty tuning reports empty', () {
      final merged = mergeCompactionTuning(
        global: const CompactionTuning(),
        project: null,
      );
      expect(merged!.isEmpty, isTrue);
    });
  });
}
