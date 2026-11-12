// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2044 — auto-compact fragile-band escalation. An automatic structured
/// run (`force == false`) that settles with less than one full reserve of
/// headroom (`0 <= trigger - settled < settings.reserveTokens`) performs
/// exactly ONE extra checkpoint pass through the existing checkpoint
/// machinery — whether or not hideable entries remain. Deep relief, forced
/// runs (manual and message-cap) and the whole failure-safety contract are
/// unchanged.
///
/// Fixture math: the estimator is 4 chars/token, so every payload below is
/// an exact multiple and the settled margin is pinned exactly. Hidden
/// records ride one-line markers on the wire, so the expected settled count
/// is computed with the SAME projection helpers the engine uses
/// (`recordTokens` + `hiddenMarkerTokens`), not hand-derived.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart'
    show RecordSeqIndex, hiddenMarkerTokens, recordTokens;
import 'package:test/test.dart';

AssistantMessage _carrier(String callId) => AssistantMessage(
  content: [
    const TextContent(text: 'a'),
    ToolCall(id: callId, name: 'read', arguments: {}),
  ],
  api: 'anthropic-messages',
  provider: 'p',
  model: 'm1',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

ToolResultMessage _result(String callId, int tokens) => ToolResultMessage(
  toolCallId: callId,
  toolName: 'read',
  content: [TextContent(text: 'x' * (tokens * 4))],
  isError: false,
  timestamp: DateTime.utc(2026),
);

/// An assistant text filler — a hideable singleton group. (A user-role
/// filler would be `exempt` and the judge could never hide it.)
AssistantMessage _filler(int tokens) => AssistantMessage(
  content: [TextContent(text: 'f' * (tokens * 4))],
  api: 'anthropic-messages',
  provider: 'p',
  model: 'm1',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

final class _Hooks implements StructuredCompactorHooks {
  final passes = <StructuredCompactionPass>[];
  int summarizeCalls = 0;

  @override
  void onDelta(String delta) {}

  @override
  void onPass(StructuredCompactionPass pass) => passes.add(pass);
}

/// gh-1742 scaled settings at the incident's 400k window:
/// reserve 25000, keepRecent 500 → trigger 375000, band 25000.
const _incidentSettings = CompactionSettings(
  enabled: true,
  reserveTokens: 25000,
  keepRecentTokens: 500,
);

/// Window 800, reserve 200 → trigger 600, band 200.
const _boundarySettings = CompactionSettings(
  enabled: true,
  reserveTokens: 200,
  keepRecentTokens: 200,
);

AgentState _stateFor(List<Message> messages, {int contextWindow = 800}) =>
    AgentState(
      model: Model(
        id: 'm1',
        name: 'm1',
        api: 'anthropic-messages',
        provider: 'p',
        baseUrl: 'http://localhost:1',
        contextWindow: contextWindow,
        maxTokens: 4096,
      ),
      messages: messages,
    );

/// The request-size estimate the engine gates on (no system prompt, no
/// tools → pure transcript estimate).
int _requestTokens(AgentState state) => estimateRequestTokens(state.messages);

/// The projected wire cost of [entries] with [hidden] records rendered at
/// their marker size — the exact basis the settled-margin gate reads after
/// the engine's `_refreshState`.
int _settledTokens(List<SessionRecord> entries, Set<String> hidden) {
  final seqs = RecordSeqIndex(entries);
  var total = 0;
  for (final record in entries) {
    if (record is! MessageRecord) continue;
    final seq = seqs.seqOf(record.id)!;
    total += hidden.contains(record.id)
        ? hiddenMarkerTokens(record, seq)
        : recordTokens(record);
  }
  return total;
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  /// The incident shape at the 400k settings: user ask (100 tok) +
  /// [pairs] read pairs of 1002 tok each (1000-token results). 376 pairs
  /// put the entry at 376,852; the minimal fallback hide then takes 2
  /// pairs (freed 2004 ≥ over 1852) and lands the settle in the fragile
  /// band (the wire keeps one-line markers for the hidden records — the
  /// same marker tax the real incident paid).
  Future<(Session, AgentState)> incidentSession([int pairs = 376]) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('u' * 400));
    for (var i = 0; i < pairs; i++) {
      await session.appendMessage(_carrier('c$i'));
      await session.appendMessage(_result('c$i', 1000));
    }
    return (
      session,
      _stateFor(await session.buildContextMessages(), contextWindow: 400000),
    );
  }

  /// A boundary fixture settling at EXACTLY `600 - margin` tokens with a
  /// scripted judge hide. Layout (file order): user (100 tok), one filler
  /// the judge hides, [hiddenPairs] pairs of 102 tok the judge hides,
  /// [keptPairs] pairs of 102 tok kept, then one kept filler sized so the
  /// settle (kept records + hidden markers) hits the margin exactly.
  /// Returns the session, state, and the hidden id set.
  Future<(Session, AgentState, Set<String>)> boundarySession({
    required int hiddenPairs,
    required int keptPairs,
    required int margin,
    int hiddenFillerTokens = 100,
    int userTokens = 100,
  }) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('u' * (userTokens * 4)));
    await session.appendMessage(_filler(hiddenFillerTokens));
    for (var i = 0; i < hiddenPairs + keptPairs; i++) {
      await session.appendMessage(_carrier('c$i'));
      await session.appendMessage(_result('c$i', 100));
    }
    final entries = await session.getEntries();
    // The records the judge hides: the filler + the first [hiddenPairs]
    // pair groups (file seqs, header is line 1).
    final seqs = RecordSeqIndex(entries);
    final hidden = <String>{for (final r in entries) r.id};
    hidden.retainWhere((id) {
      final record = entries.firstWhere((r) => r.id == id);
      return record is MessageRecord;
    });
    // Keep only the filler + first [hiddenPairs] pairs.
    final keepVisible = <String>{};
    final pairRecordCount = hiddenPairs * 2;
    var seenPairRecords = 0;
    for (final record in entries) {
      if (record is! MessageRecord) continue;
      final seq = seqs.seqOf(record.id)!;
      if (seq == 3) {
        keepVisible.add(record.id); // the hidden filler (any role)
        continue;
      }
      final message = record.message;
      if ((message is AssistantMessage || message is ToolResultMessage) &&
          seenPairRecords < pairRecordCount) {
        keepVisible.add(record.id);
        seenPairRecords++;
      }
    }
    final hiddenIds = keepVisible;

    // Marker overhead of the hidden set (projection helpers, not guesses):
    // projected total with hidden records at marker size, minus what the
    // kept records plus the hidden records cost in full.
    final allFull = entries.whereType<MessageRecord>().fold<int>(
      0,
      (sum, r) => sum + recordTokens(r),
    );
    final hiddenFull = entries
        .whereType<MessageRecord>()
        .where((r) => hiddenIds.contains(r.id))
        .fold<int>(0, (sum, r) => sum + recordTokens(r));
    final markerTotal =
        _settledTokens(entries, hiddenIds) - allFull + hiddenFull;

    // kept filler: settle = user 100 + 102*keptPairs + filler + markers
    //            = 600 - margin
    final keptFiller =
        600 - margin - userTokens - (102 * keptPairs) - markerTotal;
    assert(keptFiller > 0, 'fixture degenerate: keptFiller=$keptFiller');
    await session.appendMessage(_filler(keptFiller));

    final finalEntries = await session.getEntries();
    final settled = _settledTokens(finalEntries, hiddenIds);
    assert(settled == 600 - margin, 'settled $settled != ${600 - margin}');
    assert(
      _requestTokens(_stateFor(await session.buildContextMessages())) > 600,
      'fixture must enter over the trigger',
    );
    final state = _stateFor(await session.buildContextMessages());
    return (session, state, hiddenIds);
  }

  /// The judge answer lines (file seqs) hiding exactly [hiddenIds] via
  /// whole groups: the filler's seq plus each hidden pair's carrier seq.
  String judgeAnswerFor(List<SessionRecord> entries, Set<String> hiddenIds) {
    final seqs = RecordSeqIndex(entries);
    final picks = <int>[];
    for (final record in entries) {
      if (record is! MessageRecord) continue;
      if (!hiddenIds.contains(record.id)) continue;
      final message = record.message;
      if (message is UserMessage || message is AssistantMessage) {
        picks.add(seqs.seqOf(record.id)!);
      }
    }
    picks.sort();
    return '[${picks.join(',')}]';
  }

  group('UT-ESC-1/REG-ESC-2 — incident replay', () {
    test('385,619→360,497-shaped relief escalates on the same run '
        '(judge dead twice, fallback hide, no hides-exhausted gate)', () async {
      final (session, state) = await incidentSession();
      var judgeCalls = 0;
      final hooks = _Hooks();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 400000,
        settings: _incidentSettings,
        judge: (_, [token]) async {
          judgeCalls++;
          return null; // the incident's dead judge
        },
        summarize: (_) {
          hooks.summarizeCalls++;
          return Future.value(SummarizationResult.success('ESCALATED'));
        },
        checkpointPrompt: 'P',
        hooks: hooks,
      );

      final ok = await compactor.run();

      expect(ok, isTrue, reason: 'escalated relief lands under the trigger');
      expect(judgeCalls, 2, reason: 'the incident burns two judge attempts');
      final fallback = hooks.passes.where((p) => p.kind == 'hide-fallback');
      expect(fallback, hasLength(1), reason: 'deterministic hide receipt');
      // The fallback is minimal: hideables REMAIN (66 non-exempt visible
      // records outside the protected tail) — the rejected exhaustion gate
      // would have suppressed the escalation.
      final escalations = hooks.passes
          .where((p) => p.kind == 'checkpoint-escalation')
          .toList();
      expect(escalations, hasLength(1));
      final escalation = escalations.single;
      expect(escalation.ok, isTrue);
      expect(escalation.marginTokens, isNotNull);
      expect(escalation.marginTokens!, greaterThan(0));
      expect(
        escalation.marginTokens!,
        lessThan(_incidentSettings.reserveTokens),
      );
      expect(escalation.bandTokens, _incidentSettings.reserveTokens);
      expect(escalation.hideableRemaining, greaterThan(0));
      expect(escalation.judgeCalls, 1, reason: 'one summarizer call');
      // One escalation checkpoint appended in the SAME run.
      final ckpts = (await session.getEntries())
          .whereType<CompactCheckpointRecord>()
          .toList();
      expect(ckpts, hasLength(1));
      expect(ckpts.single.text, 'ESCALATED');
      // No hide-pass re-entry after the escalation.
      expect(hooks.summarizeCalls, 1);
    });

    test('375,609→360,010-shaped relief escalates too (second incident '
        'transition is a merge-blocking fixture)', () async {
      // 375 pairs: entry 375,850, over 850 — the fallback takes ONE pair
      // and the settle (with its marker tax) stays in the band.
      final (session, state) = await incidentSession(375);
      expect(_requestTokens(state), greaterThan(375000));
      var judgeCalls = 0;
      final hooks = _Hooks();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 400000,
        settings: _incidentSettings,
        judge: (_, [token]) async {
          judgeCalls++;
          return null;
        },
        summarize: (_) =>
            Future.value(SummarizationResult.success('ESCALATED')),
        checkpointPrompt: 'P',
        hooks: hooks,
      );

      final ok = await compactor.run();

      expect(ok, isTrue);
      expect(judgeCalls, 2);
      final escalations = hooks.passes
          .where((p) => p.kind == 'checkpoint-escalation')
          .toList();
      expect(escalations, hasLength(1));
      expect(escalations.single.ok, isTrue);
      expect(escalations.single.marginTokens!, lessThan(25000));
      expect(
        (await session.getEntries()).whereType<CompactCheckpointRecord>(),
        hasLength(1),
      );
    });

    test('IT-ESC-4: the next run starting under the trigger performs no '
        'judge call and no escalation', () async {
      final (session, state) = await incidentSession();
      var judgeCalls = 0;
      var summarizeCalls = 0;
      final hooks = _Hooks();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 400000,
        settings: _incidentSettings,
        judge: (_, [token]) async {
          judgeCalls++;
          return null;
        },
        summarize: (_) {
          summarizeCalls++;
          return Future.value(SummarizationResult.success('ESCALATED'));
        },
        checkpointPrompt: 'P',
        hooks: hooks,
      );
      expect(await compactor.run(), isTrue);
      final escalationsAfterFirst = hooks.passes
          .where((p) => p.kind == 'checkpoint-escalation')
          .length;

      final ok = await compactor.run();

      expect(ok, isTrue);
      expect(judgeCalls, 2, reason: 'the second run adds no judge call');
      expect(summarizeCalls, 1, reason: 'the second run adds no checkpoint');
      expect(
        hooks.passes.where((p) => p.kind == 'checkpoint-escalation').length,
        escalationsAfterFirst,
        reason: 'no escalation on an under-trigger run',
      );
    });
  });

  group('UT-ESC-4 — exact boundary table', () {
    Future<(bool, _Hooks, Session)> runBoundary(int margin) async {
      final (session, state, hiddenIds) = await boundarySession(
        hiddenPairs: margin == 0 ? 1 : 2,
        keptPairs: margin == 0 ? 4 : 1,
        margin: margin,
      );
      final hooks = _Hooks();
      final entries = await session.getEntries();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async => judgeAnswerFor(entries, hiddenIds),
        summarize: (_) => Future.value(SummarizationResult.success('CKPT')),
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 2,
      );
      final ok = await compactor.run();
      return (ok, hooks, session);
    }

    test('margin == 0 escalates', () async {
      final (ok, hooks, _) = await runBoundary(0);
      final escalations = hooks.passes
          .where((p) => p.kind == 'checkpoint-escalation')
          .toList();
      expect(escalations, hasLength(1));
      expect(escalations.single.marginTokens, 0);
      expect(escalations.single.bandTokens, 200);
      expect(ok, isTrue);
    });

    test('margin == reserve - 1 escalates', () async {
      final (ok, hooks, _) = await runBoundary(199);
      final escalations = hooks.passes
          .where((p) => p.kind == 'checkpoint-escalation')
          .toList();
      expect(escalations, hasLength(1));
      expect(escalations.single.marginTokens, 199);
      expect(ok, isTrue);
    });

    test('margin == reserve does not escalate', () async {
      final (ok, hooks, _) = await runBoundary(200);
      expect(
        hooks.passes.where((p) => p.kind == 'checkpoint-escalation'),
        isEmpty,
      );
      expect(ok, isTrue);
    });

    test('margin == reserve + 1 does not escalate', () async {
      final (ok, hooks, _) = await runBoundary(201);
      expect(
        hooks.passes.where((p) => p.kind == 'checkpoint-escalation'),
        isEmpty,
      );
      expect(ok, isTrue);
    });

    test('negative margin (still over the trigger) is not a thin '
        'settlement: no escalation, verdict fails', () async {
      // Judge declines: nothing relieves, settle == entry over the trigger.
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('u' * 400));
      await session.appendMessage(_filler(4));
      for (var i = 0; i < 5; i++) {
        await session.appendMessage(_carrier('c$i'));
        await session.appendMessage(_result('c$i', 100));
      }
      await session.appendMessage(_filler(28));
      assert(
        _requestTokens(_stateFor(await session.buildContextMessages())) > 600,
        'fixture must enter over the trigger',
      );
      final state = _stateFor(await session.buildContextMessages());
      final hooks = _Hooks();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async => '[]',
        summarize: (_) => Future.value(SummarizationResult.success('CKPT')),
        checkpointPrompt: 'P',
        hooks: hooks,
      );
      final ok = await compactor.run();
      expect(
        hooks.passes.where((p) => p.kind == 'checkpoint-escalation'),
        isEmpty,
        reason: 'a settle still over the trigger never escalates',
      );
      // The classic ladder still falls through to the checkpoint, which
      // succeeds — only the escalation is absent.
      expect(ok, isTrue);
    });
  });

  group('UT-ESC-5 — automatic-only gating', () {
    test('manual force == true skips the escalation', () async {
      final (session, state, hiddenIds) = await boundarySession(
        hiddenPairs: 1,
        keptPairs: 4,
        margin: 0,
      );
      final hooks = _Hooks();
      final entries = await session.getEntries();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async => judgeAnswerFor(entries, hiddenIds),
        summarize: (_) => Future.value(SummarizationResult.success('CKPT')),
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 4,
      );
      await compactor.run(force: true);
      expect(
        hooks.passes.where((p) => p.kind == 'checkpoint-escalation'),
        isEmpty,
        reason: 'forced runs keep their existing behavior',
      );
    });
  });

  group('UT-ESC-6 — bounded work', () {
    test('exactly one escalation; a still-thin result does not loop', () async {
      // user 100 + 9 pairs of 56 = 604 (over the 600 trigger); the ladder
      // checkpoint folds user+pair1, the escalation folds pair2 — the
      // result is still in the band and must NOT re-escalate.
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('u' * 400));
      for (var i = 0; i < 9; i++) {
        await session.appendMessage(_carrier('c$i'));
        await session.appendMessage(_result('c$i', 54));
      }
      final state = _stateFor(await session.buildContextMessages());
      final hooks = _Hooks();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 200,
          keepRecentTokens: 400,
        ),
        judge: (_, [token]) async => '[]',
        summarize: (_) => Future.value(SummarizationResult.success('CKPT')),
        checkpointPrompt: 'P',
        hooks: hooks,
      );
      final ok = await compactor.run();
      expect(
        hooks.passes.where((p) => p.kind == 'checkpoint-escalation'),
        hasLength(1),
        reason: 'at most one escalation per run()',
      );
      expect(ok, isTrue, reason: 'still under the trigger after one pass');
    });

    test('maxCheckpointPasses == 0 produces no checkpoint call and no '
        'escalation', () async {
      final (session, state, hiddenIds) = await boundarySession(
        hiddenPairs: 1,
        keptPairs: 4,
        margin: 0,
      );
      final hooks = _Hooks();
      final entries = await session.getEntries();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async => judgeAnswerFor(entries, hiddenIds),
        summarize: (_) {
          hooks.summarizeCalls++;
          return Future.value(SummarizationResult.success('CKPT'));
        },
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 4,
        maxCheckpointPasses: 0,
      );
      final ok = await compactor.run();
      expect(hooks.summarizeCalls, 0, reason: 'no checkpoint call at all');
      expect(
        (await session.getEntries()).whereType<CompactCheckpointRecord>(),
        isEmpty,
      );
      expect(
        hooks.passes.where((p) => p.kind == 'checkpoint-escalation'),
        isEmpty,
      );
      expect(ok, isTrue, reason: 'the fallback hide already settled thin');
    });
  });

  group('UT-ESC-7 — failure safety', () {
    test('empty summary: the failed escalation report fires and the '
        'pre-escalation under-trigger success stands', () async {
      final (session, state, hiddenIds) = await boundarySession(
        hiddenPairs: 1,
        keptPairs: 4,
        margin: 0,
      );
      final hooks = _Hooks();
      final entries = await session.getEntries();
      final messagesBefore = [...state.messages];
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async => judgeAnswerFor(entries, hiddenIds),
        summarize: (_) => Future.value(SummarizationResult.success('')),
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 4,
      );
      final ok = await compactor.run();
      expect(
        ok,
        isTrue,
        reason: 'optional deepening must not flip the verdict',
      );
      final escalations = hooks.passes
          .where((p) => p.kind == 'checkpoint-escalation')
          .toList();
      expect(escalations, hasLength(1));
      expect(escalations.single.ok, isFalse);
      expect(escalations.single.error, isA<CompactionException>());
      expect(
        (await session.getEntries()).whereType<CompactCheckpointRecord>(),
        isEmpty,
      );
      expect(state.messages.length, messagesBefore.length);
    });

    test('failed processing (throwing summarizer): verdict stands, '
        'failure reported', () async {
      final (session, state, hiddenIds) = await boundarySession(
        hiddenPairs: 1,
        keptPairs: 4,
        margin: 0,
      );
      final hooks = _Hooks();
      final entries = await session.getEntries();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async => judgeAnswerFor(entries, hiddenIds),
        summarize: (_) async => throw StateError('smol endpoint down'),
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 4,
      );
      final ok = await compactor.run();
      expect(ok, isTrue);
      final escalations = hooks.passes
          .where((p) => p.kind == 'checkpoint-escalation')
          .toList();
      expect(escalations, hasLength(1));
      expect(escalations.single.ok, isFalse);
      expect(
        (await session.getEntries()).whereType<CompactCheckpointRecord>(),
        isEmpty,
      );
    });
  });

  group('UT-ESC-8 — projection invariants inherited', () {
    test('escalation never swallows pinned records and the wire stays '
        'pair-safe', () async {
      final (session, state, hiddenIds) = await boundarySession(
        hiddenPairs: 1,
        keptPairs: 4,
        margin: 0,
      );
      // Pin the second kept pair: no checkpoint may ever cover it.
      final entries = await session.getEntries();
      final visiblePairs = entries
          .whereType<MessageRecord>()
          .where((r) => !hiddenIds.contains(r.id))
          .toList();
      final pinnedPair = visiblePairs
          .where((r) => r.message is AssistantMessage)
          .skip(1)
          .first;
      final pinnedIds = <String>{
        pinnedPair.id,
        ...entries
            .whereType<MessageRecord>()
            .where(
              (r) =>
                  r.message is ToolResultMessage &&
                  (r.message as ToolResultMessage).toolCallId ==
                      (pinnedPair.message as AssistantMessage).content
                          .whereType<ToolCall>()
                          .first
                          .id,
            )
            .map((r) => r.id),
      };
      await session.appendSegmentPin(
        recordIds: pinnedIds.toList(),
        pinned: true,
      );

      final hooks = _Hooks();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async => judgeAnswerFor(entries, hiddenIds),
        summarize: (_) => Future.value(SummarizationResult.success('CKPT')),
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 4,
      );
      final ok = await compactor.run();
      expect(ok, isTrue);
      for (final record in await session.getBranch()) {
        if (record is CompactCheckpointRecord) {
          expect(record.coversRecordIds, anyElement(isNot(pinnedPair.id)));
          expect(
            record.coversRecordIds.where(pinnedIds.contains),
            isEmpty,
            reason: 'no checkpoint may swallow a pinned record',
          );
        }
      }
      expect(validateToolPairing(state.messages), isEmpty);
    });

    test('a marker-only escalation range consolidates deterministically '
        'with NO summarizer call', () async {
      // user (500 tok) + one 102-tok pair, protectLastN 0, user pinned:
      // the judge hides the pair, the settle rides the user's own 500
      // tokens into the band, and the only foldable projection left is
      // the pair's marker.
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('u' * 2000));
      await session.appendMessage(_carrier('c0'));
      await session.appendMessage(_result('c0', 100));
      final entries = await session.getEntries();
      final userId = entries.whereType<MessageRecord>().first.id;
      await session.appendSegmentPin(recordIds: [userId], pinned: true);
      final state = _stateFor(await session.buildContextMessages());
      final hooks = _Hooks();
      var summarizeCalls = 0;
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async =>
            '["${RecordSeqIndex(entries).seqOf(entries.whereType<MessageRecord>().elementAt(1).id)}"]',
        summarize: (_) {
          summarizeCalls++;
          return Future.value(SummarizationResult.success('must not run'));
        },
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 0,
      );
      final ok = await compactor.run();
      expect(ok, isTrue);
      final escalations = hooks.passes
          .where((p) => p.kind == 'checkpoint-escalation')
          .toList();
      expect(escalations, hasLength(1));
      expect(escalations.single.ok, isTrue);
      expect(escalations.single.judgeCalls, 0, reason: 'no fake LM call');
      expect(summarizeCalls, 0, reason: 'marker-only ranges never call the LM');
      expect(
        escalations.single.summary,
        contains('already hidden behind expand markers'),
      );
      final ckpts = (await session.getEntries())
          .whereType<CompactCheckpointRecord>()
          .toList();
      expect(ckpts, hasLength(1));
      // The hidden pair ids stay expandable through the covers list.
      final hiddenIds = entries
          .whereType<MessageRecord>()
          .skip(1)
          .map((r) => r.id)
          .toSet();
      expect(
        ckpts.single.coversRecordIds.toSet().containsAll(hiddenIds),
        isTrue,
      );
    });
  });

  group('UT-ESC-9/AC9-AC10 — cancellation and budgets', () {
    test('a cancellation during the escalation surfaces: run() reports '
        'failure instead of swallowing the abort', () async {
      final (session, state, hiddenIds) = await boundarySession(
        hiddenPairs: 1,
        keptPairs: 4,
        margin: 0,
      );
      final cancelSource = CancelTokenSource();
      final hooks = _Hooks();
      final entries = await session.getEntries();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async => judgeAnswerFor(entries, hiddenIds),
        summarize: (request) async {
          // The user aborts mid-deepening; the adapter lands aborted.
          cancelSource.cancel('user abort');
          return SummarizationResult.failure('aborted', aborted: true);
        },
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 4,
        cancelToken: cancelSource.token,
      );
      final ok = await compactor.run();
      expect(ok, isFalse, reason: 'a cancelled run is never a success');
      expect(
        hooks.passes.where((p) => p.kind == 'checkpoint-escalation' && !p.ok),
        isEmpty,
        reason: 'no failed-escalation receipt may mask the abort',
      );
      expect(
        (await session.getEntries()).whereType<CompactCheckpointRecord>(),
        isEmpty,
      );
    });

    test(
      'an already-cancelled run token skips the escalation entirely',
      () async {
        final (session, state, hiddenIds) = await boundarySession(
          hiddenPairs: 1,
          keptPairs: 4,
          margin: 0,
        );
        final cancelSource = CancelTokenSource()..cancel('user abort');
        final hooks = _Hooks();
        final entries = await session.getEntries();
        var summarizeCalls = 0;
        final compactor = StructuredCompactor(
          session: session,
          state: state,
          window: 800,
          settings: _boundarySettings,
          judge: (_, [token]) async => judgeAnswerFor(entries, hiddenIds),
          summarize: (_) {
            summarizeCalls++;
            return Future.value(SummarizationResult.success('CKPT'));
          },
          checkpointPrompt: 'P',
          hooks: hooks,
          protectLastN: 4,
          cancelToken: cancelSource.token,
        );
        final ok = await compactor.run();
        expect(ok, isFalse);
        expect(summarizeCalls, 0, reason: 'a cancelled run never deepens');
      },
    );

    test('an attempt-budget expiry during the escalation propagates as '
        'the named TimeoutException (no chunk after it)', () async {
      final (session, state, hiddenIds) = await boundarySession(
        hiddenPairs: 1,
        keptPairs: 4,
        margin: 0,
      );
      final hooks = _Hooks();
      final entries = await session.getEntries();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async => judgeAnswerFor(entries, hiddenIds),
        summarize: (_) async => throw TimeoutException(
          'checkpoint summarizer deadline',
          const Duration(seconds: 1),
        ),
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 4,
      );
      await expectLater(compactor.run(), throwsA(isA<TimeoutException>()));
      expect(
        (await session.getEntries()).whereType<CompactCheckpointRecord>(),
        isEmpty,
      );
    });
  });

  group('UT-ESC-11 — multi-chunk escalation stays one pass (AC9/IT-ESC-2)', () {
    test('a range needing several chunked summarizer calls reports exactly '
        'one escalation record', () async {
      // A foldable prefix > 256 tokens (the chunker's floor) so the
      // #729 chunked fold actually splits — the exempt user ask and the
      // keep-recent tail are outside the range, so the marker-rich middle
      // plus the kept filler must carry the weight.
      // Kept FULL pairs outside the keep-recent tail put >256 tokens of
      // non-marker content in the foldable range (markers alone never
      // chunk — they consolidate deterministically).
      final (session, state, hiddenIds) = await boundarySession(
        hiddenPairs: 1,
        keptPairs: 3,
        margin: 0,
      );
      final hooks = _Hooks();
      final entries = await session.getEntries();
      var summarizerCalls = 0;
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async => judgeAnswerFor(entries, hiddenIds),
        summarize: (request) {
          summarizerCalls++;
          return Future.value(SummarizationResult.success('CKPT chunk'));
        },
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 2,
        // A tiny summarizer window forces the #729 chunked fold:
        // budget = max(128 - 200, 64) = 64 tokens per chunk.
        summarizerWindow: 128,
      );
      final ok = await compactor.run();
      expect(ok, isTrue);
      expect(
        summarizerCalls,
        greaterThanOrEqualTo(2),
        reason: 'the range must actually need multiple chunks',
      );
      final escalations = hooks.passes
          .where((p) => p.kind == 'checkpoint-escalation')
          .toList();
      expect(
        escalations,
        hasLength(1),
        reason: 'N summarizer calls fold into ONE escalation pass record',
      );
      expect(escalations.single.ok, isTrue);
      expect(escalations.single.marginTokens, 0);
      expect(escalations.single.bandTokens, 200);
      // gh-2044 rework (review thread 4): the receipt's judgeCalls must
      // report the REAL summarizer call count — a #729 chunked fold makes
      // N calls, and the old hardcoded `1` under-reported them.
      expect(
        escalations.single.judgeCalls,
        summarizerCalls,
        reason: 'the receipt carries the real chunked call count',
      );
      expect(escalations.single.judgeCalls, greaterThanOrEqualTo(2));
    });
  });

  group('UT-ESC-10 — observability is content-safe', () {
    test('the escalation report carries margin/band/outcome and never '
        'ledger content in its diagnostics', () async {
      final (session, state) = await incidentSession();
      final hooks = _Hooks();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 400000,
        settings: _incidentSettings,
        judge: (_, [token]) async => null,
        summarize: (_) =>
            Future.value(SummarizationResult.success('ESCALATED')),
        checkpointPrompt: 'P',
        hooks: hooks,
      );
      await compactor.run();
      final escalations = hooks.passes
          .where((p) => p.kind == 'checkpoint-escalation')
          .toList();
      expect(escalations, hasLength(1));
      final escalation = escalations.single;
      expect(escalation.pass, greaterThan(0));
      expect(escalation.tokensBefore, greaterThan(0));
      expect(escalation.tokensAfter, lessThan(escalation.tokensBefore));
      expect(escalation.marginTokens, isNotNull);
      expect(escalation.bandTokens, isNotNull);
      // Counts only: no pass diagnostic embeds rendered ledger or
      // message content (the fixture's payload bytes never appear).
      for (final pass in hooks.passes) {
        final errorText = pass.error?.toString() ?? '';
        expect(errorText.contains('xxxx'), isFalse);
        expect(errorText.contains('uuuu'), isFalse);
      }
    });
  });

  group('UT-ESC-12 — the keep-recent boundary cannot fold the whole live '
      'world (gh-2044 rework)', () {
    test('an escalation whose foldable path fits keepRecentTokens with live '
        'records left declines: no fold, no live-tail swallow, honest '
        'no-range receipt, verdict stands', () async {
      // Layout (file order): user ask (100 tok, LIVE), one pinned filler
      // (300 tok — absorbs the weight so the settle stays in the band),
      // two read pairs the judge hides (102 tok full → 35 tok markers),
      // one live 25-tok filler tail. Entry 629 > 600; after the hides the
      // settle is 495 → margin 105 rides into the band and the escalation
      // fires. Its foldable path — user + both marker pairs + the tail —
      // is 195 tokens, INSIDE keepRecentTokens (200): the keep-recent
      // region covers the whole path, so NOTHING may fold. The old
      // whole-world fold swallowed the live user ask and the tail filler
      // (leaving hosts a projection with no live turn at all — the
      // resumed-child "subagent produced no assistant message" CI
      // regression).
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('u' * 400));
      await session.appendMessage(_filler(300));
      await session.appendMessage(_carrier('c0'));
      await session.appendMessage(_result('c0', 100));
      await session.appendMessage(_carrier('c1'));
      await session.appendMessage(_result('c1', 100));
      await session.appendMessage(_filler(25));
      final entries = await session.getEntries();
      // Pin the big filler: it can never fold, and it keeps the settle
      // inside the fragile band after the hides.
      final pinnedId = entries.whereType<MessageRecord>().elementAt(1).id;
      await session.appendSegmentPin(recordIds: [pinnedId], pinned: true);
      // The judge hides both pairs (whole groups, carrier seqs).
      final hiddenIds = <String>{
        entries.whereType<MessageRecord>().elementAt(2).id,
        entries.whereType<MessageRecord>().elementAt(3).id,
        entries.whereType<MessageRecord>().elementAt(4).id,
        entries.whereType<MessageRecord>().elementAt(5).id,
      };
      final state = _stateFor(await session.buildContextMessages());
      expect(
        _requestTokens(state),
        greaterThan(600),
        reason: 'fixture precondition: the run enters over the trigger',
      );

      final hooks = _Hooks();
      var summarizeCalls = 0;
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async => judgeAnswerFor(entries, hiddenIds),
        summarize: (_) {
          summarizeCalls++;
          return Future.value(SummarizationResult.success('SWALLOWED'));
        },
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 0,
      );
      final ok = await compactor.run();

      // The verdict stands: the run settled at 495, under the trigger.
      expect(ok, isTrue);
      final escalations = hooks.passes
          .where((p) => p.kind == 'checkpoint-escalation')
          .toList();
      expect(escalations, hasLength(1));
      // The bounded no-op receipt (gh-2044 semantic 5): nothing foldable
      // below the keep-recent boundary.
      expect(escalations.single.ok, isFalse);
      expect(
        escalations.single.error.toString(),
        contains('no foldable range'),
      );
      expect(escalations.single.marginTokens, 105);
      expect(escalations.single.bandTokens, 200);
      expect(
        summarizeCalls,
        0,
        reason: 'no LM call may summarize the live tail away',
      );
      expect(
        (await session.getEntries()).whereType<CompactCheckpointRecord>(),
        isEmpty,
        reason: 'the whole-live-world fold must not append a checkpoint',
      );
      // The live projection survives: the user ask and the tail filler
      // are still rendered messages, never checkpoint-covered.
      final userAsk = state.messages.whereType<UserMessage>().firstOrNull;
      expect(userAsk, isNotNull, reason: 'the live user ask survives');
      expect(
        state.messages.whereType<AssistantMessage>().where(
          (m) => m.content.whereType<TextContent>().any(
            (b) => b.text.startsWith('ffff'),
          ),
        ),
        isNotEmpty,
        reason: 'the live tail filler survives',
      );
    });

    test('the hideableRemaining diagnostic reads 0 when every entry is '
        'exempt or inside the protected tail', () async {
      // Same shape as the pinned-pair fixture (UT-ESC-8) but with
      // protectLastN 16: every visible non-exempt record (9 after the
      // hide) sits inside the protected tail, so the diagnostic count
      // rides 0 — the count-only diagnostic branch the review thread
      // flagged.
      final (session, state, hiddenIds) = await boundarySession(
        hiddenPairs: 1,
        keptPairs: 4,
        margin: 0,
      );
      final entries = await session.getEntries();
      final hooks = _Hooks();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        judge: (_, [token]) async => judgeAnswerFor(entries, hiddenIds),
        summarize: (_) => Future.value(SummarizationResult.success('CKPT')),
        checkpointPrompt: 'P',
        hooks: hooks,
        protectLastN: 16,
      );
      final ok = await compactor.run();
      expect(ok, isTrue);
      final escalations = hooks.passes
          .where((p) => p.kind == 'checkpoint-escalation')
          .toList();
      expect(escalations, hasLength(1));
      expect(
        escalations.single.hideableRemaining,
        0,
        reason: 'every hideable entry is exempt or tail-protected',
      );
    });
  });

  group('UT-ESC-13 — an over-window run whose whole ledger fits '
      'keepRecentTokens still folds (gh-2044 rework, flutter_app '
      'over-window relief AC)', () {
    test('the ladder folds the tool-result-heavy whole world when relief is '
        'required — the decline stays escalation-only', () async {
      // The flutter_app over-window fixture (agent_service_test.dart
      // "auto-compaction over-window guard"): user ask + carrier +
      // a 34000-char tool result over an 8192 window with the app's
      // hosted settings (reserve 2048, keep 4096). The request estimate
      // (~8.5k) is far over the trigger, yet every LEDGER token (~870)
      // fits keepRecentTokens — the keep-recent walk cuts nowhere, and
      // the tool result alone exceeds the window, so folding the whole
      // world is the ONLY summarizer-based relief. The shared decline
      // must NOT starve the ladder here: main's whole-world fold
      // collapsed this transcript to ~85 tokens and the turn continued;
      // the decline turned the relief into a hollow classic record
      // (+29 tokens) and the app AC red.
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('go'));
      await session.appendMessage(_carrier('tc-1'));
      await session.appendMessage(_result('tc-1', 8500));
      final model = Model(
        id: 'm1',
        name: 'm1',
        api: 'anthropic-messages',
        provider: 'p',
        baseUrl: 'http://localhost:1',
        contextWindow: 8192,
        maxTokens: 4096,
      );
      final state = _stateFor(
        await session.buildContextMessages(),
        contextWindow: 8192,
      );
      const appSettings = CompactionSettings(
        enabled: true,
        reserveTokens: 2048,
        keepRecentTokens: 4096,
      );
      final before = _requestTokens(state);
      expect(before, greaterThan(8192 - 512));
      // (The ledger's walk tokens for this fixture total well under
      // keepRecentTokens — the whole-world regime the pick's walk
      // measures — but that currency is engine-internal; the assertions
      // below pin the OBSERVABLE behavior instead.)

      final hooks = _CapturingAutoHooks();
      AssistantMessage reliefMessage() => AssistantMessage(
        content: [TextContent(text: 'continued')],
        api: 'test-api',
        provider: 'test-provider',
        model: 'm1',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      );
      final ok = await AutoCompactorFactory(
        session: session,
        state: state,
        window: 8192,
        settings: appSettings,
        sources: AutoCompactorSources(
          smolStream: null,
          smolModel: null,
          mainStream: (m, c, {cancelToken}) {
            final message = reliefMessage();
            return AssistantMessageEventStream()
              ..push(DoneEvent(reason: StopReason.stop, message: message))
              ..end();
          },
          mainModel: model,
        ),
        hooks: hooks,
        prompts: const CompactionPrompts(),
        engine: CompactionEngine.structured,
      ).run();

      expect(ok, isTrue);
      final folds = hooks.passes
          .where((p) => p.ok && p.tokensAfter < p.tokensBefore)
          .toList();
      expect(
        folds,
        isNotEmpty,
        reason:
            'relief is required: at least one pass must SHRINK the '
            'request — the app relief gate reads afterTokens < beforeTokens',
      );
      expect(
        hooks.passes.map((p) => p.fallback),
        everyElement(startsWith('structured')),
        reason:
            'no hollow classic fall-through may run when the ladder '
            'can fold',
      );
      expect(
        (await session.getEntries()).whereType<CompactionRecord>(),
        isEmpty,
        reason: 'the classic contentless record must not appear',
      );
      final after = _requestTokens(
        _stateFor(await session.buildContextMessages(), contextWindow: 8192),
      );
      expect(
        after,
        lessThan(before),
        reason:
            'the rebuilt projection must shrink: the huge tool result '
            'folds into the checkpoint summary',
      );
    });
  });

  group('IT-ESC — factory wiring', () {
    AssistantMessage streamMessage(StopReason reason, String text) =>
        AssistantMessage(
          content: [TextContent(text: text)],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: reason,
          timestamp: DateTime.utc(2026),
        );

    AssistantMessageEventStream streamOf(
      AssistantMessage message,
      List<AssistantMessageEvent> events,
    ) {
      final stream = AssistantMessageEventStream()
        ..push(StartEvent(partial: message));
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
      return stream;
    }

    String promptText(Context context) {
      final last = context.messages.last;
      return switch (last) {
        UserMessage() =>
          last.content is String
              ? last.content as String
              : (last.content as List<Object>)
                    .whereType<TextContent>()
                    .map((b) => b.text)
                    .join(),
        _ => '',
      };
    }

    test('IT-ESC-1: a dead judge + deterministic fallback hide still '
        'escalates in the same structured run', () async {
      final (session, state) = await incidentSession();
      final hooks = _CapturingAutoHooks();
      var judgeStreamCalls = 0;
      var checkpointStreamCalls = 0;
      final ok = await AutoCompactorFactory(
        session: session,
        state: state,
        window: 400000,
        settings: _incidentSettings,
        sources: AutoCompactorSources(
          smolStream: (m, c, {cancelToken}) {
            if (promptText(c).contains('<conversation>')) {
              checkpointStreamCalls++;
              final message = streamMessage(StopReason.stop, 'ESCALATED');
              return streamOf(message, [
                TextStartEvent(
                  contentIndex: 0,
                  partial: streamMessage(StopReason.stop, ''),
                ),
                DoneEvent(reason: StopReason.stop, message: message),
              ]);
            }
            judgeStreamCalls++;
            final message = streamMessage(StopReason.error, '');
            return streamOf(message, [
              ErrorEvent(reason: StopReason.error, error: message),
            ]);
          },
          smolModel: null,
          mainStream: (m, c, {cancelToken}) => throw UnimplementedError(),
          mainModel: _factoryModel,
        ),
        hooks: hooks,
      ).run();

      expect(ok, isTrue, reason: 'structured success: fallback + escalation');
      expect(judgeStreamCalls, 2, reason: 'two judge stalls, then fallback');
      expect(checkpointStreamCalls, 1, reason: 'the escalation checkpoint');
      final fallbackLabels = hooks.passes.map((p) => p.fallback).toList();
      expect(fallbackLabels, contains('structured·hide-fallback'));
      expect(fallbackLabels, contains('structured·ckpt-escalation'));
      expect(hooks.doneCount, 1, reason: 'the host bracket closes once');
    });

    test('IT-ESC-6: a user abort mid-escalation through the factory '
        'surfaces — even when the cancel reason is a TimeoutException '
        '(gh-2044 review thread 3)', () async {
      // The production abort path: _runStructured links the factory's
      // runToken into the budget token (budgetSource.cancel(runToken
      // .cancelReason)). A watchdog-shaped cancel reason (any
      // TimeoutException) used to defeat the engine's reason-type
      // heuristic — the escalation proceeded, its LM call died, and the
      // abort dissolved into a "summarizer returned no text" failed
      // receipt while run() reported SUCCESS (the #1085 shape). The
      // wired cancelToken makes _runCancelled authoritative instead.
      final (session, state) = await incidentSession();
      final runSource = CancelTokenSource();
      final hooks = _CapturingAutoHooks();
      var checkpointStreamCalls = 0;
      final run = AutoCompactorFactory(
        session: session,
        state: state,
        window: 400000,
        settings: _incidentSettings,
        runToken: runSource.token,
        sources: AutoCompactorSources(
          smolStream: (m, c, {cancelToken}) {
            if (promptText(c).contains('<conversation>')) {
              checkpointStreamCalls++;
              // The user (or a watchdog) aborts mid-deepening.
              runSource.cancel(
                TimeoutException('watchdog fired', const Duration(seconds: 5)),
              );
              final message = streamMessage(StopReason.aborted, '');
              return streamOf(message, [
                ErrorEvent(reason: StopReason.aborted, error: message),
              ]);
            }
            // The incident's dead judge: two stalls, then the fallback.
            final message = streamMessage(StopReason.error, '');
            return streamOf(message, [
              ErrorEvent(reason: StopReason.error, error: message),
            ]);
          },
          smolModel: null,
          mainStream: (m, c, {cancelToken}) => throw UnimplementedError(),
          mainModel: _factoryModel,
        ),
        hooks: hooks,
      ).run();

      // The abort must surface as an exception (#1085), never as a
      // success or a failed-optional-pass receipt.
      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(checkpointStreamCalls, 1, reason: 'the escalation was entered');
      expect(
        hooks.passes.where(
          (p) => p.fallback == 'structured·ckpt-escalation' && !p.ok,
        ),
        isEmpty,
        reason: 'no failed-escalation receipt may mask the abort',
      );
    });

    test('IT-ESC-5: a cap-forced run does not escalate (cap channel keeps '
        'its existing classic fall-through)', () async {
      // 4 messages at ~100 tok each: under the 600 token trigger, over
      // the message-cap trigger (cap 4, margin 2 → fires at count >= 2).
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      for (var i = 0; i < 2; i++) {
        await session.appendMessage(UserMessage.text('u' * 400));
        await session.appendMessage(_filler(100));
      }
      final state = _stateFor(await session.buildContextMessages());
      final hooks = _CapturingAutoHooks();
      final ok = await AutoCompactorFactory(
        session: session,
        state: state,
        window: 800,
        settings: _boundarySettings,
        sources: AutoCompactorSources(
          smolStream: null,
          smolModel: null,
          mainStream: (m, c, {cancelToken}) {
            final message = streamMessage(StopReason.stop, 'classic fold');
            return streamOf(message, [
              TextStartEvent(
                contentIndex: 0,
                partial: streamMessage(StopReason.stop, ''),
              ),
              DoneEvent(reason: StopReason.stop, message: message),
            ]);
          },
          mainModel: _factoryModel,
        ),
        hooks: hooks,
        messageCap: 4,
        messageCapMargin: 2,
      ).run();

      expect(ok, isTrue);
      expect(
        hooks.passes
            .map((p) => p.fallback)
            .where((f) => f == 'structured·ckpt-escalation'),
        isEmpty,
        reason: 'cap-forced runs never escalate',
      );
      expect(
        hooks.passes.map((p) => p.fallback),
        everyElement(isNot(startsWith('structured'))),
        reason: 'the cap channel falls through to the classic engine',
      );
    });
  });
}

const _factoryModel = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 400000,
  maxTokens: 4096,
);

final class _CapturingAutoHooks implements AutoCompactorHooks {
  final passes = <AutoCompactorPass>[];
  int doneCount = 0;

  @override
  void onDelta(String delta) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}

  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);

  @override
  void onDone(int passes, int tokens) => doneCount++;

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onBothRolesFailed(Object lastError) {}
}
