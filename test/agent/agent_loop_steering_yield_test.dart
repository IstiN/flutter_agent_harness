/// Provider-phase steering interrupt tests (issue #1923 AC1/AC4/AC5):
/// steering arriving while the loop awaits an UNPRODUCTIVE provider stream
/// cancels the attempt, injects the pending steering into the rebuilt
/// request, and resubmits — without touching healthy streams or retry
/// budgets. Fake gated streams only; no real network, no scripted clocks
/// beyond short real timers.
library;

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

/// A scripted text turn (the second, post-interrupt response).
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

/// A stream that emits nothing until its cancel token fires, then
/// synthesizes the adapter-abort terminal (what real adapters produce).
AssistantMessageEventStream _hangingStream(
  CancelToken? cancelToken, {
  void Function()? onStarted,
}) {
  final stream = AssistantMessageEventStream();
  onStarted?.call();
  if (cancelToken != null) {
    unawaited(
      cancelToken.onCancel.then((_) {
        final aborted = _assistant(
          stopReason: StopReason.aborted,
          errorMessage: 'Operation aborted',
        );
        stream.push(ErrorEvent(reason: StopReason.aborted, error: aborted));
        stream.end();
      }),
    );
  }
  return stream;
}

/// A stream that emits Start + one text delta, then goes silent forever
/// (the mid-stream stall). The delta is delivered after [firstGap].
AssistantMessageEventStream _stalledAfterBytesStream(
  CancelToken? cancelToken, {
  required Duration firstGap,
  void Function()? onStarted,
}) {
  final stream = AssistantMessageEventStream();
  onStarted?.call();
  final empty = _assistant();
  stream.push(StartEvent(partial: empty));
  Timer(firstGap, () {
    final partial = _assistant(content: const [TextContent(text: 'par')]);
    stream.push(
      TextDeltaEvent(contentIndex: 0, delta: 'par', partial: partial),
    );
  });
  if (cancelToken != null) {
    unawaited(
      cancelToken.onCancel.then((_) {
        final aborted = _assistant(
          content: const [TextContent(text: 'par')],
          stopReason: StopReason.aborted,
          errorMessage: 'Operation aborted',
        );
        stream.push(ErrorEvent(reason: StopReason.aborted, error: aborted));
        stream.end();
      }),
    );
  }
  return stream;
}

/// A healthy stream: Start, several text deltas [gap] apart (each records
/// whether its cancel token was already cancelled), then Done.
AssistantMessageEventStream _activeStream(
  CancelToken? cancelToken, {
  required Duration gap,
  required List<bool> cancelStates,
  void Function()? onStarted,
}) {
  final stream = AssistantMessageEventStream();
  onStarted?.call();
  final empty = _assistant();
  stream.push(StartEvent(partial: empty));
  var i = 0;
  late final Timer timer;
  timer = Timer.periodic(gap, (_) {
    if (cancelToken?.isCancelled ?? false) cancelStates.add(true);
    if (i >= 4) {
      timer.cancel();
      final partial = _assistant(content: [TextContent(text: 'full-answer')]);
      stream.push(DoneEvent(reason: StopReason.stop, message: partial));
      stream.end();
      return;
    }
    final partial = _assistant(content: [TextContent(text: 'chunk-${i}_')]);
    stream.push(
      TextDeltaEvent(contentIndex: 0, delta: 'chunk-${i}_', partial: partial),
    );
    i++;
  });
  return stream;
}

