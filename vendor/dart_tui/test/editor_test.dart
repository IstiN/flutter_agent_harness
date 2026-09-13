// LineEditor unit tests (issue #275, AC3/UT-editor): kill-ring capacity ≥ 8
// with round-robin, yank rotation, grouped undo (word coalescing, no
// per-char entries inside a word burst), undo cap, transpose, withBuffer.
import 'package:dart_tui/src/editor.dart';
import 'package:test/test.dart';

/// An editor with [text] in the buffer and the caret at the end, so
/// kill-to-line-end has something ahead of it to kill.
LineEditor atEnd(String text) =>
    LineEditor(text).withBuffer(LineBuffer(text, text.length));

void main() {
  group('kill-ring', () {
    test('ctrl-w kills the word before the cursor onto the ring', () {
      final next = atEnd('hello world').killWordBefore();
      expect(next.text, 'hello ');
      expect(next.canYank, isTrue);
      expect(next.yank().text, 'hello world');
    });

    test('ring of 8: the ninth kill evicts the oldest entry', () {
      var ed = const LineEditor.empty();
      // Nine kill rounds; round i types a distinct word and kills it.
      for (var i = 0; i < 9; i++) {
        ed = ed.insert('w$i').killToLineStart();
      }
      expect(ed.killRing.length, 8);
      // The oldest ('w0') is gone; the most recent ('w8') is the head.
      expect(ed.killRing, isNot(contains('w0')));
      expect(ed.killRing.last, 'w8');
      expect(ed.yank().text, 'w8');
    });

    test('killRingSize is at least 8 (issue requirement)', () {
      expect(LineEditor.killRingSize, greaterThanOrEqualTo(8));
    });

    test('ctrl-y yank inserts the most recent kill', () {
      final ed = atEnd('foo').killToLineStart().yank();
      expect(ed.text, 'foo');
    });

    test('consecutive yanks rotate to older ring entries', () {
      final ed = atEnd('one')
          .killToLineStart() // ring: [one]
          .insert('two')
          .killToLineStart(); // ring: [one, two]
      final y1 = ed.yank();
      expect(y1.text, 'two');
      final y2 = y1.yankOlder();
      expect(y2.text, 'one');
    });

    test('yankOlder replaces the previous yank instead of appending', () {
      final ed = atEnd('ab')
          .killToLineStart() // ring: [ab]
          .insert('cd')
          .killToLineStart(); // ring: [ab, cd]
      final y1 = ed.yank();
      expect(y1.text, 'cd');
      final y2 = y1.yankOlder();
      expect(y2.text, 'ab');
    });

    test('ctrl-u and ctrl-k both land on the ring', () {
      final ed = LineEditor(
        'kill me',
      ).withBuffer(const LineBuffer('kill me', 4)).killToLineStart();
      expect(ed.text, ' me');
      final yanked = ed.yank();
      expect(yanked.text, 'kill me');
      expect(atEnd(' me').killToLineStart().yank().text, ' me');
    });
  });

  group('grouped undo', () {
    test('a single insert burst undoes as one step', () {
      final ed = const LineEditor.empty().insert('hello');
      final undone = ed.undo();
      expect(undone.text, '');
      expect(undone.undoStack, isEmpty);
    });

    test('per-key typing inside a word undoes in one step', () {
      var ed = const LineEditor.empty();
      for (final ch in 'hello'.split('')) {
        ed = ed.insert(ch);
      }
      // No undo entry per single char inside the word burst: one undo
      // walks back to before the whole word (the anchor step stays on the
      // stack but restores the same pre-word buffer).
      final once = ed.undo();
      expect(once.text, '');
      expect(once.undo().text, '');
    });

    test('two words undo separately across the space boundary', () {
      var ed = const LineEditor.empty();
      for (final ch in 'hello world'.split('')) {
        ed = ed.insert(ch);
      }
      final once = ed.undo();
      expect(once.text, 'hello '); // the trailing word goes first
      final twice = once.undo();
      expect(twice.text, 'hello'); // the word-start anchor is its own step
      expect(twice.undo().text, '');
    });

    test('kills group into one undo (kill then undo restores the line)', () {
      final ed = atEnd('data').killToLineStart();
      expect(ed.undo().text, 'data');
    });

    test('undo stack caps at 100 grouped steps', () {
      var ed = const LineEditor.empty();
      for (var i = 0; i < 150; i++) {
        ed = ed.insert('x$i ').killToLineStart();
      }
      // Two groups per round (typed run + kill) × 150 rounds caps.
      expect(ed.undoStack.length, lessThanOrEqualTo(LineEditor.undoLimit));
      // Undoing all the way still terminates at the empty buffer.
      var cur = ed;
      var guard = 0;
      while (cur.canUndo && guard++ < 500) {
        cur = cur.undo();
      }
      expect(cur.text, '');
      expect(cur.undoStack, isEmpty);
    });
  });

  group('editing basics', () {
    test('transpose at end-of-line swaps the last two chars', () {
      expect(atEnd('helo').transpose().text, 'heol');
    });

    test('transpose mid-line swaps the chars around the caret', () {
      final ed = LineEditor('ab').withBuffer(const LineBuffer('ab', 1));
      expect(ed.transpose().text, 'ba');
    });

    test('backspace deletes one char and pushes it on the ring', () {
      final ed = atEnd('ab').backspace();
      expect(ed.text, 'a');
      expect(ed.yank().text, 'ab');
    });

    test('withBuffer preserves ring and undo, replaces text+cursor', () {
      final ed = atEnd('temp').killToLineStart();
      final moved = ed.withBuffer(const LineBuffer('recalled', 8));
      expect(moved.text, 'recalled');
      expect(moved.cursor, 8);
      expect(moved.canYank, isTrue); // ring survived the set
      expect(moved.undo().text, 'temp'); // undo history survived too
    });

    test('cursor motion rides withBuffer untouched', () {
      final ed = LineEditor('word', 4).withBuffer(const LineBuffer('word', 0));
      expect(ed.cursor, 0);
      expect(ed.undoStack, isEmpty); // motion is not an edit
    });

    test('value semantics: equal text+cursor, independent history', () {
      final a = LineEditor('x').insert('y');
      final b = LineEditor('x').insert('y');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });
}
