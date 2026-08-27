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
  int doneTokens = 0;

  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens) {
    donePasses = passes;
    doneTokens = tokens;
  }

  @override
  void onBothRolesFailed(Object lastError) {}
}

class _FakeSummarizer {
  _FakeSummarizer(this.results);

  final List<SummarizationResult> results;
  var calls = 0;

  Future<SummarizationResult> call(SummarizationRequest request) async {
    calls++;
    return results.removeAt(0);
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

  AssistantMessage assistantWithUsage(String text, int totalTokens) =>
      AssistantMessage(
        content: [TextContent(text: text)],
        api: 'test-api',
        provider: 'test-provider',
        model: 'test-model',
        usage: Usage(
          input: totalTokens,
          output: 10,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: totalTokens,
          cost: const UsageCost(
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
            total: 0,
          ),
        ),
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      );

  AutoCompactor compactorFor(
    Session session,
    AgentState state,
    _FakeSummarizer fake,
    _RecordingHooks hooks, {
    bool force = false,
  }) {
    return AutoCompactor(
      session: session,
      state: state,
      window: 1000,
      settings: settings,
      summary: fake.call,
      mainSummary: fake.call,
      smolModel: null,
      hooks: hooks,
      force: force,
    );
  }

  test('a successful pass clears the stale usage anchor — the estimate drops '
      'and the loop stops after one pass', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    // The last assistant message's usage reports a huge generation-time
    // context; after compaction the kept transcript is small, but the stale
    // anchor would keep the estimate high and retrigger the loop forever.
    await session.appendMessage(UserMessage.text('u1${'a' * 400}'));
    await session.appendMessage(assistantWithUsage('b' * 400, 5000));
    await session.appendMessage(UserMessage.text('u2${'a' * 400}'));
    await session.appendMessage(assistantWithUsage('c' * 400, 5000));

    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    final fake = _FakeSummarizer([SummarizationResult.success('SUMMARY')]);
    final hooks = _RecordingHooks();

    final ok = await compactorFor(session, state, fake, hooks).run();

    expect(ok, isTrue);
    expect(fake.calls, 1);
    expect(hooks.passes, hasLength(1));
    // The post-pass estimate is the small compacted size, not the stale 5000.
    expect(hooks.passes.single.tokensAfter, lessThan(1000));
    expect(hooks.donePasses, 1);
  });

  test('a no-op pass (already compacted at the leaf) stops the loop instead '
      'of spinning to maxPasses', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    await session.appendMessage(UserMessage.text('u1${'a' * 400}'));
    await session.appendMessage(assistantWithUsage('b' * 400, 5000));
    // Compact once for real: the leaf becomes a compaction record.
    final fake = _FakeSummarizer([SummarizationResult.success('SUMMARY')]);
    final manager = CompactionManager(summarize: fake.call, settings: settings);
    await manager.compactSession(session);

    // force: skip the shouldCompact gate — the point is the pass behavior.
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    final hooks = _RecordingHooks();
    final ok = await compactorFor(
      session,
      state,
      fake,
      hooks,
      force: true,
    ).run();

    expect(ok, isTrue);
    expect(hooks.passes, hasLength(1)); // one no-op pass, not maxPasses(8)
    // The no-op pass never reaches the summarizer (nothing to cut).
    expect(fake.calls, 1); // only the real compaction above
  });

  test('both summarizers down over the window: local trim bounds the '
      'context and reports an honest local-trim pass', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    // ~101 tokens per message (404 chars / 4); 12 of them ≈ 1212 — over
    // the 1000-token window. No usage anchors: pure char/4 estimate.
    for (var i = 0; i < 12; i++) {
      await session.appendMessage(UserMessage.text('u$i${'a' * 400}'));
    }
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    expect(state.messages.length, 12);

    Future<SummarizationResult> failing(SummarizationRequest request) async {
      throw const CompactionException(
        'Summarization failed: TimeoutException after 0:05:00.000',
      );
    }

    final hooks = _RecordingHooks();
    final ok = await AutoCompactor(
      session: session,
      state: state,
      window: 1000,
      settings: settings,
      summary: failing,
      mainSummary: failing,
      smolModel: null,
      hooks: hooks,
    ).run();

    expect(ok, isTrue, reason: 'the local trim bounds the context');
    // Marker + the kept recent messages — far fewer than the original 12.
    expect(state.messages.length, lessThan(12));
    expect(state.messages.first, isA<UserMessage>());
    final marker = state.messages.first as UserMessage;
    expect(marker.content as String, contains('context trimmed locally'));
    final pass = hooks.passes.last;
    expect(pass.fallback, 'local-trim');
    expect(pass.ok, isTrue);
    expect(pass.tokensAfter, lessThan(pass.tokensBefore));
  });

  test('both summarizers down but the transcript fits the keep budget: '
      'no trim, honest failure', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    // One short message: under keepRecentTokens — nothing droppable.
    await session.appendMessage(UserMessage.text('tiny'));
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );

    Future<SummarizationResult> failing(SummarizationRequest request) async {
      throw const CompactionException('boom');
    }

    final hooks = _RecordingHooks();
    // force: the point is the both-failed path, not the threshold gate.
    final ok = await AutoCompactor(
      session: session,
      state: state,
      window: 1000,
      settings: settings,
      summary: failing,
      mainSummary: failing,
      smolModel: null,
      hooks: hooks,
      force: true,
    ).run();

    expect(ok, isFalse);
    expect(hooks.passes.single.ok, isFalse);
    expect(hooks.passes.single.fallback, isNull);
  });
}
