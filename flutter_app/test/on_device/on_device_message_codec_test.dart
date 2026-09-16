// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.
import 'dart:convert';

/// Table tests for the shared on-device message walk: ONE fixture set of
/// harness contexts drives ALL THREE provider codecs (gemma,
/// transformers.js, WebLLM) — each fixture asserts the exact records the
/// provider's engine receives. The fixtures ARE the shared conversion
/// table: a new provider codec joins by adding a column, not by
/// re-deriving the conversions.
import 'package:fa/gemma/gemma_stream_function.dart';
import 'package:fa/prompts.g.dart';
import 'package:fa/transformers_js/transformers_js_stream_function.dart';
import 'package:fa/webllm/webllm_stream_function.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// The `bash` tool every content fixture registers (keeps the no-tools
/// system note out of content-shape assertions).
const _bashTool = Tool(
  name: 'bash',
  description: 'Runs a shell command',
  parameters: {
    'type': 'object',
    'properties': {
      'cmd': {'type': 'string'},
    },
  },
);

Context _context({
  String? systemPrompt,
  List<Tool> tools = const [_bashTool],
  required List<Message> messages,
}) => Context(systemPrompt: systemPrompt, tools: tools, messages: messages);

/// The shared fixture set: named harness contexts exercising every walk
/// branch (system policies, image degradation, tool-call history, tool
/// results).
final _fixtures = <String, Context>{
  'system prompt, no tools': _context(
    systemPrompt: 'You are Fa.',
    tools: const [],
    messages: [UserMessage.text('hi')],
  ),
  'multi-part user text and image': _context(
    messages: [
      UserMessage(
        content: [
          const TextContent(text: 'look at this'),
          const ImageContent(data: 'AAAA', mimeType: 'image/png'),
        ],
        timestamp: DateTime.now(),
      ),
    ],
  ),
  'empty user strings are dropped': _context(
    tools: const [],
    messages: [UserMessage.text('   ')],
  ),
  'assistant text plus historical tool calls': _context(
    messages: [
      AssistantMessage(
        content: const [
          TextContent(text: 'running it'),
          ToolCall(id: 'c1', name: 'bash', arguments: {'cmd': 'ls'}),
        ],
        api: 'x',
        provider: 'x',
        model: 'm',
        usage: Usage.zero,
        stopReason: StopReason.toolUse,
        timestamp: DateTime.now(),
      ),
    ],
  ),
  'tool result ok': _context(
    messages: [
      ToolResultMessage(
        toolCallId: 'c1',
        toolName: 'bash',
        content: const [TextContent(text: 'file.txt')],
        isError: false,
        timestamp: DateTime.now(),
      ),
    ],
  ),
  'tool result error': _context(
    messages: [
      ToolResultMessage(
        toolCallId: 'c1',
        toolName: 'bash',
        content: const [TextContent(text: 'boom')],
        isError: true,
        timestamp: DateTime.now(),
      ),
    ],
  ),
  'empty tool result': _context(
    messages: [
      ToolResultMessage(
        toolCallId: 'c1',
        toolName: 'bash',
        content: const [],
        isError: false,
        timestamp: DateTime.now(),
      ),
    ],
  ),
};

/// The transformers.js SVG fixture: undecodable on-device MIME degrades;
/// decodable PNG passes as a data: URI.
final _svgFixture = _context(
  messages: [
    UserMessage(
      content: [
        const TextContent(text: 'see'),
        const ImageContent(data: 'PHN2Zz4=', mimeType: 'image/svg+xml'),
        const ImageContent(data: 'AAAA', mimeType: 'image/png'),
      ],
      timestamp: DateTime.now(),
    ),
  ],
);

