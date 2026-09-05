import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/agent_event_handler.dart';
import 'package:test/test.dart';

TrajectoryRequestDetail _requestDetail() => const TrajectoryRequestDetail(
  messageCount: 2,
  systemPromptChars: 120,
  toolCount: 1,
  toolNames: ['read'],
  messages: [],
);
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
          timestamp: DateTime.utc(2026),
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

  test('routes ModelRequestEvent to the model request callback', () async {
    final details = <TrajectoryRequestDetail>[];
    await handleAgentEvent(
      ModelRequestEvent(detail: _requestDetail()),
      onMessageLifecycle: (_, {required start}) => fail('unexpected lifecycle'),
      onMessageUpdate: (_) => fail('unexpected update'),
      onToolExecutionStart: (_, _) => fail('unexpected tool start'),
      onToolExecutionEnd: (_, _, {required isError}) =>
          fail('unexpected tool end'),
      onTurnEnd: (_) => fail('unexpected turn end'),
      onModelRequest: (detail) async => details.add(detail),
    );
    expect(details, hasLength(1));
    expect(details.single.toolNames, ['read']);
  });

  test('the persisted summary replays onto the assistant step', () async {
    final repo = JsonlSessionRepo(
      fs: MemoryFileSystem(),
      sessionsRoot: '/sessions',
    );
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('deploy the service'));
    // Production wiring: the CLI appends the context-omitted CustomRecord
    // BEFORE the assistant message record, so the replay walk sees it as
    // the step's predecessor.
    await handleAgentEvent(
      ModelRequestEvent(detail: _requestDetail()),
      onMessageLifecycle: (_, {required start}) => fail('unexpected lifecycle'),
      onMessageUpdate: (_) => fail('unexpected update'),
      onToolExecutionStart: (_, _) => fail('unexpected tool start'),
      onToolExecutionEnd: (_, _, {required isError}) =>
          fail('unexpected tool end'),
      onTurnEnd: (_) => fail('unexpected turn end'),
      onModelRequest: (detail) => session.appendCustomEntry(
        customType: 'model_request_summary',
        data: detail.toJson(),
      ),
    );
    await session.appendMessage(_assistantMessage());

    // Re-open from the JSONL file: a fresh replay walk.
    final reopened = await repo.open(await session.getMetadata());
    final builder = TrajectorySnapshotBuilder();
    for (final record in await reopened.getEntries()) {
      builder.append(record);
    }
    final assistant = builder
        .build()
        .records
        .whereType<TrajectoryAssistantRecord>()
        .single;
    expect(assistant.requestDetail?.messageCount, 2);
    expect(assistant.requestDetail?.toolCount, 1);
    expect(assistant.requestDetail?.toolNames, ['read']);
  });
}
