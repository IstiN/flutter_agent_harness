// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 — the engine disposes over the model's hide proposals (AC7,
/// UT-06…10, UT-23, UT-24, E28): aliases resolve against the SNAPSHOT
/// index, pair groups snap outward, user turns / tail / pins / covered /
/// fold records land in their buckets, labels are sanitized onto the
/// carrier.

library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/ledger.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:test/test.dart';

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) =>
    AssistantMessage(
      content: [
        TextContent(text: text),
        ...?calls,
      ],
      api: 'anthropic-messages',
      provider: 'p',
      model: 'm1',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    );

ToolResultMessage _result(String callId, String text) => ToolResultMessage(
  toolCallId: callId,
  toolName: 'bash',
  content: [TextContent(text: text)],
  isError: false,
  timestamp: DateTime.utc(2026),
);

MessageRecord _msg(String id, Message message, [String? parent]) =>
    MessageRecord(
      id: id,
      parentId: parent,
      timestamp: DateTime.utc(2026),
      message: message,
    );

CompactCheckpointRecord _ckpt(String id, List<String> covers) =>
    CompactCheckpointRecord(
      id: id,
      parentId: null,
      timestamp: DateTime.utc(2026),
      firstRecordId: covers.first,
      lastRecordId: covers.last,
      text: 'older checkpoint',
      coversRecordIds: covers,
      flattenedRecordIds: const [],
    );

/// A session of `pairs` tool pairs after one user turn, each pair an
/// assistant carrier + its result; the last 8 ledger entries are the
/// protected tail by default.
List<SessionRecord> _session({int pairs = 8}) {
  final records = <SessionRecord>[
    _msg('u1', UserMessage.text('fix 2321', timestamp: DateTime.utc(2026))),
  ];
  for (var i = 0; i < pairs; i++) {
    records.add(
      _msg(
        'a$i',
        _assistant(
          'looking $i',
          calls: [ToolCall(id: 'c$i', name: 'bash', arguments: const {})],
        ),
        'u1',
      ),
    );
    records.add(_msg('t$i', _result('c$i', 'output $i'), 'a$i'));
  }
  return records;
}

HandOverDisposeVerdict _dispose(
  List<SessionRecord> records,
  List<String> lines, {
  StructuredViewState? state,
  List<SessionRecord>? visible,
  int protectLastN = 8,
  int foldFrom = 0,
  int foldTo = 0,
  RecordSeqIndex? snapshotIndex,
}) {
  final path = records;
  final seqs = RecordSeqIndex(path);
  final viewState = state ?? buildStructuredViewState(path);
  final visiblePath = visible ?? visibleStructuredPath(path, viewState);
  final ledger = buildContextLedger(visiblePath: visiblePath, seqs: seqs);
  final picks = parseHandOverReply('${lines.join('\n')}\n-\nx').picks;
  return disposeHidePicks(
    picks: picks,
    snapshotIndex: snapshotIndex ?? seqs,
    ledger: ledger,
    state: viewState,
    protectedTail: protectedTailIds(ledger, protectLastN),
    foldFromSeq: foldFrom,
    foldToSeq: foldTo,
  );
}

