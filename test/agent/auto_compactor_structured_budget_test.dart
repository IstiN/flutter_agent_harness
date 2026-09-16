import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Issue #515: the compaction phase's LLM calls (structured judge and
/// summarizer, classic summarizer) must die at the provider layer when
/// their watchdog budget expires — not pend forever, and not survive the
/// timeout as an abandoned zombie call.
const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _message(StopReason reason) => AssistantMessage(
  content: const [],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: reason,
  timestamp: DateTime.utc(2026),
);

final class _CapturingHooks implements AutoCompactorHooks {
  Object? bothRolesError;
  final passes = <AutoCompactorPass>[];

  @override
  void onDelta(String delta) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}

  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens) {}

  @override
  void onBothRolesFailed(Object lastError) => bothRolesError = lastError;
}

/// A provider stream that never answers — unless the request's cancel
/// token fires, in which case it settles as aborted, like a real
/// adapter's abort path.
AssistantMessageEventStream _neverAnsweringStream(
  Model m,
  Context c, {
  CancelToken? cancelToken,
  List<CancelToken?>? tokensSeen,
}) {
  tokensSeen?.add(cancelToken);
  final stream = AssistantMessageEventStream();
  stream.push(StartEvent(partial: _message(StopReason.stop)));
  if (cancelToken != null) {
    unawaited(
      cancelToken.onCancel.then((_) {
        stream.push(
          DoneEvent(
            reason: StopReason.aborted,
            message: _message(StopReason.aborted),
          ),
        );
        stream.end();
      }),
    );
  }
  return stream;
}

/// A summarizer that pends forever until its cancel token fires.
Future<SummarizationResult> _hangingSummarizer(
  SummarizationRequest request,
  List<CancelToken?> tokensSeen,
) {
  tokensSeen.add(request.cancelToken);
  final done = Completer<SummarizationResult>();
  if (request.cancelToken != null) {
    unawaited(
      request.cancelToken!.onCancel.then((_) {
        done.complete(SummarizationResult.failure('aborted', aborted: true));
      }),
    );
  }
  return done.future;
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

  test('structured engine: a never-answering judge dies at the attempt '
      'budget with a named error and a cancelled provider call', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    // Ten turns: the ledger has hideable entries beyond protect-last-8,
    // so the structured run actually reaches the judge call.
    for (var i = 0; i < 10; i++) {
      await session.appendMessage(UserMessage.text('a' * 1600));
    }
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    final tokensSeen = <CancelToken?>[];
    final hooks = _CapturingHooks();
    final sw = Stopwatch()..start();

    final ok = await AutoCompactorFactory(
      session: session,
      state: state,
      window: 1000,
      settings: settings,
      sources: AutoCompactorSources(
        smolStream: null,
        smolModel: null,
        mainStream: (m, c, {cancelToken}) => _neverAnsweringStream(
          m,
          c,
          cancelToken: cancelToken,
          tokensSeen: tokensSeen,
        ),
        mainModel: _model,
      ),
      hooks: hooks,
      attemptBudget: const Duration(milliseconds: 150),
      totalBudget: const Duration(seconds: 2),
    ).run();
    sw.stop();

    // Fail-fast, bounded — not an infinite wedge.
    expect(ok, isFalse);
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    // The budget reached the provider call AND killed it.
    expect(tokensSeen, isNotEmpty);
    expect(
      tokensSeen.every((t) => t != null),
      isTrue,
      reason: 'the budget token must ride the judge/summarizer request',
    );
    expect(
      tokensSeen.every((t) => t!.isCancelled),
      isTrue,
      reason: 'budget expiry must cancel the in-flight provider call',
    );
    // The named error surfaces through the hooks (not silence).
    expect(hooks.bothRolesError, isA<TimeoutException>());
    expect(
      (hooks.bothRolesError as TimeoutException).message,
      contains('issue #515'),
    );
    // Failure appends nothing: zero records, like the incident's run.
    final records = await session.getEntries();
    expect(records.whereType<CompactionRecord>(), isEmpty);
  });

  test('classic engine: budget expiry cancels the wedged summarizer call '
      'instead of abandoning it', () async {
    // Usage-anchored messages put the estimate at 5000 tokens, well over
    // the 900-token trigger, so the classic loop reaches the summarizer.
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    for (var i = 0; i < 2; i++) {
      await session.appendMessage(UserMessage.text('u$i${'a' * 400}'));
      await session.appendMessage(
        AssistantMessage(
          content: [TextContent(text: 'b$i')],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: const Usage(
            input: 5000,
            output: 10,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 5010,
            cost: UsageCost(
              input: 0,
              output: 0,
              cacheRead: 0,
              cacheWrite: 0,
              total: 0,
            ),
          ),
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      );
    }
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    final tokensSeen = <CancelToken?>[];
    final hooks = _CapturingHooks();

    final ok = await AutoCompactor(
      session: session,
      state: state,
      window: 1000,
      settings: settings,
      summary: (r) => _hangingSummarizer(r, tokensSeen),
      mainSummary: (r) => _hangingSummarizer(r, tokensSeen),
      smolModel: null,
      hooks: hooks,
      // force: true goes straight at the summarizer (the incident's
      // over-window context) instead of gating on the trigger estimate.
      force: true,
      attemptBudget: const Duration(milliseconds: 150),
      totalBudget: const Duration(seconds: 2),
    ).run();

    // The run ends (local trim rescues the turn), and — the regression —
    // the wedged call was CANCELLED, not left running with no token.
    expect(ok, isTrue);
    expect(tokensSeen, isNotEmpty);
    expect(tokensSeen.every((t) => t != null), isTrue);
    expect(
      tokensSeen.every((t) => t!.isCancelled),
      isTrue,
      reason: 'budget expiry must cancel the in-flight summarizer call',
    );
  });
}
