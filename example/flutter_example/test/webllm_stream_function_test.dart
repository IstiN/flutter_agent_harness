import 'package:flutter_agent_example/prompts.g.dart';
import 'package:flutter_agent_example/webllm/webllm_stream_function.dart';
import 'package:flutter_agent_example/webllm/webllm_types.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [WebLlmEngineApi] driven entirely by test script: canned chunks, an
/// optional stream/load failure, and a "hold the stream open" mode for abort
/// tests. Records everything the stream function hands it.
final class FakeWebLlmEngine implements WebLlmEngineApi {
  /// Chunks delivered through `onChunk`, in order.
  List<String> chunks = [];

  /// Finish reason reported through `onDone` (web-llm reports `stop` or
  /// `length`).
  String finishReason = 'stop';

  /// When set, `chatStream` reports this via `onError` instead of chunks.
  String? streamErrorMessage;

  /// When set, `loadModel` throws this.
  Object? loadError;

  /// When false, `chatStream` never calls `onDone` (stays open until the
  /// returned cancel function is invoked — the abort path).
  bool completeStream = true;

  WebLlmModelPreset? loadedPreset;
  List<WebLlmChatMessage>? lastMessages;
  int? lastMaxTokens;
  var interruptCount = 0;
  var jsStreamCancelled = false;

  @override
  bool get isAvailable => true;

  @override
  String? get loadedModelId => loadedPreset?.id;

  @override
  Stream<WebLlmProgress> get progressEvents => const Stream.empty();

  @override
  Future<void> loadModel(WebLlmModelPreset preset) async {
    final error = loadError;
    if (error != null) throw error;
    loadedPreset = preset;
  }

  @override
  Future<void Function()> chatStream({
    required List<WebLlmChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function(String finishReason)? onDone,
    void Function(String message)? onError,
    int? maxTokens,
  }) async {
    lastMessages = messages;
    lastMaxTokens = maxTokens;
    final streamError = streamErrorMessage;
    if (streamError != null) {
      onError?.call(streamError);
    } else {
      for (final chunk in chunks) {
        onChunk(chunk);
      }
      if (completeStream) onDone?.call(finishReason);
    }
    return () => jsStreamCancelled = true;
  }

  @override
  Future<void> interrupt() async {
    interruptCount++;
  }

  @override
  Future<WebLlmCacheInfo?> modelCacheInfo(String modelId) async => null;

  @override
  Future<void> deleteCachedModel(String modelId) async {}
}

Model _model([String? id]) => Model(
  id: id ?? webLlmModelPresets.first.id,
  api: webLlmProviderKind,
  provider: webLlmProviderKind,
  baseUrl: '',
  contextWindow: 2048,
  maxTokens: 1024,
);

Context _context({
  String? systemPrompt,
  List<Message>? messages,
  List<Tool>? tools,
}) => Context(
  systemPrompt: systemPrompt,
  messages: messages ?? [UserMessage.text('hi')],
  tools: tools,
);

const _bashTool = Tool(
  name: 'bash',
  description: 'Runs a shell command',
  parameters: {
    'type': 'object',
    'properties': {
      'cmd': {'type': 'string'},
    },
    'required': ['cmd'],
  },
);

AssistantMessage _assistant(List<ContentBlock> content) => AssistantMessage(
  content: content,
  api: webLlmProviderKind,
  provider: webLlmProviderKind,
  model: webLlmModelPresets.first.id,
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.now(),
);

String _partialText(AssistantMessage message) =>
    message.content.whereType<TextContent>().map((block) => block.text).join();

