/// Shared scripted-stream test harness for agent-loop-level tests: a const
/// test model, assistant-message builders, scripted turn event lists, and a
/// fake [StreamFunction] that replays turns while recording every request
/// payload. Lives outside the `*_test.dart` glob so it is never run as a
/// suite of its own.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The provider-agnostic model every scripted turn claims.
const testModel = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

/// Builds an [AssistantMessage] with the harness' fixed api/provider/model
/// identity and a zero usage stamp.
AssistantMessage scriptedAssistant({
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

/// A scripted turn: stream start, text delta, done.
List<AssistantMessageEvent> textTurn(String text) {
  final empty = scriptedAssistant();
  final partial = scriptedAssistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// A scripted turn that ends with tool calls.
List<AssistantMessageEvent> toolTurn(
  List<ToolCall> calls, {
  StopReason reason = StopReason.toolUse,
}) {
  final empty = scriptedAssistant();
  final partial = scriptedAssistant(content: calls, stopReason: reason);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: reason, message: partial));
  return events;
}

/// A [ToolCall] with an empty-argument default.
ToolCall toolCall(String id, String name, [Map<String, dynamic>? args]) {
  return ToolCall(id: id, name: name, arguments: args ?? const {});
}

/// Fake [StreamFunction]: replays scripted turns, records every request
/// payload it was called with.
class FakeStreamFunction {
  FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}
