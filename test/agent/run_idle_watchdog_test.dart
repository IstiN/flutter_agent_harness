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

/// A provider stream that never produces a byte on its own; on cancel it
/// ends with an aborted error event, mirroring the real adapters.
AssistantMessageEventStream _hangingStream(CancelToken? token) {
  final stream = AssistantMessageEventStream();
  unawaited(
    token?.onCancel.then((_) {
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

/// A scripted text turn ending with [DoneEvent].
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

Tool _tool(String name) =>
    Tool(name: name, description: '$name tool', parameters: const {});

void main() {
  group('Agent run idle watchdog', () {
    test('aborts a wedged run and reports via onRunIdleTimeout', () async {
      var fires = 0;
      Object? fireError;
      final agent = Agent(
        model: _model,
        streamFunction: (model, context, {cancelToken}) =>
            _hangingStream(cancelToken),
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        runIdleTimeout: const Duration(milliseconds: 100),
        onRunIdleTimeout: (error) {
          fires++;
          fireError = error;
        },
      );
      await agent.prompt('hi');
      await agent.waitForIdle();

      expect(fires, 1);
      expect(fireError, isA<TimeoutException>());
      final last = agent.state.messages.last as AssistantMessage;
      expect(last.stopReason, StopReason.aborted);
    });

    test('stays quiet while a tool is executing (long test gates)', () async {
      var fires = 0;
      final turns = <List<AssistantMessageEvent>>[
        _toolTurn([ToolCall(id: 'c1', name: 'bash', arguments: const {})]),
        _textTurn('done'),
      ];
      final agent = Agent(
        model: _model,
        tools: [_tool('bash')],
        streamFunction: (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          for (final event in turns.removeAt(0)) {
            stream.push(event);
          }
          stream.end();
          return stream;
        },
        toolExecutor: (_, _, _) async {
          // A legitimate 300ms tool — well past the 100ms watchdog.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return ToolExecutionResult.text('ok');
        },
        runIdleTimeout: const Duration(milliseconds: 100),
        onRunIdleTimeout: (_) => fires++,
      );
      await agent.prompt('run it');
      await agent.waitForIdle();

      expect(fires, 0);
      final last = agent.state.messages.last as AssistantMessage;
      expect(last.stopReason, StopReason.stop);
    });

    test('streaming deltas keep the watchdog disarmed', () async {
      var fires = 0;
      final agent = Agent(
        model: _model,
        streamFunction: (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          final empty = _assistant();
          stream.push(StartEvent(partial: empty));
          // Deltas every 50ms for 300ms with a 100ms watchdog: silence
          // never exceeds the timeout, the run must survive.
          var sent = 0;
          final timer = Timer.periodic(const Duration(milliseconds: 50), (t) {
            sent++;
            stream.push(
              TextDeltaEvent(
                contentIndex: 0,
                delta: 'x',
                partial: _assistant(content: [TextContent(text: 'x' * sent)]),
              ),
            );
            if (sent == 6) {
              t.cancel();
              stream.push(
                DoneEvent(
                  reason: StopReason.stop,
                  message: _assistant(content: [TextContent(text: 'xxxxxx')]),
                ),
              );
              stream.end();
            }
          });
          unawaited(
            cancelToken?.onCancel.then((_) {
              timer.cancel();
              stream.end();
            }),
          );
          return stream;
        },
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        runIdleTimeout: const Duration(milliseconds: 100),
        onRunIdleTimeout: (_) => fires++,
      );
      await agent.prompt('stream');
      await agent.waitForIdle();

      expect(fires, 0);
      final last = agent.state.messages.last as AssistantMessage;
      expect(last.stopReason, StopReason.stop);
    });

    test('Duration.zero disables the watchdog', () async {
      var fires = 0;
      late Agent agent;
      agent = Agent(
        model: _model,
        streamFunction: (model, context, {cancelToken}) =>
            _hangingStream(cancelToken),
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
        runIdleTimeout: Duration.zero,
        onRunIdleTimeout: (_) => fires++,
      );
      unawaited(agent.prompt('hi'));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(fires, 0);
      agent.abort();
      await agent.waitForIdle();
      expect(fires, 0);
    });

    test(
      'issue #1126: a watchdog fire resumes through the retry wrapper and '
      'the tool phase runs on the re-armed run token',
      () async {
        var fires = 0;
        var innerCalls = 0;
        final contexts = <Context>[];
        final executorTokens = <CancelToken?>[];
        final agent = Agent(
          model: _model,
          tools: [_tool('bash')],
          // The production shape: the provider function wrapped by the
          // transient-retry wrapper (provider_catalog does the same).
          streamFunction: transientRetryStreamFunction((
            model,
            context, {cancelToken}) {
            innerCalls++;
            contexts.add(context);
            final stream = AssistantMessageEventStream();
            if (innerCalls == 1) {
              // Attempt 1: content streams, then the run goes silent past
              // the watchdog. The fire cancels the run token; the fake
              // mirrors the real adapters and ends with the abort.
              final empty = _assistant();
              final partial = _assistant(
                content: [const TextContent(text: 'watchdog cut')],
              );
              stream
                ..push(StartEvent(partial: empty))
                ..push(TextStartEvent(contentIndex: 0, partial: empty))
                ..push(
                  TextDeltaEvent(
                    contentIndex: 0,
                    delta: 'watchdog cut',
                    partial: partial,
                  ),
                )
                ..push(
                  TextEndEvent(
                    contentIndex: 0,
                    content: 'watchdog cut',
                    partial: partial,
                  ),
                );
              unawaited(
                cancelToken!.onCancel.then((_) {
                  stream
                    ..push(
                      ErrorEvent(
                        reason: StopReason.aborted,
                        error: _assistant(
                          content: [
                            const TextContent(text: 'watchdog cut'),
                          ],
                          stopReason: StopReason.aborted,
                          errorMessage: 'Request was aborted',
                        ),
                      ),
                    )
                    ..end();
                }),
              );
            } else if (innerCalls == 2) {
              for (final event in _toolTurn([
                ToolCall(id: 'c1', name: 'bash', arguments: const {}),
              ])) {
                stream.push(event);
              }
              stream.end();
            } else {
              for (final event in _textTurn('done')) {
                stream.push(event);
              }
              stream.end();
            }
            return stream;
          }),
          toolExecutor: (call, cancelToken, _) async {
            executorTokens.add(cancelToken);
            return ToolExecutionResult.text('ok');
          },
          runIdleTimeout: const Duration(milliseconds: 100),
          onRunIdleTimeout: (_) => fires++,
        );
        await agent.prompt('go');
        await agent.waitForIdle();

        expect(fires, 1);
        // The wrapper resumed: the tail request carries the anchor (prefix
        // text only — no dangling tool call for strict providers).
        expect(innerCalls, greaterThanOrEqualTo(2));
        final anchor = contexts[1].messages.last as AssistantMessage;
        expect(
          anchor.content.whereType<TextContent>().map((b) => b.text),
          ['watchdog cut'],
        );
        expect(anchor.content.whereType<ToolCall>(), isEmpty);
        // The tool phase ran on the SAME run token, re-armed in place by
        // the resume — `throwIfCancelled` in real tools must pass.
        expect(executorTokens, hasLength(1));
        expect(executorTokens.single!.isCancelled, isFalse);
        // The run completed: the resumed tool call executed, then the text
        // turn ended the loop cleanly (not aborted).
        final last = agent.state.messages.last as AssistantMessage;
        expect(last.stopReason, StopReason.stop);
      },
    );

    test(
      'issue #1132 r2: a completed dead tool call is dropped on resume — '
      'the regenerated call is the only one the tool phase executes',
      () async {
        var fires = 0;
        var innerCalls = 0;
        var executorCalls = 0;
        final agent = Agent(
          model: _model,
          tools: [_tool('sed')],
          streamFunction: transientRetryStreamFunction((
            model,
            context, {cancelToken}) {
          innerCalls++;
          final stream = AssistantMessageEventStream();
          if (innerCalls == 1) {
            // Attempt 1: a text block AND a completed tool call stream,
            // then the run goes silent past the watchdog — the tool phase
            // never runs for this attempt (the message never finished).
            final empty = _assistant();
            const call = ToolCall(
              id: 'dead-1',
              name: 'sed',
              arguments: {'i': 'orig'},
            );
            final withCall = _assistant(
              content: [const TextContent(text: 'working'), call],
            );
            stream
              ..push(StartEvent(partial: empty))
              ..push(TextStartEvent(contentIndex: 0, partial: empty))
              ..push(
                TextEndEvent(
                  contentIndex: 0,
                  content: 'working',
                  partial: _assistant(
                    content: [const TextContent(text: 'working')],
                  ),
                ),
              )
              ..push(ToolCallStartEvent(contentIndex: 1, partial: empty))
              ..push(
                ToolCallEndEvent(
                  contentIndex: 1,
                  toolCall: call,
                  partial: withCall,
                ),
              );
            unawaited(
              cancelToken!.onCancel.then((_) {
                stream
                  ..push(
                    ErrorEvent(
                      reason: StopReason.aborted,
                      error: _assistant(
                        content: [
                          const TextContent(text: 'working'),
                          call,
                        ],
                        stopReason: StopReason.aborted,
                        errorMessage: 'Request was aborted',
                      ),
                    ),
                  )
                  ..end();
              }),
            );
          } else if (innerCalls == 2) {
            // The tail regenerates the same action under a fresh id.
            for (final event in _toolTurn([
              ToolCall(id: 'live-2', name: 'sed', arguments: {'i': 'new'}),
            ])) {
              stream.push(event);
            }
            stream.end();
          } else {
            for (final event in _textTurn('done')) {
              stream.push(event);
            }
            stream.end();
          }
          return stream;
        }),
          toolExecutor: (call, cancelToken, _) async {
            executorCalls++;
            expect(cancelToken!.isCancelled, isFalse);
            return ToolExecutionResult.text('ok');
          },
          runIdleTimeout: const Duration(milliseconds: 100),
          onRunIdleTimeout: (_) => fires++,
        );
        await agent.prompt('go');
        await agent.waitForIdle();

        expect(fires, 1);
        // The action ran EXACTLY ONCE: the dead call (id dead-1) never
        // reached any tool phase — neither live (its attempt aborted) nor
        // as a passenger in the resumed transcript next to its twin.
        expect(executorCalls, 1);
        final calls = agent.state.messages
            .whereType<AssistantMessage>()
            .expand((m) => m.content.whereType<ToolCall>())
            .toList();
        expect(calls, hasLength(1));
        expect(calls.single.id, 'live-2');
        final last = agent.state.messages.last as AssistantMessage;
        expect(last.stopReason, StopReason.stop);
      },
    );
  });
}
