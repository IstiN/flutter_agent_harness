import 'package:flutter_agent_example/prompts.g.dart';
import 'package:flutter_agent_example/webllm/webllm_stream_function.dart';
import 'package:flutter_agent_example/webllm/webllm_types.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [WebLlmEngineApi] driven entirely by test script: canned chunks,
/// canned `tool_calls` payloads, an optional stream/load failure, and a
/// "hold the stream open" mode for abort tests. Records everything the
/// stream function hands it.
final class FakeWebLlmEngine implements WebLlmEngineApi {
  /// Chunks delivered through `onChunk`, in order.
  List<String> chunks = [];

  /// `tool_calls` JSON payloads delivered through `onToolCalls`, in order
  /// (each is one chunk's `delta.tool_calls` array, JSON-encoded).
  List<String> toolCallsPayloads = [];

  /// Finish reason reported through `onDone` (web-llm reports `stop`,
  /// `length`, or `tool_calls`).
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
  List<Map<String, dynamic>>? lastTools;
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
    void Function(String toolCallsJson)? onToolCalls,
    List<Map<String, dynamic>>? tools,
    int? maxTokens,
  }) async {
    lastMessages = messages;
    lastTools = tools;
    lastMaxTokens = maxTokens;
    final streamError = streamErrorMessage;
    if (streamError != null) {
      onError?.call(streamError);
    } else {
      for (final chunk in chunks) {
        onChunk(chunk);
      }
      for (final payload in toolCallsPayloads) {
        onToolCalls?.call(payload);
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

/// The one preset with `supportsTools: true` (in web-llm's
/// functionCallingModelIds).
const _fcPresetId = 'Hermes-3-Llama-3.1-8B-q4f16_1-MLC';

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
  group('webLlmStreamFunction event mapping', () {
    test(
      'streams chunks partial-first and ends with DoneEvent(stop)',
      () async {
        final engine = FakeWebLlmEngine()..chunks = ['Hello', ', world', '!'];
        final events = await streamWebLlm(
          engine,
          _model(),
          _context(),
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
          _context(systemPrompt: 'You are fah.'),
        ).toList();

        expect(engine.loadedPreset?.id, webLlmModelPresets.first.id);
        expect(engine.lastMessages, [
          (role: 'system', content: 'You are fah.', toolCallId: null),
          (role: 'user', content: 'hi', toolCallId: null),
        ]);
        expect(engine.lastMaxTokens, 1024);
        expect(engine.lastTools, isNull);
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

  group('webLlmStreamFunction tool calling', () {
    test('serializes tools for function-calling presets, drops the system '
        'message, and keeps the no-tools note off', () async {
      final engine = FakeWebLlmEngine();
      final events = await streamWebLlm(
        engine,
        _model(_fcPresetId),
        _context(systemPrompt: 'You are fah.', tools: [_bashTool]),
      ).toList();

      expect(events.whereType<DoneEvent>(), hasLength(1));
      expect(engine.loadedPreset?.id, _fcPresetId);
      expect(engine.lastTools, [
        {
          'type': 'function',
          'function': {
            'name': 'bash',
            'description': 'Runs a shell command',
            'parameters': _bashTool.parameters,
          },
        },
      ]);
      // WebLLM injects its own function-calling system prompt and rejects a
      // user-supplied one (CustomSystemPromptError), so none may be sent.
      expect(engine.lastMessages!.where((m) => m.role == 'system'), isEmpty);
      expect(engine.lastMessages, [
        (role: 'user', content: 'hi', toolCallId: null),
      ]);
    });

    test(
      'streams tool_calls into start/delta/end events with parsed args',
      () async {
        final engine = FakeWebLlmEngine()
          // Raw tool-call JSON streams as content — must be suppressed.
          ..chunks = ['[{"name": "bash", "arguments": {"cmd": "ls"}}]']
          ..finishReason = 'tool_calls'
          ..toolCallsPayloads = [
            '[{"index": 0, "type": "function", '
                '"function": {"name": "bash", "arguments": "{\\"cmd\\": \\"ls\\"}"}}]',
          ];
        final events = await streamWebLlm(
          engine,
          _model(_fcPresetId),
          _context(tools: [_bashTool]),
        ).toList();

        // No text leaks: the raw JSON never becomes a TextContent block.
        expect(events.whereType<TextDeltaEvent>(), isEmpty);
        expect(events.whereType<TextStartEvent>(), isEmpty);

        final start = events.whereType<ToolCallStartEvent>().single;
        expect(start.contentIndex, 0);

        final delta = events.whereType<ToolCallDeltaEvent>().single;
        expect(delta.contentIndex, 0);
        expect(delta.delta, '{"cmd": "ls"}');
        // Partial-first: the delta's snapshot carries the accumulated raw JSON.
        final partialCall = delta.partial.content[0] as ToolCall;
        expect(partialCall.name, 'bash');
        expect(partialCall.partialArguments, '{"cmd": "ls"}');
        expect(partialCall.arguments, isEmpty);
        // WebLLM streaming tool_calls carry no id — one is synthesized.
        expect(partialCall.id, isNotEmpty);
        expect(partialCall.id, contains('bash'));

        final end = events.whereType<ToolCallEndEvent>().single;
        expect(end.contentIndex, 0);
        expect(end.toolCall.name, 'bash');
        expect(end.toolCall.arguments, {'cmd': 'ls'});
        expect(end.toolCall.partialArguments, isNull);

        final done = events.whereType<DoneEvent>().single;
        expect(done.reason, StopReason.toolUse);
        expect(done.message.stopReason, StopReason.toolUse);
        final call = done.message.content.single as ToolCall;
        expect(call.id, end.toolCall.id);
        expect(call.name, 'bash');
        expect(call.arguments, {'cmd': 'ls'});
        expect(call.partialArguments, isNull);
        expect(events.last, same(done));
      },
    );

    test('multiple tool calls keep stream order and distinct ids', () async {
      final engine = FakeWebLlmEngine()
        ..finishReason = 'tool_calls'
        ..toolCallsPayloads = [
          '['
              '{"index": 0, "type": "function", "function": '
              '{"name": "bash", "arguments": "{\\"cmd\\": \\"ls\\"}"}},'
              '{"index": 1, "type": "function", "function": '
              '{"name": "read", "arguments": "{\\"path\\": \\"a.txt\\"}"}}'
              ']',
        ];
      final events = await streamWebLlm(
        engine,
        _model(_fcPresetId),
        _context(tools: [_bashTool]),
      ).toList();

      final starts = events.whereType<ToolCallStartEvent>().toList();
      expect(starts.map((e) => e.contentIndex), [0, 1]);
      final deltas = events.whereType<ToolCallDeltaEvent>().toList();
      expect(deltas.map((e) => e.contentIndex), [0, 1]);
      final ends = events.whereType<ToolCallEndEvent>().toList();
      expect(ends.map((e) => e.contentIndex), [0, 1]);
      expect(ends[0].toolCall.name, 'bash');
      expect(ends[1].toolCall.name, 'read');
      expect(ends[1].toolCall.arguments, {'path': 'a.txt'});
      expect(ends[0].toolCall.id, isNot(ends[1].toolCall.id));

      final done = events.whereType<DoneEvent>().single;
      expect(done.message.content.map((b) => (b as ToolCall).name), [
        'bash',
        'read',
      ]);
    });

    test('an empty tool_calls array ends with stop and no content', () async {
      final engine = FakeWebLlmEngine()
        ..finishReason = 'tool_calls'
        ..toolCallsPayloads = ['[]'];
      final events = await streamWebLlm(
        engine,
        _model(_fcPresetId),
        _context(tools: [_bashTool]),
      ).toList();

      expect(events.whereType<ToolCallStartEvent>(), isEmpty);
      final done = events.whereType<DoneEvent>().single;
      expect(done.reason, StopReason.stop);
      expect(done.message.content, isEmpty);
    });

    test('non-FC presets never receive tools, even when registered', () async {
      final engine = FakeWebLlmEngine()..chunks = ['ok'];
      await streamWebLlm(
        engine,
        _model(), // SmolLM2 135M — supportsTools: false
        _context(systemPrompt: 'You are fah.', tools: [_bashTool]),
      ).toList();

      expect(engine.lastTools, isNull);
      final system = engine.lastMessages!.first;
      expect(system.role, 'system');
      expect(system.content, contains(webLlmNoToolsNote));
    });
  });

  group('convertWebLlmMessages', () {
    test('system prompt becomes the leading system message', () {
      final messages = convertWebLlmMessages(
        _context(systemPrompt: 'You are fah.'),
      );
      expect(messages.first, (
        role: 'system',
        content: 'You are fah.',
        toolCallId: null,
      ));
      expect(messages.last, (role: 'user', content: 'hi', toolCallId: null));
    });

    test('no system message when there is no prompt and no tools', () {
      final messages = convertWebLlmMessages(_context());
      expect(messages.single.role, 'user');
    });

    test(
      'registered tools are NOT forwarded; the no-tools note is appended',
      () {
        const tool = Tool(
          name: 'bash',
          description: 'runs commands',
          parameters: {'type': 'object'},
        );
        final messages = convertWebLlmMessages(
          _context(systemPrompt: 'You are fah.', tools: [tool]),
        );

        expect(messages, hasLength(2));
        final system = messages.first;
        expect(system.role, 'system');
        expect(system.content, startsWith('You are fah.'));
        expect(system.content, contains(webLlmNoToolsNote));
        // The tool schema itself never reaches the engine payload.
        expect(system.content, isNot(contains('runs commands')));
      },
    );

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

      expect(messages.map((m) => m.role), ['user', 'assistant', 'user']);
      expect(messages[1].content, contains('[tool call: bash({"cmd":"ls"})]'));
      expect(messages[2].content, '[tool result · bash]\na.txt');
      expect(messages[2].toolCallId, isNull);
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
      expect(messages.single.content, '[tool result · bash · error]\nnope');
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
      expect(messages.single.role, 'user');
      expect(messages.single.content, contains('what is this?'));
      expect(messages.single.content, contains('image omitted'));
    });

    test('empty user messages are dropped', () {
      final messages = convertWebLlmMessages(
        _context(messages: [UserMessage.text('   '), UserMessage.text('real')]),
      );
      expect(messages.single, (
        role: 'user',
        content: 'real',
        toolCallId: null,
      ));
    });
  });

  group('convertWebLlmMessages (toolsMode)', () {
    test('omits the system message and the no-tools note', () {
      final messages = convertWebLlmMessages(
        _context(systemPrompt: 'You are fah.', tools: [_bashTool]),
        toolsMode: true,
      );
      expect(messages.where((m) => m.role == 'system'), isEmpty);
      expect(
        messages.any((m) => m.content.contains(webLlmNoToolsNote)),
        isFalse,
      );
    });

    test('assistant tool calls serialize as the raw JSON array', () {
      final messages = convertWebLlmMessages(
        toolsMode: true,
        _context(
          messages: [
            UserMessage.text('list files'),
            _assistant([
              const TextContent(text: 'Let me check.'),
              const ToolCall(
                id: 'call-1',
                name: 'bash',
                arguments: {'cmd': 'ls'},
              ),
              const ToolCall(
                id: 'call-2',
                name: 'read',
                arguments: {'path': 'a.txt'},
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

      expect(messages.map((m) => m.role), ['user', 'assistant', 'tool']);
      // WebLLM requires string assistant content (no OpenAI tool_calls
      // arrays in history); the JSON array is the model's own output shape.
      expect(
        messages[1].content,
        'Let me check.\n'
        '[{"name":"bash","arguments":{"cmd":"ls"}},'
        '{"name":"read","arguments":{"path":"a.txt"}}]',
      );
      expect(messages[1].toolCallId, isNull);
      // Tool results map to the tool role with the call id.
      expect(messages[2].content, 'a.txt');
      expect(messages[2].toolCallId, 'call-1');
    });

    test('empty tool results become a placeholder tool message', () {
      final messages = convertWebLlmMessages(
        toolsMode: true,
        _context(
          messages: [
            ToolResultMessage(
              toolCallId: 'call-1',
              toolName: 'bash',
              content: const [],
              isError: false,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      expect(messages.single.role, 'tool');
      expect(messages.single.content, '(no output)');
      expect(messages.single.toolCallId, 'call-1');
    });
  });

  group('webLlmModelPresets tool capability', () {
    test('only web-llm functionCallingModelIds presets get supportsTools', () {
      final withTools = webLlmModelPresets
          .where((p) => p.supportsTools)
          .map((p) => p.id)
          .toList();
      // Source: functionCallingModelIds in @mlc-ai/web-llm src/config.ts
      // (v0.2.84) — Hermes-2-Pro/Hermes-2-Mistral entries are not presets.
      expect(withTools, ['Hermes-3-Llama-3.1-8B-q4f16_1-MLC']);
    });
  });
}
