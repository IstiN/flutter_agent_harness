// Fuzzy scorer unit tests (issue #275, AC1/UT-fuzzy): subsequence ranking,
// camel/snake boundary bonuses, tie-breaks, rankFuzzy ordering + caps.
import 'package:flutter_agent_harness/src/cli/fuzzy_matcher.dart';
import 'package:test/test.dart';

void main() {
  group('scoreFuzzy', () {
    test('empty needle matches everything with score 0', () {
      final m = scoreFuzzy('anything', '');
      expect(m, isNotNull);
      expect(m!.score, 0);
      expect(m.indices, isEmpty);
    });

    test('non-matching needle returns null', () {
      expect(scoreFuzzy('/skills', 'xyz'), isNull);
      expect(scoreFuzzy('compact', 'ctx'), isNull);
    });

    test('case-insensitive subsequence match with ascending indices', () {
      final m = scoreFuzzy('/TrajectoryView', 'trv');
      expect(m, isNotNull);
      expect(m!.indices, everyElement(isNonNegative));
      expect(m.indices, orderedEquals(m.indices.toList()..sort()));
    });

    test('exact match outranks scattered subsequence', () {
      final exact = scoreFuzzy('/model', 'model')!;
      final scattered = scoreFuzzy('/model', 'moel')!;
      expect(exact.score, greaterThan(scattered.score));
    });

    test('boundary (snake) hit outranks mid-word hit', () {
      // 'p' after '_' is a word boundary; 'p' inside 'compact' is not.
      final boundary = scoreFuzzy('/task_prompt', 'tp')!;
      final midword = scoreFuzzy('/stamp', 'tp');
      // sanity: the boundary match must at least beat an equal-length
      // mid-word alternative for the same needle position.
      expect(boundary.score, greaterThan(scoreFuzzy('/stop', 'tp')!.score));
      expect(midword, isNotNull);
    });

    test('camelCase hump counts as a boundary', () {
      final m = scoreFuzzy('trajectoryView', 'tv')!;
      // 't' anchors (20) + 'v' at camel hump (12) − tail penalty.
      expect(m.score, greaterThan(0));
      expect(m.indices, [0, 10]);
    });

    test('contiguous runs outrank gappy matches of the same needle', () {
      final tight = scoreFuzzy('/compact', 'comp')!;
      final gappy = scoreFuzzy('/caaaompaqp', 'comp')!;
      expect(tight.score, greaterThan(gappy.score));
    });

    test('shorter haystack wins the tie (tight-match penalty)', () {
      expect(
        scoreFuzzy('/model', 'mod')!.score,
        greaterThan(scoreFuzzy('/modelling', 'mod')!.score),
      );
    });

    test('compareTo: score desc, then shorter text, then lexicographic', () {
      final a = FuzzyMatch(10, const [0], 'ab');
      final b = FuzzyMatch(12, const [0], 'abc');
      final d = FuzzyMatch(10, const [0], 'ac');
      expect(b.compareTo(a), lessThan(0)); // higher score first
      expect(a.compareTo(d), lessThan(0)); // tie: lexicographic text order
      expect(a.compareTo(FuzzyMatch(10, const [1], 'ab')), 0);
      final shorter = FuzzyMatch(10, const [0], 'a');
      expect(shorter.compareTo(a), lessThan(0)); // shorter text first
    });
  });

  group('rankFuzzy', () {
    const commands = [
      '/model',
      '/models',
      '/mode',
      '/compact',
      '/skills',
      '/skill:review',
    ];

    test('drops non-matches and sorts best-first', () {
      final ranked = rankFuzzy(commands, 'mod');
      // Shortest tight match wins: /mode > /model > /models.
      expect(ranked.map((m) => m.text).first, '/mode');
      expect(ranked.map((m) => m.text), contains('/model'));
      expect(ranked, everyElement(isA<FuzzyMatch>()));
      for (var i = 1; i < ranked.length; i++) {
        expect(ranked[i - 1].score, greaterThanOrEqualTo(ranked[i].score));
      }
    });

    test('empty needle keeps candidate order up to the limit', () {
      final ranked = rankFuzzy(commands, '');
      expect(ranked.map((m) => m.text), commands);
    });

    test('caps the result at limit', () {
      final many = List.generate(200, (i) => '/cmd$i');
      expect(rankFuzzy(many, 'cmd').length, 64);
      expect(rankFuzzy(many, 'cmd', limit: 7).length, 7);
    });
  });
}
