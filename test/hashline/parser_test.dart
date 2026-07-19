import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

HashlineParseResult parse(String diff) => parseHashlinePatch(diff);

void main() {
  group('hashline parser: SWAP', () {
    test('single-line replace lowers to replacement inserts + one delete', () {
      final result = parse('SWAP 2.=2:\n+new line');
      expect(result.edits, hasLength(2));
      final insert = result.edits[0] as HashlineInsert;
      expect(insert.replacement, isTrue);
      expect(insert.text, 'new line');
      expect(insert.cursor, isA<HashlineCursorBefore>());
      expect((insert.cursor as HashlineCursorBefore).anchor.line, 2);
      final delete = result.edits[1] as HashlineDelete;
      expect(delete.anchor.line, 2);
    });

    test('range replace with multi-line body keeps parse order', () {
      final result = parse('SWAP 2.=4:\n+a\n+b\n+c');
      expect(result.edits, hasLength(6));
      final texts = [
        for (final e in result.edits.take(3)) (e as HashlineInsert).text,
      ];
      expect(texts, ['a', 'b', 'c']);
      final deletes = [
        for (final e in result.edits.skip(3)) (e as HashlineDelete).anchor.line,
      ];
      expect(deletes, [2, 3, 4]);
      // Indices are strictly increasing in patch order.
      for (var i = 1; i < result.edits.length; i++) {
        expect(result.edits[i].index, greaterThan(result.edits[i - 1].index));
      }
    });

    test('bare range separator variants parse', () {
      for (final header in [
        'SWAP 2.=4:',
        'SWAP 2..4:',
        'SWAP 2-4:',
        'SWAP 2,4:',
        'SWAP 2 4:',
      ]) {
        final result = parse('$header\n+x');
        final delete = result.edits.last as HashlineDelete;
        expect(delete.anchor.line, 4, reason: header);
      }
    });

    test('stray dot before colon is tolerated (GLM 5.2 shape)', () {
      final result = parse('SWAP 2.=3.:\n+x');
      expect(result.edits, hasLength(3)); // 1 insert + deletes of lines 2,3
    });

    test('permuted :=: / =: trailers are tolerated', () {
      expect(parse('SWAP 1.=1:=:\n+x').edits, hasLength(2));
      expect(parse('SWAP 1.=1=:\n+x').edits, hasLength(2));
    });

    test('empty SWAP body lowers to a pure range deletion (omp semantics)', () {
      final result = parse('SWAP 2.=3:\nINS.HEAD:\n+keep');
      final deletes = result.edits.whereType<HashlineDelete>().toList();
      expect([for (final d in deletes) d.anchor.line], [2, 3]);
      expect(
        (result.edits.last as HashlineInsert).cursor,
        isA<HashlineCursorBof>(),
      );
    });

    test('reversed range is rejected', () {
      expect(
        () => parse('SWAP 5.=2:\n+x'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('ends before it starts'),
          ),
        ),
      );
    });
  });

  group('hashline parser: DEL', () {
    test('single line and range', () {
      final single = parse('DEL 3');
      expect((single.edits.single as HashlineDelete).anchor.line, 3);
      final range = parse('DEL 2.=4');
      expect(
        [for (final e in range.edits) (e as HashlineDelete).anchor.line],
        [2, 3, 4],
      );
    });

    test('DEL with a trailing colon is contamination, not a hunk', () {
      expect(
        () => parse('DEL 3:\n+x'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('has no colon and no body'),
          ),
        ),
      );
    });

    test('DEL with a body row is rejected', () {
      expect(
        () => parse('DEL 3\n+x'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('does not take body rows'),
          ),
        ),
      );
    });

    test('overlapping deletes from two hunks are rejected', () {
      expect(
        () => parse('DEL 2.=4\nDEL 4.=6'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('already targeted by another hunk'),
          ),
        ),
      );
    });
  });

  group('hashline parser: INS', () {
    test('INS.PRE / INS.POST anchor on the named line', () {
      final pre = parse('INS.PRE 5:\n+x');
      final preInsert = pre.edits.single as HashlineInsert;
      expect(preInsert.replacement, isFalse);
      expect((preInsert.cursor as HashlineCursorBefore).anchor.line, 5);

      final post = parse('INS.POST 5:\n+x');
      final postInsert = post.edits.single as HashlineInsert;
      expect((postInsert.cursor as HashlineCursorAfter).anchor.line, 5);
    });

    test('INS.HEAD / INS.TAIL', () {
      final head = parse('INS.HEAD:\n+x');
      expect(
        (head.edits.single as HashlineInsert).cursor,
        isA<HashlineCursorBof>(),
      );
      final tail = parse('INS.TAIL:\n+x');
      expect(
        (tail.edits.single as HashlineInsert).cursor,
        isA<HashlineCursorEof>(),
      );
    });

    test('INS without a body is rejected', () {
      expect(
        () => parse('INS.POST 5:'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('needs at least one'),
          ),
        ),
      );
    });

    test('stray dot before colon is tolerated (INS.POST 2.:)', () {
      expect(parse('INS.POST 2.:\n+x').edits, hasLength(1));
    });
  });

  group('hashline parser: body rows', () {
    test('`+` alone adds a blank line', () {
      final result = parse('INS.HEAD:\n+');
      expect((result.edits.single as HashlineInsert).text, '');
    });

    test('literal rows keep leading whitespace and sigils verbatim', () {
      final result = parse('INS.HEAD:\n+    indented\n++ plus\n+- minus');
      expect(
        [for (final e in result.edits) (e as HashlineInsert).text],
        ['    indented', '+ plus', '- minus'],
      );
    });

    test('a `-` body row is rejected with the Markdown hint', () {
      expect(
        () => parse('INS.HEAD:\n- item'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('`-` rows are not valid'),
          ),
        ),
      );
    });

    test('bare rows are auto-prefixed with a warning', () {
      final result = parse('SWAP 1.=1:\nbare row');
      expect(result.warnings, contains(bareBodyAutoPipedWarning));
      expect((result.edits[0] as HashlineInsert).text, 'bare row');
    });

    test(
      'interior blank rows are body content; trailing blanks are layout',
      () {
        final result = parse('INS.HEAD:\n+a\n\n\n+b\n\n\nDEL 1');
        final texts = [
          for (final e in result.edits.whereType<HashlineInsert>()) e.text,
        ];
        expect(texts, ['a', '', '', 'b']);
      },
    );

    test('uniform N: prefixes on bare rows are stripped (read paste)', () {
      final result = parse('SWAP 1.=2:\n1:alpha\n2:beta');
      expect(
        [for (final e in result.edits.whereType<HashlineInsert>()) e.text],
        ['alpha', 'beta'],
      );
    });

    test('mixed bare rows keep their digits: text (genuine content)', () {
      final result = parse('SWAP 1.=2:\n12:30 meeting\nplain row');
      expect(
        [for (final e in result.edits.whereType<HashlineInsert>()) e.text],
        ['12:30 meeting', 'plain row'],
      );
    });

    test('numeric-keyed dict bodies are not stripped', () {
      final result = parse('SWAP 1.=2:\n1: "one",\n2: "two",');
      expect(
        [for (final e in result.edits.whereType<HashlineInsert>()) e.text],
        ['1: "one",', '2: "two",'],
      );
    });

    test('payload without a preceding hunk header is rejected', () {
      expect(
        () => parse('+orphan'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('no preceding hunk header'),
          ),
        ),
      );
    });

    test('comment lines between sections are skippable', () {
      final result = parse('# a comment\nDEL 1');
      expect(result.edits, hasLength(1));
    });
  });

  group('hashline parser: contamination detection', () {
    test('apply_patch sentinels are rejected with guidance', () {
      expect(
        () => parse('*** Update File: foo.ts\nSWAP 1.=1:\n+x'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('apply_patch sentinel'),
          ),
        ),
      );
    });

    test('unified-diff hunk headers are rejected', () {
      expect(
        () => parse('@@ -1,2 +1,2 @@\n+x'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('unified-diff hunk header'),
          ),
        ),
      );
    });

    test('bare @@ brackets are rejected', () {
      expect(
        () => parse('@@ something @@\nSWAP 1.=1:\n+x'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('@@'),
          ),
        ),
      );
    });

    test('a bare line number needs a verb', () {
      expect(
        () => parse('42\nSWAP 1.=1:\n+x'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('hunk headers need a verb'),
          ),
        ),
      );
    });

    test('a bare range needs a verb', () {
      expect(
        () => parse('2-4\n+x'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('bare range hunk header'),
          ),
        ),
      );
    });
  });

  group('hashline parser: unsupported ops (recognized, rejected)', () {
    test('REM', () {
      expect(
        () => parse('REM'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('`REM` (whole-file delete) is not supported'),
          ),
        ),
      );
    });

    test('MV dest', () {
      expect(
        () => parse('MV other.ts'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('`MV` (move/rename) is not supported'),
          ),
        ),
      );
    });

    test('SWAP.BLK / DEL.BLK / INS.BLK.POST', () {
      for (final op in [
        'SWAP.BLK 2:\n+x',
        'DEL.BLK 2',
        'INS.BLK.POST 2:\n+x',
      ]) {
        expect(
          () => parse(op),
          throwsA(
            isA<HashlineFormatException>().having(
              (e) => e.message,
              'message',
              contains('no block resolver configured'),
            ),
          ),
          reason: op,
        );
      }
    });
  });

  group('hashline parser: envelope and line splitting', () {
    test('envelope markers are consumed; End Patch terminates', () {
      final result = parse(
        '*** Begin Patch\nSWAP 1.=1:\n+x\n*** End Patch\nDEL 2',
      );
      expect(result.edits, hasLength(2));
    });

    test('abort sentinel terminates parsing', () {
      final result = parse('SWAP 1.=1:\n+x\n*** Abort\nDEL 2');
      expect(result.edits, hasLength(2));
    });

    test('CRLF input is split cleanly', () {
      final result = parse('SWAP 1.=1:\r\n+x\r\n');
      expect((result.edits[0] as HashlineInsert).text, 'x');
    });
  });

  group('hashline parser: edge cases', () {
    test('a bracket line inside a body flushes the pending hunk', () {
      final result = parse('INS.HEAD:\n+x\n[looks-like-a-header]\nDEL 1');
      expect(result.edits, hasLength(2));
      expect((result.edits[0] as HashlineInsert).text, 'x');
      expect((result.edits[1] as HashlineDelete).anchor.line, 1);
    });

    test('whitespace-only rows inside a body count as blank rows', () {
      final result = parse('INS.HEAD:\n+a\n   \n+b');
      expect(
        [for (final e in result.edits) (e as HashlineInsert).text],
        ['a', '   ', 'b'],
      );
    });

    test('a whitespace-only line outside a hunk is ignored', () {
      expect(parse('   \nDEL 1').edits, hasLength(1));
    });

    test('a plain garbage line outside a hunk is rejected', () {
      expect(
        () => parse('garbage line'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('no preceding hunk header'),
          ),
        ),
      );
    });

    test('a comment line followed by payload re-surfaces as an error', () {
      expect(
        () => parse('# a comment\n+orphan'),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('no preceding hunk header'),
          ),
        ),
      );
    });

    test('long contamination lines are preview-truncated', () {
      final longSentinel = '*** Update File: ${'x' * 60}';
      expect(
        () => parse(longSentinel),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('…'),
          ),
        ),
      );
      final longBrackets = '@@ ${'y' * 60}';
      expect(
        () => parse(longBrackets),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('…'),
          ),
        ),
      );
    });
  });
}
