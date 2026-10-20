// gh-1680 IT-3 / AC4 / AC8 — the pre-emptive message-count trigger on the
// auto-compactor: a model with a learned cap compacts when the live count
// reaches `cap − margin`, BEFORE the request, even when the token trigger
// is untouched; a model without a learned cap behaves byte-identically
// (token-only).

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

final class _RecordingHooks implements AutoCompactorHooks {
  final passes = <AutoCompactorPass>[];
  int? donePasses;

  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);

  @override
  void onDelta(String delta) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens) => donePasses = passes;

  @override
  void onBothRolesFailed(Object lastError) {}
}

class _FakeSummarizer {
  var calls = 0;

  Future<SummarizationResult> call(SummarizationRequest request) async {
    calls++;
    return SummarizationResult.success('SUMMARY');
  }
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  const settings = CompactionSettings(
    enabled: true,
    reserveTokens: 100,
    keepRecentTokens: 150,
  );

  Future<({Session session, AgentState state, int count})> manyMessagesSession(
    int pairs, {
    CompactionSettings? compactionSettings,
  }) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    // Many SMALL messages: the token estimate stays far under the
    // (window − reserve) trigger while the count climbs.
    for (var i = 0; i < pairs; i++) {
      await session.appendMessage(UserMessage.text('u$i'));
      await session.appendMessage(
        AssistantMessage(
          content: [TextContent(text: 'a$i')],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      );
    }
    final messages = await session.buildContextMessages();
    final state = AgentState(model: _model, messages: messages);
    return (session: session, state: state, count: messages.length);
  }

  test('message count at cap − margin fires compaction with tokens far '
      'under the trigger (AC4)', () async {
    final env = await manyMessagesSession(20); // 40 messages
    final fake = _FakeSummarizer();
    final hooks = _RecordingHooks();
    // cap 56, margin 16 → trigger at 40: the live count is exactly there.
    // A tight keep-recent window so one pass hides most of the array —
    // the token estimate stays far under the token trigger either way.
    final compactor = AutoCompactor(
      session: env.session,
      state: env.state,
      window: 1000,
      settings: const CompactionSettings(
        enabled: true,
        reserveTokens: 100,
        keepRecentTokens: 30,
      ),
      summary: fake.call,
      mainSummary: fake.call,
      smolModel: null,
      hooks: hooks,
      messageCap: 56,
    );

    final ok = await compactor.run();

    expect(ok, isTrue);
    expect(
      fake.calls,
      greaterThanOrEqualTo(1),
      reason:
          'the cap trigger fired the pass with tokens far under the '
          'token trigger',
    );
    // Bounded like the token dimension: passes repeat until the engine has
    // nothing hideable left (the keep-recent window bounds the tail), then
    // STOP — never spinning to maxPasses.
    expect(hooks.passes.length, lessThan(8));
    // The request rides a compacted array — the count dropped hard.
    expect(env.state.messages.length, lessThan(env.count));
    final after = await env.session.buildContextMessages();
    expect(after.length, lessThan(env.count));
  });

  test('just under the trigger: no compaction (the margin is real)', () async {
    final env = await manyMessagesSession(20); // 40 messages
    final fake = _FakeSummarizer();
    final hooks = _RecordingHooks();
    // cap 57 → trigger at 41 > 40: one message short, nothing fires.
    final compactor = AutoCompactor(
      session: env.session,
      state: env.state,
      window: 1000,
      settings: settings,
      summary: fake.call,
      mainSummary: fake.call,
      smolModel: null,
      hooks: hooks,
      messageCap: 57,
    );

    final ok = await compactor.run();

    expect(ok, isTrue, reason: 'no trigger, nothing to do — success no-op');
    expect(fake.calls, 0);
    expect(hooks.passes, isEmpty);
  });

  test('no learned cap: token-only behavior, byte-identical (AC8)', () async {
    final env = await manyMessagesSession(20); // 40 messages
    final fake = _FakeSummarizer();
    final hooks = _RecordingHooks();
    final compactor = AutoCompactor(
      session: env.session,
      state: env.state,
      window: 1000,
      settings: settings,
      summary: fake.call,
      mainSummary: fake.call,
      smolModel: null,
      hooks: hooks,
      // messageCap: null — the default.
    );

    final ok = await compactor.run();

    expect(ok, isTrue);
    expect(
      fake.calls,
      0,
      reason:
          '40 small messages are far under the '
          'token trigger; without a learned cap nothing fires',
    );
    expect(env.state.messages, hasLength(env.count));
  });
}
