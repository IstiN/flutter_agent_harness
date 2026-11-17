// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2237 — the compaction basis contract: usage anchors travel with the
/// data through `refreshAgentState`, so the arming gate's basis and the
/// structured engine's own basis are ONE measurement of ONE message list.
/// The field defect: the gate armed on a usage-anchored over-trigger
/// basis, the engine's state refresh blanket-zeroed every anchor, the
/// re-derived chars/4 basis sat under the trigger, and the run exited
/// with zero passes and zero receipts — over and over (six
/// `auto-compact start` receipts, tokens growing).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:test/test.dart';

AssistantMessage _assistant(
  String text, {
  int anchorTokens = 0,
  List<ToolCall>? calls,
}) => AssistantMessage(
  content: [
    TextContent(text: text),
    ...?calls,
  ],
  api: 'anthropic-messages',
  provider: 'p',
  model: 'm1',
  usage: anchorTokens == 0
      ? Usage.zero
      : Usage(
          input: anchorTokens,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: anchorTokens,
          cost: const UsageCost(),
        ),
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

ToolResultMessage _result(String callId, String name, String text) =>
    ToolResultMessage(
      toolCallId: callId,
      toolName: name,
      content: [TextContent(text: text)],
      isError: false,
      timestamp: DateTime.utc(2026),
    );

/// Window 800, reserve 200 -> trigger 600.
const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 200,
  keepRecentTokens: 200,
);

