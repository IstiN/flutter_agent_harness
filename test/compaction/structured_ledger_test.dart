// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #148 — the judge-facing ledger: kinds, exemption tagging of real
/// user turns, pair-atomic groups, and the validation funnel that turns
/// judge picks into safe record ids.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/ledger.dart';
import 'package:flutter_agent_harness/src/compaction/structured/judge.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:test/test.dart';

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) {
  return AssistantMessage(
    content: [
      TextContent(text: text),
      if (calls != null) ...calls,
    ],
    api: 'anthropic-messages',
    provider: 'p',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

ToolResultMessage _result(String callId, String name, String text) {
  return ToolResultMessage(
    toolCallId: callId,
    toolName: name,
    content: [TextContent(text: text)],
    isError: false,
    timestamp: DateTime.utc(2026),
  );
}

void main() {
  test('ledger kinds, exemption tags, and pair groups', () {
    final records = <SessionRecord>[
      MessageRecord(
        id: 'r1',
        parentId: null,
        timestamp: DateTime.utc(2026),
        message: UserMessage.text('fix the login crash'),
      ),
      MessageRecord(
        id: 'r2',
        parentId: 'r1',
        timestamp: DateTime.utc(2026),
        message: _assistant(
          'looking',
          calls: [ToolCall(id: 'c1', name: 'read', arguments: {})],
        ),
      ),
      MessageRecord(
        id: 'r3',
        parentId: 'r2',
        timestamp: DateTime.utc(2026),
        message: _result('c1', 'read', 'x' * 200),
      ),
      MessageRecord(
        id: 'r4',
        parentId: 'r3',
        timestamp: DateTime.utc(2026),
        message: UserMessage.text(
          '<system-notice>tool detached</system-notice>',
        ),
      ),
    ];
    final seqs = RecordSeqIndex(records);
    final ledger = buildContextLedger(visiblePath: records, seqs: seqs);

    final lines = ledger.render().split('\n');
    expect(lines, hasLength(4));
    // Real user turn: exempt, previewed, first line number is 2 (header
    // is line 1).
    expect(lines[0], startsWith('[2] user·exempt ~'));
    expect(lines[0], contains('fix the login crash'));
    // Tool-call carrier names its tools.
    expect(lines[1], startsWith('[3] assistant-TOOLCALL(read)'));
    // Result names the tool that produced it.
    expect(lines[2], startsWith('[4] toolResult(read)'));
    // System notices are hideable data, not user asks.
    expect(lines[3], startsWith('[5] notice ~'));

    // Pair group: carrier + result hide together.
    final group = ledger.groupOf('r2');
    expect(group, {'r2', 'r3'});
    expect(ledger.groupOf('r3'), same(group));
    // A groupless record hides alone.
    expect(ledger.groupOf('r1'), {'r1'});
  });

  test('agent mail and branch summaries classify as notices', () {
    final records = <SessionRecord>[
      MessageRecord(
        id: 'r1',
        parentId: null,
        timestamp: DateTime.utc(2026),
        message: UserMessage.text('from subagent: done scanning'),
      ),
    ];
    final ledger = buildContextLedger(
      visiblePath: records,
      seqs: RecordSeqIndex(records),
    );
    expect(ledger.entries.single.exempt, isFalse);
    expect(ledger.entries.single.kind, 'notice');
  });

  test('parseHidePicks: arrays, ranges, junk, no-ops', () {
    expect(parseHidePicks('["3", "7-8"]'), {3, 7, 8});
    expect(parseHidePicks('[1, 2, 3]'), {1, 2, 3});
    expect(parseHidePicks('```json\n["12"]\n```'), {12});
    expect(parseHidePicks('[]'), isEmpty);
    expect(parseHidePicks('I would hide nothing'), isNull);
    expect(parseHidePicks('{"ids": []}'), isEmpty); // [] found -> no-op
    expect(parseHidePicks('["abc"]'), isEmpty);
    // A degenerate range that would explode is ignored, not thrown.
    expect(parseHidePicks('["9-9"]'), {9});
    expect(parseHidePicks('[0, -3]'), isEmpty); // non-positive ints drop
    expect(parseHidePicks('[1.5, null, true]'), isEmpty); // non-int/string
  });

  test('validateHidePicks strips unknown, exempt, and protected ids', () {
    final records = <SessionRecord>[];
    void add(Message message) {
      records.add(
        MessageRecord(
          id: 'r${records.length + 1}',
          parentId: records.isEmpty ? null : 'r${records.length}',
          timestamp: DateTime.utc(2026),
          message: message,
        ),
      );
    }

    add(UserMessage.text('ask one'));
    add(
      _assistant(
        'a',
        calls: [ToolCall(id: 'c1', name: 'bash', arguments: {})],
      ),
    );
    add(_result('c1', 'bash', 'out'));
    for (var i = 0; i < 9; i++) {
      add(_assistant('filler $i'));
    }
    final ledger = buildContextLedger(
      visiblePath: records,
      seqs: RecordSeqIndex(records),
    );

    // Unknown ids (hallucinated), the exempt user turn, and the protected
    // tail entries all drop; the picked result snaps outward to its
    // whole pair group.
    final picks = {
      99, // unknown
      2, // exempt user
      4, // bash result (inside the protected tail: last 8)
      5, // assistant right after the pair
    };
    final ids = validateHidePicks(picks, ledger, protectLastN: 8);
    // Picks 4 (bash result) and 5 (notice) sit outside the last-8 tail
    // (r5..r12 of 12 records); the result snaps to its whole pair group.
    expect(ids, {'r2', 'r3', 'r4'});

    final idsLoose = validateHidePicks({4}, ledger, protectLastN: 2);
    // With a tiny protected tail the pair group survives — snapped.
    expect(idsLoose, containsAll(['r2', 'r3']));

    // Snapping outward also protects a call whose result is protected:
    // picking the carrier alone never splits the pair. With a 10-entry
    // protected tail covering the result (r3) but not the carrier's
    // neighbors, the whole group drops.
    final snapCarrier = validateHidePicks({3}, ledger, protectLastN: 10);
    expect(snapCarrier, isEmpty);
  });
  group('streamFunctionHideJudge', () {
    AssistantMessage msg(
      String text, {
      StopReason reason = StopReason.stop,
      List<ContentBlock> content = const [],
    }) => AssistantMessage(
      content: content.isNotEmpty ? content : [TextContent(text: text)],
      api: 'anthropic-messages',
      provider: 'p',
      model: 'm1',
      usage: Usage.zero,
      stopReason: reason,
      timestamp: DateTime.utc(2026),
    );

    AssistantMessageEventStream streamOf(List<AssistantMessageEvent> events) {
      final stream = AssistantMessageEventStream();
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
      return stream;
    }

    final model = Model(
      id: 'm1',
      name: 'm1',
      api: 'anthropic-messages',
      provider: 'p',
      baseUrl: 'http://localhost:1',
      contextWindow: 8000,
      maxTokens: 4096,
    );

    test('joins text blocks; routes with fresh session, no cache', () async {
      ({String? sessionId, String? cacheRetention})? routing;
      AssistantMessageEventStream fn(
        Model m,
        Context c, {
        CancelToken? cancelToken,
      }) {
        routing = StreamCacheRouting.current;
        final finalMsg = msg('["2"]');
        return streamOf([
          StartEvent(partial: msg('')),
          DoneEvent(reason: StopReason.stop, message: finalMsg),
        ]);
      }

      final judge = streamFunctionHideJudge(fn, model, system: 'judge sys');
      expect(await judge('ledger text'), '["2"]');
      expect(routing!.sessionId, isNotNull, reason: 'fresh routing session');
      expect(routing!.cacheRetention, 'none');
    });

    test('onDelta sees text and thinking deltas, skips other events', () async {
      final deltas = <String>[];
      AssistantMessageEventStream fn(
        Model m,
        Context c, {
        CancelToken? cancelToken,
      }) => streamOf([
        StartEvent(partial: msg('')), // non-delta event — skipped
        TextDeltaEvent(contentIndex: 0, delta: 'a', partial: msg('a')),
        ThinkingDeltaEvent(contentIndex: 1, delta: 'b', partial: msg('a')),
        DoneEvent(reason: StopReason.stop, message: msg('ab')),
      ]);

      final judge = streamFunctionHideJudge(
        fn,
        model,
        system: 's',
        onDelta: deltas.add,
      );
      expect(await judge('ledger'), 'ab');
      // Deltas stream in asynchronously alongside the awaited result.
      await pumpEventQueue();
      expect(deltas, ['a', 'b']);
    });

    test('aborted, error, empty, and throwing calls all yield null', () async {
      AssistantMessageEventStream of(AssistantMessage done, StopReason why) =>
          streamOf([DoneEvent(reason: why, message: done)]);

      final aborted = streamFunctionHideJudge(
        (m, c, {cancelToken}) =>
            of(msg('', reason: StopReason.aborted), StopReason.aborted),
        model,
        system: 's',
      );
      expect(await aborted('l'), isNull);

      final errored = streamFunctionHideJudge(
        (m, c, {cancelToken}) =>
            of(msg('', reason: StopReason.error), StopReason.error),
        model,
        system: 's',
      );
      expect(await errored('l'), isNull);

      final empty = streamFunctionHideJudge(
        (m, c, {cancelToken}) => of(msg('   '), StopReason.stop),
        model,
        system: 's',
      );
      expect(await empty('l'), isNull, reason: 'whitespace-only is empty');

      AssistantMessageEventStream throwsFn(
        Model m,
        Context c, {
        CancelToken? cancelToken,
      }) => throw Exception('provider down');
      final crashed = streamFunctionHideJudge(throwsFn, model, system: 's');
      expect(await crashed('l'), isNull);
    });
  });

  test(
    'ledger lines cover every record kind (custom, ckpt, legacy, branch)',
    () {
      final records = <SessionRecord>[
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('ask'),
        ),
        CustomMessageRecord(
          id: 'r2',
          parentId: 'r1',
          timestamp: DateTime.utc(2026),
          customType: 'notice',
          content: 'host says hi',
          display: true,
        ),
        CompactCheckpointRecord(
          id: 'r3',
          parentId: 'r2',
          timestamp: DateTime.utc(2026),
          firstRecordId: 'r1',
          lastRecordId: 'r2',
          text: 'the arc in one line',
          coversRecordIds: ['r1', 'r2'],
          flattenedRecordIds: const [],
        ),
        CompactionRecord(
          id: 'r4',
          parentId: 'r3',
          timestamp: DateTime.utc(2026),
          summary: 'legacy summary',
          firstKeptEntryId: 'r1',
          tokensBefore: 123,
        ),
        BranchSummaryRecord(
          id: 'r5',
          parentId: 'r4',
          timestamp: DateTime.utc(2026),
          fromId: 'r4',
          summary: 'old branch',
        ),
      ];
      final ledger = buildContextLedger(
        visiblePath: records,
        seqs: RecordSeqIndex(records),
      );
      final lines = ledger.render().split('\n');
      expect(lines, hasLength(5));
      expect(lines[0], contains('user'));
      expect(lines[1], contains('notice'));
      expect(lines[2], contains('ckpt'));
      expect(lines[3], contains('legacy-ckpt'));
      expect(lines[4], contains('branch-summary'));
      expect(lines[4], contains('old branch'));
    },
  );
}