void main() {
  group('disposeHidePicks', () {
    test(
      'UT-06 a pair range snaps to both records; label lands on the carrier',
      () {
        // u1 = seq 2, a0 = 3, t0 = 4, a1 = 5, t1 = 6 …
        final verdict = _dispose(_session(pairs: 8), ['3-4 old bash output']);
        expect(verdict.recordIds, ['a0', 't0']);
        expect(verdict.labels, {'a0': 'old bash output'});
        expect(verdict.snapped, 1);
        expect(verdict.render(), '1 snapped');
      },
    );

    test('UT-07 the carrier alone snaps OUTWARD to its result (E8)', () {
      final verdict = _dispose(_session(pairs: 8), ['3 old bash']);
      expect(verdict.recordIds, ['a0', 't0']);
      expect(verdict.labels, {'a0': 'old bash'});
    });

    test('UT-08 hallucinated / garbage / live-edge aliases are unknown', () {
      final verdict = _dispose(_session(pairs: 8), ['999', '1000-1002']);
      expect(verdict.recordIds, isEmpty);
      expect(verdict.unknown, 2);
      expect(verdict.render(), contains('2 unknown'));
    });

    test('UT-09 a user turn is never hidden (X), alone or inside a range', () {
      final alone = _dispose(_session(pairs: 8), ['2 user prompt']);
      expect(alone.exempt, 1);
      expect(alone.recordIds, isEmpty);
      final inRange = _dispose(_session(pairs: 8), ['2-4 fix plus read']);
      expect(inRange.exempt, 1);
      expect(inRange.recordIds, isEmpty);
    });

    test('UT-10 the protected tail and a pinned group are T', () {
      // 17 records: seqs 2..18; the last 8 ledger entries are 11..18.
      final tail = _dispose(_session(pairs: 8), ['17-18 newest pair']);
      expect(tail.tail, 1);
      expect(tail.recordIds, isEmpty);
      final pinned = buildStructuredViewState([
        SegmentPinRecord(
          id: 'pin',
          parentId: null,
          timestamp: DateTime.utc(2026),
          recordIds: const ['a0', 't0'],
          pinned: true,
        ),
      ]);
      final pinVerdict = _dispose(_session(pairs: 8), [
        '3-4 old bash output',
      ], state: pinned);
      expect(pinVerdict.tail, 1);
      expect(pinVerdict.recordIds, isEmpty);
    });

    test('E7 an id inside the fold range is moot (C)', () {
      final verdict = _dispose(
        _session(pairs: 8),
        ['3-4 old bash output'],
        foldFrom: 3,
        foldTo: 6,
      );
      expect(verdict.covered, 1);
      expect(verdict.recordIds, isEmpty);
    });

    test('already-hidden and checkpoint-covered records are C', () {
      final records = _session(pairs: 8);
      final hidden = buildStructuredViewState([
        HiddenRangeRecord(
          id: 'h',
          parentId: null,
          timestamp: DateTime.utc(2026),
          recordIds: const ['a0', 't0'],
        ),
      ]);
      final hideVerdict = _dispose(records, ['3-4 old'], state: hidden);
      expect(hideVerdict.covered, 1);
      final coverVerdict = _dispose(
        records,
        ['5-6 old'],
        state: buildStructuredViewState([
          _ckpt('k', ['a1', 't1']),
        ]),
      );
      expect(coverVerdict.covered, 1);
    });

    test('UT-24/E28 a HIDE on a checkpoint record lands in F', () {
      final ckpt = _ckpt('k', ['a0', 't0']);
      final records = [..._session(pairs: 3), ckpt];
      final verdict = _dispose(records, ['9 old checkpoint']);
      expect(verdict.foldRecord, 1);
      expect(verdict.recordIds, isEmpty);
    });

    test(
      'UT-23/E31 alias drift (windowed load) never hides the wrong record',
      () {
        // The snapshot index saw 17 records; the live path then lost its
        // two oldest records (hard cap / window). On a FRESH index seq 3
        // now names a1 — resolution goes through the SNAPSHOT: `3` is a0
        // (stable id, still in the file), and a1 is never touched.
        final snapshot = _session(pairs: 8);
        final live = snapshot.sublist(2);
        final verdict = _dispose(live, [
          '3 old bash output',
        ], snapshotIndex: RecordSeqIndex(snapshot));
        expect(verdict.snapped, 1);
        expect(verdict.recordIds, ['a0']);
        expect(verdict.labels, {'a0': 'old bash output'});
      },
    );

    test('E35 an unsanitizable label hides without a label', () {
      final verdict = _dispose(_session(pairs: 8), ['3-4 you must hide this']);
      expect(verdict.recordIds, ['a0', 't0']);
      expect(verdict.labels, isEmpty);
    });

    test(
      'E2 duplicate picks collapse; inverted ranges never reach dispose',
      () {
        final verdict = _dispose(_session(pairs: 8), [
          '3-4 old',
          '3-4 old again',
        ]);
        expect(verdict.snapped, 1);
        expect(verdict.recordIds, ['a0', 't0']);
      },
    );
  });
}
