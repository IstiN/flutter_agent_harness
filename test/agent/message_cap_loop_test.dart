// gh-1680 IT-2 / AC3 / AC7 / AC8 — the reactive message-cap repair in the
// agent loop: a classified cap-400 learns the cap, runs ONE host
// compaction pass, retries ONCE and succeeds; a second cap-400 surfaces
// the terminal error (no infinite loop); without a policy the refusal is
// terminal immediately (byte-identical to today); the coalesce only
// touches the outbound payload (the session transcript is never mutated).

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

const _incident =
    '400: {"error":{"message":"400 messages: array length 2049 exceeds '
    'limit 2048","type":"api_error"}}';

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

List<AssistantMessageEvent> _capRefusalTurn(String error) {
  final msg = _assistant(stopReason: StopReason.error, errorMessage: error);
  return [StartEvent(partial: msg), ErrorEvent(reason: StopReason.error, error: msg)];
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

List<Message> _history(int toolPairs) => [
  for (var i = 0; i < toolPairs; i++) ...[
    UserMessage.text('question $i'),
    AssistantMessage(
      content: [
        ToolCall(id: 'c$i', name: 'read', arguments: const {}),
      ],
      api: 'test-api',
      provider: 'test-provider',
      model: 'test-model',
      usage: Usage.zero,
      stopReason: StopReason.toolUse,
      timestamp: DateTime.utc(2026),
    ),
    ToolResultMessage(
      toolCallId: 'c$i',
      toolName: 'read',
      content: [TextContent(text: 'result $i')],
      isError: false,
      timestamp: DateTime.utc(2026),
    ),
  ],
];

void main() {
  test('cap-400: learn + one compaction pass + one retry → success (AC3)', () async {
    final fake = _FakeStreamFunction([
      _capRefusalTurn(_incident),
      _textTurn('recovered'),
    ]);
    final store = ModelCapsStore();
    var reliefCalls = 0;
    final events = <AgentEvent>[];
    final messages = await runAgentLoop(
      prompts: [UserMessage.text('go')],
      context: Context(messages: _history(4)),
      config: AgentLoopConfig(
        model: _model,
        messageCapPolicy: store,
        messageCapRelief: (messages) async {
          reliefCalls++;
          // The host compaction pass: keep the newest half.
          return messages.sublist(messages.length ~/ 2);
        },
      ),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => const ToolExecutionResult(content: []),
      emit: events.add,
    );

    expect(fake.calls, 2, reason: 'the refused request was retried once');
    expect(reliefCalls, 1, reason: 'relief is bounded to one attempt');
    expect(store.learnedCapFor(_model), 2048, reason: 'cap learned (AC2)');
    final repair = events.whereType<MessageCapRepairEvent>().single;
    expect(repair.learnedCap, 2048);
    expect(repair.compacted, isTrue);
    expect(
      repair.messageCount,
      fake.contexts.first.messages.length,
      reason: 'the notice names the refused count',
    );
    final assistant = messages.whereType<AssistantMessage>().last;
    expect(assistant.stopReason, StopReason.stop);
    expect(assistant.errorMessage, isNull);
  });

  test('a second cap-400 surfaces the terminal error — no infinite loop', () async {
    final fake = _FakeStreamFunction([
      _capRefusalTurn(_incident),
      _capRefusalTurn(
        '400 messages: array length 2051 exceeds limit 2048',
      ),
    ]);
    final store = ModelCapsStore();
    var reliefCalls = 0;
    final messages = await runAgentLoop(
      prompts: [UserMessage.text('go')],
      context: Context(messages: _history(2)),
      config: AgentLoopConfig(
        model: _model,
        messageCapPolicy: store,
        messageCapRelief: (messages) async {
          reliefCalls++;
          return messages.sublist(1);
        },
      ),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => const ToolExecutionResult(content: []),
      emit: (_) {},
    );
    expect(fake.calls, 2);
    expect(reliefCalls, 1);
    // The stale-cap re-learn path (E4): the second refusal re-teaches M.
    expect(store.learnedCapFor(_model), 2048);
    final assistant = messages.whereType<AssistantMessage>().last;
    expect(assistant.stopReason, StopReason.error);
    expect(assistant.errorMessage, contains('exceeds limit 2048'));
  });

  test('no policy: the cap-400 is terminal immediately (AC8, byte-identical)', () async {
    final fake = _FakeStreamFunction([_capRefusalTurn(_incident)]);
    final messages = await runAgentLoop(
      prompts: [UserMessage.text('go')],
      context: Context(messages: _history(2)),
      config: AgentLoopConfig(model: _model),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => const ToolExecutionResult(content: []),
      emit: (_) {},
    );
    expect(fake.calls, 1, reason: 'no policy — no repair, no retry');
    final assistant = messages.whereType<AssistantMessage>().last;
    expect(assistant.stopReason, StopReason.error);
    expect(assistant.errorMessage, contains('exceeds limit 2048'));
  });

  test('cap-unknown refusal still heals once, with a null learned cap (E1)', () async {
    final fake = _FakeStreamFunction([
      _capRefusalTurn('400 messages: array length exceeds limit'),
      _textTurn('recovered'),
    ]);
    final store = ModelCapsStore();
    final events = <AgentEvent>[];
    final messages = await runAgentLoop(
      prompts: [UserMessage.text('go')],
      context: Context(messages: _history(2)),
      config: AgentLoopConfig(
        model: _model,
        messageCapPolicy: store,
        messageCapRelief: (messages) async => messages.sublist(1),
      ),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => const ToolExecutionResult(content: []),
      emit: events.add,
    );
    expect(fake.calls, 2, reason: 'one coalesce+compact retry even cap-unknown');
    expect(store.learnedCapFor(_model), isNull);
    expect(store.isCapUnknown(_model.provider, _model.id), isTrue);
    final repair = events.whereType<MessageCapRepairEvent>().single;
    expect(repair.learnedCap, isNull);
    expect(messages.whereType<AssistantMessage>().last.stopReason,
        StopReason.stop);
  });

  test('the retry rides a coalesced payload; the transcript is untouched '
      '(AC6/AC7)', () async {
    // A small learned cap so the coalesce has work to do on the wire:
    // 30 messages refused with limit 24 → retry payload ≤ 24 − 16 = 8.
    final fake = _FakeStreamFunction([
      _capRefusalTurn('400 messages: array length 30 exceeds limit 24'),
      _textTurn('recovered'),
    ]);
    final store = ModelCapsStore();
    final history = _history(10); // 30 messages
    final historyBefore = [...history];
    await runAgentLoop(
      prompts: [UserMessage.text('go')],
      context: Context(messages: history),
      config: AgentLoopConfig(
        model: _model,
        messageCapPolicy: store,
        // No relief: the coalesce-only retry must still be attempted.
      ),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => const ToolExecutionResult(content: []),
      emit: (_) {},
    );

    expect(fake.calls, 2);
    final retryPayload = fake.contexts[1].messages;
    expect(
      retryPayload.length,
      lessThanOrEqualTo(8),
      reason: 'coalesced toward cap − margin',
    );
    expect(validateToolPairing(retryPayload), isEmpty);
    // AC7: the session transcript is byte-identical — the input history
    // list was never mutated by the repair (outbound-only surgery).
    expect(history, orderedEquals(historyBefore));
  });

  test('a throwing relief degrades to the coalesce-only retry', () async {
    final fake = _FakeStreamFunction([
      _capRefusalTurn(_incident),
      _textTurn('recovered'),
    ]);
    final store = ModelCapsStore();
    final events = <AgentEvent>[];
    final messages = await runAgentLoop(
      prompts: [UserMessage.text('go')],
      context: Context(messages: _history(2)),
      config: AgentLoopConfig(
        model: _model,
        messageCapPolicy: store,
        messageCapRelief: (messages) async => throw StateError('smol down'),
      ),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => const ToolExecutionResult(content: []),
      emit: events.add,
    );
    expect(fake.calls, 2);
    final repair = events.whereType<MessageCapRepairEvent>().single;
    expect(repair.compacted, isFalse);
    expect(messages.whereType<AssistantMessage>().last.stopReason,
        StopReason.stop);
  });
}
