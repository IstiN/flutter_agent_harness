import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _message({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
  String model = 'test-model',
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: model,
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );
}

void main() {
  group('EventStream', () {
    test('pushed events are delivered in order', () async {
      final stream = AssistantMessageEventStream();
      final partial = _message();
      stream
        ..push(StartEvent(partial: partial))
        ..push(TextStartEvent(contentIndex: 0, partial: partial))
        ..push(
          DoneEvent(
            reason: StopReason.stop,
            message: _message(content: [const TextContent(text: 'hi')]),
          ),
        )
        ..end();

      final events = await stream.toList();
      expect(events, hasLength(3));
      expect(events[0], isA<StartEvent>());
      expect(events[1], isA<TextStartEvent>());
      expect(events[2], isA<DoneEvent>());
    });

    test('events pushed before listen are buffered', () async {
      final stream = AssistantMessageEventStream();
      final partial = _message();
      stream
        ..push(StartEvent(partial: partial))
        ..end();

      await Future<void>.delayed(Duration.zero);
      final events = await stream.toList();
      expect(events.single, isA<StartEvent>());
    });

    test('result resolves with message on DoneEvent', () async {
      final stream = AssistantMessageEventStream();
      final message = _message(content: [const TextContent(text: 'done')]);
      stream
        ..push(DoneEvent(reason: StopReason.stop, message: message))
        ..end();

      expect(await stream.result, same(message));
    });

    test('result resolves with error message on ErrorEvent', () async {
      final stream = AssistantMessageEventStream();
      final error = _message(
        stopReason: StopReason.error,
        errorMessage: 'boom',
      );
      stream
        ..push(ErrorEvent(reason: StopReason.error, error: error))
        ..end();

      final result = await stream.result;
      expect(result.errorMessage, 'boom');
      expect(result.stopReason, StopReason.error);
    });

    test('pushes after a completion event are ignored', () async {
      final stream = AssistantMessageEventStream();
      final message = _message();
      stream
        ..push(DoneEvent(reason: StopReason.stop, message: message))
        ..push(StartEvent(partial: message))
        ..end();

      final events = await stream.toList();
      expect(events, hasLength(1));
      expect(events.single, isA<DoneEvent>());
    });

    test('pushes after end are ignored', () async {
      final stream = AssistantMessageEventStream();
      final partial = _message();
      stream
        ..end()
        ..push(StartEvent(partial: partial));

      expect(await stream.toList(), isEmpty);
    });

    test('end(result) resolves result without a completion event', () async {
      final stream = AssistantMessageEventStream();
      final message = _message();
      stream.end(message);

      expect(await stream.result, same(message));
    });

    test('first result resolution wins', () async {
      final stream = AssistantMessageEventStream();
      final first = _message();
      final second = _message(model: 'other');
      stream
        ..end(first)
        ..end(second);

      expect(await stream.result, same(first));
    });

    test(
      'end without completion event completes result with StateError',
      () async {
        final stream = AssistantMessageEventStream()
          ..push(StartEvent(partial: _message()))
          ..end();

        await expectLater(stream.toList(), completion(hasLength(1)));
        await expectLater(stream.result, throwsStateError);
      },
    );

    test('createAssistantMessageEventStream factory works', () {
      expect(
        createAssistantMessageEventStream(),
        isA<AssistantMessageEventStream>(),
      );
    });
  });

  group('partial-first invariant', () {
    test('every delta event carries the live partial message', () async {
      final stream = AssistantMessageEventStream();
      final t0 = DateTime.utc(2026);

      // Simulate a provider accumulating text + a tool call.
      final partials = <AssistantMessage>[
        _message(),
        _message(content: [const TextContent(text: '')]),
        _message(content: [const TextContent(text: 'Hel')]),
        _message(content: [const TextContent(text: 'Hello')]),
        _message(
          content: [
            const TextContent(text: 'Hello'),
            const ToolCall(
              id: 'call_1',
              name: 'search',
              arguments: {},
              partialArguments: '{"q":',
            ),
          ],
        ),
        _message(
          content: [
            const TextContent(text: 'Hello'),
            const ToolCall(
              id: 'call_1',
              name: 'search',
              arguments: {'q': 'dart'},
            ),
          ],
          stopReason: StopReason.toolUse,
        ),
      ];

      stream
        ..push(StartEvent(partial: partials[0]))
        ..push(TextStartEvent(contentIndex: 0, partial: partials[1]))
        ..push(
          TextDeltaEvent(contentIndex: 0, delta: 'Hel', partial: partials[2]),
        )
        ..push(
          TextEndEvent(contentIndex: 0, content: 'Hello', partial: partials[3]),
        )
        ..push(ToolCallStartEvent(contentIndex: 1, partial: partials[3]))
        ..push(
          ToolCallDeltaEvent(
            contentIndex: 1,
            delta: '{"q":',
            partial: partials[4],
          ),
        )
        ..push(
          ToolCallEndEvent(
            contentIndex: 1,
            toolCall: partials[5].content[1] as ToolCall,
            partial: partials[5],
          ),
        )
        ..push(DoneEvent(reason: StopReason.toolUse, message: partials[5]))
        ..end();

      final events = await stream.toList();
      expect(events, hasLength(8));

      // Every event exposes its partial; deltas share the live snapshot.
      const expectedPartials = [0, 1, 2, 3, 3, 4, 5, 5];
      for (var i = 0; i < events.length; i++) {
        expect(events[i].partial, same(partials[expectedPartials[i]]));
      }

      final delta = events[2] as TextDeltaEvent;
      expect(delta.delta, 'Hel');
      expect((delta.partial.content[0] as TextContent).text, 'Hel');

      final toolDelta = events[5] as ToolCallDeltaEvent;
      final partialTool = toolDelta.partial.content[1] as ToolCall;
      expect(partialTool.partialArguments, '{"q":');
      expect(partialTool.arguments, isEmpty);

      final end = events[6] as ToolCallEndEvent;
      expect(end.toolCall.arguments, {'q': 'dart'});

      final done = events[7] as DoneEvent;
      expect(done.partial, same(done.message));
      expect(done.message.timestamp, t0);
      expect(await stream.result, same(partials[5]));
    });

    test('ErrorEvent partial is the error message', () {
      final error = _message(
        stopReason: StopReason.aborted,
        errorMessage: 'cancelled',
      );
      final event = ErrorEvent(reason: StopReason.aborted, error: error);
      expect(event.partial, same(error));
      expect(event.partial.errorMessage, 'cancelled');
    });
  });
}
