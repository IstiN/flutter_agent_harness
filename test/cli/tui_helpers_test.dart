import 'package:flutter_agent_harness/src/cli/tui_helpers.dart';
import 'package:test/test.dart';

void main() {
  group('drainQueueRounds', () {
    test('an empty queue ends immediately', () async {
      var drains = 0;
      await drainQueueRounds(
        drain: () async {
          drains++;
          return const [];
        },
        runRound: (_) async => fail('no round expected'),
        abortRequested: () => false,
        onDropped: () => fail('nothing to drop'),
      );
      expect(drains, 1);
    });

    test(
      'runs each drained batch as a round until the queue is empty',
      () async {
        final batches = [
          ['a'],
          ['b', 'c'],
          <String>[],
        ];
        final ran = <List<String>>[];
        await drainQueueRounds(
          drain: () async => batches.removeAt(0),
          runRound: (queued) async => ran.add(queued),
          abortRequested: () => false,
          onDropped: () => fail('nothing to drop'),
        );
        expect(ran, [
          ['a'],
          ['b', 'c'],
        ]);
      },
    );

    test('an abort drops the pending batch without running it', () async {
      var batches = [
        ['a'],
      ];
      var dropped = 0;
      await drainQueueRounds(
        drain: () async => batches.removeAt(0),
        runRound: (_) async => fail('aborted round must not run'),
        abortRequested: () => true,
        onDropped: () => dropped++,
      );
      expect(dropped, 1);
    });

    test('the round cap drops a self-sustaining queue', () async {
      final ran = <List<String>>[];
      var dropped = 0;
      await drainQueueRounds(
        drain: () async => ['x'],
        runRound: (queued) async => ran.add(queued),
        abortRequested: () => false,
        onDropped: () => dropped++,
        maxRounds: 3,
      );
      expect(ran, hasLength(3));
      expect(dropped, 1);
    });
  });

  group('listItemAt', () {
    test('returns the element for a valid index', () {
      expect(listItemAt(['a', 'b', 'c'], 1), 'b');
      expect(listItemAt(['a', 'b', 'c'], 0), 'a');
      expect(listItemAt(['a', 'b', 'c'], 2), 'c');
    });

    test('returns null for out-of-bounds and null lists', () {
      expect(listItemAt(['a'], -1), isNull);
      expect(listItemAt(['a'], 1), isNull);
      expect(listItemAt(<String>[], 0), isNull);
      expect(listItemAt(null, 0), isNull);
    });
  });
}