void main() {
  group('shared on-device codec walk: gemma adapter', () {
    test('system prompt stays out (travels via systemInstruction)', () {
      final messages = convertGemmaMessages(
        _fixtures['system prompt, no tools']!,
      );
      expect(messages, [(role: 'user', content: 'hi', toolName: null)]);
    });

    test('images degrade to the text-only omission note', () {
      final messages = convertGemmaMessages(
        _fixtures['multi-part user text and image']!,
      );
      expect(messages, [
        (
          role: 'user',
          content:
              'look at this\n'
              '(attached image omitted: the Gemma provider is text-only '
              'in this build)',
          toolName: null,
        ),
      ]);
    });

    test('empty user strings are dropped', () {
      // Gemma keeps the system prompt out entirely, so nothing survives.
      expect(
        convertGemmaMessages(_fixtures['empty user strings are dropped']!),
        isEmpty,
      );
    });

    test('historical tool calls become the OpenAI-style tool_call message', () {
      final messages = convertGemmaMessages(
        _fixtures['assistant text plus historical tool calls']!,
      );
      expect(messages, hasLength(2));
      expect(messages[0], (
        role: 'assistant',
        content: 'running it',
        toolName: null,
      ));
      expect(messages[1].role, 'tool_call');
      expect(messages[1].toolName, isNull);
      expect(messages[1].content, _jsonToolCalls('bash', 'ls'));
    });

    test('tool results carry the tool name; empty collapses', () {
      expect(convertGemmaMessages(_fixtures['tool result ok']!), [
        (role: 'tool_result', content: 'file.txt', toolName: 'bash'),
      ]);
      expect(convertGemmaMessages(_fixtures['empty tool result']!), [
        (role: 'tool_result', content: '(no output)', toolName: 'bash'),
      ]);
    });
  });

  group('shared on-device codec walk: transformers.js adapter', () {
    test('no tools appends the no-tools note to the system message', () {
      final system = convertTransformersJsMessages(
        _fixtures['system prompt, no tools']!,
        supportsVision: false,
      ).first;
      expect(system.role, 'system');
      expect(system.content, 'You are Fa.\n\n$transformersJsNoToolsNote');
    });

    test('blank system prompt with no tools becomes the note itself', () {
      final system = convertTransformersJsMessages(
        _context(tools: const [], messages: [UserMessage.text('hi')]),
        supportsVision: false,
      ).first;
      expect(system.content, transformersJsNoToolsNote);
    });

    test(
      'vision presets pass decodable images as data URIs, degrade the rest',
      () {
        final messages = convertTransformersJsMessages(
          _svgFixture,
          supportsVision: true,
        );
        expect(messages, hasLength(1));
        expect(messages.single.role, 'user');
        expect(
          messages.single.content,
          'see\n(attached image omitted: format not decodable on-device)',
        );
        expect(messages.single.images, ['data:image/png;base64,AAAA']);
      },
    );

    test('text-only presets omit every image', () {
      final messages = convertTransformersJsMessages(
        _svgFixture,
        supportsVision: false,
      );
      expect(
        messages.single.content,
        'see\n(attached image omitted: this model is text-only)',
      );
      expect(messages.single.images, isEmpty);
    });

    test('historical tool calls inline as [tool call: ...] lines', () {
      final messages = convertTransformersJsMessages(
        _fixtures['assistant text plus historical tool calls']!,
        supportsVision: false,
      );
      expect(messages, hasLength(1));
      expect(
        messages.single.content,
        'running it\n[tool call: bash({"cmd":"ls"})]',
      );
    });

    test('tool results become user messages with the header', () {
      expect(
        convertTransformersJsMessages(
          _fixtures['tool result ok']!,
          supportsVision: false,
        ).single.content,
        '[tool result · bash]\nfile.txt',
      );
      expect(
        convertTransformersJsMessages(
          _fixtures['tool result error']!,
          supportsVision: false,
        ).single.content,
        '[tool result · bash · error]\nboom',
      );
      expect(
        convertTransformersJsMessages(
          _fixtures['empty tool result']!,
          supportsVision: false,
        ).single.content,
        '[tool result · bash]\n(no output)',
      );
    });
  });

  group('shared on-device codec walk: WebLLM adapter', () {
    test('no tools appends the no-tools note; blank becomes the note', () {
      final system = convertWebLlmMessages(
        _fixtures['system prompt, no tools']!,
      ).first;
      expect(system.role, 'system');
      expect(system.content, 'You are Fa.\n\n$webLlmNoToolsNote');
      expect(
        convertWebLlmMessages(
          _context(tools: const [], messages: [UserMessage.text('hi')]),
        ).first.content,
        webLlmNoToolsNote,
      );
    });

    test('images degrade to the text-only note', () {
      final messages = convertWebLlmMessages(
        _fixtures['multi-part user text and image']!,
      );
      expect(
        messages.single.content,
        'look at this\n'
        '(attached image omitted: on-device models are text-only)',
      );
    });

    test('historical tool calls inline; tool results header', () {
      final messages = convertWebLlmMessages(
        _fixtures['assistant text plus historical tool calls']!,
      );
      expect(
        messages.single.content,
        'running it\n[tool call: bash({"cmd":"ls"})]',
      );
      expect(
        convertWebLlmMessages(_fixtures['tool result ok']!).single.content,
        '[tool result · bash]\nfile.txt',
      );
    });

    test('the walk drops empty user text', () {
      // Only the no-tools system note survives; the blank user message
      // produces nothing.
      final messages = convertWebLlmMessages(
        _fixtures['empty user strings are dropped']!,
      );
      expect(messages, hasLength(1));
      expect(messages.single.role, 'system');
    });
  });
}

/// The gemma tool_call envelope's exact JSON (arguments double-encoded).
String _jsonToolCalls(String name, String args) => jsonEncode({
  'role': 'assistant',
  'tool_calls': [
    {
      'type': 'function',
      'function': {
        'name': name,
        'arguments': jsonEncode({'cmd': args}),
      },
    },
  ],
});
