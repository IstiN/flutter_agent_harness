import 'dart:async';

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

const _readTool = Tool(
  name: 'read',
  description: 'Read a file from disk.',
  parameters: {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'File path.'},
    },
    'required': ['path'],
  },
);

const _writeTool = Tool(
  name: 'write',
  description: 'Write a file to disk.',
  parameters: {
    'type': 'object',
    'properties': {
      'path': {'type': 'string'},
      'content': {'type': 'string'},
    },
    'required': ['path', 'content'],
  },
);

AssistantMessage _snapshot(
  String text, {
  StopReason stopReason = StopReason.stop,
  Usage? usage,
}) {
  return AssistantMessage(
    content: text.isEmpty ? const [] : [TextContent(text: text)],
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: usage ?? Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

/// Scripted chat-model inner stream: replays [chunks] as text deltas with
/// partial-first snapshots, records the context it was called with.
class _FakeChatStream {
  _FakeChatStream(
    this.chunks, {
    this.reason = StopReason.stop,
    this.usage,
    this.errorReason,
    this.errorMessage,
    this.retryAfter,
  });

  final List<String> chunks;
  final StopReason reason;
  final Usage? usage;

  /// When set, the stream terminates with an [ErrorEvent] instead.
  final StopReason? errorReason;
  final String? errorMessage;
  final Duration? retryAfter;

  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final stream = AssistantMessageEventStream();
    var accumulated = '';
    stream.push(StartEvent(partial: _snapshot('', usage: usage)));
    if (chunks.isNotEmpty) {
      stream.push(
        TextStartEvent(contentIndex: 0, partial: _snapshot('', usage: usage)),
      );
      for (final chunk in chunks) {
        accumulated += chunk;
        stream.push(
          TextDeltaEvent(
            contentIndex: 0,
            delta: chunk,
            partial: _snapshot(accumulated, usage: usage),
          ),
        );
      }
      stream.push(
        TextEndEvent(
          contentIndex: 0,
          content: accumulated,
          partial: _snapshot(accumulated, usage: usage),
        ),
      );
    }
    if (errorReason != null) {
      final error = _snapshot(
        accumulated,
        stopReason: errorReason!,
        usage: usage,
      ).copyWith(errorMessage: errorMessage);
      stream.push(
        ErrorEvent(reason: errorReason!, error: error, retryAfter: retryAfter),
      );
    } else {
      stream.push(
        DoneEvent(
          reason: reason,
          message: _snapshot(accumulated, stopReason: reason, usage: usage),
        ),
      );
    }
    stream.end();
    return stream;
  }
}

Context _context({
  String? systemPrompt,
  List<Message>? messages,
  List<Tool>? tools,
}) {
  return Context(
    systemPrompt: systemPrompt,
    messages: messages ?? [UserMessage.text('hi')],
    tools: tools,
  );
}

/// Collects all events of a wrapped run plus its final message.
Future<({List<AssistantMessageEvent> events, AssistantMessage message})> _run(
  StreamFunction wrapped,
  Context context,
) async {
  final stream = wrapped(_model, context);
  final events = await stream.toList();
  return (events: events, message: await stream.result);
}

String _allText(AssistantMessage message) {
  return message.content.whereType<TextContent>().map((b) => b.text).join();
}

List<ToolCall> _toolCalls(AssistantMessage message) {
  return message.content.whereType<ToolCall>().toList();
}

void main() {
  group('injection', () {
    test('appends tools section to an existing system prompt', () async {
      final inner = _FakeChatStream(const ['ok']);
      final wrapped = promptToolStreamFunction(inner.call);
      await _run(
        wrapped,
        _context(
          systemPrompt: 'You are helpful.',
          tools: const [_readTool, _writeTool],
        ),
      );

      final prompt = inner.contexts.single.systemPrompt!;
      expect(prompt, startsWith('You are helpful.\n\n'));
      expect(prompt, contains('## Available tools'));
      expect(prompt, contains('1. read: Read a file from disk.'));
      expect(prompt, contains('2. write: Write a file to disk.'));
      expect(
        prompt,
        contains(
          'Parameters: {"type":"object","properties":{"path":'
          '{"type":"string","description":"File path."}},"required":["path"]}',
        ),
      );
      // The call format and the rules.
      expect(prompt, contains('```tool_call'));
      expect(prompt, contains('{"name": "example_tool"'));
      expect(prompt, contains('STOP immediately'));
      expect(prompt, contains('```tool_result'));
      expect(prompt, contains('error: true'));
    });

    test('uses the section alone when no system prompt exists', () async {
      final inner = _FakeChatStream(const ['ok']);
      final wrapped = promptToolStreamFunction(inner.call);
      await _run(wrapped, _context(tools: const [_readTool]));

      final prompt = inner.contexts.single.systemPrompt!;
      expect(prompt, startsWith('## Available tools'));
      expect(prompt, contains('1. read: Read a file from disk.'));
    });

    test(
      'empty tools: byte-identical passthrough of context and events',
      () async {
        final inner = _FakeChatStream(const ['hello', ' world']);
        final wrapped = promptToolStreamFunction(inner.call);
        final context = _context(systemPrompt: 'Keep me.');
        final (:events, :message) = await _run(wrapped, context);

        // Context forwarded untouched.
        final forwarded = inner.contexts.single;
        expect(forwarded.systemPrompt, 'Keep me.');
        expect(forwarded.messages, same(context.messages));
        expect(forwarded.tools, isNull);

        // Events forwarded untouched.
        expect(events.map((e) => e.runtimeType).toList(), [
          StartEvent,
          TextStartEvent,
          TextDeltaEvent,
          TextDeltaEvent,
          TextEndEvent,
          DoneEvent,
        ]);
        expect(
          events.whereType<TextDeltaEvent>().map((e) => e.delta).toList(),
          ['hello', ' world'],
        );
        expect(message.content, [
          isA<TextContent>().having((b) => b.text, 'text', 'hello world'),
        ]);
        expect(message.stopReason, StopReason.stop);
      },
    );

    test('empty tools + injectWhenNoTools injects and parses', () async {
      final inner = _FakeChatStream(const [
        '```tool_call\n{"name": "read"}\n```\n',
      ]);
      final wrapped = promptToolStreamFunction(
        inner.call,
        options: const PromptToolOptions(injectWhenNoTools: true),
      );
      final (:events, :message) = await _run(wrapped, _context());

      expect(
        inner.contexts.single.systemPrompt,
        contains('## Available tools'),
      );
      expect(_toolCalls(message), hasLength(1));
      expect(message.stopReason, StopReason.toolUse);
      expect(events.whereType<ToolCallEndEvent>(), hasLength(1));
    });

    test(
      'promptToolInstructions returns exactly the appended section',
      () async {
        // Hosts sizing a context window count the wrapper's bytes through
        // promptToolInstructions; it must be byte-identical to what the
        // wrapper appends to the system prompt.
        const tools = [_readTool, _writeTool];
        final inner = _FakeChatStream(const ['ok']);
        final wrapped = promptToolStreamFunction(inner.call);
        await _run(wrapped, _context(systemPrompt: 'Base.', tools: tools));

        final section = promptToolInstructions(tools);
        expect(inner.contexts.single.systemPrompt, 'Base.\n\n$section');
        expect(section, startsWith('## Available tools'));
        expect(section, contains('1. read: Read a file from disk.'));
        expect(section, contains('2. write: Write a file to disk.'));
      },
    );
  });

  group('parsing', () {
    test('single tool call with surrounding text', () async {
      final inner = _FakeChatStream(const [
        'Let me read it.\n',
        '```tool_call\n{"name": "read", "arguments": {"path": "a.txt"}}\n```\n',
        'Waiting.',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(message.stopReason, StopReason.toolUse);
      expect(events.last, isA<DoneEvent>());
      expect((events.last as DoneEvent).reason, StopReason.toolUse);

      final calls = _toolCalls(message);
      expect(calls, hasLength(1));
      expect(calls.single.name, 'read');
      expect(calls.single.arguments, {'path': 'a.txt'});
      expect(calls.single.id, startsWith('read_'));
      expect(calls.single.partialArguments, isNull);

      // Text blocks surround the call, fences stripped. The newline
      // terminating the closing fence line stays text (chunk-independent
      // fence semantics).
      final texts = message.content.whereType<TextContent>().toList();
      expect(texts, hasLength(2));
      expect(texts[0].text, 'Let me read it.\n');
      expect(texts[1].text, '\nWaiting.');
      expect(_allText(message), isNot(contains('tool_call')));

      // The tool-call event triple: start, one full-args delta, end.
      final starts = events.whereType<ToolCallStartEvent>().toList();
      final deltas = events.whereType<ToolCallDeltaEvent>().toList();
      final ends = events.whereType<ToolCallEndEvent>().toList();
      expect(starts, hasLength(1));
      expect(deltas, hasLength(1));
      expect(ends, hasLength(1));
      expect(deltas.single.delta, '{"path":"a.txt"}');
      expect(ends.single.toolCall.arguments, {'path': 'a.txt'});
      expect(
        starts.single.contentIndex,
        1, // text block 0 precedes the call
      );
      expect(deltas.single.contentIndex, 1);
      expect(ends.single.contentIndex, 1);
    });

    test('opener split across two chunks', () async {
      final inner = _FakeChatStream(const [
        'sure ```to',
        'ol_call\n{"name": "read", "arguments": {"path": "b.txt"}}\n```\n',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      final calls = _toolCalls(message);
      expect(calls.single.name, 'read');
      expect(calls.single.arguments, {'path': 'b.txt'});
      expect(_allText(message), 'sure \n');
      // The split opener never leaked into a text delta.
      expect(
        events.whereType<TextDeltaEvent>().map((e) => e.delta).join(),
        'sure \n',
      );
    });

    test('opener split across three chunks', () async {
      final inner = _FakeChatStream(const [
        '`',
        '``tool_ca',
        'll\n{"name": "read"}\n```',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      final calls = _toolCalls(message);
      expect(calls.single.name, 'read');
      expect(calls.single.arguments, isEmpty);
      expect(message.stopReason, StopReason.toolUse);
      expect(_allText(message), isEmpty);
      expect(events.whereType<TextDeltaEvent>(), isEmpty);
    });

    test('closer split across chunks', () async {
      final inner = _FakeChatStream(const [
        '```tool_call\n{"name": "read", "arguments": {"path": "c.txt"}}\n`',
        '``',
        '\ndone',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(_toolCalls(message).single.arguments, {'path': 'c.txt'});
      expect(_allText(message), '\ndone');
    });

    test('multiple calls in one message', () async {
      final inner = _FakeChatStream(const [
        'reading both\n',
        '```tool_call\n{"name": "read", "arguments": {"path": "a.txt"}}\n```\n',
        'and\n',
        '```tool_call\n{"name": "read", "arguments": {"path": "b.txt"}}\n```\n',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      final calls = _toolCalls(message);
      expect(calls, hasLength(2));
      expect(calls[0].arguments, {'path': 'a.txt'});
      expect(calls[1].arguments, {'path': 'b.txt'});
      expect(calls[0].id, isNot(calls[1].id));
      expect(message.stopReason, StopReason.toolUse);
      expect(events.whereType<ToolCallEndEvent>(), hasLength(2));
      // Newlines after the closing fences remain text.
      expect(_allText(message), 'reading both\n\nand\n\n');
    });

    test('backticks not at line start do not close the block', () async {
      final inner = _FakeChatStream(const [
        '```tool_call\n{"name": "write", "arguments": {"content": "a```b"}}\n```\n',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_writeTool]),
      );

      expect(_toolCalls(message).single.arguments, {'content': 'a```b'});
    });

    test('false-positive fences in prose and code pass through', () async {
      const prose =
          'Use ```tool_calls or ```tool_call2, not the fence. Code:\n'
          '```dart\nvoid main() {}\n```\n'
          'Also inline `code` and a lone ``` fence.\n'
          'A mention without newline: ```tool_call done.';
      final inner = _FakeChatStream(const [prose]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(_toolCalls(message), isEmpty);
      expect(message.stopReason, StopReason.stop);
      expect(_allText(message), prose);
      expect(events.whereType<ToolCallStartEvent>(), isEmpty);
    });

    test('unclosed block at stream end is flushed as text', () async {
      final inner = _FakeChatStream(const [
        'note\n',
        '```tool_call\n{"name": "read", "arguments": {"path": "a.txt"}}',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(_toolCalls(message), isEmpty);
      expect(message.stopReason, StopReason.stop);
      expect(
        _allText(message),
        'note\n```tool_call\n{"name": "read", "arguments": {"path": "a.txt"}}',
      );
    });

    test('unterminated opener at stream end is flushed as text', () async {
      final inner = _FakeChatStream(const ['trailing ```tool_call']);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(_toolCalls(message), isEmpty);
      expect(_allText(message), 'trailing ```tool_call');
    });

    test('invalid JSON recovery: trailing commas', () async {
      final inner = _FakeChatStream(const [
        '```tool_call\n{"name": "read", "arguments": {"path": "a.txt",},}\n```\n',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(_toolCalls(message).single.arguments, {'path': 'a.txt'});
    });

    test('invalid JSON recovery: single quotes', () async {
      final inner = _FakeChatStream(const [
        "```tool_call\n{'name': 'read', 'arguments': {'path': 'a.txt'}}\n```\n",
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(_toolCalls(message).single.arguments, {'path': 'a.txt'});
    });

    test('unrecoverable JSON falls back to text', () async {
      final inner = _FakeChatStream(const [
        'before\n',
        '```tool_call\nthis is not json\n```\n',
        'after',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(_toolCalls(message), isEmpty);
      expect(message.stopReason, StopReason.stop);
      expect(
        _allText(message),
        'before\n```tool_call\nthis is not json\n```\nafter',
      );
    });

    test('missing name falls back to text', () async {
      final inner = _FakeChatStream(const [
        '```tool_call\n{"arguments": {"path": "a.txt"}}\n```\n',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(_toolCalls(message), isEmpty);
      expect(_allText(message), contains('"arguments"'));
    });

    test('non-map arguments fall back to text', () async {
      final inner = _FakeChatStream(const [
        '```tool_call\n{"name": "read", "arguments": "a.txt"}\n```\n',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(_toolCalls(message), isEmpty);
      expect(_allText(message), contains('"a.txt"'));
    });

    test('block overflow emits the buffer as plain text', () async {
      final inner = _FakeChatStream(const [
        '```tool_call\n{"name": "read", "arguments": {"path": "averylongpath.txt"}}',
      ]);
      final wrapped = promptToolStreamFunction(
        inner.call,
        options: const PromptToolOptions(maxBlockSize: 16),
      );
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(_toolCalls(message), isEmpty);
      expect(message.stopReason, StopReason.stop);
      expect(
        _allText(message),
        '```tool_call\n{"name": "read", "arguments": {"path": "averylongpath.txt"}}',
      );
    });

    test('partial-first: snapshots accumulate text and partial args', () async {
      final inner = _FakeChatStream(const [
        'ab',
        'cd\n```tool_call\n{"name": "read", "arguments": {"path": "x"}}\n```\n',
        'ef',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final stream = wrapped(_model, _context(tools: const [_readTool]));
      final events = await stream.toList();

      // Text deltas carry growing full snapshots.
      final deltas = events.whereType<TextDeltaEvent>().toList();
      expect(deltas.first.partial.content, hasLength(1));
      final firstText = deltas.first.partial.content.first as TextContent;
      expect(firstText.text, isNotEmpty);
      expect(deltas.first.delta, isNotEmpty);

      // At ToolCallStart the partial carries a ToolCall with empty parsed
      // args and the full raw partialArguments buffer (google.dart writes
      // the args before the start event too); at ToolCallEnd args are
      // parsed.
      final start = events.whereType<ToolCallStartEvent>().single;
      final startCall = start.partial.content[1] as ToolCall;
      expect(startCall.name, 'read');
      expect(startCall.arguments, isEmpty);
      expect(startCall.partialArguments, '{"path":"x"}');

      final delta = events.whereType<ToolCallDeltaEvent>().single;
      final deltaCall = delta.partial.content[1] as ToolCall;
      expect(deltaCall.partialArguments, '{"path":"x"}');

      final end = events.whereType<ToolCallEndEvent>().single;
      expect(end.toolCall.arguments, {'path': 'x'});
      expect(end.toolCall.partialArguments, isNull);

      // Every event carries a consistent partial.
      for (final event in events) {
        expect(event.partial, isA<AssistantMessage>());
      }
    });

    test('CRLF opener is accepted', () async {
      final inner = _FakeChatStream(const [
        '```tool_call\r\n{"name": "read"}\r\n```\r\n',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(_toolCalls(message).single.name, 'read');
    });

    test('inner thinking blocks are mirrored with correct indices', () async {
      // Custom inner: thinking + text + a parsed call.
      AssistantMessageEventStream inner(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        final stream = AssistantMessageEventStream();
        AssistantMessage snap(List<ContentBlock> content) => AssistantMessage(
          content: content,
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        );
        const thinking = ThinkingContent(thinking: 'hmm');
        stream.push(StartEvent(partial: snap(const [])));
        stream.push(
          ThinkingStartEvent(contentIndex: 0, partial: snap(const [thinking])),
        );
        stream.push(
          ThinkingDeltaEvent(
            contentIndex: 0,
            delta: 'hmm',
            partial: snap(const [thinking]),
          ),
        );
        stream.push(
          ThinkingEndEvent(
            contentIndex: 0,
            content: 'hmm',
            partial: snap(const [thinking]),
          ),
        );
        stream.push(
          TextStartEvent(contentIndex: 1, partial: snap(const [thinking])),
        );
        stream.push(
          TextDeltaEvent(
            contentIndex: 1,
            delta: '```tool_call\n{"name": "read"}\n```\n',
            partial: snap(const [thinking, TextContent(text: 'x')]),
          ),
        );
        stream.push(
          DoneEvent(reason: StopReason.stop, message: snap(const [thinking])),
        );
        stream.end();
        return stream;
      }

      final wrapped = promptToolStreamFunction(inner);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(events.whereType<ThinkingStartEvent>(), hasLength(1));
      expect(events.whereType<ThinkingDeltaEvent>(), hasLength(1));
      expect(events.whereType<ThinkingEndEvent>(), hasLength(1));
      expect(events.whereType<ThinkingEndEvent>().single.content, 'hmm');
      final thinking = message.content.first as ThinkingContent;
      expect(thinking.thinking, 'hmm');
      expect(_toolCalls(message).single.name, 'read');
      expect(message.stopReason, StopReason.toolUse);
    });

    test('native tool calls from the inner stream pass through', () async {
      AssistantMessageEventStream inner(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        final stream = AssistantMessageEventStream();
        const call = ToolCall(
          id: 'native_1',
          name: 'read',
          arguments: {'path': 'n.txt'},
        );
        AssistantMessage snap(List<ContentBlock> content, StopReason reason) =>
            AssistantMessage(
              content: content,
              api: 'test-api',
              provider: 'test-provider',
              model: 'test-model',
              usage: Usage.zero,
              stopReason: reason,
              timestamp: DateTime.utc(2026),
            );
        stream.push(StartEvent(partial: snap(const [], StopReason.stop)));
        stream.push(
          ToolCallStartEvent(
            contentIndex: 0,
            partial: snap(const [call], StopReason.stop),
          ),
        );
        stream.push(
          ToolCallDeltaEvent(
            contentIndex: 0,
            delta: '{"path":"n.txt"}',
            partial: snap(const [call], StopReason.stop),
          ),
        );
        stream.push(
          ToolCallEndEvent(
            contentIndex: 0,
            toolCall: call,
            partial: snap(const [call], StopReason.toolUse),
          ),
        );
        stream.push(
          DoneEvent(
            reason: StopReason.toolUse,
            message: snap(const [call], StopReason.toolUse),
          ),
        );
        stream.end();
        return stream;
      }

      final wrapped = promptToolStreamFunction(inner);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(events.whereType<ToolCallStartEvent>(), hasLength(1));
      expect(events.whereType<ToolCallEndEvent>(), hasLength(1));
      final call = _toolCalls(message).single;
      expect(call.id, 'native_1');
      expect(call.arguments, {'path': 'n.txt'});
      expect(message.stopReason, StopReason.toolUse);
    });
  });

  group('history re-serialization', () {
    test('tool results become fenced user text with error marker', () async {
      final inner = _FakeChatStream(const ['ok']);
      final wrapped = promptToolStreamFunction(inner.call);
      final result = ToolResultMessage(
        toolCallId: 'read_1',
        toolName: 'read',
        content: const [TextContent(text: 'file not found: a.txt')],
        isError: true,
        timestamp: DateTime.utc(2026),
      );
      await _run(
        wrapped,
        _context(messages: [result], tools: const [_readTool]),
      );

      final forwarded = inner.contexts.single.messages.single;
      expect(forwarded, isA<UserMessage>());
      expect(forwarded.role, 'user');
      expect(forwarded.timestamp, result.timestamp);
      final text = (forwarded as UserMessage).content as String;
      expect(
        text,
        '```tool_result\ntool: read\nerror: true\n\nfile not found: a.txt\n```',
      );
    });

    test('successful tool result has no error marker', () async {
      final inner = _FakeChatStream(const ['ok']);
      final wrapped = promptToolStreamFunction(inner.call);
      final result = ToolResultMessage(
        toolCallId: 'read_1',
        toolName: 'read',
        content: const [TextContent(text: 'contents')],
        isError: false,
        timestamp: DateTime.utc(2026),
      );
      await _run(
        wrapped,
        _context(messages: [result], tools: const [_readTool]),
      );

      final text =
          (inner.contexts.single.messages.single as UserMessage).content
              as String;
      expect(text, isNot(contains('error: true')));
      expect(text, contains('tool: read'));
      expect(text, contains('contents'));
    });

    test('image content in tool results becomes an omission note', () async {
      final inner = _FakeChatStream(const ['ok']);
      final wrapped = promptToolStreamFunction(inner.call);
      final result = ToolResultMessage(
        toolCallId: 'snap_1',
        toolName: 'snap',
        content: const [
          TextContent(text: 'screenshot:'),
          ImageContent(data: 'aGVsbG8=', mimeType: 'image/png'),
        ],
        isError: false,
        timestamp: DateTime.utc(2026),
      );
      await _run(
        wrapped,
        _context(messages: [result], tools: const [_readTool]),
      );

      final text =
          (inner.contexts.single.messages.single as UserMessage).content
              as String;
      expect(text, contains('screenshot:'));
      expect(text, contains('[image omitted: image/png]'));
      expect(text, isNot(contains('aGVsbG8=')));
    });

    test(
      'historical assistant tool calls re-serialize as fenced text',
      () async {
        final inner = _FakeChatStream(const ['ok']);
        final wrapped = promptToolStreamFunction(inner.call);
        final assistant = AssistantMessage(
          content: const [
            TextContent(text: 'Let me read it.'),
            ToolCall(id: 'read_1', name: 'read', arguments: {'path': 'a.txt'}),
            ThinkingContent(thinking: 'scratch'),
          ],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: StopReason.toolUse,
          timestamp: DateTime.utc(2026),
        );
        await _run(
          wrapped,
          _context(messages: [assistant], tools: const [_readTool]),
        );

        final forwarded =
            inner.contexts.single.messages.single as AssistantMessage;
        expect(forwarded.role, 'assistant');
        expect(forwarded.timestamp, assistant.timestamp);
        expect(forwarded.stopReason, StopReason.toolUse);
        expect(forwarded.content, [
          isA<TextContent>().having((b) => b.text, 'text', 'Let me read it.'),
          isA<TextContent>().having(
            (b) => b.text,
            'text',
            '```tool_call\n{"name":"read","arguments":{"path":"a.txt"}}\n```',
          ),
        ]);
      },
    );

    test(
      'assistant messages without tool calls pass through untouched',
      () async {
        final inner = _FakeChatStream(const ['ok']);
        final wrapped = promptToolStreamFunction(inner.call);
        final assistant = AssistantMessage(
          content: const [TextContent(text: 'plain answer')],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        );
        await _run(
          wrapped,
          _context(messages: [assistant], tools: const [_readTool]),
        );

        expect(inner.contexts.single.messages.single, same(assistant));
      },
    );

    test('full round-trip: history feeds back parseable fences', () async {
      // Turn 2: the model sees the re-serialized history and answers with
      // another fenced call; the wrapper parses it again.
      final inner = _FakeChatStream(const [
        '```tool_call\n{"name": "write", "arguments": {"path": "b.txt", "content": "hi"}}\n```\n',
      ]);
      final wrapped = promptToolStreamFunction(inner.call);
      final history = <Message>[
        UserMessage.text('read a.txt then write b.txt'),
        AssistantMessage(
          content: const [
            ToolCall(id: 'read_1', name: 'read', arguments: {'path': 'a.txt'}),
          ],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: StopReason.toolUse,
          timestamp: DateTime.utc(2026),
        ),
        ToolResultMessage(
          toolCallId: 'read_1',
          toolName: 'read',
          content: const [TextContent(text: 'AAA')],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
      ];
      final (:events, :message) = await _run(
        wrapped,
        _context(messages: history, tools: const [_readTool, _writeTool]),
      );

      final forwarded = inner.contexts.single.messages;
      expect(forwarded, hasLength(3));
      expect(
        ((forwarded[1] as AssistantMessage).content.single as TextContent).text,
        '```tool_call\n{"name":"read","arguments":{"path":"a.txt"}}\n```',
      );
      expect(
        (forwarded[2] as UserMessage).content as String,
        '```tool_result\ntool: read\n\nAAA\n```',
      );

      final call = _toolCalls(message).single;
      expect(call.name, 'write');
      expect(call.arguments, {'path': 'b.txt', 'content': 'hi'});
      expect(message.stopReason, StopReason.toolUse);
    });
  });

  group('terminal mapping', () {
    test('no calls: inner stopReason passes through (length)', () async {
      final inner = _FakeChatStream(const [
        'cut off',
      ], reason: StopReason.length);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect((events.last as DoneEvent).reason, StopReason.length);
      expect(message.stopReason, StopReason.length);
    });

    test('usage passes through to the final message', () async {
      const usage = Usage(
        input: 10,
        output: 5,
        cacheRead: 2,
        cacheWrite: 0,
        totalTokens: 17,
        cost: UsageCost(input: 0.1, output: 0.2, total: 0.3),
      );
      final inner = _FakeChatStream(const [
        '```tool_call\n{"name": "read"}\n```\n',
      ], usage: usage);
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      expect(message.usage.input, 10);
      expect(message.usage.output, 5);
      expect(message.usage.totalTokens, 17);
      expect(message.usage.cost.total, 0.3);
    });

    test('error passes through with retryAfter', () async {
      final inner = _FakeChatStream(
        const ['partial'],
        errorReason: StopReason.error,
        errorMessage: 'boom',
        retryAfter: const Duration(seconds: 3),
      );
      final wrapped = promptToolStreamFunction(inner.call);
      final stream = wrapped(_model, _context(tools: const [_readTool]));
      final events = await stream.toList();
      final message = await stream.result;

      final error = events.whereType<ErrorEvent>().single;
      expect(error.reason, StopReason.error);
      expect(error.retryAfter, const Duration(seconds: 3));
      expect(message.stopReason, StopReason.error);
      expect(message.errorMessage, 'boom');
      expect(_allText(message), 'partial');
    });

    test('abort passes through', () async {
      final inner = _FakeChatStream(
        const ['partial ```tool_call\n{"name":'],
        errorReason: StopReason.aborted,
        errorMessage: 'Request was aborted',
      );
      final wrapped = promptToolStreamFunction(inner.call);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      final error = events.whereType<ErrorEvent>().single;
      expect(error.reason, StopReason.aborted);
      expect(message.stopReason, StopReason.aborted);
      // The unclosed block buffer is flushed into the error snapshot.
      expect(_allText(message), 'partial ```tool_call\n{"name":');
    });

    test('a throwing inner stream is converted into an ErrorEvent', () async {
      AssistantMessageEventStream throwing(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        throw StateError('inner exploded');
      }

      final wrapped = promptToolStreamFunction(throwing);
      final (:events, :message) = await _run(
        wrapped,
        _context(tools: const [_readTool]),
      );

      final error = events.whereType<ErrorEvent>().single;
      expect(error.reason, StopReason.error);
      expect(message.errorMessage, contains('inner exploded'));
    });

    test(
      'an inner stream without a terminal event gets a synthetic error',
      () async {
        AssistantMessageEventStream unterminated(
          Model model,
          Context context, {
          CancelToken? cancelToken,
        }) {
          final stream = AssistantMessageEventStream();
          stream.push(StartEvent(partial: _snapshot('')));
          stream.end();
          return stream;
        }

        final wrapped = promptToolStreamFunction(unterminated);
        final (:events, :message) = await _run(
          wrapped,
          _context(tools: const [_readTool]),
        );

        final error = events.whereType<ErrorEvent>().single;
        expect(error.reason, StopReason.error);
        expect(
          message.errorMessage,
          contains('Inner stream ended without a terminal event'),
        );
      },
    );
  });
}
