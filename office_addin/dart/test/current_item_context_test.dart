// CurrentItemContext (current_item_context.dart): the E1 decision table —
// announce on change, dedupe on the same item, re-announce on switch and
// on no-item, decorate prepends, a failed probe runs the turn bare.
// Issue #89.
import 'package:test/test.dart';

import '../src/current_item_context.dart';
import '../src/fake_office.dart';

void main() {
  group('lineFor', () {
    test('announces a new item once, silent on the same item id', () {
      final ctx = CurrentItemContext();
      final a = fakeMessage(itemId: 'A', subject: 'Invoice');
      final line = ctx.lineFor(a);
      expect(line, startsWith('[context] current item:'));
      expect(line, contains('Invoice'));
      expect(ctx.lineFor(a), isNull, reason: 'same item id: stay silent');
      // A fresh snapshot object with the SAME id is still unchanged —
      // the change-key is itemId.
      expect(ctx.lineFor(fakeMessage(itemId: 'A')), isNull);
    });

    test('item switch re-announces the new item', () {
      final ctx = CurrentItemContext();
      expect(
        ctx.lineFor(fakeMessage(itemId: 'A', subject: 'First')),
        isNotNull,
      );
      final line = ctx.lineFor(fakeMessage(itemId: 'B', subject: 'Second'));
      expect(line, contains('Second'));
      expect(ctx.lineFor(fakeMessage(itemId: 'B')), isNull);
    });

    test('no item announces "none open" once per change', () {
      final ctx = CurrentItemContext();
      expect(ctx.lineFor(null), '[context] current item: none open');
      expect(ctx.lineFor(null), isNull);
      // item → none is a change again.
      expect(ctx.lineFor(fakeMessage(itemId: 'A')), isNotNull);
      expect(ctx.lineFor(null), '[context] current item: none open');
      expect(ctx.lineFor(null), isNull);
    });

    test('line carries mode and sender, never body text', () {
      final ctx = CurrentItemContext();
      final line = ctx.lineFor(
        fakeDraft(itemId: 'D', subject: 'Reply: hello'),
      )!;
      expect(line, contains('Reply: hello'));
      expect(line, contains('compose draft'));
      expect(line, isNot(contains('<body')));
    });
  });

  group('decorate (E1)', () {
    test('prepends the line on a new item', () async {
      final ctx = CurrentItemContext();
      final out = await ctx.decorate(
        () async => fakeMessage(itemId: 'A', subject: 'Hello'),
        'user turn',
      );
      expect(out, startsWith('[context] current item: Hello'));
      expect(out.endsWith('user turn'), isTrue);
    });

    test('unchanged item: runs bare', () async {
      final ctx = CurrentItemContext();
      await ctx.decorate(() async => fakeMessage(itemId: 'A'), 'first');
      final again = await ctx.decorate(
        () async => fakeMessage(itemId: 'A'),
        'second',
      );
      expect(again, 'second');
    });

    test('failed probe never blocks the turn', () async {
      final ctx = CurrentItemContext();
      final out = await ctx.decorate(
        () async => throw StateError('facade down'),
        'user turn',
      );
      expect(out, 'user turn');
    });
  });
}