void main() {
  group('provider-phase steering interrupt (#1923 AC1)', () {
    test('zero-byte stalled submit: steering interrupts immediately, rides '
        'the rebuilt request, and the run completes healthy', () async {
      final steering = StreamController<void>.broadcast(sync: true);
      final queue = <Message>[];
      final completions = <Completer<void>>[];
      var calls = 0;
      DateTime? steeredAt;
      var resubmittedAt = DateTime.now();

      Future<List<Message>> drain() async =>
          queue.isEmpty ? const <Message>[] : [queue.removeAt(0)];

      AssistantMessageEventStream streamFunction(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        calls++;
        if (calls == 1) {
          // The stalled submit: emits nothing. Fire steering 30ms in.
          return _hangingStream(
            cancelToken,
            onStarted: () {
              Timer(const Duration(milliseconds: 30), () {
                queue.add(UserMessage.text('do this instead'));
                steeredAt = DateTime.now();
                steering.add(null);
              });
            },
          );
        }
        // The rebuilt request: record when it went out and answer.
        resubmittedAt = DateTime.now();
        completions.add(Completer<void>()..complete());
        final stream = AssistantMessageEventStream();
        for (final event in _textTurn('interrupted-then-answered')) {
          stream.push(event);
        }
        stream.end();
        return stream;
      }

      final runSource = CancelTokenSource();
      final run = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: AgentLoopConfig(
          model: _model,
          getSteeringMessages: drain,
          steeringNotifications: steering.stream,
          steeringStallWindow: () => const Duration(minutes: 5),
        ),
        streamFunction: streamFunction,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        cancelToken: runSource.token,
        cancelTokenSource: runSource,
      );

      final messages = await run.result.timeout(const Duration(seconds: 10));

      // The steering interrupted the stalled attempt and rode the rebuilt
      // request: two provider calls, the second context carries the
      // steering user message right after the original prompt.
      expect(calls, 2);
      expect(steeredAt, isNotNull);
      // AC5: bounded latency — steering to rebuilt request well under 5s.
      expect(
        resubmittedAt.difference(steeredAt!).inMilliseconds,
        lessThan(5000),
      );
      final userTexts = messages
          .whereType<UserMessage>()
          .map((m) => m.content as String)
          .toList();
      expect(userTexts, ['hi', 'do this instead']);
      // The run completed healthy — the interrupt never surfaced as an
      // aborted terminal.
      final lastAssistant = messages.whereType<AssistantMessage>().last;
      expect(lastAssistant.stopReason, StopReason.stop);
      expect(_textOf(lastAssistant), 'interrupted-then-answered');
      steering.close();
    });

    test('mid-stream stall: steering waits out the stall window, then '
        'interrupts; the partial content is preserved', () async {
      final steering = StreamController<void>.broadcast(sync: true);
      final queue = <Message>[];
      var calls = 0;
      final secondContexts = Completer<Context>();

      AssistantMessageEventStream streamFunction(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        calls++;
        if (calls == 1) {
          return _stalledAfterBytesStream(
            cancelToken,
            firstGap: const Duration(milliseconds: 40),
            onStarted: () {
              // Steering lands while bytes are still fresh — the watch
              // must NOT interrupt; the stall window does the work.
              Timer(const Duration(milliseconds: 20), () {
                queue.add(UserMessage.text('steer-mid'));
                steering.add(null);
              });
            },
          );
        }
        secondContexts.complete(context);
        final stream = AssistantMessageEventStream();
        for (final event in _textTurn('recovered')) {
          stream.push(event);
        }
        stream.end();
        return stream;
      }

      final runSource = CancelTokenSource();
      final run = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: AgentLoopConfig(
          model: _model,
          getSteeringMessages: () async =>
              queue.isEmpty ? const <Message>[] : [queue.removeAt(0)],
          steeringNotifications: steering.stream,
          steeringStallWindow: () => const Duration(milliseconds: 150),
        ),
        streamFunction: streamFunction,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        cancelToken: runSource.token,
        cancelTokenSource: runSource,
      );

      final messages = await run.result.timeout(const Duration(seconds: 10));
      expect(calls, 2);
      final rebuilt = await secondContexts.future;
      // The rebuilt request rides the partial assistant content (existing
      // abort semantics) AND the steering user message.
      final rebuiltUser =
          rebuilt.messages.whereType<UserMessage>().last.content as String;
      expect(rebuiltUser, 'steer-mid');
      expect(
        rebuilt.messages.any(
          (m) => m is AssistantMessage && _textOf(m).contains('par'),
        ),
        isTrue,
      );
      expect(
        messages
            .whereType<UserMessage>()
            .map((m) => m.content as String)
            .toList(),
        contains('steer-mid'),
      );
      final lastAssistant = messages.whereType<AssistantMessage>().last;
      expect(lastAssistant.stopReason, StopReason.stop);
      steering.close();
    });

    test('a productive stream is never cancelled — steering keeps its '
        'next-boundary delivery', () async {
      final steering = StreamController<void>.broadcast(sync: true);
      final queue = <Message>[];
      final cancelStates = <bool>[];
      var calls = 0;

      AssistantMessageEventStream streamFunction(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        calls++;
        if (calls == 1) {
          return _activeStream(
            cancelToken,
            gap: const Duration(milliseconds: 30),
            cancelStates: cancelStates,
            onStarted: () {
              // Steering arrives mid-stream, bytes flowing.
              Timer(const Duration(milliseconds: 45), () {
                queue.add(UserMessage.text('steer-live'));
                steering.add(null);
              });
            },
          );
        }
        final stream = AssistantMessageEventStream();
        for (final event in _textTurn('after-boundary')) {
          stream.push(event);
        }
        stream.end();
        return stream;
      }

      final runSource = CancelTokenSource();
      final run = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: AgentLoopConfig(
          model: _model,
          getSteeringMessages: () async =>
              queue.isEmpty ? const <Message>[] : [queue.removeAt(0)],
          steeringNotifications: steering.stream,
          steeringStallWindow: () => const Duration(milliseconds: 150),
        ),
        streamFunction: streamFunction,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        cancelToken: runSource.token,
        cancelTokenSource: runSource,
      );

      final messages = await run.result.timeout(const Duration(seconds: 10));
      // The healthy attempt completed untouched: no cancellation was ever
      // observed while it streamed.
      expect(cancelStates, everyElement(isFalse));
      // The steering message was NOT injected mid-stream; it drained at
      // the next step boundary into the second turn.
      expect(calls, 2);
      expect(
        messages
            .whereType<UserMessage>()
            .map((m) => m.content as String)
            .toList(),
        ['hi', 'steer-live'],
      );
      steering.close();
    });

    test('no steering: a stalled-then-completing run is byte-identical '
        'legacy (REG parity — no interrupt, no resubmit)', () async {
      var calls = 0;
      AssistantMessageEventStream streamFunction(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        calls++;
        // Emits nothing for a while, then completes normally — with no
        // steering pending the watch stays disarmed and the attempt just
        // runs to its Done.
        final stream = AssistantMessageEventStream();
        Timer(const Duration(milliseconds: 200), () {
          for (final event in _textTurn('slow-but-fine')) {
            stream.push(event);
          }
          stream.end();
        });
        return stream;
      }

      final run = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: AgentLoopConfig(
          model: _model,
          steeringStallWindow: () => const Duration(milliseconds: 50),
        ),
        streamFunction: streamFunction,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );

      final messages = await run.result.timeout(const Duration(seconds: 10));
      expect(calls, 1);
      final lastAssistant = messages.whereType<AssistantMessage>().last;
      expect(lastAssistant.stopReason, StopReason.stop);
      expect(_textOf(lastAssistant), 'slow-but-fine');
    });

    test('a run-token abort (esc) still wins: the run ends aborted with no '
        'resubmit', () async {
      final runToken = CancelTokenSource();
      var calls = 0;
      AssistantMessageEventStream streamFunction(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        calls++;
        return _hangingStream(cancelToken);
      }

      final run = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: const AgentLoopConfig(model: _model),
        streamFunction: streamFunction,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        cancelToken: runToken.token,
        cancelTokenSource: runToken,
      );

      Timer(const Duration(milliseconds: 50), () => runToken.cancel());
      final messages = await run.result.timeout(const Duration(seconds: 10));
      expect(calls, 1);
      final lastAssistant = messages.whereType<AssistantMessage>().last;
      expect(lastAssistant.stopReason, StopReason.aborted);
    });

    test('the interrupt respects maxSteeringTurns: over-cap steering ends '
        'the run aborted with the mail left queued', () async {
      final steering = StreamController<void>.broadcast(sync: true);
      final queue = <Message>[];
      var calls = 0;

      AssistantMessageEventStream streamFunction(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        calls++;
        return _hangingStream(
          cancelToken,
          onStarted: () {
            Timer(const Duration(milliseconds: 20), () {
              queue.add(UserMessage.text('steer-$calls'));
              steering.add(null);
            });
          },
        );
      }

      final runSource = CancelTokenSource();
      final run = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: AgentLoopConfig(
          model: _model,
          getSteeringMessages: () async =>
              queue.isEmpty ? const <Message>[] : [queue.removeAt(0)],
          steeringNotifications: steering.stream,
          maxSteeringTurns: 1,
        ),
        streamFunction: streamFunction,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        cancelToken: runSource.token,
        cancelTokenSource: runSource,
      );

      final messages = await run.result.timeout(const Duration(seconds: 10));
      // Attempt 1 interrupted (cap 1 allows one extension), attempt 2's
      // interrupt found the drain short-circuited by the cap — the run
      // ended aborted instead of chasing the queue forever.
      expect(calls, 2);
      final lastAssistant = messages.whereType<AssistantMessage>().last;
      expect(lastAssistant.stopReason, StopReason.aborted);
      expect(queue, isNotEmpty);
      steering.close();
    });

    test('the AC4 notices fire with the pinned copy at the interrupt and '
        'the delivery', () async {
      final steering = StreamController<void>.broadcast(sync: true);
      final queue = <Message>[];
      final notices = <String>[];
      var calls = 0;

      AssistantMessageEventStream streamFunction(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        calls++;
        if (calls == 1) {
          return _hangingStream(
            cancelToken,
            onStarted: () {
              Timer(const Duration(milliseconds: 20), () {
                queue.add(UserMessage.text('notice-me'));
                steering.add(null);
              });
            },
          );
        }
        final stream = AssistantMessageEventStream();
        for (final event in _textTurn('ok')) {
          stream.push(event);
        }
        stream.end();
        return stream;
      }

      final runSource = CancelTokenSource();
      final run = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: AgentLoopConfig(
          model: _model,
          getSteeringMessages: () async =>
              queue.isEmpty ? const <Message>[] : [queue.removeAt(0)],
          steeringNotifications: steering.stream,
          steeringInterruptNotice: notices.add,
        ),
        streamFunction: streamFunction,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        cancelToken: runSource.token,
        cancelTokenSource: runSource,
      );

      await run.result.timeout(const Duration(seconds: 10));
      expect(
        notices.first,
        stringContainsInOrder([
          'steering queued — provider stalled ',
          ' seconds, interrupting to deliver',
        ]),
      );
      expect(RegExp(r'stalled \d+ seconds').hasMatch(notices.first), isTrue);
      expect(notices[1], 'steering delivered into rebuilt request');
      steering.close();
    });

    test('a disposed watch can never cancel the live run token (r1 '
        'blocker regression): a probe completing after dispose fires '
        'nothing, and the next attempt stays healthy', () async {
      final probeGate = Completer<bool>();
      final cancelStates = <bool>[];
      var calls = 0;
      // Attempt 1 streams normally (so its watch is disposed at ~t2);
      // attempt 2 hangs (its own watch armed). The attempt-1 probe was
      // called at the 2s tick and only completes AFTER attempt 1 ended —
      // the disposed watch must drop it instead of cancelling the run
      // token under attempt 2.
      AssistantMessageEventStream streamFunction(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        calls++;
        if (cancelToken != null) {
          unawaited(cancelToken.onCancel.then((_) => cancelStates.add(true)));
        }
        final stream = AssistantMessageEventStream();
        if (calls == 1) {
          // Complete shortly AFTER the probe tick so dispose precedes the
          // probe completion.
          Timer(const Duration(milliseconds: 2200), () {
            for (final event in _textTurn('first-ok')) {
              stream.push(event);
            }
            stream.end();
          });
          return stream;
        }
        // Attempt 2: healthy but slow — if the stale watch fired, this
        // would surface aborted instead.
        Timer(const Duration(milliseconds: 500), () {
          for (final event in _textTurn('second-ok')) {
            stream.push(event);
          }
          stream.end();
        });
        return stream;
      }

      final runSource = CancelTokenSource();
      final run = agentLoop(
        prompts: [UserMessage.text('hi')],
        context: const Context(messages: []),
        config: AgentLoopConfig(
          model: _model,
          hasPendingSteering: () => probeGate.future,
          // A tiny window: without the disposed guard the stale watch's
          // decision would see attempt-1 silence past the window and fire
          // the interrupt into the live run token mid-attempt-2.
          steeringStallWindow: () => const Duration(milliseconds: 50),
        ),
        streamFunction: streamFunction,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        cancelToken: runSource.token,
        cancelTokenSource: runSource,
      );

      // Let the 2s probe tick fire inside attempt 1 and hold it open.
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(calls, 1);
      // Attempt 1 settles (watch disposed); then the probe completes with
      // pending-steering=true into the DISPOSED watch.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      probeGate.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // No stale interrupt: the run token was never cancelled.
      expect(runSource.token.isCancelled, isFalse);

      final messages = await run.result.timeout(const Duration(seconds: 15));
      expect(cancelStates, everyElement(isFalse));
      final lastAssistant = messages.whereType<AssistantMessage>().last;
      expect(lastAssistant.stopReason, StopReason.stop);
      expect(
        messages.whereType<UserMessage>().map((m) => m.content as String),
        ['hi'],
      );
    });

    test('the steering cancel reason is SteeringInterruptFire, never a '
        'retry-ladder class', () async {
      final watch = _SteeringYieldProbe();
      watch.fire();
      expect(watch.token.cancelReason, isA<SteeringInterruptFire>());
      expect(watch.token.cancelReason, isNot(isA<RunIdleWatchdogFire>()));
    });
  });
}

/// The assistant text payload (the test-suite's text extraction —
/// [AssistantMessage] has no `.text` convenience getter).
String _textOf(AssistantMessage m) =>
    m.content.whereType<TextContent>().map((c) => c.text).join();

/// Minimal probe exposing the interrupt token semantics without the loop.
class _SteeringYieldProbe {
  final _source = CancelTokenSource();

  CancelToken get token => _source.token;

  void fire() =>
      _source.cancel(SteeringInterruptFire('test', const Duration(seconds: 1)));
}
