import 'dart:async';

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
  final deltas = <String>[];
  final attempts = <(String, int, Duration)>[];

  @override
  void onDelta(String delta) => deltas.add(delta);

  @override
  void onAttemptStart(String label, int attempt, Duration budget) =>
      attempts.add((label, attempt, budget));

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
    Duration? attemptBudget,
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
      attemptBudget: attemptBudget ?? const Duration(minutes: 10),
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

  test('a hung summarizer burns the attempt budget, not the session — the '
      'local trim still rescues the turn', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    await session.appendMessage(UserMessage.text('u1${'a' * 400}'));
    await session.appendMessage(assistantWithUsage('b' * 400, 5000));
    await session.appendMessage(UserMessage.text('u2${'a' * 400}'));
    await session.appendMessage(assistantWithUsage('c' * 400, 5000));
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    final hooks = _RecordingHooks();
    // The endpoint accepted the request and never answered (no error
    // event, no done) — stream.result pends forever.
    Future<SummarizationResult> hung(SummarizationRequest request) =>
        Completer<SummarizationResult>().future;

    final watch = Stopwatch()..start();
    final ok = await AutoCompactor(
      session: session,
      state: state,
      window: 1000,
      settings: settings,
      summary: hung,
      mainSummary: hung,
      smolModel: null,
      hooks: hooks,
      force: true,
      attemptBudget: const Duration(milliseconds: 100),
    ).run();
    watch.stop();

    // The budget cut the hung attempt: the run ENDED (local trim) instead
    // of spinning forever.
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(hooks.passes, hasLength(1));
    expect(hooks.passes.single.fallback, 'local-trim');
    expect(ok, isTrue);
  });

  test(
    'a hung summarizer with nothing to trim fails the run honestly',
    () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      // One small message: over the window via the stale usage anchor, but
      // the local trim has nothing droppable (keep budget covers it all).
      await session.appendMessage(UserMessage.text('u1'));
      await session.appendMessage(assistantWithUsage('b', 5000));
      final state = AgentState(
        model: _model,
        messages: await session.buildContextMessages(),
      );
      final hooks = _RecordingHooks();
      Future<SummarizationResult> hung(SummarizationRequest request) =>
          Completer<SummarizationResult>().future;

      final watch = Stopwatch()..start();
      final ok = await AutoCompactor(
        session: session,
        state: state,
        window: 1000,
        settings: settings,
        summary: hung,
        mainSummary: hung,
        smolModel: null,
        hooks: hooks,
        force: true,
        attemptBudget: const Duration(milliseconds: 100),
      ).run();
      watch.stop();

      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      expect(ok, isFalse);
      expect(hooks.passes.single.fallback, isNull);
      expect(hooks.passes.single.ok, isFalse);
      expect(hooks.passes.single.error, isA<TimeoutException>());
      expect(hooks.donePasses, 1);
    },
  );

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

  test('default budgets are tight — 90 s per attempt, 4 min total', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    final state = AgentState(model: _model, messages: const []);
    final fake = _FakeSummarizer([SummarizationResult.success('S')]);
    final compactor = AutoCompactor(
      session: session,
      state: state,
      window: 1000,
      settings: settings,
      summary: fake.call,
      mainSummary: fake.call,
      smolModel: null,
      hooks: _RecordingHooks(),
    );
    expect(compactor.attemptBudget, const Duration(seconds: 90));
    expect(compactor.totalBudget, const Duration(minutes: 4));
  });

  test('an exhausted total budget skips further summarizer attempts and '
      'falls to the local trim', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    // 400 chars = ~100 estimated tokens each: the last one fits the
    // keepRecentTokens budget (150), the pair busts it — so exactly one
    // message is droppable and the local trim has something to keep.
    await session.appendMessage(UserMessage.text('a' * 400));
    await session.appendMessage(UserMessage.text('b' * 400));
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );

    var attempts = 0;
    Future<SummarizationResult> failing(SummarizationRequest request) async {
      attempts++;
      throw const CompactionException('connection closed');
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
      force: true,
      totalBudget: Duration.zero,
    ).run();

    expect(attempts, 0);
    expect(ok, isTrue);
    expect(hooks.passes.single.fallback, 'local-trim');
    final marker = state.messages.first;
    expect(marker, isA<UserMessage>());
    expect(
      (marker as UserMessage).content as String,
      contains('trimmed locally'),
    );
  });

  test(
    'onAttemptStart reports each summarizer attempt with its budget',
    () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      await session.appendMessage(UserMessage.text('a' * 1200));
      final state = AgentState(
        model: _model,
        messages: await session.buildContextMessages(),
      );
      const smolModel = Model(
        id: 'smol-model',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 1000,
        maxTokens: 4096,
      );

      Future<SummarizationResult> failing(SummarizationRequest request) async {
        throw const CompactionException('nope');
      }

      final mainFake = _FakeSummarizer([
        SummarizationResult.success('SUMMARY'),
      ]);
      final hooks = _RecordingHooks();
      await AutoCompactor(
        session: session,
        state: state,
        window: 1000,
        settings: settings,
        summary: failing,
        mainSummary: mainFake.call,
        smolModel: smolModel,
        hooks: hooks,
        force: true,
        attemptBudget: const Duration(seconds: 7),
      ).run();

      expect(hooks.attempts, [
        ('smol=test-provider/smol-model', 1, const Duration(seconds: 7)),
        ('main=test-provider/test-model', 1, const Duration(seconds: 7)),
      ]);
    },
  );

  test('the factory forwards attempt and total budgets', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    final state = AgentState(model: _model, messages: const []);
    AssistantMessageEventStream dummy(
      Model m,
      Context c, {
      CancelToken? cancelToken,
    }) => throw UnimplementedError('never called by build()');
    final compactor = AutoCompactorFactory(
      session: session,
      state: state,
      window: 1000,
      settings: settings,
      sources: AutoCompactorSources(
        smolStream: null,
        smolModel: null,
        mainStream: dummy,
        mainModel: _model,
      ),
      hooks: _RecordingHooks(),
      attemptBudget: const Duration(seconds: 7),
      totalBudget: const Duration(minutes: 9),
    ).build();
    expect(compactor.attemptBudget, const Duration(seconds: 7));
    expect(compactor.totalBudget, const Duration(minutes: 9));
  });
}
