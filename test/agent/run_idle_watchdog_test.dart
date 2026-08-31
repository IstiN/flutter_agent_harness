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
  });
}
