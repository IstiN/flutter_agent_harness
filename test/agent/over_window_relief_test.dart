// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

// Issue #387 — the over-window guard's emergency relief.
//
// The mid-turn guard refuses to send a request past the model window
// (gross overflow). With a host-provided over-window relief the loop runs
// ONE synchronous compaction and retries the request once with the
// relieved context — the turn completes instead of dying. A relief that
// cannot get under the window (or none hideable) keeps today's verbatim
// error, bounded to a single attempt (never a loop).

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

/// Registered so the loop's tool phase accepts the call — an unregistered
/// tool short-circuits to a tiny "not found" error result before the
/// executor ever runs.
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

class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

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

ToolCall _call(String id, String name) =>
    ToolCall(id: id, name: name, arguments: const {});

/// Estimated request tokens of a captured request — the guard's basis.
int _requestTokens(Context context) => estimateRequestTokens(
  context.messages,
  systemPrompt: context.systemPrompt,
  tools: context.tools ?? const [],
);

/// Drops the oldest messages until the estimate fits under [limit] — a
/// mechanical stand-in for the host's hide/checkpoint pass.
List<Message> trimTo(List<Message> messages, int limit) {
  var kept = messages;
  while (kept.length > 2 && estimateContextTokens(kept).tokens > limit) {
    kept = kept.sublist(1);
  }
  return kept;
}

void main() {
  test('gross mid-turn overflow: one relief + one retry completes the turn', () async {
    // Request 1 (~76 tok) fits; the tool result balloons request 2
    // (~180 tok) past the 120-token window; the relief drops the stale
    // prompt and the retried request (~105 tok) goes out.
    final fake = _FakeStreamFunction([
      _toolTurn([_call('c1', 'bash')]),
      _textTurn('done'),
    ]);
    var reliefCalls = 0;
    final stream = agentLoop(
      prompts: [UserMessage.text('u' * 300)],
      context: const Context(messages: [], tools: [_bashTool]),
      config: AgentLoopConfig(
        model: _model,
        overWindowRelief: (messages) async {
          reliefCalls++;
          return trimTo(messages, 100);
        },
      ),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('r' * 400),
    );

    final messages = await stream.result as List<dynamic>;

    // The invariant: every request that left was measured under the window.
    for (final context in fake.contexts) {
      expect(_requestTokens(context), lessThanOrEqualTo(120));
    }
    expect(fake.calls, 2, reason: 'the guarded request was retried once');
    expect(reliefCalls, 1, reason: 'relief is bounded to one attempt');
    final assistant = messages.whereType<AssistantMessage>().last;
    expect(assistant.stopReason, StopReason.stop);
    expect(assistant.errorMessage, isNull);
  });

  test('the loop adopts the relieved context for later requests', () async {
    // After the relief, the next request must be built on the compacted
    // transcript — not on the stale pre-relief copy (a relief the loop
    // discards would re-trip the guard on every remaining turn).
    final fake = _FakeStreamFunction([
      _toolTurn([_call('c1', 'bash')]),
      _textTurn('done'),
    ]);
    final stream = agentLoop(
      prompts: [UserMessage.text('u' * 300)],
      context: const Context(messages: [], tools: [_bashTool]),
      config: AgentLoopConfig(
        model: _model,
        overWindowRelief: (messages) async => trimTo(messages, 100),
      ),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('r' * 400),
    );

    await stream.result as List<dynamic>;

    final second = fake.contexts[1].messages;
    // The stale prompt was dropped by the relief and never came back.
    expect(
      second.whereType<UserMessage>(),
      isEmpty,
      reason: 'the request rides the relieved transcript, not the stale one',
    );
    expect(second, hasLength(2), reason: 'assistant carrier + tool result');
  });

  test('nothing hideable: the verbatim guard error survives, no loop', () async {
    final fake = _FakeStreamFunction([_textTurn('never')]);
    var reliefCalls = 0;
    final stream = agentLoop(
      prompts: [UserMessage.text('x' * 800)],
      context: const Context(messages: [], tools: [_bashTool]),
      config: AgentLoopConfig(
        model: _model,
        overWindowRelief: (messages) async {
          reliefCalls++;
          return null; // The host could not free the window.
        },
      ),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
    );

    final messages = await stream.result as List<dynamic>;
    expect(fake.calls, 0);
    expect(reliefCalls, 1, reason: 'one attempt — never a loop');
    final assistant = messages.whereType<AssistantMessage>().single;
    expect(assistant.stopReason, StopReason.error);
    expect(assistant.errorMessage, contains(contextWindowExhaustedMarker));
    expect(assistant.errorMessage, contains('The request was not sent'));
  });

  test('relief that stays over the window counts as failure (E1: never loops)', () async {
    // A single tool result larger than the whole window: no compaction can
    // save it, and the relief's "compacted" list is STILL over — the loop
    // must give up with the honest error, not retry forever.
    final fake = _FakeStreamFunction([
      _toolTurn([_call('c1', 'bash')]),
      _textTurn('never'),
    ]);
    var reliefCalls = 0;
    final stream = agentLoop(
      prompts: [UserMessage.text('u' * 40)],
      context: const Context(messages: [], tools: [_bashTool]),
      config: AgentLoopConfig(
        model: _model,
        overWindowRelief: (messages) async {
          reliefCalls++;
          return messages; // "Compacted" but still over the window.
        },
      ),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('r' * 800),
    );

    final messages = await stream.result as List<dynamic>;
    expect(fake.calls, 1, reason: 'the first request fit and went out');
    expect(reliefCalls, 1, reason: 'one attempt — never a loop');
    final assistant = messages.whereType<AssistantMessage>().last;
    expect(assistant.stopReason, StopReason.error);
    expect(assistant.errorMessage, contains(contextWindowExhaustedMarker));
  });

  test("no relief configured: today's behavior is byte-identical", () async {
    final fake = _FakeStreamFunction([_textTurn('never')]);
    final stream = agentLoop(
      prompts: [UserMessage.text('x' * 800)],
      context: const Context(messages: [], tools: [_bashTool]),
      config: AgentLoopConfig(model: _model),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
    );

    final messages = await stream.result as List<dynamic>;
    expect(fake.calls, 0);
    final assistant = messages.whereType<AssistantMessage>().single;
    expect(assistant.stopReason, StopReason.error);
    expect(assistant.errorMessage, contains(contextWindowExhaustedMarker));
  });

  test('a throwing relief degrades to the plain guard error', () async {
    final fake = _FakeStreamFunction([_textTurn('never')]);
    final stream = agentLoop(
      prompts: [UserMessage.text('x' * 800)],
      context: const Context(messages: [], tools: [_bashTool]),
      config: AgentLoopConfig(
        model: _model,
        overWindowRelief: (messages) async => throw StateError('smol down'),
      ),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
    );

    final messages = await stream.result as List<dynamic>;
    expect(fake.calls, 0);
    final assistant = messages.whereType<AssistantMessage>().single;
    expect(assistant.stopReason, StopReason.error);
    expect(assistant.errorMessage, contains(contextWindowExhaustedMarker));
  });
}
