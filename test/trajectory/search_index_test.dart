import 'package:flutter_agent_harness/src/trajectory/search_index.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_layout.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_record.dart';
import 'package:test/test.dart';

TrajectoryGroupModel _group(
  List<TrajectoryRecord> cells, {
  TrajectoryGroupKind kind = TrajectoryGroupKind.message,
}) {
  return TrajectoryGroupModel(kind: kind, cells: cells);
}

TrajectoryTurnModel _turn(int? number, List<TrajectoryGroupModel> groups) {
  return TrajectoryTurnModel(turn: number, groups: groups);
}

TrajectoryUserRecord _user(String recordId, String text) {
  return TrajectoryUserRecord(
    index: 1,
    recordId: recordId,
    text: text,
    opensTurn: true,
  );
}

TrajectoryAssistantRecord _assistant(
  String recordId, {
  required int turn,
  bool requestOnly = false,
  String? thinkingDetail,
  String? outputDetail,
}) {
  return TrajectoryAssistantRecord(
    index: 2,
    recordId: recordId,
    messageId: recordId,
    turn: turn,
    step: 1,
    requestOnly: requestOnly,
    thinkingDetail: thinkingDetail,
    outputDetail: outputDetail,
  );
}

TrajectoryToolRecord _tool(
  String recordId, {
  String? parentCallId,
  String result = '',
}) {
  return TrajectoryToolRecord(
    index: 3,
    recordId: recordId,
    callId: recordId,
    parentCallId: parentCallId,
    name: 'grep',
    argsRaw: '{"pattern":"needle"}',
    result: result,
  );
}

TrajectorySearchIndex _indexWith(List<List<TrajectoryTurnModel>> layouts) {
  final index = TrajectorySearchIndex();
  index.update(layouts);
  return index;
}

