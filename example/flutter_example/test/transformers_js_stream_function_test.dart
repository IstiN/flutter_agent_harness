import 'package:flutter_agent_example/prompts.g.dart';
import 'package:flutter_agent_example/transformers_js/transformers_js_stream_function.dart';
import 'package:flutter_agent_example/transformers_js/transformers_js_types.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [TransformersJsEngineApi] driven entirely by test script: canned
/// chunks, an optional stream/load failure, and a "hold the stream open"
/// mode for abort tests. Records everything the stream function hands it.
final class FakeTransformersJsEngine implements TransformersJsEngineApi {
  /// Chunks delivered through `onChunk`, in order.
  List<String> chunks = [];

  /// Finish reason reported through `onDone` (`stop` or `length` — the JS
  /// helper derives it from the generated token count).
  String finishReason = 'stop';

  /// When set, `chatStream` reports this via `onError` instead of chunks.
  String? streamErrorMessage;

  /// When set, `loadModel` throws this.
  Object? loadError;

  /// When false, `chatStream` never calls `onDone` (stays open until the
  /// returned cancel function is invoked — the abort path).
  bool completeStream = true;

  TransformersJsModelPreset? loadedPreset;
  List<TransformersJsChatMessage>? lastMessages;
  int? lastMaxTokens;
  var interruptCount = 0;
  var jsStreamCancelled = false;

  @override
  bool get isAvailable => true;

  @override
  String? get loadedModelId => loadedPreset?.id;

  @override
  Stream<TransformersJsProgress> get progressEvents => const Stream.empty();

  @override
  Future<void> loadModel(TransformersJsModelPreset preset) async {
    final error = loadError;
    if (error != null) throw error;
    loadedPreset = preset;
  }

