// Pins the fake: provider script (the deterministic CI seam, AC2/AC6):
// the navigate directive, the "[from <sender>] dm …" dap_dm seam, the
// inject_js / sessions_restore e2e directives, and the tool-result turn.
// No network, no browser — the fake provider is pure Dart, so this runs on
// the VM.
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

  test(
    'dm directive survives a prepended [context] line (issue #41)',
    () async {
      // The host decorates turns with "[context] active tab: …" (issue #34);
      // a ^-anchored DM regex then never matches and the DM gets echoed
      // instead of answered — the DAP e2e timed out on exactly this.
      final (reason, message) = await _finalOf([
        UserMessage.text(
          '[context] active tab: t — https://a.dev\n'
          '[from abc123def45678] dm ping-browser-loop',
        ),
      ]);
      expect(reason, StopReason.toolUse);
      final call = message.content.whereType<ToolCall>().single;
      expect(call.name, 'dap_dm');
      expect(call.arguments['to'], 'abc123def45678');
      expect(call.arguments['text'], 'fake: dm ping-browser-loop');
    },
  );

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

  test('inject_js directive → inject_js call with tabId/world/code', () async {
    final (reason, message) = await _finalOf([
      UserMessage.text(
        '[context] active tab: t — https://a.dev\n'
        'inject_js 42 MAIN window.__faMain = "hi";\nsecond line',
      ),
    ]);
    expect(reason, StopReason.toolUse);
    final call = message.content.whereType<ToolCall>().single;
    expect(call.name, 'inject_js');
    expect(call.arguments['tabId'], 42);
    expect(call.arguments['world'], 'MAIN');
    expect(call.arguments['code'], 'window.__faMain = "hi";\nsecond line');
  });

  test('run_script directive → run_script call with language/code', () async {
    final (reason, message) = await _finalOf([
      UserMessage.text(
        '[context] active tab: t — https://a.dev\n'
        'run_script python print("hi")\nsecond line',
      ),
    ]);
    expect(reason, StopReason.toolUse);
    final call = message.content.whereType<ToolCall>().single;
    expect(call.name, 'run_script');
    expect(call.arguments['language'], 'python');
    expect(call.arguments['code'], 'print("hi")\nsecond line');
  });

  test(
    'sessions_restore directive → sessions_restore call with the id',
    () async {
      final (reason, message) = await _finalOf([
        UserMessage.text(
          '[context] active tab: t — https://a.dev\nsessions_restore 17',
        ),
      ]);
      expect(reason, StopReason.toolUse);
      final call = message.content.whereType<ToolCall>().single;
      expect(call.name, 'sessions_restore');
      expect(call.arguments['sessionId'], '17');
    },
  );

  test('tool result carrying an image reports the vision seen', () async {
    // The scripted stand-in for a vision model: an ImageContent block in
    // the tool result must reach the model context (the screenshot tools'
    // contract) and be acknowledged in the reply.
    final (reason, message) = await _finalOf([
      UserMessage.text('shoot'),
      AssistantMessage(
        content: const [
          ToolCall(id: 'c2', name: 'page_screenshot', arguments: {}),
        ],
        api: 'openai-completions',
        provider: 'fake',
        model: 'fake:test',
        usage: Usage.zero,
        stopReason: StopReason.toolUse,
        timestamp: DateTime.now(),
      ),
      ToolResultMessage(
        toolCallId: 'c2',
        toolName: 'page_screenshot',
        content: const [
          ImageContent(data: 'cGl4', mimeType: 'image/png'),
          TextContent(text: '{"ok":true,"tabId":1}'),
        ],
        isError: false,
        timestamp: DateTime.now(),
      ),
    ]);
    expect(reason, StopReason.stop);
    expect(
      message.content.whereType<TextContent>().single.text,
      'fake: page_screenshot succeeded (image seen)',
    );
  });

  test('think directive streams thinking deltas before the text', () async {
    final thinking = <String>[];
    final text = <String>[];
    StopReason reason = StopReason.stop;
    await for (final event in fakeStream(
      _fakeModel,
      _contextOf([UserMessage.text('fake: think it through')]),
    )) {
      if (event is ThinkingDeltaEvent) thinking.add(event.delta);
      if (event is TextDeltaEvent) text.add(event.delta);
      if (event is DoneEvent) reason = event.reason;
    }
    expect(reason, StopReason.stop);
    expect(thinking.join(), isNotEmpty);
    expect(text.join(), contains('fake:'));
  });

  test('screenshot directive → browser_screenshot tool call', () async {
    final (reason, message) = await _finalOf([
      UserMessage.text('take a screenshot now'),
    ]);
    expect(reason, StopReason.toolUse);
    expect(
      message.content.whereType<ToolCall>().single.name,
      'browser_screenshot',
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