void main() {
  group('search basics', () {
    final layouts = [
      [
        _turn(1, [
          _group([_user('u1', 'Hello World')]),
          _group([_assistant('a2', turn: 1)], kind: TrajectoryGroupKind.step),
        ]),
      ],
    ];
    final index = _indexWith(layouts);

    test('empty query returns null', () {
      expect(index.search(''), isNull);
    });

    test('whitespace-only query returns null', () {
      expect(index.search('   \t '), isNull);
    });

    test('match is case-insensitive substring', () {
      expect(index.search('HELLO'), {'u1'});
      expect(index.search('ello wor'), {'u1'});
    });

    test('multi-token query is an AND of substrings', () {
      expect(index.search('hello world'), {'u1'});
      expect(index.search('hello missing'), isEmpty);
    });

    test('kind name of message records is searchable as assistant', () {
      // Both records sit in a `message` group; the group kind name is indexed.
      expect(index.search('message'), {'u1', 'a2'});
      expect(index.search('step'), {'a2'});
      expect(index.search('turn 1'), {'u1', 'a2'});
    });
  });

  group('field coverage', () {
    final user = TrajectoryUserRecord(
      index: 1,
      recordId: 'u1',
      text: 'plain text',
      previewMarkdown: '# Rich **preview**',
      sourceBlocks: [
        TrajectorySourceBlock(
          type: 'image',
          content: 'screenshot bytes',
          attachmentName: 'shot.png',
        ),
      ],
      opensTurn: true,
      inputDetail: 'full user request',
    );
    final assistant = TrajectoryAssistantRecord(
      index: 2,
      recordId: 'a2',
      messageId: 'm2',
      turn: 1,
      step: 1,
      inputDetail: 'assistant payload',
      outputDetail: 'response body',
      thinkingDetail: 'secret reasoning',
      schemaDetail: 'tool schema json',
      sourceBlocks: [
        TrajectorySourceBlock(
          type: 'toolCall',
          content: 'bash args',
          callId: 'call-9',
          toolName: 'bash',
        ),
      ],
      partialBlocks: [
        const TrajectoryPartialBlock(type: 'text', content: 'streamed so far'),
      ],
    );
    final tool = TrajectoryToolRecord(
      index: 3,
      recordId: 't3',
      callId: 'call-77',
      parentCallId: null,
      name: 'grep',
      argsRaw: '{"pattern":"needle"}',
      result: 'raw result text',
      resultPreviewMarkdown: '**3** matches found',
    );
    final subtool = _tool(
      'st4',
      parentCallId: 'call-77',
      result: 'nested output',
    );
    final compacted = TrajectoryCompactedRecord(
      index: 4,
      recordId: 'cp5',
      text: 'bounded summary',
      summary: 'full compaction summary detail',
    );
    final layouts = [
      [
        _turn(1, [
          _group([user, assistant, tool, subtool]),
        ]),
        _turn(null, [
          _group([compacted], kind: TrajectoryGroupKind.compaction),
        ]),
      ],
    ];
    final index = _indexWith(layouts);

    test('user text and inputDetail', () {
      expect(index.search('plain text'), {'u1'});
      expect(index.search('full user request'), {'u1'});
    });

    test('preview markdown is stripped before indexing', () {
      expect(index.search('rich preview'), {'u1'});
      expect(index.search('text · rich'), {'u1'});
    });

    test('assistant details', () {
      expect(index.search('assistant payload'), {'a2'});
      expect(index.search('response body'), {'a2'});
      expect(index.search('secret reasoning'), {'a2'});
      expect(index.search('tool schema json'), {'a2'});
    });

    test('assistant block fields', () {
      expect(index.search('call-9'), {'a2'});
      expect(index.search('bash'), {'a2'});
      expect(index.search('streamed so far'), {'a2'});
    });

    test('tool result, call id, and result preview markdown', () {
      expect(index.search('raw result text'), {'t3'});
      expect(index.search('call-77'), {'t3'});
      expect(index.search('3 matches found'), {'t3'});
    });

    test('subtool kind is searchable', () {
      expect(index.search('subtool'), {'st4'});
      expect(index.search('nested output'), {'st4'});
    });

    test('compaction summary and between-turns section', () {
      expect(index.search('full compaction summary detail'), {'cp5'});
      expect(index.search('between turns'), {'cp5'});
      expect(index.search('compaction'), {'cp5'});
    });
  });

  group('incremental update', () {
    test('identity short-circuit returns false', () {
      final index = TrajectorySearchIndex();
      final layouts = <List<TrajectoryTurnModel>>[
        [
          _turn(1, [
            _group([_user('u1', 'alpha')]),
          ]),
        ],
      ];
      expect(index.update(layouts), isTrue);
      expect(index.update(layouts), isFalse);
    });

    test(
      'only the changed record is re-indexed; unchanged stay searchable',
      () {
        final index = TrajectorySearchIndex();
        final user = _user('u1', 'stable anchor');
        final assistantV1 = _assistant(
          'a2',
          turn: 1,
          thinkingDetail: 'v1 thought',
        );
        final layoutsV1 = [
          [
            _turn(1, [
              _group([user]),
              _group([assistantV1]),
            ]),
          ],
        ];
        expect(index.update(layoutsV1), isTrue);

        final assistantV2 = _assistant(
          'a2',
          turn: 1,
          thinkingDetail: 'v2 thought',
        );
        final layoutsV2 = [
          [
            _turn(1, [
              _group([user]),
              _group([assistantV2]),
            ]),
          ],
        ];
        expect(index.update(layoutsV2), isTrue);
        expect(index.search('v1 thought'), isEmpty);
        expect(index.search('v2 thought'), {'a2'});
        expect(index.search('stable anchor'), {'u1'});
      },
    );

    test('tombstone eviction when a record disappears', () {
      final index = TrajectorySearchIndex();
      final user = _user('u1', 'stays put');
      final ghost = _user('ghost', 'phantom token');
      expect(
        index.update([
          [
            _turn(1, [
              _group([user, ghost]),
            ]),
          ],
        ]),
        isTrue,
      );
      expect(index.search('phantom token'), {'ghost'});

      expect(
        index.update([
          [
            _turn(1, [
              _group([user]),
            ]),
          ],
        ]),
        isTrue,
      );
      expect(index.search('phantom token'), isEmpty);
      expect(index.search('stays put'), {'u1'});
    });

    test('request-only separators are not indexed', () {
      final index = TrajectorySearchIndex();
      index.update([
        [
          _turn(1, [
            _group([
              _assistant(
                'req-only',
                turn: 1,
                requestOnly: true,
                outputDetail: 'unseen marker',
              ),
            ]),
          ]),
        ],
      ]);
      expect(index.search('unseen marker'), isEmpty);
    });

    test('index stays bounded across generations', () {
      final index = TrajectorySearchIndex();
      for (var generation = 0; generation < 50; generation++) {
        expect(
          index.update([
            [
              _turn(1, [
                _group([_user('gen-$generation', 'token $generation unique')]),
              ]),
            ],
          ]),
          isTrue,
        );
      }
      expect(index.search('token 0 unique'), isEmpty);
      expect(index.search('token 49 unique'), {'gen-49'});
    });
  });

  group('ThrottledTrajectorySearchIndex', () {
    test('first update is immediate and searchable', () {
      final throttled = ThrottledTrajectorySearchIndex(
        throttle: const Duration(milliseconds: 40),
      );
      expect(
        throttled.update([
          [
            _turn(1, [
              _group([_user('u1', 'immediate hit')]),
            ]),
          ],
        ]),
        isTrue,
      );
      expect(throttled.search('immediate hit'), {'u1'});
      throttled.dispose();
    });

    test(
      'rapid updates coalesce into a trailing flush of the latest layouts',
      () async {
        final throttled = ThrottledTrajectorySearchIndex(
          throttle: const Duration(milliseconds: 40),
        );
        final layoutsV1 = [
          [
            _turn(1, [
              _group([_user('u1', 'first version')]),
            ]),
          ],
        ];
        expect(throttled.update(layoutsV1), isTrue);

        final layoutsV2 = [
          [
            _turn(1, [
              _group([
                _user('u1', 'first version'),
                _user('u2', 'second version'),
              ]),
            ]),
          ],
        ];
        expect(throttled.update(layoutsV2), isFalse);
        expect(throttled.search('second version'), isEmpty);

        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(throttled.search('second version'), {'u2'});
        expect(throttled.search('first version'), {'u1'});
        throttled.dispose();
      },
    );

    test('update after an idle window is immediate again', () async {
      final throttled = ThrottledTrajectorySearchIndex(
        throttle: const Duration(milliseconds: 40),
      );
      expect(
        throttled.update([
          [
            _turn(1, [
              _group([_user('u1', 'first')]),
            ]),
          ],
        ]),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        throttled.update([
          [
            _turn(1, [
              _group([_user('u1', 'first'), _user('u2', 'later')]),
            ]),
          ],
        ]),
        isTrue,
      );
      expect(throttled.search('later'), {'u2'});
      throttled.dispose();
    });

    test('dispose cancels the pending trailing flush', () async {
      final throttled = ThrottledTrajectorySearchIndex(
        throttle: const Duration(milliseconds: 40),
      );
      expect(
        throttled.update([
          [
            _turn(1, [
              _group([_user('u1', 'flushed')]),
            ]),
          ],
        ]),
        isTrue,
      );
      expect(
        throttled.update([
          [
            _turn(1, [
              _group([_user('u1', 'flushed'), _user('u2', 'pending')]),
            ]),
          ],
        ]),
        isFalse,
      );
      throttled.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(throttled.search('pending'), isEmpty);
      expect(throttled.search('flushed'), {'u1'});
    });
  });

  group('ThrottledTrajectorySearchIndex.onFlushed (P3-10)', () {
    test('fires only when a trailing flush lands a parked update', () async {
      var flushes = 0;
      final index = ThrottledTrajectorySearchIndex(
        throttle: const Duration(milliseconds: 20),
        onFlushed: () => flushes++,
      );
      addTearDown(index.dispose);

      final first = _turn(1, [_group([_user('u1', 'hello')])]);
      expect(index.update([[first]]), isTrue);
      // The immediate flush inside update() never fires the hook.
      expect(flushes, 0);
      expect(index.search('hello'), {'u1'});

      // A second update inside the throttle window parks; the parked
      // version is invisible until the trailing flush lands.
      final second = _turn(1, [
        _group([_user('u1', 'hello'), _user('u2', 'world')]),
      ]);
      expect(index.update([[second]]), isFalse);
      expect(index.search('world'), isEmpty);

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (flushes == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(flushes, 1);
      expect(index.search('world'), {'u2'});
    });


  });
}
