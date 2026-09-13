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

    test('needle longer than the haystack returns null', () {
      expect(scoreFuzzy('ab', 'abc'), isNull);
    });

    test('maxIndices keeps the tail of the index list', () {
      final m = scoreFuzzy('a' * 300, 'a' * 300, maxIndices: 8);
      expect(m, isNotNull);
      expect(m!.indices.length, 8);
      expect(m.indices.last, 299);
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

  group('FuzzyMatch value semantics', () {
    test('equality and hashCode compare indices elementwise', () {
      final a = FuzzyMatch(3, [0, 2], 'ab');
      final same = FuzzyMatch(3, [0, 2], 'ab');
      final diffIndices = FuzzyMatch(3, [1, 2], 'ab');
      expect(a, equals(same));
      expect(a.hashCode, same.hashCode);
      expect(a == diffIndices, isFalse);
      // _listEquals length branch: shorter index list is unequal.
      expect(a == FuzzyMatch(3, [0], 'ab'), isFalse);
    });

    test('compareTo breaks score ties by length then lexicographic', () {
      final hi = FuzzyMatch(9, [0], 'x');
      final lo = FuzzyMatch(1, [0], 'x');
      expect(hi.compareTo(lo), isNegative);
      expect(lo.compareTo(hi), isPositive);
      // Same score: shorter text first.
      final short = FuzzyMatch(5, [0], 'ab');
      final long = FuzzyMatch(5, [0], 'abcd');
      expect(short.compareTo(long), isNegative);
      // Same score and length: lexicographic.
      expect(
        FuzzyMatch(5, [0], 'b').compareTo(FuzzyMatch(5, [0], 'a')),
        isPositive,
      );
    });

    test('toString carries score and text', () {
      expect(FuzzyMatch(2, [1], 'hi').toString(), 'FuzzyMatch(2, hi)');
    });
  });
}
