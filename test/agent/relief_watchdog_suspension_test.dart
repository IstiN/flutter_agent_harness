// Issue #1085 — post-compaction silence, M1/M3.
//
// UT-1: the run idle watchdog (injected short timeout) must NOT fire while
// the over-window relief compaction runs — the relief is a declared long
// silent window, the watchdog is suspended around it and re-armed after.
// UT-2: an explicit USER abort during the relief still cancels the run
// promptly (suspension never swallows aborts), the run ends aborted —
// not with the guard error (which would re-arm the auto-continuation).
// UT-2b: the relief's compaction tokens are LINKED to the run token, so
// a run-token cancel reaches the in-flight summarizer on both engines.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 120,
  maxTokens: 4096,
);

const _bashTool = Tool(name: 'bash', description: 'b', parameters: {});

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

List<AssistantMessageEvent> _toolTurn(List<ToolCall> calls) {
  final empty = _assistant();
  final partial = _assistant(content: calls, stopReason: StopReason.toolUse);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
  return events;
}

ToolCall _call(String id) =>
    ToolCall(id: id, name: 'bash', arguments: const {});

/// Drops the oldest messages until the estimate fits under [limit].
List<Message> _trimTo(List<Message> messages, int limit) {
  var kept = messages;
  while (kept.length > 1 && estimateContextTokens(kept).tokens > limit) {
    kept = kept.sublist(1);
  }
  return kept;
}

