// gh-2237 AC3/OQ3 — the engine knows the deciding gate for every
// receipt-free zero-pass exit and exposes it as `zeroPassReason`, so the
// run-level terminal receipt can say WHERE/WHY the run did nothing.
// Counts only, never content (the repo's receipt rule).

library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:test/test.dart';

const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 2000,
  keepRecentTokens: 2000,
);

Model get _model => const Model(
  id: 'm1',
  api: 'test-api',
  provider: 'p',
  baseUrl: 'http://localhost:1',
  contextWindow: 8000,
  maxTokens: 4096,
);

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) =>
    AssistantMessage(
      content: [
        TextContent(text: text),
        ...?calls,
      ],
      api: 'test-api',
      provider: 'p',
      model: 'm1',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    );

/// A collecting hooks double — counts passes, records nothing else.
final class _PassCounter implements StructuredCompactorHooks {
  var passes = 0;

  @override
  void onDelta(String delta) {}

  @override
  void onPass(StructuredCompactionPass pass) {
    passes++;
  }
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  /// A small transcript (~2.2k estimated tokens) — far under the 6000
  /// trigger of the 8000-token window.
  Future<(Session, AgentState)> underTriggerSession() async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('fix the login crash'));
    await session.appendMessage(_assistant('looking around ' * 100));
    await session.appendMessage(_assistant('found it ' * 100));
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    return (session, state);
  }

  test(
    'UT-4: unforced under-trigger run exits with a run-gate reason',
    () async {
      final (session, state) = await underTriggerSession();
      final hooks = _PassCounter();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledger, [token]) async => '[]',
        summarize: (request) async =>
            SummarizationResult.failure('must not summarize'),
        checkpointPrompt: 'SUMMARY INSTRUCTIONS',
        hooks: hooks,
      );

      final ok = await compactor.run();

      expect(ok, isTrue);
      expect(hooks.passes, 0, reason: 'nothing ran — basis under trigger');
      expect(
        compactor.zeroPassReason,
        matches(RegExp(r'basis \d+ below trigger \d+ at the run gate')),
        reason:
            'AC2/OQ3: the terminal receipt must carry the deciding gate '
            'and the basis/trigger numbers',
      );
    },
  );

  test('AC3: a forced under-trigger run names the hide-pass gate', () async {
    final (session, state) = await underTriggerSession();
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 8000,
      settings: _settings,
      judge: (ledger, [token]) async => '[]',
      summarize: (request) async =>
          SummarizationResult.failure('must not summarize'),
      checkpointPrompt: 'SUMMARY INSTRUCTIONS',
    );

    final ok = await compactor.run(force: true);

    expect(ok, isTrue);
    expect(
      compactor.zeroPassReason,
      matches(RegExp(r'basis \d+ below trigger \d+ at the hide-pass gate')),
    );
  });

  test(
    'AC3: no hide passes available — the checkpoint gate is named',
    () async {
      final (session, state) = await underTriggerSession();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledger, [token]) async => '[]',
        summarize: (request) async =>
            SummarizationResult.failure('must not summarize'),
        checkpointPrompt: 'SUMMARY INSTRUCTIONS',
        maxHidePasses: 0,
      );

      final ok = await compactor.run(force: true);

      expect(ok, isTrue);
      expect(
        compactor.zeroPassReason,
        matches(RegExp(r'basis \d+ below trigger \d+ at the checkpoint gate')),
      );
    },
  );

  test('a run that did passes leaves the reason unset', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('fix the login crash'));
    await session.appendMessage(
      _assistant(
        'looking',
        calls: [ToolCall(id: 'c1', name: 'read', arguments: {})],
      ),
    );
    await session.appendMessage(
      ToolResultMessage(
        toolCallId: 'c1',
        toolName: 'read',
        content: [TextContent(text: 'x' * 16000)],
        isError: false,
        timestamp: DateTime.utc(2026),
      ),
    );
    await session.appendMessage(_assistant('found token-expiry bug'));
    for (var i = 0; i < 6; i++) {
      await session.appendMessage(_assistant('filler analysis $i'));
    }
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 5000,
      settings: _settings,
      judge: (ledger, [token]) async => '["3"]',
      summarize: (request) async => SummarizationResult.success('summary'),
      checkpointPrompt: 'SUMMARY INSTRUCTIONS',
    );

    final ok = await compactor.run();

    expect(ok, isTrue);
    expect(
      compactor.zeroPassReason,
      isNull,
      reason: 'pass receipts carry the story for runs that folded',
    );
  });
}
