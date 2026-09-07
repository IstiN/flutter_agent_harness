// Pins the pure AgentHost ↔ panel event contracts on the VM:
//   - ThinkingDeltaEvent maps to a `thinking_delta` UI event (it used to be
//     dropped silently — the panel never saw any reasoning);
//   - tool-result UI events carry text only (no base64 flood);
//   - the v1 `browser_screenshot` bridge converts `pngBase64` results into
//     a vision ImageContent block the model actually sees.
// agent_host.dart itself is web-only (package:web via fetch_client), so the
// mappings live in host_event_map.dart and are tested here directly.
import 'dart:convert';

import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import '../src/host_event_map.dart';

AssistantMessage _assistant(List<ContentBlock> content) => AssistantMessage(
  content: content,
  api: 'openai-completions',
  provider: 'fake',
  model: 'fake:test',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.now(),
);

void main() {
  test('ThinkingDeltaEvent → thinking_delta UI event', () {
    final map = hostEventOf(
      MessageUpdateEvent(
        message: _assistant([ThinkingContent(thinking: 'hmm ')]),
        assistantMessageEvent: ThinkingDeltaEvent(
          contentIndex: 0,
          delta: 'hmm ',
          partial: _assistant([ThinkingContent(thinking: 'hmm ')]),
        ),
      ),
    );
    expect(map, {'type': 'thinking_delta', 'text': 'hmm '});
  });

  test('TextDeltaEvent → delta UI event (unchanged shape)', () {
    final map = hostEventOf(
      MessageUpdateEvent(
        message: _assistant(const [TextContent(text: 'hi')]),
        assistantMessageEvent: TextDeltaEvent(
          contentIndex: 0,
          delta: 'hi',
          partial: _assistant(const [TextContent(text: 'hi')]),
        ),
      ),
    );
    expect(map, {'type': 'delta', 'text': 'hi'});
  });

  test('tool_result UI event strips images — text channel stays clean', () {
    final png = base64Encode(List.filled(64, 7));
    final map = hostEventOf(
      ToolExecutionEndEvent(
        toolCallId: 'c1',
        toolName: 'page_screenshot',
        result: ToolExecutionResult(
          content: [
            ImageContent(data: png, mimeType: 'image/png'),
            const TextContent(text: '{"ok":true,"tabId":1}'),
          ],
        ),
        isError: false,
      ),
    );
    expect(map?['type'], 'tool_result');
    expect(map?['toolName'], 'page_screenshot');
    expect(map?['isError'], false);
    final text = map?['text'] as String;
    expect(text, contains('"tabId":1'));
    expect(text, isNot(contains(png)));
  });

  test('v1 screenshot bridge: pngBase64 becomes a vision block', () {
    final png = base64Encode(List.filled(64, 7));
    final res = v1OpToolResult('screenshot', {
      'ok': true,
      'result': {'tabId': 1, 'pngBase64': png},
    });
    final images = res.content.whereType<ImageContent>().toList();
    expect(images, hasLength(1));
    expect(images.single.data, png);
    expect(images.single.mimeType, 'image/png');
    final text = res.content
        .whereType<TextContent>()
        .map((c) => c.text)
        .join('\n');
    expect(text, contains('"tabId":1'));
    expect(text, isNot(contains(png)));
  });

  test('v1 bridge: non-screenshot results stay plain text', () {
    final res = v1OpToolResult('navigate', {
      'ok': true,
      'result': {'url': 'https://example.com'},
    });
    expect(res.content.whereType<ImageContent>(), isEmpty);
    expect(
      res.content.whereType<TextContent>().single.text,
      contains('example.com'),
    );
  });

  test('v1 bridge: resultless ops report plain ok', () {
    final res = v1OpToolResult('tabs', {'ok': true, 'result': null});
    expect(res.content.whereType<TextContent>().single.text, 'ok');
  });

  test('message_done maps assistant toolCalls so the UI can tell the '
      'story', () {
    final map = messageToJs(
      _assistant(const [
        ToolCall(id: 'c1', name: 'tabs_open', arguments: {'url': 'u'}),
      ]),
    );
    expect(map['role'], 'assistant');
    expect(map['text'], '');
    expect(map['toolCalls'], ['tabs_open']);
  });
}
