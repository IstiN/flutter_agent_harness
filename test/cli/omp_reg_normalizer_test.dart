import 'package:test/test.dart';

import 'package:flutter_agent_harness/src/cli/omp_reg_normalizer.dart';

void main() {
  // The glyph transport-mangles as an empty string in hand-typed
  // literals — always reference the map entry.
  final glyph = kRegSeparatorGlyphs['powerline-thin']!;

  group('scrubVolatile', () {
    test('costs collapse including the bracketed spend form', () {
      expect(scrubVolatile('spend [\$0.00] today'), 'spend <cost> today');
      expect(scrubVolatile('\$12.34'), '<cost>');
      expect(scrubVolatile('\$0.00'), '<cost>');
    });

    test('token counts collapse; the tok unit stays (structural)', () {
      expect(scrubVolatile('12.3k tok/s'), '<tok> tok/s');
      expect(scrubVolatile('1,234 tok'), '<tok> tok');
      expect(scrubVolatile('9 tok'), '<tok> tok');
    });

    test('elapsed forms collapse', () {
      expect(scrubVolatile('running 3d 4h 12m'), 'running <time>');
      expect(scrubVolatile('running 1h 05m'), 'running <time>');
      expect(scrubVolatile('running 4m 30s'), 'running <time>');
      expect(scrubVolatile('ran 12s'), 'ran <time>');
      expect(scrubVolatile('840ms'), '<time>');
    });

    test('paths collapse, home-abbreviated and raw', () {
      expect(scrubVolatile('~/work/omp'), '<path>');
      expect(scrubVolatile('./.worktrees/x'), '<path>');
      expect(scrubVolatile('/usr/local/bin/fa'), '<path>');
      // Digit-bearing anchored paths must be claimed whole BEFORE the
      // numeric rules see them - the round-1 ordering fix these rows pin.
      expect(scrubVolatile('/logs/2024/run'), '<path>');
      expect(scrubVolatile('~/cache/2024/run'), '<path>');
      // Bare relative paths (no ~/./ anchor) are OUT of the path rule's
      // documented scope; their numeric segments still scrub to the same
      // placeholders deterministically on both sides.
      expect(scrubVolatile('2024/cache/v2/store'), '<num><path>');
      expect(scrubVolatile('plain-text'), 'plain-text');
    });

    test('large raw numbers and gauge fills collapse', () {
      expect(scrubVolatile('46,000'), '<num>');
      expect(scrubVolatile('12.3k'), '<num>');
      expect(scrubVolatile('46000'), '<num>');
      expect(scrubVolatile('23%'), '<pct>%');
    });

    test('structural words survive scrubbing', () {
      expect(
        scrubVolatile('test model yolo reg-session main'),
        'test model yolo reg-session main',
      );
    });

    test('scrub order: cost survives, generic number does not eat it', () {
      // The cost rule must run BEFORE the bare-number rule: "$0.00" is a
      // cost shape, not two "<num>"s.
      expect(segmentSignature('\$0.00'), '<cost>');
      expect(segmentSignature('23%'), '<pct>');
      expect(segmentSignature('4m 30s'), '<time>');
    });

    test('findStatusBarRow picks the densest separator row', () {
      final screen = [
        'welcome banner',
        ' pi $glyph test model $glyph yolo $glyph 23% ',
        'prompt line',
      ];
      final bar = findStatusBarRow(screen, glyph);
      expect(bar, isNotNull);
      expect(bar, contains('yolo'));
      expect(findStatusBarRow(['no separators here'], glyph), isNull);
    });

    test('barSignature: same scenario shape survives volatile drift', () {
      // omp twin and fa render of the same boot: model id, clock and cost
      // differ; presence/order/shape must not.
      final omp = ' pi $glyph Test Model $glyph yolo $glyph 23% $glyph \$0.00 ';
      final fa =
          ' >_Fa $glyph test-model $glyph yolo $glyph 23% $glyph \$0.01 ';
      expect(barSignature(omp, glyph), barSignature(fa, glyph));
    });

    test('barSignature: a missing segment shifts the signature', () {
      final full =
          ' pi $glyph test model $glyph yolo $glyph 23% $glyph \$0.00 ';
      final trimmed = ' pi $glyph test model $glyph yolo $glyph 23% ';
      expect(barSignature(full, glyph), isNot(barSignature(trimmed, glyph)));
    });

    test('splitBarSegments drops blank padding tokens', () {
      expect(splitBarSegments('  a $glyph $glyph  b ', glyph), ['a', 'b']);
    });

    test('structuralDiff reports chrome and bar drift, silent on parity', () {
      final ompScreen = [
        'banner',
        ' pi $glyph Test Model $glyph yolo $glyph 23% $glyph \$0.00 ',
        'input',
      ];
      final faScreen = [
        'other banner',
        ' >_Fa $glyph test-model $glyph yolo $glyph 23% $glyph \$0.00 ',
        'input',
      ];
      expect(
        structuralDiff(
          faScreen,
          ompScreen,
          surfaceName: 'boot',
          separatorGlyph: glyph,
        ),
        isEmpty,
      );

      final drifted = [...faScreen]..removeLast();
      final findings = structuralDiff(
        drifted,
        ompScreen,
        surfaceName: 'boot',
        separatorGlyph: glyph,
      );
      expect(findings, hasLength(1));
      expect(findings.single, contains('chrome row count'));
    });
  });
}
