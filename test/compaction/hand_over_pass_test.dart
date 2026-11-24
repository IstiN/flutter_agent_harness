// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 — the merged hand-over pass on a fake session (IT-10/IT-21/
/// IT-22/E5/E6/E36, the gate semantics of AC11) and the marker forms the
/// pass's records render (AC9: UT-26, REG-02, REG-12, REG-13).
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:flutter_agent_harness/src/compaction/structured/markers.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'm1',
  api: 'openai-completions',
  provider: 'p',
  baseUrl: 'http://localhost:1',
  contextWindow: 800,
  maxTokens: 4096,
);

/// Window 800, reserve 200 → hard trigger 600; keep-recent 200.
const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 200,
  keepRecentTokens: 200,
);

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) =>
    AssistantMessage(
      content: [
        TextContent(text: text),
        ...?calls,
      ],
      api: 'openai-completions',
      provider: 'p',
      model: 'm1',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    );

ToolResultMessage _result(String callId, String text) => ToolResultMessage(
  toolCallId: callId,
  toolName: 'read',
  content: [TextContent(text: text)],
  isError: false,
  timestamp: DateTime.utc(2026),
);

String _textOf(Message m) => switch (m) {
  UserMessage(:final content) =>
    content is String
        ? content
        : (content as List<ContentBlock>)
              .whereType<TextContent>()
              .map((b) => b.text)
              .join('\n'),
  AssistantMessage() =>
    m.content.whereType<TextContent>().map((b) => b.text).join('\n'),
  ToolResultMessage() =>
    m.content.whereType<TextContent>().map((b) => b.text).join('\n'),
  _ => '',
};

/// A fake provider answering scripted texts in order and recording every
/// request (prefix + instruction shape).
final class _Fake {
  _Fake(this.replies);
  final List<String> replies;
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final message = _assistant(replies[contexts.length - 1]);
    final stream = AssistantMessageEventStream();
    stream.push(StartEvent(partial: message));
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  }
}

final class _Hooks implements StructuredCompactorHooks {
  final passes = <StructuredCompactionPass>[];

  @override
  void onDelta(String delta) {}

  @override
  void onPass(StructuredCompactionPass pass) => passes.add(pass);
}