/// Scripted turns: request 1 fits, the tool result balloons request 2
/// past the window (the guard refuses), the relief frees it, request 3
/// goes out and completes.
class _GuardedTurns {
  final turns = <List<AssistantMessageEvent>>[
    _toolTurn([_call('c1')]),
    _textTurn('done'),
  ];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

void main() {
  test('UT-1: watchdog suspended across a slow relief — the run survives '
      '(was: aborted mid-relief)', () async {
    var watchdogFires = 0;
    var watchdogPauses = 0;
    final turns = _GuardedTurns();
    var reliefCalls = 0;
    final agent = Agent(
      model: _model,
      tools: [_bashTool],
      streamFunction: turns.call,
      toolExecutor: (_, _, _) async {
        // Balloons the next request past the 120-token window.
        return ToolExecutionResult.text('r' * 400);
      },
      runIdleTimeout: const Duration(milliseconds: 200),
      onRunIdleTimeout: (_) => watchdogFires++,
      onRunWatchdogPaused: () => watchdogPauses++,
      overWindowRelief: (messages) async {
        reliefCalls++;
        // The relief outlasts the 200ms watchdog (the production shape:
        // a 15-30 min compaction against an 8-min watchdog).
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return _trimTo(messages, 100);
      },
    );

    await agent.prompt('u' * 300);
    await agent.waitForIdle();

    expect(reliefCalls, 1);
    expect(watchdogPauses, 1, reason: 'the pause is observable');
    expect(watchdogFires, 0, reason: 'suspension covers the relief');
    final last = agent.state.messages.last as AssistantMessage;
    expect(last.stopReason, StopReason.stop);
    expect(last.errorMessage, isNull);
  });

  test('UT-2: user abort DURING the relief ends the run aborted, promptly — '
      'suspension never swallows an explicit abort', () async {
    var watchdogFires = 0;
    Object? fireError;
    late Agent agent;
    final reliefEntered = Completer<void>();
    agent = Agent(
      model: _model,
      tools: [_bashTool],
      streamFunction: (model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream();
        final events = context.messages.whereType<ToolResultMessage>().isEmpty
            ? _toolTurn([_call('c1')])
            : <AssistantMessageEvent>[];
        for (final event in events) {
          stream.push(event);
        }
        stream.end();
        return stream;
      },
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('r' * 400),
      runIdleTimeout: const Duration(minutes: 8),
      onRunIdleTimeout: (error) {
        watchdogFires++;
        fireError = error;
      },
      overWindowRelief: (messages) async {
        reliefEntered.complete();
        // Hangs until the USER abort cancels the run token — the linked
        // in-flight compaction in production.
        final token = agent.cancelToken;
        while (token == null || !token.isCancelled) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return null;
      },
    );

    final run = agent.prompt('u' * 300);
    await reliefEntered.future;
    agent.abort();
    await run.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        fail('abort during relief did not settle the run promptly');
      },
    );
    await agent.waitForIdle();

    expect(
      watchdogFires,
      0,
      reason:
          'the abort is the user’s, not the '
          'watchdog’s — suspension must not swallow it',
    );
    expect(fireError, isNull);
    final last = agent.state.messages.last as AssistantMessage;
    expect(
      last.stopReason,
      StopReason.aborted,
      reason:
          'aborted, NOT the context-window guard error: the guard '
          'error would re-arm the auto-continuation funnel after an '
          'explicit stop',
    );
  });

  test('UT-2b: classic-engine compaction tokens are linked to the run '
      'token — the cancel reaches the in-flight summarizer', () async {
    final summarizerInFlight = Completer<void>();
    final summarizerCancelled = Completer<void>();
    // The factory builds its summarizers from the sources' stream — hang
    // THAT on its cancel token (the linked attempt token) and end with an
    // aborted event on cancel, mirroring the real adapters.
    AssistantMessageEventStream mainStream(
      Model model,
      Context context, {
      CancelToken? cancelToken,
    }) {
      summarizerInFlight.complete();
      final stream = AssistantMessageEventStream();
      unawaited(
        (cancelToken?.onCancel ?? Future<void>.value()).then((_) {
          summarizerCancelled.complete();
          stream.push(
            ErrorEvent(
              reason: StopReason.aborted,
              error: _assistant(
                stopReason: StopReason.aborted,
                errorMessage: 'aborted',
              ),
            ),
          );
          stream.end();
        }),
      );
      return stream;
    }

    final fs = MemoryFileSystem();
    final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    final state = AgentState(model: _model);
    // Well past the compaction trigger (window 1000, reserve 100) so the
    // summarizer actually goes in flight. The SESSION carries the records
    // (compactSession reads the branch); state mirrors them.
    final old = UserMessage.text('old ' * 4000);
    final mid = _assistant(content: [TextContent(text: 'mid ' * 4000)]);
    final recent = UserMessage.text('recent ' * 4000);
    await session.appendMessage(old);
    await session.appendMessage(mid);
    await session.appendMessage(recent);
    state.messages = [old, mid, recent];

    final runTokenSource = CancelTokenSource();
    final factory = AutoCompactorFactory(
      session: session,
      state: state,
      window: 1000,
      settings: const CompactionSettings(
        enabled: true,
        reserveTokens: 100,
        keepRecentTokens: 150,
      ),
      sources: AutoCompactorSources(
        smolStream: null,
        smolModel: null,
        mainStream: mainStream,
        mainModel: _model,
      ),
      hooks: _NoopHooks(),
      engine: CompactionEngine.classic,
      runToken: runTokenSource.token,
    );

    final run = factory.run();
    await summarizerInFlight.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        fail('summarizer never started — test fixture is broken');
      },
    );
    // The summarizer is in flight; cancel the RUN token — exactly the
    // user-abort-during-relief shape — and the linked attempt token must
    // reach it promptly (the completer completes ON the cancel).
    final stopwatch = Stopwatch()..start();
    runTokenSource.cancel('user abort');
    await summarizerCancelled.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        fail('linked cancel did not reach the in-flight summarizer');
      },
    );
    stopwatch.stop();
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: 'the cancel propagated through the token link, not a timeout',
    );
    // Issue #1085 round-4: a cancelled compaction is NEVER a mere failed
    // pass — run() rethrows the cancellation so callers (the CLI relief
    // path, the continuation funnel) see the abort instead of reading it
    // as "nothing changed" and relaunching.
    await expectLater(run, throwsA(isA<CancelledException>())).timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        fail('compaction did not settle after the linked cancel');
      },
    );
  });
}

final class _NoopHooks implements AutoCompactorHooks {
  @override
  void onDelta(String delta) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}

  @override
  void onPass(AutoCompactorPass pass) {}

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens) {}

  @override
  void onBothRolesFailed(Object lastError) {}
}