final Model _model = const Model(
  id: 'm1',
  api: 'anthropic-messages',
  provider: 'p',
  baseUrl: 'http://localhost:1',
  contextWindow: 800,
  maxTokens: 4096,
);

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  /// A session whose LAST assistant carries a provider usage anchor of
  /// [anchorTokens] tokens while the raw bytes price only a fraction of
  /// it — the exact shape where an unanchored re-derivation collapses
  /// the basis under the trigger (PF1/PF4).
  Future<(Session, AgentState)> anchoredSession({
    int anchorTokens = 700,
  }) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('fix the login crash'));
    await session.appendMessage(
      _assistant(
        'looking',
        calls: [ToolCall(id: 'c1', name: 'read', arguments: const {})],
      ),
    );
    await session.appendMessage(_result('c1', 'read', 'x' * 400));
    await session.appendMessage(
      _assistant('root cause found', anchorTokens: anchorTokens),
    );
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    return (session, state);
  }

  group('UT-1 — refreshAgentState preserves projection-curated anchors', () {
    test(
      'an anchor on a current (non-stale) assistant survives the refresh',
      () async {
        final (session, state) = await anchoredSession();
        // Sanity: the live basis the gate measures is anchored — the raw
        // bytes alone sit well under the 700-token anchor.
        expect(estimateContextTokens(state.messages).tokens, 700);

        await refreshAgentState(session, state);

        final assistants = state.messages
            .whereType<AssistantMessage>()
            .toList();
        expect(
          assistants.last.usage.totalTokens,
          700,
          reason:
              'gh-2237: the state rebuild must not blanket-zero the '
              'anchor the projection curated',
        );
        expect(estimateContextTokens(state.messages).tokens, 700);
      },
    );
  });

  group('UT-2 — boundary-keyed stale anchors stay reset (gh-2097 twin)', () {
    test('anchors behind a compaction boundary do not resurrect the '
        'pre-fold size through the refresh', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('old'));
      final kept = await session.appendMessage(
        _assistant('kept carrier', anchorTokens: 201798),
      );
      await session.appendCompaction(
        summary: 'earlier marathon digest',
        firstKeptEntryId: kept,
        tokensBefore: 201798,
      );
      await session.appendMessage(_assistant('fresh turn', anchorTokens: 50));

      final state = AgentState(
        model: _model,
        messages: await session.buildContextMessages(),
      );
      await refreshAgentState(session, state);

      // The stale pre-boundary anchor must stay RESET: the projection's
      // boundary-keyed normalization is the single anchor authority, and
      // the refresh must not re-arm the pre-fold 201k size.
      final messages = state.messages;
      expect(estimateContextTokens(messages).tokens, lessThan(1000));
      final texts = [
        for (final m in messages)
          if (m is AssistantMessage)
            m.content.whereType<TextContent>().map((b) => b.text).join(),
      ];
      expect(texts, contains('kept carrier'));
    });
  });

  group('UT-3 — the gate basis and the engine basis are one measurement', () {
    test(
      'the refreshed engine basis equals the gate basis, both orders',
      () async {
        final (session, state) = await anchoredSession();
        int basis(List<Message> messages) => estimateRequestTokens(
          messages,
          systemPrompt: state.systemPrompt,
          tools: state.tools,
        );

        // Gate order: measure first, refresh second (the funnel's order —
        // agent_cli_compaction.dart measures, THEN the engine refreshes).
        final gateFirst = basis(state.messages);
        await refreshAgentState(session, state);
        final engineBasis = basis(state.messages);

        expect(
          gateFirst,
          700,
          reason: 'the gate measures the usage-anchored basis',
        );
        expect(
          engineBasis,
          gateFirst,
          reason:
              'gh-2237: two derivations of one transcript must never '
              'diverge — the engine must not re-derive a different basis',
        );

        // Reverse order: refresh first, measure second (a pre-flight
        // compaction runs the refresh before anything measures).
        await refreshAgentState(session, state);
        expect(basis(state.messages), gateFirst);
      },
    );

    test(
      'no anchors from turn one: both derivations agree trivially (E2)',
      () async {
        final session = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        await session.appendMessage(UserMessage.text('plain'));
        await session.appendMessage(_assistant('plain answer'));
        final state = AgentState(
          model: _model,
          messages: await session.buildContextMessages(),
        );
        int basis(List<Message> messages) => estimateRequestTokens(
          messages,
          systemPrompt: state.systemPrompt,
          tools: state.tools,
        );
        final gateFirst = basis(state.messages);
        await refreshAgentState(session, state);
        expect(basis(state.messages), gateFirst);
      },
    );
  });

  group('AC6/IT-5 — an anchored over-trigger UNFORCED run still folds', () {
    test('the gate-armed basis reaches the judge (no silent under-trigger '
        'exit)', () async {
      final (session, state) = await anchoredSession();
      // The gate's basis is over the 600 trigger — this is what arms the
      // post-run funnel in the field incident.
      expect(estimateRequestTokens(state.messages), greaterThan(600));

      var judgeCalls = 0;
      final passes = <StructuredCompactionPass>[];
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 800,
        settings: _settings,
        protectLastN: 0,
        maxHidePasses: 1,
        judge: (ledger, [token]) async {
          judgeCalls++;
          // Hide the read pair: the assistant carrier snaps the whole
          // group with its result.
          return '["3"]';
        },
        summarize: (request) async =>
            SummarizationResult.success('digest of the login-crash fix'),
        checkpointPrompt: 'DIGEST INSTRUCTIONS',
        hooks: StructuredCompactorHooksProbe(passes),
      );

      final underPressure = await compactor.run();

      expect(
        judgeCalls,
        greaterThanOrEqualTo(1),
        reason:
            'pre-fix the collapsed chars/4 basis exited under-trigger '
            'before the judge ever ran',
      );
      expect(
        passes,
        isNotEmpty,
        reason: 'the fold must perform at least one visible pass',
      );
      expect(underPressure, isTrue);
    });
  });
}

/// A [StructuredCompactorHooks] probe recording completed passes.
final class StructuredCompactorHooksProbe implements StructuredCompactorHooks {
  StructuredCompactorHooksProbe(this.passes);

  final List<StructuredCompactionPass> passes;

  @override
  void onDelta(String delta) {}

  @override
  void onPass(StructuredCompactionPass pass) => passes.add(pass);
}
