// Pins the fake: provider script (the deterministic CI seam, AC2/AC6):
// the navigate directive, the "[from <sender>] dm …" dap_dm seam, and the
// tool-result turn. No network, no browser — the fake provider is pure
// Dart, so this runs on the VM.
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import '../src/fake_provider.dart';

const _fakeModel = Model(
  id: 'fake:test',
  api: 'openai-completions',
  provider: 'fake',
  baseUrl: '',
  contextWindow: 128000,
  maxTokens: 8192,
);

Context _contextOf(List<Message> messages) => Context(messages: messages);

/// Runs one fake turn; returns the terminal (reason, message).
Future<(StopReason, AssistantMessage)> _finalOf(List<Message> messages) async {
  StopReason reason = StopReason.stop;
  AssistantMessage? message;
  await for (final event in fakeStream(_fakeModel, _contextOf(messages))) {
    if (event is DoneEvent) {
      reason = event.reason;
      message = event.message;
    }
  }
  return (reason, message!);
}

void main() {
  test(
    'navigate directive → browser_navigate tool call with the url',
    () async {
      final (reason, message) = await _finalOf([
        UserMessage.text('selftest: navigate data:text/html,<h1>fa</h1>'),
      ]);
      expect(reason, StopReason.toolUse);
      final call = message.content.whereType<ToolCall>().single;
      expect(call.name, 'browser_navigate');
      expect(call.arguments['url'], 'data:text/html,<h1>fa</h1>');
    },
  );

  test('dm directive → dap_dm back to the sender', () async {
    final (reason, message) = await _finalOf([
      UserMessage.text('[from abc123def45678] dm ping-browser-loop'),
    ]);
    expect(reason, StopReason.toolUse);
    final call = message.content.whereType<ToolCall>().single;
    expect(call.name, 'dap_dm');
    expect(call.arguments['to'], 'abc123def45678');
    expect(call.arguments['text'], 'fake: dm ping-browser-loop');
  });

  test('tool-result turn reports the executed tool and stops', () async {
    final (reason, message) = await _finalOf([
      UserMessage.text('go'),
      AssistantMessage(
        content: const [
          ToolCall(id: 'c1', name: 'browser_navigate', arguments: {'url': 'u'}),
        ],
        api: 'openai-completions',
        provider: 'fake',
        model: 'fake:test',
        usage: Usage.zero,
        stopReason: StopReason.toolUse,
        timestamp: DateTime.now(),
      ),
      ToolResultMessage(
        toolCallId: 'c1',
        toolName: 'browser_navigate',
        content: const [TextContent(text: 'ok')],
        isError: false,
        timestamp: DateTime.now(),
      ),
    ]);
    expect(reason, StopReason.stop);
    expect(
      message.content.whereType<TextContent>().single.text,
      'fake: browser_navigate succeeded',
    );
  });

  test('plain prompt is echoed as text', () async {
    final (reason, message) = await _finalOf([UserMessage.text('hello agent')]);
    expect(reason, StopReason.stop);
    expect(
      message.content.whereType<TextContent>().single.text,
      'fake: hello agent',
    );
  });
}
