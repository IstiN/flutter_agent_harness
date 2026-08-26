import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/agent_event_handler.dart';
import 'package:test/test.dart';

AssistantMessage _assistantMessage({StopReason stopReason = StopReason.stop}) {
  return AssistantMessage(
    content: const [TextContent(text: 'hi')],
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

ToolExecutionResult _toolResult() =>
    const ToolExecutionResult(content: [TextContent(text: 'ok')]);

void main() {
  group('handleAgentEvent', () {
    test('routes MessageStartEvent and MessageEndEvent to lifecycle', () {
      final calls = <({Message message, bool start})>[];
      final message = _assistantMessage();
      handleAgentEvent(
        MessageStartEvent(message),
        onMessageLifecycle: (m, {required start}) =>
            calls.add((message: m, start: start)),
        onMessageUpdate: (_) => fail('unexpected update'),
        onToolExecutionStart: (_, _) => fail('unexpected tool start'),
        onToolExecutionEnd: (_, _, {required isError}) =>
            fail('unexpected tool end'),
        onTurnEnd: (_) => fail('unexpected turn end'),
      );
      handleAgentEvent(
        MessageEndEvent(message),
        onMessageLifecycle: (m, {required start}) =>
            calls.add((message: m, start: start)),
        onMessageUpdate: (_) => fail('unexpected update'),
        onToolExecutionStart: (_, _) => fail('unexpected tool start'),
        onToolExecutionEnd: (_, _, {required isError}) =>
            fail('unexpected tool end'),
        onTurnEnd: (_) => fail('unexpected turn end'),
      );
      expect(calls, [
        (message: message, start: true),
        (message: message, start: false),
      ]);
    });

    test('routes MessageUpdateEvent to update callback', () {
      final events = <AssistantMessageEvent>[];
      final message = _assistantMessage();
      final delta = TextDeltaEvent(
        contentIndex: 0,
        delta: 'x',
        partial: AssistantMessage(
          content: const [],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      );
      handleAgentEvent(
        MessageUpdateEvent(message: message, assistantMessageEvent: delta),
        onMessageLifecycle: (_, {required start}) =>
            fail('unexpected lifecycle'),
        onMessageUpdate: events.add,
        onToolExecutionStart: (_, _) => fail('unexpected tool start'),
        onToolExecutionEnd: (_, _, {required isError}) =>
            fail('unexpected tool end'),
        onTurnEnd: (_) => fail('unexpected turn end'),
      );
      expect(events, [delta]);
    });

    test('routes tool start/end events to tool callbacks', () {
      final startNames = <String>[];
      final startArgs = <Map<String, Object?>>[];
      final endNames = <String>[];
      final endErrors = <bool>[];
      final result = _toolResult();
      handleAgentEvent(
        ToolExecutionStartEvent(
          toolCallId: 'c1',
          toolName: 'read',
          args: const {'path': 'x'},
        ),
        onMessageLifecycle: (_, {required start}) =>
            fail('unexpected lifecycle'),
        onMessageUpdate: (_) => fail('unexpected update'),
        onToolExecutionStart: (n, a) {
          startNames.add(n);
          startArgs.add(a);
        },
        onToolExecutionEnd: (n, r, {required isError}) {
          endNames.add(n);
          endErrors.add(isError);
        },
        onTurnEnd: (_) => fail('unexpected turn end'),
      );
      handleAgentEvent(
        ToolExecutionEndEvent(
          toolCallId: 'c1',
          toolName: 'read',
          result: result,
          isError: false,
        ),
        onMessageLifecycle: (_, {required start}) =>
            fail('unexpected lifecycle'),
        onMessageUpdate: (_) => fail('unexpected update'),
        onToolExecutionStart: (n, a) {
          startNames.add(n);
          startArgs.add(a);
        },
        onToolExecutionEnd: (n, r, {required isError}) {
          endNames.add(n);
          endErrors.add(isError);
        },
        onTurnEnd: (_) => fail('unexpected turn end'),
      );
      expect(startNames, ['read']);
      expect(startArgs, [
        const {'path': 'x'},
      ]);
      expect(endNames, ['read']);
      expect(endErrors, [false]);
    });

    test('routes TurnEndEvent to turn end callback', () {
      AssistantMessage? seen;
      final message = _assistantMessage();
      handleAgentEvent(
        TurnEndEvent(message: message, toolResults: const []),
        onMessageLifecycle: (_, {required start}) =>
            fail('unexpected lifecycle'),
        onMessageUpdate: (_) => fail('unexpected update'),
        onToolExecutionStart: (_, _) => fail('unexpected tool start'),
        onToolExecutionEnd: (_, _, {required isError}) =>
            fail('unexpected tool end'),
        onTurnEnd: (m) => seen = m,
      );
      expect(seen, message);
    });
  });
}
