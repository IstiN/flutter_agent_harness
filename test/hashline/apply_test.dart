import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

HashlineApplyResult apply(String text, String diff) {
  return applyHashlineEdits(text, parseHashlinePatch(diff).edits);
}

void main() {
  group('applyHashlineEdits: basic ops', () {
    test('SWAP replaces an inclusive range with the body', () {
      final result = apply('a\nb\nc\nd', 'SWAP 2.=3:\n+x\n+y');
      expect(result.text, 'a\nx\ny\nd');
      expect(result.firstChangedLine, 2);
    });

    test('SWAP can expand one line into many', () {
      final result = apply('a\nb\nc', 'SWAP 2.=2:\n+x\n+y\n+z');
      expect(result.text, 'a\nx\ny\nz\nc');
    });

    test('DEL removes the inclusive range', () {
      final result = apply('a\nb\nc\nd', 'DEL 2.=3');
      expect(result.text, 'a\nd');
      expect(result.firstChangedLine, 2);
    });

    test('INS.PRE / INS.POST land around the anchor line', () {
      expect(apply('a\nb\nc', 'INS.PRE 2:\n+x').text, 'a\nx\nb\nc');
      expect(apply('a\nb\nc', 'INS.POST 2:\n+x').text, 'a\nb\nx\nc');
    });

    test('INS.HEAD / INS.TAIL', () {
      expect(apply('a\nb', 'INS.HEAD:\n+x').text, 'x\na\nb');
      expect(apply('a\nb', 'INS.TAIL:\n+x').text, 'a\nb\nx');
    });

    test('empty edits are a no-op', () {
      final result = applyHashlineEdits('a\nb', const []);
      expect(result.text, 'a\nb');
      expect(result.firstChangedLine, isNull);
    });
  });

  group('applyHashlineEdits: line-number semantics', () {
    test('anchors refer to ORIGINAL lines; hunks do not shift each other', () {
      // Bottom-up application: the SWAP on line 1 and the DEL on line 3 both
      // index the original file even though each changes the line count.
      final result = apply('a\nb\nc\nd', 'SWAP 1.=1:\n+x\n+y\nDEL 3.=3');
      expect(result.text, 'x\ny\nb\nd');
    });

    test('later hunks at the same line apply in patch order', () {
      final result = apply('a\nb', 'INS.POST 1:\n+x\nINS.POST 1:\n+y');
      expect(result.text, 'a\nx\ny\nb');
    });

    test(
      'insert before and after the same line keeps patch order per side',
      () {
        final result = apply(
          'a\nb',
          'INS.POST 1:\n+after\nINS.PRE 1:\n+before',
        );
        expect(result.text, 'before\na\nafter\nb');
      },
    );

    test('SWAP + INS around one line compose', () {
      final result = apply(
        'a\nb\nc',
        'SWAP 2.=2:\n+B\nINS.PRE 2:\n+before\nINS.POST 2:\n+after',
      );
      expect(result.text, 'a\nbefore\nB\nafter\nc');
    });

    test('out-of-bounds anchors are rejected', () {
      expect(
        () => apply('a\nb', 'DEL 3'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            'Line 3 does not exist (file has 2 lines)',
          ),
        ),
      );
      expect(
        () => apply('a\nb', 'INS.POST 9:\n+x'),
        throwsA(isA<HashlineFormatException>()),
      );
    });
  });

  group('applyHashlineEdits: trailing-newline phantom line', () {
    test(
      'INS.TAIL on a newline-terminated file inserts before the phantom',
      () {
        final result = apply('a\nb\n', 'INS.TAIL:\n+x');
        expect(result.text, 'a\nb\nx\n');
      },
    );

    test('a DEL spanning into the phantom strips no extra content', () {
      // 'a\nb\n' splits to ['a','b','']; the trailing '' is the phantom line
      // 3. `DEL 2.=3` must delete only line 2 (the phantom delete is dropped)
      // and the file keeps its final newline.
      final result = apply('a\nb\n', 'DEL 2.=3');
      expect(result.text, 'a\n');
    });

    test('the phantom line is addressable for inserts', () {
      final result = apply('a\nb\n', 'INS.PRE 3:\n+x');
      expect(result.text, 'a\nb\nx\n');
    });
  });

  group('applyHashlineEdits: empty-file edge cases', () {
    test('INS.HEAD / INS.TAIL on an empty file produce the body', () {
      expect(apply('', 'INS.HEAD:\n+x').text, 'x');
      expect(apply('', 'INS.TAIL:\n+x').text, 'x');
    });

    test('INS.HEAD + INS.TAIL compose on an empty file', () {
      expect(apply('', 'INS.HEAD:\n+h\nINS.TAIL:\n+t').text, 'h\nt');
    });
  });

  group('applyHashlineEdits: firstChangedLine', () {
    test('tracks the earliest change across hunks', () {
      final result = apply('a\nb\nc\nd\ne', 'DEL 4\nSWAP 2.=2:\n+x');
      expect(result.firstChangedLine, 2);
    });

    test('INS.TAIL reports the inserted landing line', () {
      final result = apply('a\nb', 'INS.TAIL:\n+x');
      expect(result.firstChangedLine, 3);
    });
  });
}
