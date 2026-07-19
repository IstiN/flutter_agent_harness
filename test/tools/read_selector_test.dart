import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('parseLineRangeChunk', () {
    test('parses a bare line number as an open range', () {
      final range = parseLineRangeChunk('50');
      expect(range, const LineRange(50));
    });

    test('parses an inclusive range', () {
      expect(parseLineRangeChunk('50-100'), const LineRange(50, 100));
    });

    test('parses start+count into an inclusive end', () {
      expect(parseLineRangeChunk('50+10'), const LineRange(50, 59));
    });

    test('parses the open-ended dash form', () {
      expect(parseLineRangeChunk('301-'), const LineRange(301));
    });

    test('parses the .. alias as -', () {
      expect(parseLineRangeChunk('2724..2727'), const LineRange(2724, 2727));
      expect(parseLineRangeChunk('2724..'), const LineRange(2724));
    });

    test('accepts the L prefix and mixed case', () {
      expect(parseLineRangeChunk('L50'), const LineRange(50));
      expect(parseLineRangeChunk('l50-L100'), const LineRange(50, 100));
      expect(parseLineRangeChunk('L5+L10'), const LineRange(5, 14));
    });

    test('returns null for non-range input', () {
      expect(parseLineRangeChunk(''), isNull);
      expect(parseLineRangeChunk('abc'), isNull);
      expect(parseLineRangeChunk('1-2-3'), isNull);
      expect(parseLineRangeChunk('raw'), isNull);
      expect(parseLineRangeChunk('5,6'), isNull);
      expect(parseLineRangeChunk('-5'), isNull);
    });

    test('throws on a zero start line', () {
      expect(
        () => parseLineRangeChunk('0'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Line selector 0 is invalid; lines are 1-indexed. Use :1.',
          ),
        ),
      );
      expect(() => parseLineRangeChunk('0-5'), throwsA(isA<StateError>()));
    });

    test('throws on a count below 1', () {
      expect(
        () => parseLineRangeChunk('5+0'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Invalid range 5+0: count must be >= 1.',
          ),
        ),
      );
    });

    test('throws when the end precedes the start', () {
      expect(
        () => parseLineRangeChunk('5-3'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Invalid range 5-3: end must be >= start.',
          ),
        ),
      );
    });
  });

  group('parseLineRanges', () {
    test('parses a single range', () {
      expect(parseLineRanges('5-10'), [const LineRange(5, 10)]);
    });

    test('sorts ranges ascending', () {
      expect(parseLineRanges('40-50,10-20'), [
        const LineRange(10, 20),
        const LineRange(40, 50),
      ]);
    });

    test('merges overlapping ranges', () {
      expect(parseLineRanges('10-20,15-25'), [const LineRange(10, 25)]);
    });

    test('merges adjacent ranges', () {
      expect(parseLineRanges('1-5,6-10'), [const LineRange(1, 10)]);
    });

    test('keeps disjoint ranges separate', () {
      expect(parseLineRanges('5-16,960-973'), [
        const LineRange(5, 16),
        const LineRange(960, 973),
      ]);
    });

    test('dedupes identical ranges', () {
      expect(parseLineRanges('5-10,5-10'), [const LineRange(5, 10)]);
    });

    test('an open-ended range absorbs everything after it', () {
      expect(parseLineRanges('5-,10-20'), [const LineRange(5)]);
      expect(parseLineRanges('10-20,30-'), [
        const LineRange(10, 20),
        const LineRange(30),
      ]);
    });

    test('an open-ended later range extends a merged earlier one', () {
      expect(parseLineRanges('10-20,15-'), [const LineRange(10)]);
    });

    test('returns null when any chunk is malformed', () {
      expect(parseLineRanges('5-10,bad'), isNull);
      expect(parseLineRanges(''), isNull);
    });
  });

  group('splitPathAndSel', () {
    test('keeps paths without a selector tail intact', () {
      expect(splitPathAndSel('foo.txt').sel, isNull);
      expect(splitPathAndSel('foo.txt').path, 'foo.txt');
      expect(splitPathAndSel('src/bar/baz.txt').path, 'src/bar/baz.txt');
    });

    test('peels a line range', () {
      final split = splitPathAndSel('foo.txt:50-100');
      expect(split.path, 'foo.txt');
      expect(split.sel, '50-100');
    });

    test('peels raw', () {
      final split = splitPathAndSel('foo.txt:raw');
      expect(split.path, 'foo.txt');
      expect(split.sel, 'raw');
    });

    test('peels a compound range+raw in either order', () {
      final a = splitPathAndSel('foo.txt:1-50:raw');
      expect(a.path, 'foo.txt');
      expect(a.sel, '1-50:raw');
      final b = splitPathAndSel('foo.txt:raw:1-50');
      expect(b.path, 'foo.txt');
      expect(b.sel, 'raw:1-50');
    });

    test('is case-insensitive', () {
      expect(splitPathAndSel('foo.txt:RAW').sel, 'RAW');
      expect(splitPathAndSel('foo.txt:L5-L10').sel, 'L5-L10');
    });

    test('leaves archive and sqlite colon syntax alone', () {
      expect(splitPathAndSel('a.zip:inner/file').sel, isNull);
      expect(splitPathAndSel('a.zip:inner/file').path, 'a.zip:inner/file');
      expect(splitPathAndSel('db.sqlite:table').sel, isNull);
      expect(splitPathAndSel('db.sqlite:table:key').sel, isNull);
    });

    test('leaves unrecognized tails alone', () {
      expect(splitPathAndSel('foo.txt:abc').sel, isNull);
      expect(splitPathAndSel('foo.txt:1-x').sel, isNull);
      expect(splitPathAndSel('foo.txt:5-10:raw:extra').sel, isNull);
    });

    test('does not peel from a bare selector', () {
      expect(splitPathAndSel(':5-10').sel, isNull);
    });

    test('peels after any colon past index 0 (omp parity)', () {
      final split = splitPathAndSel('C:raw');
      expect(split.path, 'C');
      expect(split.sel, 'raw');
    });
  });

  group('splitPathAndSelPreferringLiteral', () {
    test('a literal file with a selector-shaped name wins', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('test:1-2', 'literal');
      final split = await splitPathAndSelPreferringLiteral('test:1-2', env);
      expect(split.path, 'test:1-2');
      expect(split.sel, isNull);
    });

    test(
      'falls back to the strict split when the literal is missing',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        await env.writeFile('test', 'x\ny\nz');
        final split = await splitPathAndSelPreferringLiteral('test:1-2', env);
        expect(split.path, 'test');
        expect(split.sel, '1-2');
      },
    );

    test('passes through paths without a selector', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final split = await splitPathAndSelPreferringLiteral('plain.txt', env);
      expect(split.path, 'plain.txt');
      expect(split.sel, isNull);
    });
  });

  group('parseSel', () {
    test('none for null, empty, or unrecognized selectors', () {
      expect(parseSel(null), isA<ReadSelectorNone>());
      expect(parseSel(''), isA<ReadSelectorNone>());
      expect(parseSel('table'), isA<ReadSelectorNone>());
      expect(parseSel('raw:whatever:extra'), isA<ReadSelectorNone>());
    });

    test('raw alone', () {
      expect(parseSel('raw'), isA<ReadSelectorRaw>());
      expect(parseSel('RAW'), isA<ReadSelectorRaw>());
    });

    test('single and multi ranges', () {
      final single = parseSel('50-100');
      expect(single, isA<ReadSelectorLines>());
      expect((single as ReadSelectorLines).ranges, [const LineRange(50, 100)]);
      expect(single.raw, isFalse);

      final multi = parseSel('5-16,960-973');
      expect((multi as ReadSelectorLines).ranges, hasLength(2));
    });

    test('compound range+raw in either order', () {
      final a = parseSel('1-50:raw') as ReadSelectorLines;
      expect(a.raw, isTrue);
      expect(a.ranges, [const LineRange(1, 50)]);
      final b = parseSel('raw:1-50') as ReadSelectorLines;
      expect(b.raw, isTrue);
      expect(b.ranges, [const LineRange(1, 50)]);
    });

    test('throws on read-like but malformed compounds', () {
      expect(
        () => parseSel('1-2:3-4'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains("Invalid selector ':1-2:3-4'"),
          ),
        ),
      );
      expect(() => parseSel('raw:1-2:3-4'), throwsA(isA<StateError>()));
      expect(() => parseSel('raw:-5'), throwsA(isA<StateError>()));
    });

    test('isRawSelector covers raw alone and raw ranges', () {
      expect(isRawSelector(parseSel('raw')), isTrue);
      expect(isRawSelector(parseSel('1-2:raw')), isTrue);
      expect(isRawSelector(parseSel('1-2')), isFalse);
      expect(isRawSelector(parseSel(null)), isFalse);
    });
  });
}
