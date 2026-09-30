import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  test('core loop guard probe', () async {
    var reliefCalls = 0;
    var streamCalls = 0;
    final agent = Agent(
      model: Model(
        id: 'main-model', name: 'main-model', api: 'anthropic-messages',
        provider: 'anthropic', baseUrl: 'https://x.invalid',
        contextWindow: 8192, maxTokens: 4096, input: const ['text']),
      systemPrompt: '',
      streamFunction: (model, context, {cancelToken}) {
        streamCalls++;
        var chars = 0;
        for (final m in context.messages) {
          if (m is ToolResultMessage) {
            for (final b in m.content) {
              if (b is TextContent) chars += b.text.length;
            }
          } else if (m is UserMessage) {
            chars += m.toString().length;
          }
        }
        // ignore: avoid_print
        print('REQ$streamCalls messages=${context.messages.length} toolResultChars=$chars');
        final stream = AssistantMessageEventStream();
        if (streamCalls == 1) {
          stream.push(DoneEvent(
            reason: StopReason.toolUse,
            message: AssistantMessage(
              content: [ToolCall(id: 'tc-1', name: 'echo', arguments: const {'x': 'go'})],
              api: model.api, provider: model.provider, model: model.id,
              usage: Usage.zero, stopReason: StopReason.toolUse,
              timestamp: DateTime.now())));
        } else {
          stream.push(DoneEvent(
            reason: StopReason.stop,
            message: AssistantMessage(
              content: [TextContent(text: 'continued')],
              api: model.api, provider: model.provider, model: model.id,
              usage: Usage.zero, stopReason: StopReason.stop,
              timestamp: DateTime.now())));
        }
        stream.end();
        return stream;
      },
      toolRegistry: ToolRegistry([
        AgentTool(
          name: 'echo', description: 'echo',
          parameters: const {'type': 'object', 'properties': {
            'x': {'type': 'string'}}, 'required': ['x']},
          execute: (arguments, cancelToken, onUpdate) async =>
              ToolExecutionResult.text('y' * 34000)),
      ]),
    );
    agent.overWindowRelief = (overWindow) async {
      reliefCalls++;
      // ignore: avoid_print
      print('RELIEF CALLED messages=${overWindow.length}');
      return null;
    };
    await agent.prompt('go');
    // ignore: avoid_print
    print('reliefCalls=$reliefCalls streamCalls=$streamCalls');
    expect(true, isTrue);
  });
}