const _transfer = '''
## Open User Requests
- fix the login crash
## Hand-over
The login crash is a null deref in session_repo.dart:962; the fix is
half-written — finish the guard, then run test/session.
''';

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  /// user ask (seq 2) · 3 tool pairs with 100-token results · 3 filler
  /// turns · closing user ask. The fold range lands on seqs 2..5 (the
  /// walk stops at the second 100-token result, snapped inward to the
  /// pair boundary).
  Future<Session> session() async {
    final s = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await s.appendMessage(UserMessage.text('fix the login crash'));
    for (var i = 0; i < 3; i++) {
      await s.appendMessage(
        _assistant(
          'step $i',
          calls: [ToolCall(id: 'c$i', name: 'read', arguments: {})],
        ),
      );
      await s.appendMessage(_result('c$i', 'payload $i ${'x' * 400}'));
      await s.appendMessage(_assistant('analysis $i findings'));
    }
    for (var i = 0; i < 3; i++) {
      await s.appendMessage(_assistant('filler $i'));
    }
    await s.appendMessage(UserMessage.text('what was the exact error?'));
    return s;
  }

  /// The S0 epoch the way the agent loop captures it: the projected
  /// transcript (tags on) plus its frozen index.
  Future<RequestSnapshot> snapshotOf(Session s) async {
    final projection = await s.buildTranscriptProjection();
    return RequestSnapshot(
      model: _model,
      messages: tagTranscript(projection.messages, projection.seqMap),
      systemPrompt: 'sys',
      tools: const [Tool(name: 'read', description: 'd', parameters: {})],
      seqMap: projection.seqMap,
      sentAt: DateTime.now(),
    );
  }

  StructuredCompactor compactorFor(
    Session s,
    AgentState state, {
    required HandOverCall handOver,
    required RequestSnapshot snapshot,
    _Hooks? hooks,
  }) => StructuredCompactor(
    session: s,
    state: state,
    window: 800,
    settings: _settings,
    judge: (text, [token]) async => throw StateError('judge must not run'),
    summarize: (request) async =>
        throw StateError('digest must not run on the merged path'),
    checkpointPrompt: 'P',
    handOver: handOver,
    requestSnapshot: snapshot,
    handOverPrompt: compactionHandOverPrompt,
    hooks: hooks,
    pinnedLines: const {},
  );

  HandOverCall callFor(_Fake fake, RequestSnapshot snapshot) =>
      handOverCallAdapter(
        stream: fake.call,
        model: _model,
        cachePolicy: CompactionCachePolicy.sessionAffine(),
        prefixLength: snapshot.prefixLength,
      );

  List<String> texts(Iterable<Message> messages) => [
    for (final m in messages) _textOf(m),
  ];

  group('IT-10 merged pass on a fake session', () {
    test('ONE call → hidden_range (labels, consolidated) + checkpoint '
        '(layout tail); the file stays a byte-prefix', () async {
      final s = await session();
      final before =
          (await fs.readTextFile((await s.getMetadata()).path)).valueOrNull ??
          '';
      final state = AgentState(model: _model, messages: []);
      final snapshot = await snapshotOf(s);
      final fake = _Fake(['7 old read output\n-\n$_transfer']);
      final hooks = _Hooks();
      final compactor = compactorFor(
        s,
        state,
        handOver: callFor(fake, snapshot),
        snapshot: snapshot,
        hooks: hooks,
      );

      expect(await compactor.run(force: true), isTrue);
      expect(fake.contexts, hasLength(1));
      // AC3/AC6: the prefix is S0 as sent, the instruction is the only
      // delta and carries the fold range, the asks block and the tags.
      final sent = fake.contexts.single.messages;
      expect(
        [for (final m in sent.take(snapshot.prefixLength)) m.toJson()],
        [for (final m in snapshot.messages) m.toJson()],
      );
      final instruction = _textOf(sent.last);
      expect(instruction, contains('Fold range: records 2-5'));
      expect(instruction, contains('<open-user-requests>'));
      expect(instruction, contains('fix the login crash'));
      expect(texts(sent.take(snapshot.prefixLength)).first, startsWith('m2 '));

      final records = await s.getEntries();
      final hidden = records.whereType<HiddenRangeRecord>().toList();
      final checkpoint = records.whereType<CompactCheckpointRecord>().toList();
      expect(hidden, hasLength(1));
      // The pick named the result c1 (seq 7); the engine snapped OUTWARD to
      // the whole pair: carrier step 1 (seq 6) + its result.
      expect(
        hidden.single.recordIds,
        unorderedEquals([records[4].id, records[5].id]),
      );
      expect(hidden.single.consolidated, isTrue);
      expect(hidden.single.labels, {records[4].id: 'old read output'});
      expect(checkpoint, hasLength(1));
      expect(checkpoint.single.layout, compactCheckpointLayoutTail);
      expect(checkpoint.single.firstRecordId, records[0].id);
      expect(checkpoint.single.lastRecordId, records[3].id);
      expect(checkpoint.single.text, isNot(contains('<think>')));
      expect(checkpoint.single.text, contains('## Open User Requests'));
      // The original file is an untouched byte-prefix (REG-05).
      final after =
          (await fs.readTextFile((await s.getMetadata()).path)).valueOrNull ??
          '';
      expect(after.startsWith(before), isTrue);

      final pass = hooks.passes.single;
      expect(pass.kind, 'hand-over');
      expect(pass.ok, isTrue);
      expect(pass.judgeCalls, 1);
      expect(pass.hiddenCount, 2);
      expect(pass.summarizedCount, 4);
      expect(HandOverPassMetrics.mode, 'merged');
      expect(pass.handOver!.bucket, 'warm');
      expect(pass.handOver!.transfer, 'text');
      expect(pass.handOver!.hideList, '1 snapped');
      expect(pass.handOver!.cacheHitRatio, isNull, reason: 'no fake zeros');
      expect(
        pass.handOver!.render(),
        'merged · bucket warm · calls 1 · hide list 1 snapped · nudges 0 · '
        'budget retries 0 · transfer text',
      );
      // IT-21: labels live ONLY in the record payload — never a message.
      for (final message in state.messages) {
        expect(_textOf(message), isNot('old read output'));
      }
      for (final line in after.split('\n')) {
        if (!line.contains('"hidden_range"')) {
          expect(line, isNot(contains('old read output')));
        }
      }
    });

    test('AC9/REG-02 markers: ONE consolidated marker at the carrier, an '
        'untagged fold pointer, the transfer at its own position', () async {
      final s = await session();
      final snapshot = await snapshotOf(s);
      final fake = _Fake(['7 old read output\n-\n$_transfer']);
      final compactor = compactorFor(
        s,
        AgentState(model: _model, messages: []),
        handOver: callFor(fake, snapshot),
        snapshot: snapshot,
      );
      await compactor.run(force: true);
      final all = await s.getEntries();
      final ckptSeq =
          2 + all.indexOf(all.whereType<CompactCheckpointRecord>().single);
      final projection = await s.buildTranscriptProjection();
      final rendered = texts(
        tagTranscript(projection.messages, projection.seqMap),
      );
      // The fold pointer sits where the range's first record rendered.
      expect(rendered.first, '[expand 2-5]');
      // Records 6-7 render as ONE user marker at the carrier (seq 6), the
      // result itself renders nothing.
      expect(rendered[1], 'm6 old read output [expand 6-7]');
      expect(rendered, isNot(contains(contains('payload 1'))));
      // The transfer record renders at ITS OWN position with the header
      // and the tagged hidden index; it is tagged by the epoch.
      final transfer = rendered.last;
      expect(transfer, startsWith('m$ckptSeq '));
      expect(transfer, contains('[2-5:ckpt·'));
      expect(transfer, contains('covers:2-5'));
      expect(transfer, contains('\n## Open User Requests\n'));
      expect(transfer, contains('hidden segments (compact_expand reopens'));
      expect(transfer, contains('m4 tool_result·'));
      expect(transfer, contains('"payload 0'));
      expect(transfer, isNot(contains('[4:hidden·')));
      // The pointer is not a record: the tag epoch leaves it untagged and
      // the aligned map carries null there.
      expect(projection.seqMap.seqAt(0), isNull);
      expect(projection.seqMap.seqAt(1), 6);
      expect(projection.seqMap.seqAt(2), 8);
    });

    test('E5 hide-only: no text after the list → a hidden range, no '
        'checkpoint, transfer none', () async {
      final s = await session();
      final snapshot = await snapshotOf(s);
      final fake = _Fake(['6-7 stale read output\n']);
      final hooks = _Hooks();
      final compactor = compactorFor(
        s,
        AgentState(model: _model, messages: []),
        handOver: callFor(fake, snapshot),
        snapshot: snapshot,
        hooks: hooks,
      );
      expect(await compactor.run(force: true), isTrue);
      final records = await s.getEntries();
      expect(records.whereType<HiddenRangeRecord>(), hasLength(1));
      expect(records.whereType<CompactCheckpointRecord>(), isEmpty);
      final pass = hooks.passes.single;
      expect(pass.summary, isNull);
      expect(pass.summarizedCount, 0);
      expect(pass.handOver!.transfer, 'none');
      expect(pass.handOver!.hideList, '1 snapped');
    });

    test('IT-22 a user turn in the HIDE list is never hidden (X); a user '
        'turn inside the fold range is covered by the checkpoint', () async {
      final s = await session();
      final snapshot = await snapshotOf(s);
      final fake = _Fake(['2 fix the login crash\n-\n$_transfer']);
      final hooks = _Hooks();
      final compactor = compactorFor(
        s,
        AgentState(model: _model, messages: []),
        handOver: callFor(fake, snapshot),
        snapshot: snapshot,
        hooks: hooks,
      );
      expect(await compactor.run(force: true), isTrue);
      final records = await s.getEntries();
      expect(records.whereType<HiddenRangeRecord>(), isEmpty);
      final checkpoint = records.whereType<CompactCheckpointRecord>().single;
      expect(checkpoint.coversRecordIds, contains(records[0].id));
      // Inside the fold range the user turn counts as covered (the
      // checkpoint carries its ask verbatim) — the X bucket needs a user
      // turn OUTSIDE the range (hand_over_dispose_test UT-08).
      expect(
        hooks.passes.single.handOver!.hideList,
        '0 snapped · 1 covered/in-range',
      );
      expect(hooks.passes.single.hiddenCount, 0);
    });

    test('E36 no `## Open User Requests` section → the run FAILS and '
        'nothing is appended', () async {
      final s = await session();
      final count = (await s.getEntries()).length;
      final snapshot = await snapshotOf(s);
      final fake = _Fake(['7 old read output\n-\nNo heading hand-over.']);
      final hooks = _Hooks();
      final compactor = compactorFor(
        s,
        AgentState(model: _model, messages: []),
        handOver: callFor(fake, snapshot),
        snapshot: snapshot,
        hooks: hooks,
      );
      expect(await compactor.run(force: true), isFalse);
      expect(await s.getEntries(), hasLength(count));
      final pass = hooks.passes.single;
      expect(pass.ok, isFalse);
      expect('${pass.error}', contains('Open User Requests'));
    });

    test('E36 a dropped ask → the run FAILS and nothing is appended', () async {
      final s = await session();
      final count = (await s.getEntries()).length;
      final snapshot = await snapshotOf(s);
      final fake = _Fake([
        '7 old read output\n-\n## Open User Requests\n- none\n## Hand-over\n'
            'Did other things.',
      ]);
      final hooks = _Hooks();
      final compactor = compactorFor(
        s,
        AgentState(model: _model, messages: []),
        handOver: callFor(fake, snapshot),
        snapshot: snapshot,
        hooks: hooks,
      );
      expect(await compactor.run(force: true), isFalse);
      expect(await s.getEntries(), hasLength(count));
      expect('${hooks.passes.single.error}', contains('dropped 1 open user'));
    });

    test('E6 a failed call → nothing appended, a loud failed pass, no '
        'other engine', () async {
      final s = await session();
      final count = (await s.getEntries()).length;
      final snapshot = await snapshotOf(s);
      final fake = _Fake(['irrelevant']);
      final failing = handOverCallAdapter(
        stream: (model, context, {cancelToken}) =>
            throw StateError('hand-over call failed: boom'),
        model: _model,
        cachePolicy: CompactionCachePolicy.sessionAffine(),
        prefixLength: snapshot.prefixLength,
      );
      final hooks = _Hooks();
      final compactor = compactorFor(
        s,
        AgentState(model: _model, messages: []),
        handOver: failing,
        snapshot: snapshot,
        hooks: hooks,
      );
      expect(await compactor.run(force: true), isFalse);
      expect(await s.getEntries(), hasLength(count));
      expect(hooks.passes.single.kind, 'hand-over');
      expect(hooks.passes.single.ok, isFalse);
      expect(fake.contexts, isEmpty);
    });

    test('AC11 gate: a soft-armed post-run in the [soft, hard) band runs; '
        'an unarmed run below the hard line exits with a reason', () async {
      final s = await session();
      final snapshot = await snapshotOf(s);
      final fake = _Fake(['7 old read output\n-\n$_transfer']);
      final unarmed = compactorFor(
        s,
        AgentState(model: _model, messages: []),
        handOver: callFor(fake, snapshot),
        snapshot: snapshot,
      );
      // Session ~330 tokens < hard trigger 600 → the hard gate declines.
      expect(await unarmed.run(), isTrue);
      // run()'s own trigger gate declines first (same reason text as
      // the standalone ladder).
      expect(unarmed.exitReason, contains('trigger gate'));
      expect(fake.contexts, isEmpty);
      // The host measured the soft line (hard − 5 %) and armed the run.
      final armed = compactorFor(
        s,
        AgentState(model: _model, messages: []),
        handOver: callFor(fake, snapshot),
        snapshot: snapshot,
      );
      expect(await armed.run(softTriggered: true), isTrue);
      expect(armed.exitReason, isNull);
      expect(fake.contexts, hasLength(1));
      expect(
        (await s.getEntries()).whereType<CompactCheckpointRecord>(),
        hasLength(1),
      );
    });

    test('E28 a later run: HIDE naming the transfer record lands in the '
        'F bucket and the folded range stays folded', () async {
      final s = await session();
      var snapshot = await snapshotOf(s);
      final transfer = [
        '## Open User Requests',
        '- fix the login crash',
        '## Hand-over',
        'First hand-over.',
      ].join('\n');
      final fake = _Fake(['7 old read output\n-\n$transfer']);
      final first = compactorFor(
        s,
        AgentState(model: _model, messages: []),
        handOver: callFor(fake, snapshot),
        snapshot: snapshot,
      );
      await first.run(force: true);
      final all = await s.getEntries();
      final checkpoint = all.whereType<CompactCheckpointRecord>().single;
      final ckptSeq = 2 + all.indexOf(checkpoint);
      // A new epoch: the projection now carries the pointer, the marker
      // and the transfer record; the model names the transfer's alias.
      snapshot = await snapshotOf(s);
      final secondFake = _Fake([
        // The second range (6-17) covers the live ask at seq 15 — the
        // transfer must carry it verbatim.
        '$ckptSeq stale\n-\n## Open User Requests\n'
            '- what was the exact error?\n## Hand-over\nSecond hand-over.',
      ]);
      final hooks = _Hooks();
      final second = compactorFor(
        s,
        AgentState(model: _model, messages: []),
        handOver: callFor(secondFake, snapshot),
        snapshot: snapshot,
        hooks: hooks,
      );
      expect(await second.run(force: true), isTrue);
      expect(
        hooks.passes.single.handOver!.hideList,
        '0 snapped · 1 fold-record',
      );
      expect(hooks.passes.single.hiddenCount, 0);
      final after = await s.getEntries();
      expect(
        after.whereType<HiddenRangeRecord>().expand((r) => r.recordIds),
        isNot(contains(checkpoint.id)),
      );
    });
  });

  group('AC9/UT-26 marker forms', () {
    test('expandMarker / consolidatedHideMarker', () {
      expect(expandMarker(from: 3, to: 140), '[expand 3-140]');
      expect(expandMarker(from: 61), '[expand 61]');
      expect(expandMarker(from: 61, to: 61), '[expand 61]');
      expect(
        consolidatedHideMarker(from: 142, to: 143, label: 'old session list'),
        'old session list [expand 142-143]',
      );
      expect(consolidatedHideMarker(from: 142, to: 143), '[expand 142-143]');
      expect(
        consolidatedHideMarker(from: 142, to: 143, label: '  '),
        '[expand 142-143]',
      );
    });

    test('isCompactionMarkerText matches old + new forms, tagged or not; '
        'a tagged record is not a marker', () {
      for (final text in [
        '[3:hidden·user·12]',
        '[2-6:ckpt·38k→40tok·covers:3,5]',
        '[expand 3-140]',
        '[expand 61]',
        'm142 old session list [expand 142-143]',
        'm142 [expand 142-143]',
        'm184 [3-140:ckpt·165k→900tok·covers:3-140]\n## Open User Requests',
        'm3 [3:hidden·user·12]',
      ]) {
        expect(isCompactionMarkerText(text), isTrue, reason: text);
      }
      for (final text in [
        'm142 fix the login crash',
        'm142 [expand',
        '[expand a-b]',
        'see [expand 5-6] inside a longer sentence here',
        'user text',
      ]) {
        expect(isCompactionMarkerText(text), isFalse, reason: text);
      }
    });

    test('REG-12 hiddenIndexSection: tagged lines for the tail layout, the '
        'legacy marker form otherwise', () async {
      final s = await session();
      final records = await s.getEntries();
      final seqs = RecordSeqIndex(records);
      final tagged = hiddenIndexSection([records[1]], seqs, tagged: true);
      expect(tagged, startsWith('\n\n$hiddenIndexHeading\n'));
      expect(tagged, contains('\nm3 assistant·'));
      final legacy = hiddenIndexSection([records[1]], seqs);
      expect(legacy, contains('\n[3:hidden·assistant·'));
      expect(legacy, isNot(contains('\nm3 ')));
    });

    test('REG-12 an old checkpoint (no layout) still renders IN PLACE; a '
        'dropped tail checkpoint names its kind and seq', () async {
      final s = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      for (var i = 0; i < 4; i++) {
        await s.appendMessage(_assistant('turn $i'));
      }
      final records = await s.getEntries();
      await s.appendCompactCheckpoint(
        firstRecordId: records[0].id,
        lastRecordId: records[1].id,
        text: 'legacy summary',
        coversRecordIds: [records[0].id, records[1].id],
        flattenedRecordIds: const [],
      );
      var projection = await s.buildTranscriptProjection();
      expect(_textOf(projection.messages.first), startsWith('[2-3:ckpt·'));
      expect(projection.messages.first, isA<UserMessage>());
      // The version-skew shape: a tail checkpoint with no ids drops whole
      // and its note names the kind and the seq at ITS position.
      final first = (await s.getEntries()).first;
      final dropped = <SessionRecord>[
        MessageRecord(
          id: 'm-a',
          parentId: first.id,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('live turn'),
        ),
        CompactCheckpointRecord(
          id: 'skew',
          parentId: 'm-a',
          timestamp: DateTime.utc(2026),
          firstRecordId: '',
          lastRecordId: '',
          text: '',
          coversRecordIds: [],
          flattenedRecordIds: [],
          layout: compactCheckpointLayoutTail,
        ),
      ];
      final rendered = renderStructuredMessages(
        path: dropped,
        seqs: RecordSeqIndex(dropped),
        projectEntry: (_) => const [],
      );
      expect(
        _textOf(rendered.last),
        contains(
          '[resume] structured fold #3 '
          '(compact_checkpoint) dropped',
        ),
      );
    });

    test('REG-13 an older reader (parser without the #2394 keys) loads the '
        'new file and renders the legacy shapes', () async {
      final s = await session();
      final snapshot = await snapshotOf(s);
      final fake = _Fake(['7 old read output\n-\n$_transfer']);
      await compactorFor(
        s,
        AgentState(model: _model, messages: []),
        handOver: callFor(fake, snapshot),
        snapshot: snapshot,
      ).run(force: true);
      final path = (await s.getMetadata()).path;
      final raw = (await fs.readTextFile(path)).valueOrNull ?? '';
      expect(raw, contains('"labels"'));
      expect(raw, contains('"consolidated":true'));
      expect(raw, contains('"layout":"tail"'));
      // Simulate the pre-#2394 parser: strip the additive keys.
      final oldLines = [
        for (final line in raw.split('\n'))
          if (line.isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
      ];
      for (final map in oldLines) {
        if (map['type'] == 'hidden_range') {
          map.remove('labels');
          map.remove('consolidated');
        }
        if (map['type'] == 'compact_checkpoint') map.remove('layout');
      }
      final oldRecords = [
        for (final map in oldLines.skip(1)) SessionRecord.fromJson(map),
      ];
      final oldView = buildStructuredViewState(oldRecords);
      expect(oldView.consolidatedRanges, isEmpty);
      final rendered = renderStructuredMessages(
        path: oldRecords,
        seqs: RecordSeqIndex(oldRecords),
        projectEntry: (_) => const [],
      );
      final texts_ = texts(rendered);
      // Legacy per-record markers; the checkpoint text IN PLACE.
      expect(texts_[0], startsWith('[2-5:ckpt·'));
      expect(texts_[1], startsWith('[6:hidden·assistant·'));
      expect(texts_[2], startsWith('[7:hidden·tool_result·'));
    });
  });
}