void main() {
  group('streamWebLlm event mapping', () {
    test(
      'streams chunks partial-first and ends with DoneEvent(stop)',
      () async {
        final engine = FakeWebLlmEngine()..chunks = ['Hello', ', world', '!'];
        final events = await streamWebLlm(
          engine,
          _model(),
          _context(tools: [_bashTool]),
        ).toList();

        expect(events.first, isA<StartEvent>());
        expect(events[1], isA<TextStartEvent>());

        final deltas = events.whereType<TextDeltaEvent>().toList();
        expect(deltas.map((e) => e.delta), ['Hello', ', world', '!']);
        // Partial-first: every delta carries the FULL text so far.
        expect(deltas.map((e) => _partialText(e.partial)), [
          'Hello',
          'Hello, world',
          'Hello, world!',
        ]);

        final textEnd = events.whereType<TextEndEvent>().single;
        expect(textEnd.content, 'Hello, world!');

        final done = events.whereType<DoneEvent>().single;
        expect(done.reason, StopReason.stop);
        expect(_partialText(done.message), 'Hello, world!');
        expect(done.message.stopReason, StopReason.stop);
        // WebLLM reports no token counts: usage stays zero (documented).
        expect(done.message.usage, same(Usage.zero));
        expect(events.last, same(done));
      },
    );

    test(
      'forwards converted messages and the maxTokens cap to the engine',
      () async {
        final engine = FakeWebLlmEngine()..chunks = ['ok'];
        await streamWebLlm(
          engine,
          _model(),
          _context(systemPrompt: 'You are fah.', tools: [_bashTool]),
        ).toList();

        expect(engine.loadedPreset?.id, webLlmModelPresets.first.id);
        expect(engine.lastMessages, [
          (role: 'system', content: 'You are fah.'),
          (role: 'user', content: 'hi'),
        ]);
        expect(engine.lastMaxTokens, 1024);
      },
    );

    test('a length finish reason maps to StopReason.length', () async {
      final engine = FakeWebLlmEngine()
        ..chunks = ['cut off']
        ..finishReason = 'length';
      final events = await streamWebLlm(engine, _model(), _context()).toList();

      final done = events.whereType<DoneEvent>().single;
      expect(done.reason, StopReason.length);
      expect(done.message.stopReason, StopReason.length);
      expect(_partialText(done.message), 'cut off');
    });

    test('unknown preset id ends in an ErrorEvent, never a throw', () async {
      final engine = FakeWebLlmEngine();
      final events = await streamWebLlm(
        engine,
        _model('not-a-preset'),
        _context(),
      ).toList();

      final error = events.whereType<ErrorEvent>().single;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('Unknown WebLLM model preset'));
      expect(engine.loadedPreset, isNull);
    });

    test(
      'load failure ends in an ErrorEvent with the engine message',
      () async {
        final engine = FakeWebLlmEngine()
          ..loadError = StateError('This browser has no WebGPU support');
        final events = await streamWebLlm(
          engine,
          _model(),
          _context(),
        ).toList();

        final error = events.whereType<ErrorEvent>().single;
        expect(error.reason, StopReason.error);
        expect(error.error.errorMessage, contains('no WebGPU support'));
      },
    );

    test('mid-stream engine error ends in an ErrorEvent', () async {
      final engine = FakeWebLlmEngine()..streamErrorMessage = 'boom';
      final events = await streamWebLlm(engine, _model(), _context()).toList();

      final error = events.whereType<ErrorEvent>().single;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, 'boom');
      expect(events.whereType<DoneEvent>(), isEmpty);
    });

    test('cancel mid-stream interrupts the engine and ends aborted', () async {
      final engine = FakeWebLlmEngine()
        ..chunks = ['partial']
        ..completeStream = false;
      final source = CancelTokenSource();

      final stream = streamWebLlm(
        engine,
        _model(),
        _context(),
        cancelToken: source.token,
      );
      final eventsFuture = stream.toList();
      // Let loadModel + chatStream start and the first chunk land.
      await pumpEventQueue();
      source.cancel();
      final events = await eventsFuture;

      final error = events.whereType<ErrorEvent>().single;
      expect(error.reason, StopReason.aborted);
      expect(error.error.stopReason, StopReason.aborted);
      // Text streamed before the abort is preserved on the final message.
      expect(_partialText(error.error), 'partial');
      expect(engine.interruptCount, 1);
      expect(engine.jsStreamCancelled, isTrue);
      expect(events.whereType<DoneEvent>(), isEmpty);
    });

    test(
      'an already-cancelled token aborts before touching the engine',
      () async {
        final engine = FakeWebLlmEngine();
        final source = CancelTokenSource()..cancel();
        final events = await streamWebLlm(
          engine,
          _model(),
          _context(),
          cancelToken: source.token,
        ).toList();

        expect(
          events.whereType<ErrorEvent>().single.reason,
          StopReason.aborted,
        );
        expect(engine.loadedPreset, isNull);
        expect(engine.lastMessages, isNull);
      },
    );
  });

  group('webLlmStreamFunction prompt-tools wrapper', () {
    test('the system prompt plus tool instructions (names and schemas) reach '
        'the engine', () async {
      final engine = FakeWebLlmEngine()..chunks = ['ok'];
      final events = await webLlmStreamFunction(engine)(
        _model(),
        _context(systemPrompt: 'You are fah.', tools: [_bashTool]),
      ).toList();

      expect(events.whereType<DoneEvent>(), hasLength(1));
      final system = engine.lastMessages!.first;
      expect(system.role, 'system');
      // The fah system prompt passes through untouched...
      expect(system.content, startsWith('You are fah.'));
      // ...with the wrapper's tool section appended: the actual tool
      // name, description, and parameter schema reach the model.
      expect(system.content, contains('## Available tools'));
      expect(system.content, contains('bash: Runs a shell command'));
      expect(system.content, contains('"cmd"'));
      expect(system.content, contains('```tool_call'));
      // Tools exist, so the no-tools note must NOT appear.
      expect(system.content, isNot(contains(webLlmNoToolsNote)));
    });

    test(
      'a fenced tool_call block becomes start/delta/end and StopReason.'
      'toolUse — for ANY preset (SmolLM2 here, not a function-calling one)',
      () async {
        final engine = FakeWebLlmEngine()
          ..chunks = [
            'Let me check.\n',
            '```tool_call\n'
                '{"name": "bash", "arguments": {"cmd": "ls"}}\n'
                '```',
          ];
        final events = await webLlmStreamFunction(engine)(
          _model(), // SmolLM2 135M — tools now work for every preset.
          _context(tools: [_bashTool]),
        ).toList();

        // The text before the fence streams as ordinary text.
        final deltas = events.whereType<TextDeltaEvent>().toList();
        expect(deltas, isNotEmpty);
        expect(deltas.map((e) => e.delta).join(), 'Let me check.\n');

        final start = events.whereType<ToolCallStartEvent>().single;
        final delta = events.whereType<ToolCallDeltaEvent>().single;
        expect(start.contentIndex, delta.contentIndex);
        expect(delta.delta, '{"cmd":"ls"}');

        final end = events.whereType<ToolCallEndEvent>().single;
        expect(end.toolCall.name, 'bash');
        expect(end.toolCall.arguments, {'cmd': 'ls'});
        expect(end.toolCall.id, isNotEmpty);

        final done = events.whereType<DoneEvent>().single;
        expect(done.reason, StopReason.toolUse);
        expect(done.message.stopReason, StopReason.toolUse);
        final call = done.message.content.whereType<ToolCall>().single;
        expect(call.name, 'bash');
        expect(call.arguments, {'cmd': 'ls'});
        expect(events.last, same(done));
      },
    );

    test(
      'tool calls and results round-trip to the engine as fenced text',
      () async {
        final engine = FakeWebLlmEngine()..chunks = ['done'];
        final events = await webLlmStreamFunction(engine)(
          _model(),
          _context(
            tools: [_bashTool],
            messages: [
              UserMessage.text('list files'),
              _assistant([
                const TextContent(text: 'Let me check.'),
                const ToolCall(
                  id: 'call-1',
                  name: 'bash',
                  arguments: {'cmd': 'ls'},
                ),
              ]),
              ToolResultMessage(
                toolCallId: 'call-1',
                toolName: 'bash',
                content: [const TextContent(text: 'a.txt')],
                isError: false,
                timestamp: DateTime.now(),
              ),
            ],
          ),
        ).toList();

        expect(events.whereType<DoneEvent>(), hasLength(1));
        final messages = engine.lastMessages!;
        expect(messages.map((m) => m.role), [
          'system',
          'user',
          'assistant',
          'user',
        ]);
        // The historical call is re-serialized in the assistant's own wire
        // format (the fenced block the wrapper taught it).
        expect(messages[2].content, contains('Let me check.'));
        expect(messages[2].content, contains('```tool_call'));
        expect(messages[2].content, contains('"name":"bash"'));
        // The result arrives as a user-role fenced tool_result block.
        expect(messages[3].content, contains('```tool_result'));
        expect(messages[3].content, contains('tool: bash'));
        expect(messages[3].content, contains('a.txt'));
      },
    );

    test('plain chat without tools is a passthrough: no tool instructions, the '
        'no-tools note appended', () async {
      final engine = FakeWebLlmEngine()..chunks = ['plain'];
      final events = await webLlmStreamFunction(engine)(
        _model(),
        _context(systemPrompt: 'You are fah.'),
      ).toList();

      final system = engine.lastMessages!.first;
      expect(system.role, 'system');
      expect(system.content, startsWith('You are fah.'));
      expect(system.content, contains(webLlmNoToolsNote));
      expect(system.content, isNot(contains('## Available tools')));

      expect(events.whereType<ToolCallStartEvent>(), isEmpty);
      final done = events.whereType<DoneEvent>().single;
      expect(done.reason, StopReason.stop);
      expect(_partialText(done.message), 'plain');
    });

    test('without tools a fenced block stays plain text', () async {
      final engine = FakeWebLlmEngine()
        ..chunks = ['```tool_call\n{"name": "bash"}\n```'];
      final events = await webLlmStreamFunction(engine)(
        _model(),
        _context(),
      ).toList();

      expect(events.whereType<ToolCallStartEvent>(), isEmpty);
      final done = events.whereType<DoneEvent>().single;
      expect(done.reason, StopReason.stop);
      expect(_partialText(done.message), contains('```tool_call'));
    });
  });

  group('convertWebLlmMessages', () {
    test('system prompt becomes the leading system message (no note when tools '
        'are registered)', () {
      final messages = convertWebLlmMessages(
        _context(systemPrompt: 'You are fah.', tools: [_bashTool]),
      );
      expect(messages.first, (role: 'system', content: 'You are fah.'));
      expect(messages.last, (role: 'user', content: 'hi'));
    });

    test('the no-tools note is appended only when the registry is empty', () {
      final noTools = convertWebLlmMessages(
        _context(systemPrompt: 'You are fah.'),
      );
      expect(noTools.first.role, 'system');
      expect(noTools.first.content, 'You are fah.\n\n$webLlmNoToolsNote');

      final emptyTools = convertWebLlmMessages(
        _context(systemPrompt: 'You are fah.', tools: const []),
      );
      expect(emptyTools.first.content, contains(webLlmNoToolsNote));
    });

    test('no system message when there is no prompt and tools exist', () {
      final messages = convertWebLlmMessages(_context(tools: [_bashTool]));
      expect(messages.single.role, 'user');
    });

    test('tool calls and results degrade to plain-text lines', () {
      final messages = convertWebLlmMessages(
        _context(
          messages: [
            UserMessage.text('list files'),
            _assistant([
              const ToolCall(
                id: 'call-1',
                name: 'bash',
                arguments: {'cmd': 'ls'},
              ),
            ]),
            ToolResultMessage(
              toolCallId: 'call-1',
              toolName: 'bash',
              content: [const TextContent(text: 'a.txt')],
              isError: false,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );

      expect(messages.map((m) => m.role), [
        'system',
        'user',
        'assistant',
        'user',
      ]);
      expect(messages[2].content, contains('[tool call: bash({"cmd":"ls"})]'));
      expect(messages[3].content, '[tool result · bash]\na.txt');
    });

    test('errored tool results are flagged in the fallback header', () {
      final messages = convertWebLlmMessages(
        _context(
          messages: [
            ToolResultMessage(
              toolCallId: 'call-1',
              toolName: 'bash',
              content: [const TextContent(text: 'nope')],
              isError: true,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      expect(messages.last.content, '[tool result · bash · error]\nnope');
    });

    test('images degrade to an omission note (presets are text-only)', () {
      final messages = convertWebLlmMessages(
        _context(
          messages: [
            UserMessage(
              content: [
                const TextContent(text: 'what is this?'),
                const ImageContent(data: 'AAAA', mimeType: 'image/png'),
              ],
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      expect(messages.last.role, 'user');
      expect(messages.last.content, contains('what is this?'));
      expect(messages.last.content, contains('image omitted'));
    });

    test('empty user messages are dropped', () {
      final messages = convertWebLlmMessages(
        _context(
          tools: [_bashTool],
          messages: [UserMessage.text('   '), UserMessage.text('real')],
        ),
      );
      expect(messages.single, (role: 'user', content: 'real'));
    });
  });
}
