import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';

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

  test('structured engine: a never-answering judge no longer bricks the '
      'run — budget kill aborts the call, the deterministic fallback '
      'compacts, and the session survives', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    // A read pair plus assistant fillers: hideable entries beyond the
    // protected tail, so both the judge call and the fallback engage.
    await session.appendMessage(UserMessage.text('fix the login crash'));
    await session.appendMessage(
      AssistantMessage(
        content: [
          const TextContent(text: 'looking'),
          ToolCall(id: 'c1', name: 'read', arguments: const {}),
        ],
        api: 'test-api',
        provider: 'test-provider',
        model: 'test-model',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
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
    for (var i = 0; i < 11; i++) {
      await session.appendMessage(
        AssistantMessage(
          content: [TextContent(text: 'filler $i')],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
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

    // #541: a dead judge no longer fails the run — the deterministic
    // fallback closed the window instead.
    expect(ok, isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    // The budget reached the provider call AND killed it (#515 kept).
    expect(tokensSeen, isNotEmpty);
    expect(
      tokensSeen.every((t) => t != null && t.isCancelled),
      isTrue,
      reason: 'budget expiry must cancel the in-flight provider call',
    );
    // The failure surfaced through the hooks as a named pass report,
    // then the fallback hide reported its own receipt.
    expect(
      hooks.passes.any(
        (p) => !p.ok && p.error.toString().contains('issue #515'),
      ),
      isTrue,
      reason: 'the judge timeout surfaces as a named failed pass',
    );
    expect(
      hooks.passes.any((p) => p.ok && p.fallback == 'structured·hide-fallback'),
      isTrue,
      reason: 'the deterministic fallback reports its own receipt',
    );
    // Wire stays safe; the read pair did not split.
    expect(validateToolPairing(state.messages), isEmpty);
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

  test('structured engine, direct: the hide judge budget kill is a counted '
      'failure — the token still aborts the call, and the deterministic '
      'fallback compacts instead of bricking', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    // A read pair plus filler turns puts the ledger past protect-last-8,
    // so the hide pass actually reaches the judge call — and the
    // fallback has something pair-safe to hide afterwards.
    await session.appendMessage(UserMessage.text('fix the login crash'));
    await session.appendMessage(
      AssistantMessage(
        content: [
          const TextContent(text: 'looking'),
          ToolCall(id: 'c1', name: 'read', arguments: const {}),
        ],
        api: 'test-api',
        provider: 'test-provider',
        model: 'test-model',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
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
    for (var i = 0; i < 7; i++) {
      await session.appendMessage(
        AssistantMessage(
          content: [TextContent(text: 'filler $i')],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      );
    }
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    final budgetSource = CancelTokenSource();
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 1000,
      settings: settings,
      judge: (ledger) => Completer<String?>().future,
      summarize: (request) async => SummarizationResult.failure('unused'),
      attemptBudget: const Duration(milliseconds: 150),
      protectLastN: 3,
      checkpointPrompt: 'P',
      budgetSource: budgetSource,
    );

    final ok = await compactor.run();
    // #541: the timeout no longer bricks the run — the fallback hid
    // past the recency floor and the window closed.
    expect(ok, isTrue);
    // The engine killed the in-flight call at the token, not just the
    // await: the provider layer sees the abort (#515 semantics kept).
    expect(budgetSource.token.isCancelled, isTrue);
    // The fallback hid deterministically, whole pairs, oldest-first.
    final records = await session.getEntries();
    final hidden = records.whereType<HiddenRangeRecord>().toList();
    expect(hidden, hasLength(1));
    // The read pair (carrier + result) hid whole.
    expect(hidden.single.recordIds, hasLength(2));
    expect(validateToolPairing(state.messages), isEmpty);
  });

  test('structured engine, direct: the checkpoint summarizer budget kill '
      'propagates as a named error instead of a null summary', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    for (var i = 0; i < 10; i++) {
      await session.appendMessage(UserMessage.text('a' * 1600));
    }
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    final budgetSource = CancelTokenSource();
    final compactor = StructuredCompactor(
      session: session,
      state: state,
      window: 1000,
      settings: settings,
      // Judge declines ('[]', F1 no-op): straight to pass 2, where the
      // summarizer wedges past the attempt budget.
      judge: (ledger) async => '[]',
      summarize: (request) => Completer<SummarizationResult>().future,
      checkpointPrompt: 'P',
      budgetSource: budgetSource,
      attemptBudget: const Duration(milliseconds: 150),
    );

    await expectLater(
      compactor.run(),
      throwsA(
        isA<TimeoutException>()
            .having(
              (e) => e.message,
              'message',
              contains('checkpoint summarizer'),
            )
            .having((e) => e.message, 'issue tag', contains('issue #515')),
      ),
    );
    expect(budgetSource.token.isCancelled, isTrue);
    // The kill must NOT dissolve into the failure-safety empty summary:
    // no checkpoint was appended on the way out.
    final records = await session.getEntries();
    expect(records.whereType<CompactCheckpointRecord>(), isEmpty);
  });
}
