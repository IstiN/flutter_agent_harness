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

/// A stream function whose first turn blocks mid-stream until [gate]
/// completes — the simulated provider stream is in flight while the test
/// steers. Records whether the loop cancelled the in-flight token.
class _BlockingStream {
  Completer<void> gate = Completer<void>();
  final Completer<void> started = Completer<void>();
  CancelToken? seenToken;
  var cancelled = false;
  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    seenToken = cancelToken;
    cancelToken?.onCancel.then((_) => cancelled = true);
    final events = AssistantMessageEventStream();
    final first = !started.isCompleted;
    unawaited(() async {
      if (first) {
        started.complete();
        await gate.future;
      }
      // A real provider turns a fired token into an aborted error event
      // (openai_completions.dart:760) — mirror that contract.
      if (cancelToken?.isCancelled ?? false) {
        events
          ..push(
            ErrorEvent(
              reason: StopReason.aborted,
              error: _assistant(
                stopReason: StopReason.aborted,
                errorMessage: 'Request was aborted',
              ),
            ),
          )
          ..end();
        return;
      }
      final empty = _assistant();
      final partial = _assistant(content: [TextContent(text: 'streamed')]);
      events
        ..push(StartEvent(partial: empty))
        ..push(TextStartEvent(contentIndex: 0, partial: empty))
        ..push(
          TextDeltaEvent(contentIndex: 0, delta: 'streamed', partial: partial),
        )
        ..push(DoneEvent(reason: StopReason.stop, message: partial));
      events.end();
    }());
    return events;
  }
}

void main() {
  test('UT-steer-stream: steering during the stream phase does not abort the '
      'provider call — the stream runs to natural completion and the steer '
      'is delivered at the next boundary', () async {
    final stream = _BlockingStream();
    final agent = Agent(
      model: _model,
      streamFunction: stream.call,
      toolExecutor: (call, token, onUpdate) async =>
          ToolExecutionResult.text(''),
    );

    final run = agent.prompt('weather?');
    await stream.started.future;
    // Mid-stream: steer arrives while the provider call is in flight.
    agent.steer(UserMessage.text('actually, in Berlin'));

    // Let any bogus cancellation surface, then release the stream.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      stream.cancelled,
      isFalse,
      reason: 'steering must never cancel the in-flight provider stream',
    );

    stream.gate.complete();
    await run;

    // The stream completed naturally and the steering became the next step.
    expect(agent.state.messages.map((m) => m.role), [
      'user',
      'assistant',
      'user',
      'assistant',
    ]);
    expect(
      (agent.state.messages[2] as UserMessage).content,
      'actually, in Berlin',
    );
    final last = agent.state.messages[1] as AssistantMessage;
    expect(
      last.stopReason,
      StopReason.stop,
      reason: 'the steered run must not end aborted',
    );
  });

  test('UT-cancel-distinct: an explicit cancelTurn during the stream still '
      'aborts (user intent keeps its surface)', () async {
    final stream = _BlockingStream();
    final agent = Agent(
      model: _model,
      streamFunction: stream.call,
      toolExecutor: (call, token, onUpdate) async =>
          ToolExecutionResult.text(''),
    );

    final run = agent.prompt('weather?');
    await stream.started.future;
    agent.abort();

    stream.gate.complete();
    await run;

    final last = agent.state.messages.whereType<AssistantMessage>().last;
    expect(last.stopReason, StopReason.aborted);

    // AC4: after the cancel, a NEW turn starts cleanly - the aborted turn
    // wedges nothing.
    stream.gate = Completer<void>();
    await agent.prompt('again?');
    final next = agent.state.messages.whereType<AssistantMessage>().last;
    expect(next.stopReason, isNot(StopReason.aborted));
    expect(
      next.content.map((b) => b is TextContent ? b.text : ''),
      anyElement('streamed'),
    );
  });
}
