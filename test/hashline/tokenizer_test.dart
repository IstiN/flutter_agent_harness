import 'package:flutter_agent_harness/src/hashline/tokenizer.dart';
import 'package:test/test.dart';

void main() {
  group('parseLid', () {
    test('parses a bare line number', () {
      expect(parseLid('42', 1).line, 42);
      expect(parseLid('  7  ', 1).line, 7);
    });

    test('rejects malformed input with anchor examples', () {
      expect(
        () => parseLid('4x', 3),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('line 3:'), contains('"119", "112", "7"')),
          ),
        ),
      );
      expect(() => parseLid('0', 1), throwsA(isA<Exception>()));
    });
  });

  group('tryParseHunkHeader: MV destination forms', () {
    test('bare destination', () {
      final target = tryParseHunkHeader('MV other.ts');
      expect(target, isA<HashlineTargetMove>());
      expect((target! as HashlineTargetMove).dest, 'other.ts');
    });

    test('double-quoted destination with spaces', () {
      final target = tryParseHunkHeader('MV "my dir/file.ts"');
      expect((target! as HashlineTargetMove).dest, 'my dir/file.ts');
    });

    test('single-quoted destination', () {
      final target = tryParseHunkHeader("MV 'my dir/file.ts'");
      expect((target! as HashlineTargetMove).dest, 'my dir/file.ts');
    });

    test('quoted destination with an escaped quote', () {
      final target = tryParseHunkHeader(r'MV "a\"b.ts"');
      expect((target! as HashlineTargetMove).dest, 'a\\"b.ts');
    });

    test('unterminated or trailing-garbage quotes are not a move', () {
      expect(tryParseHunkHeader('MV "unterminated'), isNull);
      expect(tryParseHunkHeader('MV "a" extra'), isNull);
      expect(tryParseHunkHeader('MV'), isNull);
    });
  });

  group('classification helpers', () {
    test('isHashlineOp', () {
      expect(isHashlineOp('DEL 1'), isTrue);
      expect(isHashlineOp('SWAP 1.=2:'), isTrue);
      expect(isHashlineOp('INS.HEAD:'), isTrue);
      expect(isHashlineOp('DELAY 1'), isFalse);
      expect(isHashlineOp('plain text'), isFalse);
    });

    test('isHashlineHeader', () {
      expect(isHashlineHeader('[a.ts]'), isTrue);
      expect(isHashlineHeader('[a.ts#1A2B]'), isTrue);
      expect(isHashlineHeader('[a.ts#1A2B]  '), isTrue);
      expect(isHashlineHeader('[a.ts#1A2]'), isFalse);
      expect(isHashlineHeader('a.ts'), isFalse);
    });

    test('isHashlineEnvelopeMarker', () {
      expect(isHashlineEnvelopeMarker('*** Begin Patch'), isTrue);
      expect(isHashlineEnvelopeMarker('*** End Patch'), isTrue);
      expect(isHashlineEnvelopeMarker('*** Abort'), isTrue);
      expect(isHashlineEnvelopeMarker('*** Begin Patch   '), isTrue);
      expect(isHashlineEnvelopeMarker('*** Other'), isFalse);
    });
  });

  group('splitHashlineLines', () {
    test('empty input yields one empty line', () {
      expect(splitHashlineLines(''), ['']);
    });

    test('splits LF and strips one trailing CR per line', () {
      expect(splitHashlineLines('a\r\nb\r\n'), ['a', 'b']);
      expect(splitHashlineLines('a\nb'), ['a', 'b']);
    });

    test('a lone trailing CR on the final line is stripped', () {
      expect(splitHashlineLines('a\nb\r'), ['a', 'b']);
      expect(splitHashlineLines('ab\r'), ['ab']);
    });

    test('no trailing newline keeps the last line', () {
      expect(splitHashlineLines('a\nb\nc'), ['a', 'b', 'c']);
    });
  });

  group('tryParseHeader edge cases', () {
    test('rejects empty and hash-in-path headers', () {
      expect(tryParseHeader('[]'), isNull);
      expect(tryParseHeader('[#1A2B]'), isNull);
      expect(tryParseHeader('[a#b#1A2B]'), isNull);
      expect(tryParseHeader('[a.ts#1A2B'), isNull);
      expect(tryParseHeader('a.ts#1A2B]'), isNull);
    });

    test('uppercases a lowercase tag', () {
      final header = tryParseHeader('[a.ts#1a2b]');
      expect(header!.fileHash, '1A2B');
    });

    test('a path with spaces keeps its tag suffix', () {
      final header = tryParseHeader('[my dir/a.ts#9F3E]');
      expect(header!.path, 'my dir/a.ts');
      expect(header.fileHash, '9F3E');
    });
  });
}
