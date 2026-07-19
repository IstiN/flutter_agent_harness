import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/hashline/messages.dart'
    show
        HashlineFormatException,
        formatLineRanges,
        missingSnapshotTagMessage,
        pathRecoveredFromTagMessage,
        unseenLinesMessage;
import 'package:test/test.dart';

void main() {
  group('HashlineFormatException', () {
    test('toString renders the message', () {
      const error = HashlineFormatException('boom');
      expect(error.toString(), 'boom');
      expect(error.message, 'boom');
    });
  });

  group('formatAnchoredContext', () {
    final fileLines = ['l1', 'l2', 'l3', 'l4', 'l5', 'l6', 'l7'];

    test('marks anchors and shows ±2 lines of context', () {
      expect(formatAnchoredContext([4], fileLines), [
        ' 2:l2',
        ' 3:l3',
        '*4:l4',
        ' 5:l5',
        ' 6:l6',
      ]);
    });

    test('clamps at file edges', () {
      expect(formatAnchoredContext([1], fileLines), [
        '*1:l1',
        ' 2:l2',
        ' 3:l3',
      ]);
      expect(formatAnchoredContext([7], fileLines), [
        ' 5:l5',
        ' 6:l6',
        '*7:l7',
      ]);
    });

    test('out-of-range anchors contribute nothing', () {
      expect(formatAnchoredContext([0, 99], fileLines), isEmpty);
    });

    test('separates non-adjacent runs with ...', () {
      expect(formatAnchoredContext([1, 7], fileLines), [
        '*1:l1',
        ' 2:l2',
        ' 3:l3',
        '...',
        ' 5:l5',
        ' 6:l6',
        '*7:l7',
      ]);
    });
  });

  group('formatLineRanges', () {
    test('compresses runs and dedups', () {
      expect(formatLineRanges([1, 2, 3, 7, 10, 11, 12, 3]), '1-3, 7, 10-12');
      expect(formatLineRanges([5]), '5');
      expect(formatLineRanges([]), '');
    });
  });

  group('unseenLinesMessage', () {
    test('empty reveal points at a ranged re-read', () {
      final message = unseenLinesMessage(
        'a.ts',
        [9],
        '1A2B',
        (lines: const [], truncated: false),
      );
      expect(message, contains('never displayed'));
      expect(message, contains('Re-read those lines first'));
    });

    test('truncated reveal keeps the re-read guidance', () {
      final message = unseenLinesMessage(
        'a.ts',
        [9],
        '1A2B',
        (lines: const [(line: 9, text: 'x')], truncated: true),
      );
      expect(message, contains('Preview of the actual file content'));
      expect(message, contains('exceeds the inline preview cap'));
    });

    test('full reveal says a straight retry succeeds', () {
      final message = unseenLinesMessage(
        'a.ts',
        [9],
        '1A2B',
        (lines: const [(line: 9, text: 'x')], truncated: false),
      );
      expect(message, contains('Actual file content at those lines'));
      expect(message, contains('straight retry now succeeds'));
    });
  });

  group('other messages', () {
    test('missingSnapshotTagMessage', () {
      expect(
        missingSnapshotTagMessage('a.ts'),
        allOf(
          contains('Missing hashline snapshot tag for a.ts'),
          contains('write'),
        ),
      );
    });

    test('pathRecoveredFromTagMessage', () {
      expect(
        pathRecoveredFromTagMessage('bare.ts', 'src/bare.ts', '1A2B'),
        allOf(
          contains('"bare.ts" does not exist'),
          contains('src/bare.ts'),
          contains('#1A2B'),
        ),
      );
    });
  });

  group('stripBom', () {
    test('strips a leading UTF-8 BOM', () {
      final result = stripBom('\uFEFFhello');
      expect(result.bom, '\uFEFF');
      expect(result.text, 'hello');
    });

    test('leaves BOM-less text untouched', () {
      final result = stripBom('hello');
      expect(result.bom, '');
      expect(result.text, 'hello');
    });
  });
}
