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
  var unloadCount = 0;
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
  Future<void> unloadModel() async {
    unloadCount++;
    loadedPreset = null;
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

    test('an OrtRun-style engine error resets the engine so the next turn '
        'reloads', () async {
      final engine = FakeTransformersJsEngine()
        ..streamErrorMessage =
            'Error: OrtRun failed: mapAsync ... invalid Buffer';
      final events = await streamTransformersJs(
        engine,
        _model(),
        _context(),
      ).toList();

      expect(events.whereType<ErrorEvent>(), hasLength(1));
      expect(engine.unloadCount, 1);
      expect(engine.loadedPreset, isNull);
    });

    test('a clean turn does not reset the engine', () async {
      final engine = FakeTransformersJsEngine()..chunks = ['ok'];
      await streamTransformersJs(engine, _model(), _context()).toList();
      expect(engine.unloadCount, 0);
      expect(engine.loadedPreset, isNotNull);
    });

    test('a load failure does not double-reset the engine', () async {
      final engine = FakeTransformersJsEngine()
        ..loadError = StateError('no WebGPU');
      await streamTransformersJs(engine, _model(), _context()).toList();
      expect(engine.unloadCount, 0);
    });

    test('an unknown preset id does not reset a healthy engine', () async {
      final engine = FakeTransformersJsEngine();
      await streamTransformersJs(
        engine,
        _model('not-a-preset'),
        _context(),
      ).toList();
      expect(engine.unloadCount, 0);
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
      // A deliberate abort is not a session poisoning: no engine reset.
      expect(engine.unloadCount, 0);
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

    test('an SVG is never forwarded to the vision encoder', () {
      final messages = convertTransformersJsMessages(
        _context(
          messages: [
            UserMessage(
              content: [
                const TextContent(text: 'what is this?'),
                const ImageContent(data: 'PHN2Zz4=', mimeType: 'image/svg+xml'),
              ],
              timestamp: DateTime.now(),
            ),
          ],
        ),
        supportsVision: true,
      );
      expect(messages.last.role, 'user');
      // The SVG degrades to an omission note; RawImage never sees it.
      expect(messages.last.images, isEmpty);
      expect(messages.last.content, contains('what is this?'));
      expect(messages.last.content, contains('omitted'));
      expect(messages.last.content, contains('not decodable'));
    });

    test('decodable images pass while undecodable ones drop from the same '
        'message', () {
      final messages = convertTransformersJsMessages(
        _context(
          messages: [
            UserMessage(
              content: [
                const ImageContent(data: 'AAAA', mimeType: 'image/png'),
                const ImageContent(data: 'PHN2Zz4=', mimeType: 'image/svg+xml'),
                const ImageContent(data: 'Qk0=', mimeType: 'image/bmp'),
                const ImageContent(data: 'R0lG', mimeType: 'image/gif'),
              ],
              timestamp: DateTime.now(),
            ),
          ],
        ),
        supportsVision: true,
      );
      expect(messages.last.images, [
        'data:image/png;base64,AAAA',
        'data:image/gif;base64,R0lG',
      ]);
      expect(messages.last.content, contains('omitted'));
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
      final preset = transformersJsModelPresets.firstWhere(
        (p) => p.id == 'onnx-community/gemma-4-E2B-it-ONNX',
      );
      expect(preset.id, 'onnx-community/gemma-4-E2B-it-ONNX');
      expect(preset.displayName, contains('Gemma 4 E2B'));
      expect(preset.sizeLabel, '~3.4 GB');
      expect(preset.supportsVision, isTrue);
      // Every component the model class instantiates is pinned: text plus
      // the vision encoder, and the audio encoder at its SMALLEST dtype —
      // transformers.js always constructs an audio session for this model
      // class, and an unpinned component falls back to the 1.18 GB fp32
      // file.
      expect(preset.dtype, {
        'embed_tokens': 'q4f16',
        'decoder_model_merged': 'q4f16',
        'vision_encoder': 'q4f16',
        'audio_encoder': 'q4f16',
      });
      expect(findTransformersJsPreset(preset.id), same(preset));
      expect(findTransformersJsPreset('nope'), isNull);
    });

    test('the download allowlist covers exactly the requested dtype set', () {
      final preset = transformersJsModelPresets.firstWhere(
        (p) => p.id == 'onnx-community/gemma-4-E2B-it-ONNX',
      );
      final files = preset.downloadSizes.keys.toList();
      // The needed q4f16 files: text (embed + decoder), vision, the
      // unavoidable minimal audio session, and the config/tokenizer files.
      expect(
        files,
        containsAll([
          'onnx/embed_tokens_q4f16.onnx',
          'onnx/embed_tokens_q4f16.onnx_data',
          'onnx/decoder_model_merged_q4f16.onnx',
          'onnx/decoder_model_merged_q4f16.onnx_data',
          'onnx/vision_encoder_q4f16.onnx',
          'onnx/vision_encoder_q4f16.onnx_data',
          'onnx/audio_encoder_q4f16.onnx',
          'onnx/audio_encoder_q4f16.onnx_data',
          'config.json',
          'tokenizer.json',
        ]),
      );
      // Nothing outside the requested dtype set: no fp32 (suffix-less)
      // files — the 1.18 GB fp32 audio encoder first among them — and no
      // other quantizations.
      for (final file in files) {
        expect(file, isNot(endsWith('.onnx_data_1')));
        expect(file, isNot(contains('_fp16.')));
        expect(file, isNot(contains('_fp16_')), reason: file);
        expect(file, isNot(contains('_quantized.')), reason: file);
        expect(file, isNot(contains('_q4.')), reason: file);
      }
      expect(files, isNot(contains('onnx/audio_encoder.onnx')));
      expect(files, isNot(contains('onnx/audio_encoder.onnx_data')));
      // The headline sizes the progress UX advertises.
      expect(
        preset.downloadSizes['onnx/embed_tokens_q4f16.onnx_data'],
        1590689792,
      );
      expect(
        preset.downloadSizes['onnx/decoder_model_merged_q4f16.onnx_data'],
        1519700992,
      );
      expect(
        preset.downloadSizes['onnx/vision_encoder_q4f16.onnx_data'],
        99189440,
      );
      expect(
        preset.downloadSizes['onnx/audio_encoder_q4f16.onnx_data'],
        171258112,
      );
    });
  });
}