  @override
  Future<void Function()> chatStream({
    required List<TransformersJsChatMessage> messages,
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
  Future<TransformersJsCacheInfo?> modelCacheInfo(String modelId) async => null;

  @override
  Future<void> deleteCachedModel(String modelId) async {}
}

Model _model([String? id]) => Model(
  id: id ?? transformersJsModelPresets.first.id,
  api: transformersJsProviderKind,
  provider: transformersJsProviderKind,
  baseUrl: '',
  contextWindow: 4096,
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
  api: transformersJsProviderKind,
  provider: transformersJsProviderKind,
  model: transformersJsModelPresets.first.id,
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.now(),
);

String _partialText(AssistantMessage message) =>
    message.content.whereType<TextContent>().map((block) => block.text).join();

void main() {
  group('streamTransformersJs event mapping', () {
    test(
      'streams chunks partial-first and ends with DoneEvent(stop)',
      () async {
        final engine = FakeTransformersJsEngine()
          ..chunks = ['Hello', ', world', '!'];
        final events = await streamTransformersJs(
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
        // The engine reports no token counts: usage stays zero (documented).
        expect(done.message.usage, same(Usage.zero));
        expect(events.last, same(done));
      },
    );

    test(
      'forwards converted messages and the maxTokens cap to the engine',
      () async {
        final engine = FakeTransformersJsEngine()..chunks = ['ok'];
        await streamTransformersJs(
          engine,
          _model(),
          _context(systemPrompt: 'You are fah.', tools: [_bashTool]),
        ).toList();

        expect(engine.loadedPreset?.id, transformersJsModelPresets.first.id);
        expect(engine.lastMessages, [
          (role: 'system', content: 'You are fah.', images: const <String>[]),
          (role: 'user', content: 'hi', images: const <String>[]),
        ]);
        expect(engine.lastMaxTokens, 1024);
      },
    );

    test('a length finish reason maps to StopReason.length', () async {
      final engine = FakeTransformersJsEngine()
        ..chunks = ['cut off']
        ..finishReason = 'length';
      final events = await streamTransformersJs(
        engine,
        _model(),
        _context(),
      ).toList();

      final done = events.whereType<DoneEvent>().single;
      expect(done.reason, StopReason.length);
      expect(done.message.stopReason, StopReason.length);
      expect(_partialText(done.message), 'cut off');
    });

    test('unknown preset id ends in an ErrorEvent, never a throw', () async {
      final engine = FakeTransformersJsEngine();
      final events = await streamTransformersJs(
        engine,
        _model('not-a-preset'),
        _context(),
      ).toList();

      final error = events.whereType<ErrorEvent>().single;
      expect(error.reason, StopReason.error);
      expect(
        error.error.errorMessage,
        contains('Unknown transformers.js model preset'),
      );
      expect(engine.loadedPreset, isNull);
    });

    test(
      'load failure ends in an ErrorEvent with the engine message',
      () async {
        final engine = FakeTransformersJsEngine()
          ..loadError = StateError('This browser has no WebGPU support');
        final events = await streamTransformersJs(
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
      final engine = FakeTransformersJsEngine()..streamErrorMessage = 'boom';
      final events = await streamTransformersJs(
        engine,
        _model(),
        _context(),
      ).toList();

      final error = events.whereType<ErrorEvent>().single;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, 'boom');
      expect(events.whereType<DoneEvent>(), isEmpty);
    });

    test('cancel mid-stream interrupts the engine and ends aborted', () async {
      final engine = FakeTransformersJsEngine()
        ..chunks = ['partial']
        ..completeStream = false;
      final source = CancelTokenSource();

      final stream = streamTransformersJs(
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
        final engine = FakeTransformersJsEngine();
        final source = CancelTokenSource()..cancel();
        final events = await streamTransformersJs(
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

  group('transformersJsStreamFunction prompt-tools wrapper', () {
    test('the system prompt plus tool instructions (names and schemas) reach '
        'the engine', () async {
      final engine = FakeTransformersJsEngine()..chunks = ['ok'];
      final events = await transformersJsStreamFunction(engine)(
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
      expect(system.content, isNot(contains(transformersJsNoToolsNote)));
    });

    test('a fenced tool_call block becomes start/delta/end and StopReason.'
        'toolUse', () async {
      final engine = FakeTransformersJsEngine()
        ..chunks = [
          'Let me check.\n',
          '```tool_call\n'
              '{"name": "bash", "arguments": {"cmd": "ls"}}\n'
              '```',
        ];
      final events = await transformersJsStreamFunction(engine)(
        _model(),
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
    });

    test(
      'tool calls and results round-trip to the engine as fenced text',
      () async {
        final engine = FakeTransformersJsEngine()..chunks = ['done'];
        final events = await transformersJsStreamFunction(engine)(
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
      final engine = FakeTransformersJsEngine()..chunks = ['plain'];
      final events = await transformersJsStreamFunction(engine)(
        _model(),
        _context(systemPrompt: 'You are fah.'),
      ).toList();

      final system = engine.lastMessages!.first;
      expect(system.role, 'system');
      expect(system.content, startsWith('You are fah.'));
      expect(system.content, contains(transformersJsNoToolsNote));
      expect(system.content, isNot(contains('## Available tools')));

      expect(events.whereType<ToolCallStartEvent>(), isEmpty);
      final done = events.whereType<DoneEvent>().single;
      expect(done.reason, StopReason.stop);
      expect(_partialText(done.message), 'plain');
    });

    test('without tools a fenced block stays plain text', () async {
      final engine = FakeTransformersJsEngine()
        ..chunks = ['```tool_call\n{"name": "bash"}\n```'];
      final events = await transformersJsStreamFunction(engine)(
        _model(),
        _context(),
      ).toList();

      expect(events.whereType<ToolCallStartEvent>(), isEmpty);
      final done = events.whereType<DoneEvent>().single;
      expect(done.reason, StopReason.stop);
      expect(_partialText(done.message), contains('```tool_call'));
    });
  });

  group('convertTransformersJsMessages', () {
    test('system prompt becomes the leading system message (no note when tools '
        'are registered)', () {
      final messages = convertTransformersJsMessages(
        _context(systemPrompt: 'You are fah.', tools: [_bashTool]),
        supportsVision: true,
      );
      expect(messages.first, (
        role: 'system',
        content: 'You are fah.',
        images: const <String>[],
      ));
      expect(messages.last, (
        role: 'user',
        content: 'hi',
        images: const <String>[],
      ));
    });

    test('the no-tools note is appended only when the registry is empty', () {
      final noTools = convertTransformersJsMessages(
        _context(systemPrompt: 'You are fah.'),
        supportsVision: true,
      );
      expect(noTools.first.role, 'system');
      expect(
        noTools.first.content,
        'You are fah.\n\n$transformersJsNoToolsNote',
      );

      final emptyTools = convertTransformersJsMessages(
        _context(systemPrompt: 'You are fah.', tools: const []),
        supportsVision: true,
      );
      expect(emptyTools.first.content, contains(transformersJsNoToolsNote));
    });

    test('no system message when there is no prompt and tools exist', () {
      final messages = convertTransformersJsMessages(
        _context(tools: [_bashTool]),
        supportsVision: true,
      );
      expect(messages.single.role, 'user');
    });

    test('tool calls and results degrade to plain-text lines', () {
      final messages = convertTransformersJsMessages(
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
        supportsVision: true,
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
      final messages = convertTransformersJsMessages(
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
        supportsVision: true,
      );
      expect(messages.last.content, '[tool result · bash · error]\nnope');
    });

    test('images become data URIs on the message when vision is supported', () {
      final messages = convertTransformersJsMessages(
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
        supportsVision: true,
      );
      expect(messages.last.role, 'user');
      expect(messages.last.content, 'what is this?');
      expect(messages.last.images, ['data:image/png;base64,AAAA']);
      expect(messages.last.content, isNot(contains('omitted')));
    });

    test('images degrade to an omission note when vision is unsupported', () {
      final messages = convertTransformersJsMessages(
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
        supportsVision: false,
      );
      expect(messages.last.role, 'user');
      expect(messages.last.content, contains('what is this?'));
      expect(messages.last.content, contains('image omitted'));
      expect(messages.last.images, isEmpty);
    });

    test('empty user messages are dropped', () {
      final messages = convertTransformersJsMessages(
        _context(
          tools: [_bashTool],
          messages: [UserMessage.text('   '), UserMessage.text('real')],
        ),
        supportsVision: true,
      );
      expect(messages.single, (
        role: 'user',
        content: 'real',
        images: const <String>[],
      ));
    });
  });

  group('transformersJsModelPresets', () {
    test('ships the Gemma 4 E2B ONNX preset (text + vision, q4f16)', () {
      final preset = transformersJsModelPresets.single;
      expect(preset.id, 'onnx-community/gemma-4-E2B-it-ONNX');
      expect(preset.displayName, contains('Gemma 4 E2B'));
      expect(preset.sizeLabel, '~3.2 GB');
      expect(preset.supportsVision, isTrue);
      // Text components plus the vision encoder; no audio encoder (the app
      // has no audio input UI).
      expect(preset.dtype, {
        'embed_tokens': 'q4f16',
        'decoder_model_merged': 'q4f16',
        'vision_encoder': 'q4f16',
      });
      expect(findTransformersJsPreset(preset.id), same(preset));
      expect(findTransformersJsPreset('nope'), isNull);
    });
  });
}
