// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-209 — the emergency compaction tier: deterministic mid-turn
/// relief with NO language model anywhere.
///
/// AC coverage:
/// - the relief completes deterministically (no LM call is even
///   possible: the tier takes no judge/summarizer) with a bounded wall
///   time;
/// - keep-N-recent per tool class hides the stalest groups first;
/// - repeated reads of the same path dedup (newest successful copy
///   survives), including the negative cases (a failed newest read must
///   NOT fold its older good copy; different paths never dedup);
/// - the shared invariants hold: pair groups hide atomically, real user
///   turns never hide, unanswered carriers never hide, pinned
///   expansions never hide;
/// - the local trim valve bounds the live context when hides cannot;
/// - session survival (owner directive): the tier writes ONLY additive
///   hidden-range records — an old (large) session file stays
///   byte-identical apart from the appended records.
///
/// Token math (chars/4 estimator): 8000 payload chars ≈ 2000 tokens.
/// Window 8000, reserve 2000 → the relief target is 6000.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/emergency_relief.dart';
import 'package:test/test.dart';

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) {
  return AssistantMessage(
    content: [TextContent(text: text), ...?calls],
    api: 'anthropic-messages',
    provider: 'p',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

ToolResultMessage _result(
  String callId,
  String name,
  String text, {
  bool isError = false,
}) {
  return ToolResultMessage(
    toolCallId: callId,
    toolName: name,
    content: [TextContent(text: text)],
    isError: isError,
    timestamp: DateTime.utc(2026),
  );
}

/// Window 8000, reserve 2000 → trigger/relief target 6000; keep-recent
/// 2000 (the trim valve's kept region).
const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 2000,
  keepRecentTokens: 2000,
);

AgentState _state(List<Message> messages) => AgentState(
  model: Model(
    id: 'm1',
    name: 'm1',
    api: 'anthropic-messages',
    provider: 'p',
    baseUrl: 'http://localhost:1',
    contextWindow: 8000,
    maxTokens: 4096,
  ),
  messages: messages,
);

/// One read pair: an assistant carrier with a `read` call plus its
/// result ([chars] payload chars ≈ chars/4 tokens).
List<Message> _readPair(
  String callId,
  String path,
  String payloadChar, {
  int chars = 8000,
  bool isError = false,
}) => [
  _assistant(
    'reading $path',
    calls: [
      ToolCall(id: callId, name: 'read', arguments: {'path': path}),
    ],
  ),
  _result(callId, 'read', payloadChar * chars, isError: isError),
];

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  /// The session JSONL text (the memory fs's read API is Result-shaped).
  Future<String> sessionFileText(Session session) async {
    final path = (await session.getMetadata()).path;
    return (await fs.readTextFile(path)).valueOrNull ?? '';
  }

  /// Every hidden_range record's id set currently in the file.
  Future<List<List<String>>> hiddenRangesInFile(Session session) async {
    final text = await sessionFileText(session);
    final ranges = <List<String>>[];
    for (final line in text.split('\n')) {
      if (!line.contains('"type":"hidden_range"')) continue;
      final record = jsonDecode(line) as Map;
      ranges.add(
        [for (final id in (record['recordIds'] as List)) id as String],
      );
    }
    return ranges;
  }

  group('dedup repeated reads', () {
    /// Three read pairs: a.dart (older), b.dart, a.dart again (newest —
    /// its `./a.dart` spelling normalizes to the same dedup key).
    /// ~6.1k estimated tokens → over the 6000 target by a sliver the
    /// dedup pass (2k) alone relieves — no trim valve.
    Future<(Session, AgentState)> dedupSession() async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('inspect the config'));
      for (final pair in [
        ..._readPair('r1', 'a.dart', 'a'),
        ..._readPair('r2', 'b.dart', 'b'),
        ..._readPair('r3', './a.dart', 'c'),
      ]) {
        await session.appendMessage(pair);
      }
      for (var i = 0; i < 4; i++) {
        await session.appendMessage(_assistant('analysis $i'));
      }
      final messages = await session.buildContextMessages();
      assert(
        estimateContextTokens(messages).tokens > 6000,
        'fixture must be over the relief target',
      );
      return (session, _state(messages));
    }

    test('the older read of a path folds, the newest copy survives',
        () async {
      final (session, state) = await dedupSession();
      final relief = EmergencyRelief(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        // Generous class keeps: the dedup must do the work here, not
        // the keep-N-recent pass. A short live-edge floor so the old
        // groups leave the protected tail.
        keepRecent: const {'read': 99, 'exec': 99, 'other': 99},
        protectLastN: 2,
      );

      final outcome = await relief.run();

      expect(outcome.ok, isTrue);
      expect(outcome.alreadyUnder, isFalse);
      expect(outcome.dedupedPaths, 1, reason: 'only a.dart repeats');
      expect(outcome.hiddenGroups, 1);
      expect(outcome.hiddenRecords, 2, reason: 'carrier + result atomically');
      expect(outcome.usedTrimValve, isFalse);

      final messages = state.messages;
      final markerTexts = messages
          .whereType<UserMessage>()
          .map((m) => m.content as String)
          .where((text) => text.contains(':hidden'))
          .toList();
      // The r1 pair became two markers.
      expect(markerTexts, hasLength(2));
      // The two other read copies stay live.
      final liveReads = messages
          .whereType<ToolResultMessage>()
          .where((m) => m.toolName == 'read')
          .map((m) => (m.content.first as TextContent).text[0])
          .toSet();
      expect(liveReads, containsAll(<String>{'b', 'c'}));
      expect(liveReads, isNot(contains('a')), reason: 'r1 folded');
    });

    test('a failed newest read never folds its older good copy', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      await session.appendMessage(UserMessage.text('inspect the config'));
      // The GOOD older copy is heavy (24k chars ≈ 6k tokens) so the
      // session is over the target; the NEWEST copy failed.
      for (final pair in [
        ..._readPair('r1', 'a.dart', 'g', chars: 24000),
        ..._readPair('r2', 'a.dart', 'x', chars: 12, isError: true),
      ]) {
        await session.appendMessage(pair);
      }
      for (var i = 0; i < 4; i++) {
        await session.appendMessage(_assistant('analysis $i'));
      }
      final r1RecordIds = <String>[];
      // The r1 pair's record ids are the two appends before r2's —
      // resolve them from the file instead of counting appends.
      final text = await sessionFileText(session);
      for (final line in text.split('\n')) {
        if (line.contains('"r1"')) r1RecordIds.add(line);
      }
      final state = _state(await session.buildContextMessages());
      final relief = EmergencyRelief(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        keepRecent: const {'read': 99, 'exec': 99, 'other': 99},
        protectLastN: 2,
      );

      final outcome = await relief.run();

      // The dedup pass declined: no group of the path folded (the only
      // successful copy is the OLDER one; a failed newest read cannot
      // relieve it). Nothing hideable remained → the trim valve bounded
      // the live context instead, and the session file gained NO
      // hidden-range record at all.
      expect(outcome.dedupedPaths, 0);
      expect(outcome.usedTrimValve, isTrue);
      expect(await hiddenRangesInFile(session), isEmpty);
    });

    test('different paths never dedup each other', () async {
      final (session, state) = await dedupSession();
      final relief = EmergencyRelief(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        keepRecent: const {'read': 99, 'exec': 99, 'other': 99},
        protectLastN: 2,
      );

      final outcome = await relief.run();

      // Only a.dart repeats (r1 vs r3): b.dart (r2) must stay live.
      expect(outcome.dedupedPaths, 1);
      expect(outcome.usedTrimValve, isFalse);
      final liveReads = state.messages
          .whereType<ToolResultMessage>()
          .where((m) => m.toolName == 'read')
          .map((m) => (m.content.first as TextContent).text[0]);
      expect(liveReads, contains('b'));
    });
  });

  group('keep-N-recent per tool class', () {
    /// Twelve read/bash groups (~200 tokens each ≈ 2.55k total). The
    /// relief target is 2000 (window 2800 − reserve 800) → over ≈ 550;
    /// keeps at 2 per class leave 8 candidates (~1.3k net) — the
    /// stalest-first walk folds ~4 groups and lands comfortably under
    /// the target with no trim valve (candidates' net total > over is
    /// engine-guaranteed: after = before − freed, exactly).
    Future<(Session, AgentState, List<String>)> multiToolSession() async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      final carrierIds = <String>[];
      var callId = 0;
      Future<void> group(String tool, String payloadChar) async {
        final id = 'c${++callId}';
        carrierIds.add(id);
        await session.appendMessage(
          _assistant(
            'group $id',
            calls: [
              ToolCall(id: id, name: tool, arguments: {'path': 'f$id.txt'}),
            ],
          ),
        );
        await session.appendMessage(
          _result(id, tool, payloadChar * 800),
        );
      }

      await session.appendMessage(UserMessage.text('sweep the repo'));
      for (var i = 0; i < 6; i++) {
        await group('read', 'a');
      }
      for (var i = 0; i < 6; i++) {
        await group('bash', '1');
      }
      await session.appendMessage(_assistant('wrapping up'));
      final state = _state(await session.buildContextMessages());
      return (session, state, carrierIds);
    }

    const _keepTwoSettings = CompactionSettings(
      enabled: true,
      reserveTokens: 800,
      keepRecentTokens: 400,
    );
    final _keepTwoRelief = {
      'read': 2,
      'exec': 2,
      'other': 99,
    };

    test('stalest-first hides past the per-class keep budget (multi-item)',
        () async {
      final (session, state, carrierIds) = await multiToolSession();
      final relief = EmergencyRelief(
        session: session,
        state: state,
        window: 2800,
        settings: _keepTwoSettings,
        keepRecent: _keepTwoRelief,
        protectLastN: 2,
      );

      final outcome = await relief.run();

      expect(outcome.ok, isTrue);
      expect(outcome.usedTrimValve, isFalse);
      expect(outcome.droppedMessages, 0);
      // Multi-item: several groups fold (2 records each — carrier +
      // result atomically).
      expect(outcome.hiddenGroups, greaterThanOrEqualTo(2));
      expect(outcome.hiddenRecords, outcome.hiddenGroups * 2);
      // The per-class NEWEST copies stay live; the STALEST fold.
      final live = state.messages
          .whereType<ToolResultMessage>()
          .map((m) => m.toolCallId)
          .toSet();
      expect(live.contains('c1'), isFalse, reason: 'oldest read folded');
      expect(live.contains('c2'), isFalse, reason: 'second-oldest read folded');
      expect(live.contains('c5'), isTrue, reason: 'a kept read stays live');
      expect(live.contains('c6'), isTrue, reason: 'newest read kept');
      expect(live.contains('c7'), isTrue, reason: 'oldest KEPT bash stays');
      expect(live.contains('c12'), isTrue, reason: 'newest bash kept');
      // Every folded record still sits in the session file — lossless.
      final fileText = await sessionFileText(session);
      for (final id in carrierIds) {
        expect(fileText, contains('"$id"'));
      }
    });

    test('exempt user turns and the live tail never hide', () async {
      final (session, state, _) = await multiToolSession();
      const userText = 'sweep the repo';
      final relief = EmergencyRelief(
        session: session,
        state: state,
        window: 2800,
        settings: _keepTwoSettings,
        keepRecent: _keepTwoRelief,
        protectLastN: 2,
      );

      final outcome = await relief.run();

      expect(outcome.usedTrimValve, isFalse);
      // The real user turn stays live verbatim (F8 — tool groups never
      // contain it, and no hide path touches exempt records).
      final liveUsers = state.messages
          .whereType<UserMessage>()
          .where((m) => (m.content as String) == userText)
          .toList();
      expect(liveUsers, hasLength(1));
      // The newest assistant line (inside the protected tail) stays live.
      final last = state.messages.last;
      expect(last, isA<AssistantMessage>());
      expect(
        (last as AssistantMessage).content.whereType<TextContent>().first.text,
        'wrapping up',
      );
    });
  });

  group('invariants and edges', () {
    test('a single oversized newest tool result folds so the turn survives '
        '(the buster rule)', () async {
      // One pair group whose result ALONE busts the target: the trim
      // valve cannot help (its budget is capped by keepRecentTokens, and
      // the newest message exceeds it — gh-107's "nothing droppable"
      // shape), so the keep-N pass's buster rule folds the biggest
      // record. Lossless append: the full result stays in the session
      // file behind the marker.
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      await session.appendMessage(UserMessage.text('go'));
      for (final message
          in _readPair('r1', 'huge.log', 'x', chars: 40000)) {
        await session.appendMessage(message);
      }
      final state = _state(await session.buildContextMessages());
      const tightSettings = CompactionSettings(
        enabled: true,
        reserveTokens: 200,
        keepRecentTokens: 400,
      );
      final relief = EmergencyRelief(
        session: session,
        state: state,
        window: 800,
        settings: tightSettings,
        keepRecent: const {'read': 2, 'exec': 4, 'other': 8},
        protectLastN: 2,
      );

      final outcome = await relief.run();

      expect(outcome.ok, isTrue);
      expect(outcome.usedTrimValve, isFalse);
      expect(outcome.hiddenGroups, 1, reason: 'the oversized group folded');
      expect(outcome.hiddenRecords, 2, reason: 'carrier + result atomically');
      expect(
        state.messages.whereType<ToolResultMessage>(),
        isEmpty,
        reason: 'the ballooned result left the live context',
      );
      // Lossless: the full payload stays on disk.
      final fileText = await sessionFileText(session);
      expect(fileText, contains('x' * 400));
    });

    test('already-under target: no-op outcome, nothing written', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      await session.appendMessage(UserMessage.text('tiny'));
      final state = _state(await session.buildContextMessages());
      final relief = EmergencyRelief(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
      );

      final outcome = await relief.run();

      expect(outcome.ok, isTrue);
      expect(outcome.alreadyUnder, isTrue);
      expect(outcome.tokensBefore, outcome.tokensAfter);
      expect(outcome.hiddenRecords, 0);
    });

    test('unanswered carriers never hide (pair integrity)', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      await session.appendMessage(UserMessage.text('run it'));
      final live1Record = await session.appendMessage(
        _assistant('running', calls: [
          const ToolCall(id: 'live1', name: 'bash', arguments: {}),
        ]),
      );
      // NO result for live1 — the carrier must never fold, whatever the
      // class budgets say. Its stale sibling (a completed pair) is the
      // relief food.
      await session.appendMessage(_result('done1', 'bash', 'x' * 8000));
      await session.appendMessage(
        _assistant('again', calls: [
          const ToolCall(id: 'live2', name: 'bash', arguments: {}),
        ]),
      );
      await session.appendMessage(_result('live2', 'bash', 'y' * 8000));
      final state = _state(await session.buildContextMessages());
      final relief = EmergencyRelief(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        keepRecent: const {'read': 1, 'exec': 0, 'other': 99},
        protectLastN: 2,
      );

      final outcome = await relief.run();

      expect(outcome.ok, isTrue);
      // The unanswered carrier's record id never lands in a hidden
      // range; the answered sibling pair may fold atomically.
      for (final ids in await hiddenRangesInFile(session)) {
        expect(ids, isNot(contains(live1Record)));
        expect(ids, hasLength(2), reason: 'groups hide whole');
      }
      // And the live call still rides the wire unanswered (the loop's
      // request-boundary repairer owns synthesis — the relief creates
      // NO new orphans).
      final liveCalls = state.messages
          .whereType<AssistantMessage>()
          .expand((m) => m.content.whereType<ToolCall>())
          .map((c) => c.id)
          .toSet();
      expect(liveCalls, contains('live1'));
    });

    test('trim valve bounds the live context when hides free nothing',
        () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      await session.appendMessage(UserMessage.text('big'));
      // Two medium read pairs (each ~5k tokens — none ALONE busts the
      // 8000 window, so the buster rule stays out) within the per-class
      // keep budget, plus a small live tail. The hide passes free
      // nothing; only the trim valve can bound the live context,
      // keeping the tail and dropping the head.
      await session.appendMessage(
        _assistant(
          'medium read one',
          calls: [
            const ToolCall(
              id: 'm1',
              name: 'read',
              arguments: {'path': 'one.txt'},
            ),
          ],
        ),
      );
      await session.appendMessage(_result('m1', 'read', 'H' * 20000));
      await session.appendMessage(
        _assistant(
          'medium read two',
          calls: [
            const ToolCall(
              id: 'm2',
              name: 'read',
              arguments: {'path': 'two.txt'},
            ),
          ],
        ),
      );
      await session.appendMessage(_result('m2', 'read', 'H' * 20000));
      for (var i = 0; i < 4; i++) {
        await session.appendMessage(_assistant('tail $i'));
      }
      final state = _state(await session.buildContextMessages());
      final relief = EmergencyRelief(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        protectLastN: 2,
      );

      final outcome = await relief.run();

      expect(outcome.usedTrimValve, isTrue);
      expect(outcome.droppedMessages, greaterThanOrEqualTo(1));
      expect(outcome.alreadyUnder, isFalse);
      // The session file keeps every record — the trim is in-memory.
      final live = await session.buildContextMessages();
      expect(live.length, greaterThan(state.messages.length));
    });

    test('pinned expansions never hide', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      await session.appendMessage(UserMessage.text('pin me'));
      final pinCarrier = await session.appendMessage(
        _assistant(
          'reading pinned',
          calls: [
            const ToolCall(
              id: 'p1',
              name: 'read',
              arguments: {'path': 'pinned.txt'},
            ),
          ],
        ),
      );
      final pinnedResult = await session.appendMessage(
        _result('p1', 'read', 'p' * 16000),
      );
      final pinnedIds = <String>[pinCarrier, pinnedResult];
      await session.appendSegmentPin(recordIds: pinnedIds, pinned: true);
      await session.appendMessage(_assistant('filler between'));
      await session.appendMessage(
        _assistant(
          'reading other',
          calls: [
            const ToolCall(
              id: 'p2',
              name: 'read',
              arguments: {'path': 'other.txt'},
            ),
          ],
        ),
      );
      await session.appendMessage(_result('p2', 'read', 'q' * 16000));
      for (var i = 0; i < 3; i++) {
        await session.appendMessage(_assistant('tail $i'));
      }
      final state = _state(await session.buildContextMessages());
      final relief = EmergencyRelief(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        keepRecent: const {'read': 1, 'exec': 1, 'other': 99},
        protectLastN: 2,
      );

      final outcome = await relief.run();

      expect(outcome.ok, isTrue);
      // The unpinned group may fold; the pinned group must never enter
      // any hidden range.
      for (final ids in await hiddenRangesInFile(session)) {
        expect(
          ids.any(pinnedIds.contains),
          isFalse,
          reason: 'a pinned record must never hide',
        );
      }
    });
  });

  group('session survival (owner directive)', () {
    /// A "large" old session: 60 alternating turns with reads and bash
    /// results (~300 records), written the pre-gh-209 way — plain
    /// appends, no migration.
    Future<(Session, AgentState)> largeOldSession() async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
      for (var i = 0; i < 60; i++) {
        await session.appendMessage(UserMessage.text('request $i'));
        await session.appendMessage(
          _assistant(
            'reading file $i',
            calls: [
              ToolCall(
                id: 'r$i',
                name: 'read',
                arguments: {'path': 'f$i.txt'},
              ),
            ],
          ),
        );
        await session.appendMessage(_result('r$i', 'read', 'x' * 4000));
        await session.appendMessage(
          _assistant('running $i', calls: [
            ToolCall(id: 'b$i', name: 'bash', arguments: {}),
          ]),
        );
        await session.appendMessage(_result('b$i', 'bash', 'y' * 2000));
        await session.appendMessage(_assistant('done $i'));
      }
      final state = _state(await session.buildContextMessages());
      return (session, state);
    }

    test(
      'an old large session loads unchanged — byte-identical apart from '
      'the appended hidden-range records',
      timeout: const Timeout(Duration(seconds: 60)),
      () async {
        final (session, state) = await largeOldSession();
        final metadata = await session.getMetadata();
        Future<Uint8List> sessionBytes() async =>
            (await fs.readBinaryFile(metadata.path)).valueOrNull!;
        final beforeBytes = await sessionBytes();

        final relief = EmergencyRelief(
          session: session,
          state: state,
          window: 8000,
          settings: _settings,
          keepRecent: const {'read': 1, 'exec': 1, 'other': 99},
        );
        final outcome = await relief.run();

        expect(outcome.hiddenRecords, greaterThan(0));
        final afterBytes = await sessionBytes();
        // The prefix is byte-identical: nothing was rewritten or
        // migrated — the tier only APPENDS additive records.
        expect(afterBytes.length, greaterThan(beforeBytes.length));
        expect(
          afterBytes.sublist(0, beforeBytes.length),
          equals(beforeBytes),
        );
        // The appended lines are hidden-range records only.
        final appendedText = utf8.decode(afterBytes.sublist(
          beforeBytes.length,
        ));
        final appendedLines = appendedText
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .toList();
        expect(appendedLines, isNotEmpty);
        for (final line in appendedLines) {
          expect(line, contains('"type":"hidden_range"'));
        }
        // And the old session still replays: the projection rebuilds
        // with every original record reachable (hidden ones behind
        // markers, none dropped).
        final replayed = await session.buildContextMessages();
        expect(replayed, isNotEmpty);
        final markers = replayed
            .whereType<UserMessage>()
            .where((m) => (m.content as String).contains(':hidden'))
            .length;
        expect(markers, greaterThan(0));
      },
    );

    test('the tier never calls a language model (bounded wall time)',
        () async {
      // A marathon-sized session (60 turns, ~300 records) relieves in
      // bounded wall time — the tier is pure-local arithmetic over the
      // ledger memo; no LM call exists on ANY of its paths (the class
      // takes no judge/summarizer to call).
      final (session, state) = await largeOldSession();
      final relief = EmergencyRelief(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        keepRecent: const {'read': 1, 'exec': 1, 'other': 99},
      );

      final watch = Stopwatch()..start();
      final outcome = await relief.run();
      watch.stop();

      expect(outcome.ok, isTrue);
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason:
            'deterministic relief: seconds, never minutes '
            '(wall ${watch.elapsedMilliseconds}ms)',
      );
    });
  });
}
