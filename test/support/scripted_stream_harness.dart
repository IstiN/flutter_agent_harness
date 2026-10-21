/// The suite-neutral scripted-stream test harness: a const test model,
/// assistant-message builders, scripted turn event lists, and a fake
/// [StreamFunction] that replays turns while recording every request.
///
/// Lives outside the `*_test.dart` glob so it never runs as a suite of its
/// own; the agent_cli support file re-exports it so its long-standing
/// consumers keep their single import.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

const testModel = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

/// A catalog-backed cloud model, for the banner's key-status line.
const testCloudModel = Model(
  id: 'claude-sonnet-4-5',
  api: 'anthropic-messages',
  provider: 'anthropic',
  baseUrl: 'https://api.anthropic.com',
  contextWindow: 200000,
  maxTokens: 8192,
);

/// A model on a custom endpoint: the provider flips to `openai` (see
/// `buildCliDefaultModel`) while the key lookup stays by provider kind.
const testCustomEndpointModel = Model(
  id: 'local-model',
  api: 'openai-completions',
  provider: 'openai',
  baseUrl: 'http://127.0.0.1:8932',
  contextWindow: 100000,
  maxTokens: 4096,
);

/// The catalog `openai` DEFAULT endpoint, for the env/legacy key-hint
/// branches (they fire only on a spec's default endpoint — issue #40).
const testOpenAiDefaultEndpointModel = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'openai',
  baseUrl: 'https://api.openai.com/v1',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage testAssistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
  Usage? usage,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: usage ?? Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> textTurn(String text, {Usage? usage}) {
  final empty = testAssistant();
  final partial = testAssistant(
    content: [TextContent(text: text)],
    usage: usage,
  );
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

List<AssistantMessageEvent> toolTurn(List<ToolCall> calls) {
  final empty = testAssistant();
  final partial = testAssistant(content: calls, stopReason: StopReason.toolUse);
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

/// The text of a user message (string or content-block content) — the
/// shared assertion helper for outbound prompts (issue #1152).
String messageText(UserMessage message) {
  final content = message.content;
  if (content is String) return content;
  return [
    for (final block in content as List<ContentBlock>)
      if (block is TextContent) block.text,
  ].join();
}

/// Scripted [StreamFunction] replaying pre-recorded turns.
class FakeStreamFunction {
  FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];
  final models = <Model>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    models.add(model);
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
