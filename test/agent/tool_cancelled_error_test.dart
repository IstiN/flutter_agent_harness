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
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
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

Tool _tool(String name) {
  return Tool(name: name, description: '$name tool', parameters: const {});
}

/// gh-1455: a CancelledException escaping a tool call is the run's
/// DELIBERATE shutdown (the shell tool's own first-line guard, the
/// stuck-call supervisor, a tool's throwIfCancelled) — not a tool failure
/// and not a harness defect. The generic `_errorToolResult` path used to
/// render it with the "uncaught exception inside the harness tool
/// implementation" hint, telling the model its bash tool is broken and to
/// route around it (the transcript symptom: `Tool error (bash):
/// CancelledException: run was aborted by signal …`).
void main() {
  test('a CancelledException from a tool renders as a deliberate cancel, '
      'not a harness defect', () async {
    final fake = _FakeStreamFunction([
      _toolTurn([ToolCall(id: 'c1', name: 'bash', arguments: const {})]),
      _textTurn('done'),
    ]);
    final agent = Agent(
      model: _model,
      streamFunction: fake.call,
      toolExecutor: (toolCall, cancelToken, onUpdate) async {
        throw CancelledException('run was aborted by signal');
      },
    );
    agent.state.tools = [_tool('bash')];

    await agent.prompt('start the long thing');

    final toolResult = agent.state.messages
        .whereType<ToolResultMessage>()
        .single;
    final text = (toolResult.content.single as TextContent).text;
    expect(text, contains('Tool error (bash):'));
    expect(text, contains('run was aborted'));
    // gh-1455 review: "tool not started" was inaccurate for a cancel that
    // lands mid-execution (the tool WAS started and may have partially
    // run) — the message says the call was cancelled, full stop.
    expect(text, contains('call cancelled'));
    expect(text, isNot(contains('tool not started')));
    expect(text, isNot(contains('uncaught exception inside the harness')));
    // The cancel reason survives so the model (and the transcript) can see
    // WHO cancelled the run — e.g. the run-idle watchdog.
    expect(text, contains('run was aborted by signal'));
  });
}
