import 'package:flutter_agent_harness/src/cli/tui_replay.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

void main() {
  String dim(String text) => '<d>$text</d>';

  AssistantMessage assistant(List<ContentBlock> content) => AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );

  group('replayLinesTui', () {
    test('a plain-text user message renders as the background echo box', () {
      final lines = replayLinesTui(
        UserMessage.text('hello\nworld'),
        width: 10,
        dim: dim,
      );
      expect(lines, [
        '<d>──────────</d>',
        '\x1b[48;2;30;34;42mhello\x1b[0m',
        '\x1b[48;2;30;34;42mworld\x1b[0m',
        '',
      ]);
    });

    test('a block-content user message joins its text blocks', () {
      final lines = replayLinesTui(
        UserMessage(
          content: const [
            TextContent(text: 'a'),
            TextContent(text: 'b'),
          ],
          timestamp: DateTime.utc(2026),
        ),
        width: 4,
        dim: dim,
      );
      expect(lines[1], '\x1b[48;2;30;34;42ma\x1b[0m');
      expect(lines[2], '\x1b[48;2;30;34;42mb\x1b[0m');
    });

    test('an empty user message renders nothing', () {
      expect(
        replayLinesTui(UserMessage.text('   '), width: 10, dim: dim),
        isEmpty,
      );
    });

    test('assistant text plus tool calls ends with a dim indicator row', () {
      final lines = replayLinesTui(
        assistant(const [
          TextContent(text: 'answer'),
          ToolCall(id: '1', name: 'read', arguments: {}),
          ToolCall(id: '2', name: 'bash', arguments: {}),
        ]),
        width: 10,
        dim: dim,
      );
      expect(lines, ['answer', '<d>[read] [bash]</d>']);
    });

    test('assistant text is capped at 20 rows with an ellipsis', () {
      final text = [for (var i = 1; i <= 25; i++) 'row $i'].join('\n');
      final lines = replayLinesTui(
        assistant([TextContent(text: text)]),
        width: 10,
        dim: dim,
      );
      expect(lines, hasLength(20));
      expect(lines.last, 'row 20 …');
    });

    test('an assistant message without text renders nothing', () {
      expect(
        replayLinesTui(
          assistant(const [ToolCall(id: '1', name: 'read', arguments: {})]),
          width: 10,
          dim: dim,
        ),
        isEmpty,
      );
    });

    test('tool results never render', () {
      expect(
        replayLinesTui(
          ToolResultMessage(
            toolCallId: '1',
            toolName: 'read',
            content: const [],
            isError: false,
            timestamp: DateTime.utc(2026),
          ),
          width: 10,
          dim: dim,
        ),
        isEmpty,
      );
    });
  });
}
