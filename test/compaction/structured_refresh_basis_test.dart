// gh-2237 AC1 — the single-basis contract between the post-run
// auto-compact trigger gate and the structured compaction engine.
//
// The gate measures `state.messages` with `estimateRequestTokens`
// (usage-anchored when the transcript carries provider usage); the engine
// re-derives its own basis from the session projection through
// `refreshAgentState`. The old `refreshAgentState` blanket-zeroed every
// assistant usage anchor, so the engine re-derived a collapsed whole-list
// chars/4 projection the arming gate never saw — the silent zero-pass
// auto-compact start loop. These tests pin the projection-trust contract:
// anchors travel with the data, and the projection's boundary-keyed
// `_resetStaleUsageAnchors` stays the single anchor authority.

library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:test/test.dart';

Model get _model => const Model(
  id: 'm1',
  api: 'test-api',
  provider: 'p',
  baseUrl: 'http://localhost:1',
  contextWindow: 8000,
  maxTokens: 4096,
);

AssistantMessage _assistant(String text, {Usage? usage}) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'p',
  model: 'm1',
  usage: usage ?? Usage.zero,
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

/// Usage reporting 5000 context tokens — the anchor the gate sees.
Usage get _anchoredUsage => const Usage(
  input: 4000,
  output: 500,
  cacheRead: 500,
  cacheWrite: 0,
  totalTokens: 5000,
  cost: UsageCost(),
);

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  /// An anchored transcript: user ask, tool pair, usage-anchored
  /// assistant (5000 context tokens), then an unanchored trailing tail
  /// (two ~4000-char messages ≈ 1000 estimated tokens each). The
  /// whole-list chars/4 projection of this shape lands far below the
  /// anchored estimate — the collapse the defect rode.
  Future<(Session, AgentState)> anchoredSession() async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('fix the login crash'));
    await session.appendMessage(_assistant('looking'));
    await session.appendMessage(_result('c1', 'y' * 16000));
    await session.appendMessage(
      _assistant('found the token-expiry bug', usage: _anchoredUsage),
    );
    await session.appendMessage(UserMessage.text('t' * 4000));
    await session.appendMessage(UserMessage.text('u' * 4000));
    final state = AgentState(model: _model, messages: const []);
    state.messages = await session.buildContextMessages();
    return (session, state);
  }

  group('UT-1: refreshAgentState preserves projection-curated anchors', () {
    test(
      'the rebuilt state.messages keep the usage anchor (no blanket zeroing)',
      () async {
        final (session, state) = await anchoredSession();
        // The pre-refresh list IS the projection here — both derivations
        // must agree that an anchor exists.
        final before = estimateContextTokens(state.messages);
        expect(before.lastUsageIndex, isNotNull, reason: 'fixture anchored');

        await refreshAgentState(session, state);

        expect(state.messages, isNotEmpty);
        final after = estimateContextTokens(state.messages);
        expect(
          after.lastUsageIndex,
          isNotNull,
          reason:
              'gh-2237: the refreshed basis must stay usage-anchored — '
              'blanket Usage.zero zeroing collapsed it to chars/4',
        );
        expect(after.usageTokens, before.usageTokens);
        expect(after.tokens, before.tokens);
      },
    );

    test(
      'the refreshed engine basis equals the gate basis on the same list',
      () async {
        final (session, state) = await anchoredSession();
        final gateBasis = estimateRequestTokens(state.messages);

        await refreshAgentState(session, state);
        final engineBasis = estimateRequestTokens(state.messages);

        expect(
          engineBasis,
          gateBasis,
          reason:
              'AC1: the engine must not re-derive a different basis than '
              'the gate that armed it',
        );
        // The collapse the defect produced: the anchored basis (5000 +
        // tail) sits far above the whole-list chars/4 projection of the
        // same bytes — pin the anchored side so the equality above can
        // not pass on a mutually-collapsed pair.
        expect(gateBasis, greaterThan(5000));
      },
    );
  });

  group('UT-2: the boundary-keyed reset still applies (negative twin)', () {
    test(
      'anchors predating a compaction boundary reset — no stale over-anchor',
      () async {
        final (session, state) = await anchoredSession();
        // Fold everything up to and including the anchored assistant
        // behind a compaction boundary: the pre-fold usage must not
        // resurrect the pre-fold basis (E5).
        final path = await session.getBranch();
        final messageIds = [
          for (final record in path)
            if (record is MessageRecord) record.id,
        ];
        await session.appendCompactCheckpoint(
          firstRecordId: messageIds.first,
          lastRecordId: messageIds[3], // the anchored assistant
          text: 'checkpoint: the login investigation',
          coversRecordIds: messageIds.sublist(0, 4),
          flattenedRecordIds: const [],
        );

        await refreshAgentState(session, state);

        final after = estimateContextTokens(state.messages);
        expect(
          after.lastUsageIndex,
          isNull,
          reason:
              'every usage-bearing assistant now sits behind the boundary; '
              'the projection must have reset them',
        );
        expect(
          after.usageTokens,
          0,
          reason: 'no anchor survives the boundary (gh-2097 preserved)',
        );
      },
    );
  });

  group('UT-3: basis equality property (AC1)', () {
    test('both derivation orders agree on an anchored transcript', () async {
      final (session, state) = await anchoredSession();
      final inMemory = [...state.messages];

      // Order A: measure the gate basis, then refresh, then re-measure.
      final gateFirst = estimateRequestTokens(inMemory);
      await refreshAgentState(session, state);
      final afterRefresh = estimateRequestTokens(state.messages);
      expect(afterRefresh, gateFirst);

      // Order B: refresh FIRST, then measure both.
      final (session2, state2) = await anchoredSession();
      await refreshAgentState(session2, state2);
      final engineFirst = estimateRequestTokens(state2.messages);
      final gateOnProjection = estimateRequestTokens(inMemory);
      expect(engineFirst, gateOnProjection);
    });

    test('E2: a never-anchored transcript agrees by construction', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('a' * 4000));
      await session.appendMessage(
        _assistant('plain reply'), // Usage.zero — not an anchor
      );
      final state = AgentState(model: _model, messages: const []);
      state.messages = await session.buildContextMessages();

      final gateBasis = estimateRequestTokens(
        state.messages,
        systemPrompt: 'system',
      );
      await refreshAgentState(session, state);
      final engineBasis = estimateRequestTokens(
        state.messages,
        systemPrompt: 'system',
      );
      expect(engineBasis, gateBasis);
      // Both sides took the unanchored branch (overhead priced in).
      expect(estimateContextTokens(state.messages).lastUsageIndex, isNull);
    });
  });
}
