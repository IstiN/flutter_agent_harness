import 'package:flutter_agent_harness/src/cli/tui_helpers.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/types.dart';
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
        onDropped: (dropped) => fail('nothing to drop: $dropped'),
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
          onDropped: (dropped) => fail('nothing to drop: $dropped'),
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
      final dropped = <String>[];
      await drainQueueRounds(
        drain: () async => batches.removeAt(0),
        runRound: (_) async => fail('aborted round must not run'),
        abortRequested: () => true,
        onDropped: dropped.addAll,
      );
      expect(dropped, ['a']);
    });

    test('the round cap drops a self-sustaining queue', () async {
      final ran = <List<String>>[];
      final dropped = <String>[];
      await drainQueueRounds(
        drain: () async => ['x'],
        runRound: (queued) async => ran.add(queued),
        abortRequested: () => false,
        onDropped: dropped.addAll,
        maxRounds: 3,
      );
      expect(ran, hasLength(3));
      expect(dropped, ['x']);
    });
  });

  group('runQueuedTurns', () {
    test('runs each message and waits for it to settle', () async {
      final handled = <String>[];
      var settles = 0;
      await runQueuedTurns(
        queued: const ['a', 'b', 'c'],
        handle: (msg) async => handled.add(msg),
        settled: () async => settles++,
        abortRequested: () => false,
      );
      expect(handled, ['a', 'b', 'c']);
      expect(settles, 3);
    });

    test(
      'an abort discards the rest of the queue after the running turn',
      () async {
        final handled = <String>[];
        var aborts = 0;
        await runQueuedTurns(
          queued: const ['a', 'b', 'c'],
          handle: (msg) async {
            handled.add(msg);
            aborts++;
          },
          settled: () async {},
          abortRequested: () => aborts >= 2,
        );
        expect(handled, ['a', 'b']);
      },
    );
  });

  group('resolveLeftoverSteering', () {
    test('returns null when nothing is queued', () {
      final outcome = resolveLeftoverSteering(
        drain: () => const [],
        abortRequested: false,
      );
      expect(outcome, isNull);
    });

    test('runs non-empty steering joined as the next turn prompt', () {
      final outcome = resolveLeftoverSteering(
        drain: () => [UserMessage.text('first'), UserMessage.text('second')],
        abortRequested: false,
      );
      expect(outcome, isNotNull);
      expect(outcome!.run, isTrue);
      expect(outcome.texts, ['first', 'second']);
    });

    test('an abort turns the leftover into a loud drop', () {
      final outcome = resolveLeftoverSteering(
        drain: () => [UserMessage.text('never answered')],
        abortRequested: true,
      );
      expect(outcome, isNotNull);
      expect(outcome!.run, isFalse);
      expect(outcome.texts, ['never answered']);
    });

    test('non-text and blank messages are skipped', () {
      final outcome = resolveLeftoverSteering(
        drain: () => [
          UserMessage.text('   '),
          UserMessage(
            content: const [ImageContent(data: 'aGk=', mimeType: 'image/png')],
            timestamp: DateTime.utc(2026),
          ),
        ],
        abortRequested: false,
      );
      expect(outcome, isNull);
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
