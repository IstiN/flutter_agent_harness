/// Tests for the MCP tool wrapper: `mcp__<server>__<tool>` namespacing,
/// description prefix, schema passthrough, exec approval tier, call
/// routing, content-block conversion, error surfacing, and the 100k text
/// budget.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('mcpToolName', () {
    test('namespaces server and tool', () {
      expect(
        mcpToolName('github', 'create_issue'),
        'mcp__github__create_issue',
      );
    });

    test('sanitizes provider-hostile characters', () {
      expect(
        mcpToolName('my server!', 'do.thing/x'),
        'mcp__my_server___do_thing_x',
      );
    });

    test('clamps to 64 characters', () {
      final name = mcpToolName('s' * 40, 't' * 40);
      expect(name.length, 64);
      expect(name, startsWith('mcp__'));
    });
  });

  group('mcpAgentTool', () {
    test('description is prefixed and the schema passes through verbatim', () {
      const schema = {
        'type': 'object',
        'properties': {
          'q': {'type': 'string'},
        },
        'required': ['q'],
      };
      final tool = mcpAgentTool(
        server: 'github',
        tool: const McpToolInfo(
          name: 'search',
          description: 'Searches issues.',
          inputSchema: schema,
        ),
        caller: (_, _, _) async => const {},
      );
      expect(tool.name, 'mcp__github__search');
      expect(
        tool.description,
        "MCP tool from server 'github'. Searches issues.",
      );
      expect(tool.parameters, same(schema));
      expect(tool.tier, ApprovalTier.exec);
    });

    test('routes calls with the server-local tool name', () async {
      final calls = <(String, String, Map<String, dynamic>)>[];
      final tool = mcpAgentTool(
        server: 'srv',
        tool: const McpToolInfo(name: 'ping'),
        caller: (server, name, args) async {
          calls.add((server, name, args));
          return {
            'content': [
              {'type': 'text', 'text': 'pong'},
            ],
          };
        },
      );
      final result = await tool.execute({'x': 1}, null, null);
      expect(calls, hasLength(1));
      expect(calls.single.$1, 'srv');
      expect(calls.single.$2, 'ping');
      expect(calls.single.$3, {'x': 1});
      expect((result.content.single as TextContent).text, 'pong');
    });
  });

  group('mcpResultToToolResult', () {
    test('text blocks pass through as-is', () {
      final result = mcpResultToToolResult({
        'content': [
          {'type': 'text', 'text': 'hello'},
          {'type': 'text', 'text': 'world'},
        ],
      });
      expect(result.content.whereType<TextContent>().map((b) => b.text), [
        'hello',
        'world',
      ]);
    });

    test('image blocks become ImageContent', () {
      final result = mcpResultToToolResult({
        'content': [
          {'type': 'image', 'data': 'aGk=', 'mimeType': 'image/png'},
        ],
      });
      final image = result.content.single as ImageContent;
      expect(image.data, 'aGk=');
      expect(image.mimeType, 'image/png');
    });

    test('embedded text resources render their text', () {
      final result = mcpResultToToolResult({
        'content': [
          {
            'type': 'resource',
            'resource': {'uri': 'file:///a.txt', 'text': 'contents'},
          },
        ],
      });
      final text = (result.content.single as TextContent).text;
      expect(text, contains('[Resource: file:///a.txt]'));
      expect(text, contains('contents'));
    });

    test('binary resources and links become readable placeholders', () {
      final result = mcpResultToToolResult({
        'content': [
          {
            'type': 'resource',
            'resource': {
              'uri': 'file:///a.bin',
              'mimeType': 'application/pdf',
              'blob': 'QUJD',
            },
          },
          {
            'type': 'resource_link',
            'uri': 'https://x/doc',
            'name': 'Doc',
            'description': 'The docs',
          },
          {'type': 'audio', 'mimeType': 'audio/wav'},
          {'type': 'mystery'},
        ],
      });
      final texts = result.content.whereType<TextContent>().toList();
      expect(texts[0].text, contains('application/pdf'));
      expect(texts[0].text, contains('binary content not shown'));
      expect(texts[1].text, contains('[Resource link: Doc]'));
      expect(texts[1].text, contains('The docs'));
      expect(texts[2].text, contains('[Audio content omitted (audio/wav)]'));
      expect(
        texts[3].text,
        contains('[Unsupported MCP content block: mystery]'),
      );
    });

    test('isError throws so the loop records an error result', () {
      expect(
        () => mcpResultToToolResult({
          'isError': true,
          'content': [
            {'type': 'text', 'text': 'disk on fire'},
          ],
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('disk on fire'),
          ),
        ),
      );
    });

    test('empty content falls back to structuredContent, then a note', () {
      final structured = mcpResultToToolResult({
        'content': const [],
        'structuredContent': {'answer': 42},
      });
      expect(
        (structured.content.single as TextContent).text,
        jsonEncode({'answer': 42}),
      );
      final empty = mcpResultToToolResult(const {});
      expect(
        (empty.content.single as TextContent).text,
        contains('no content'),
      );
    });

    test('text beyond the shared budget is truncated with a note', () {
      final big = 'x' * (mcpResultTextBudget + 500);
      final result = mcpResultToToolResult({
        'content': [
          {'type': 'text', 'text': big},
          {'type': 'text', 'text': 'dropped'},
        ],
      });
      final texts = result.content.whereType<TextContent>().toList();
      expect(texts.first.text.length, mcpResultTextBudget);
      expect(texts.any((b) => b.text.contains('truncated')), isTrue);
      expect(texts.any((b) => b.text == 'dropped'), isFalse);
    });

    test('images do not consume the text budget', () {
      final result = mcpResultToToolResult({
        'content': [
          {'type': 'image', 'data': 'AAAA', 'mimeType': 'image/png'},
          {'type': 'text', 'text': 'short'},
        ],
      });
      expect(result.content.whereType<ImageContent>(), hasLength(1));
      expect(result.content.whereType<TextContent>().single.text, 'short');
    });
  });
}
