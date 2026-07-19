import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('hashline types debug output', () {
    test('anchors, cursors, edits, and ranges render readably', () {
      expect(const HashlineAnchor(3).toString(), 'HashlineAnchor(3)');
      expect(const HashlineCursorBof().toString(), 'bof');
      expect(const HashlineCursorEof().toString(), 'eof');
      expect(
        const HashlineCursorBefore(HashlineAnchor(4)).toString(),
        'before(4)',
      );
      expect(
        const HashlineCursorAfter(HashlineAnchor(4)).toString(),
        'after(4)',
      );
      expect(
        const HashlineRange(
          start: HashlineAnchor(2),
          end: HashlineAnchor(5),
        ).toString(),
        '2.=5',
      );
      expect(
        const HashlineInsert(
          cursor: HashlineCursorBof(),
          text: 'x',
          lineNum: 1,
          index: 0,
        ).toString(),
        contains('insert(bof'),
      );
      expect(
        const HashlineDelete(
          anchor: HashlineAnchor(9),
          lineNum: 1,
          index: 0,
        ).toString(),
        'delete(9)',
      );
    });

    test('HashlineApplyResult carries warnings', () {
      const result = HashlineApplyResult(text: 't', warnings: ['w']);
      expect(result.warnings, ['w']);
      expect(result.firstChangedLine, isNull);
    });
  });
}
