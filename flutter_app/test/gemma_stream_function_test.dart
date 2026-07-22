import 'dart:async';

import 'package:fa/gemma/gemma_stream_function.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [GemmaEngineApi] driven entirely by test script: canned chunks,
/// canned `tool_calls` payloads, an optional stream/load failure, and a
/// "hold the stream open" mode for abort tests. Records everything the
/// stream function hands it.
final class FakeGemmaEngine implements GemmaEngineApi {
  /// Chunks delivered through `onChunk`, in order.
  List<String> chunks = [];

  /// `tool_calls` JSON payloads delivered through `onToolCalls`, in order
  /// (the plugin surfaces calls complete at end-of-stream; each payload is
  /// a JSON-encoded array in the OpenAI streaming shape).
  List<String> toolCallsPayloads = [];

  /// When set, `chatStream` reports this via `onError` instead of chunks.
  String? streamErrorMessage;

  /// When set, `loadModel` throws this.
  Object? loadError;

  /// When false, `chatStream` never calls `onDone` (stays open — the abort
  /// path).
  bool completeStream = true;

  GemmaModelPreset? loadedPreset;
  List<GemmaChatMessage>? lastMessages;
  List<Map<String, dynamic>>? lastTools;
  String? lastSystemInstruction;
  int? lastMaxOutputTokens;
  var interruptCount = 0;

  @override
  bool get isAvailable => true;

  @override
  String? get loadedModelId => loadedPreset?.id;

  @override
  Stream<GemmaProgress> get progressEvents => const Stream.empty();

  @override
  Future<bool> isModelInstalled(GemmaModelPreset preset) async => true;

  @override
  Future<void> installModel(
    GemmaModelPreset preset, {
    String? huggingFaceToken,
  }) async {}

  @override
  Future<void> loadModel(GemmaModelPreset preset) async {
    final error = loadError;
    if (error != null) throw error;
    loadedPreset = preset;
  }

  @override
  Future<void> chatStream({
    required List<GemmaChatMessage> messages,
    required void Function(String chunk) onChunk,
    String? systemInstruction,
    void Function()? onDone,
    void Function(String message)? onError,
    void Function(String toolCallsJson)? onToolCalls,
    List<Map<String, dynamic>>? tools,
    int? maxOutputTokens,
  }) async {
    lastMessages = messages;
    lastSystemInstruction = systemInstruction;
    lastTools = tools;
    lastMaxOutputTokens = maxOutputTokens;
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
      if (completeStream) onDone?.call();
    }
  }

  @override
  Future<void> interrupt() async {
    interruptCount++;
  }

  @override
  Future<void> unload() async {}

  @override
  Future<List<GemmaInstalledModel>> installedModels() async => const [];

  @override
  Future<void> uninstall(String filename) async {}
}

Model _model([String? id]) => Model(
  id: id ?? gemmaModelPresets.first.id,
  api: gemmaProviderKind,
  provider: gemmaProviderKind,
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
  api: gemmaProviderKind,
  provider: gemmaProviderKind,
  model: gemmaModelPresets.first.id,
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.now(),
);

String _partialText(AssistantMessage message) =>
    message.content.whereType<TextContent>().map((block) => block.text).join();

void main() {
  group('gemmaStreamFunction event mapping', () {
    test(
      'streams chunks partial-first and ends with DoneEvent(stop)',
      () async {
        final engine = FakeGemmaEngine()..chunks = ['Hello', ', world', '!'];
        final events = await streamGemma(engine, _model(), _context()).toList();

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
        // The plugin reports no token counts: usage stays zero (documented).
        expect(done.message.usage, same(Usage.zero));
        expect(events.last, same(done));
      },
    );

    test(
      'forwards messages, system instruction, tools and the output cap',
      () async {
        final engine = FakeGemmaEngine()..chunks = ['ok'];
        await streamGemma(
          engine,
          _model(),
          _context(systemPrompt: 'You are fah.', tools: [_bashTool]),
        ).toList();

        expect(engine.loadedPreset?.id, gemmaModelPresets.first.id);
        // The system prompt travels as the chat's system instruction, not
        // as a message.
        expect(engine.lastSystemInstruction, 'You are fah.');
        expect(engine.lastMessages, [
          (role: 'user', content: 'hi', toolName: null),
        ]);
        expect(engine.lastMaxOutputTokens, 1024);
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
      },
    );

    test('no tools registered → no tools forwarded', () async {
      final engine = FakeGemmaEngine()..chunks = ['ok'];
      await streamGemma(engine, _model(), _context()).toList();
      expect(engine.lastTools, isNull);
    });

    test('unknown preset id ends in an ErrorEvent, never a throw', () async {
      final engine = FakeGemmaEngine();
      final events = await streamGemma(
        engine,
        _model('not-a-preset'),
        _context(),
      ).toList();

      final error = events.whereType<ErrorEvent>().single;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('Unknown Gemma model preset'));
      expect(engine.loadedPreset, isNull);
    });

    test(
      'load failure ends in an ErrorEvent with the engine message',
      () async {
        final engine = FakeGemmaEngine()
          ..loadError = StateError('No active inference model set');
        final events = await streamGemma(engine, _model(), _context()).toList();

        final error = events.whereType<ErrorEvent>().single;
        expect(error.reason, StopReason.error);
        expect(error.error.errorMessage, contains('No active inference model'));
      },
    );

    test('mid-stream engine error ends in an ErrorEvent', () async {
      final engine = FakeGemmaEngine()..streamErrorMessage = 'boom';
      final events = await streamGemma(engine, _model(), _context()).toList();

      final error = events.whereType<ErrorEvent>().single;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, 'boom');
      expect(events.whereType<DoneEvent>(), isEmpty);
    });

    test('cancel mid-stream interrupts the engine and ends aborted', () async {
      final engine = FakeGemmaEngine()
        ..chunks = ['partial']
        ..completeStream = false;
      final source = CancelTokenSource();

      final stream = streamGemma(
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
      expect(events.whereType<DoneEvent>(), isEmpty);
    });

    test(
      'an already-cancelled token aborts before touching the engine',
      () async {
        final engine = FakeGemmaEngine();
        final source = CancelTokenSource()..cancel();
        final events = await streamGemma(
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

  group('gemmaStreamFunction tool calling', () {
    test(
      'streams tool_calls into start/delta/end events with parsed args',
      () async {
        final engine = FakeGemmaEngine()
          ..toolCallsPayloads = [
            '[{"index": 0, "type": "function", '
                '"function": {"name": "bash", "arguments": "{\\"cmd\\": \\"ls\\"}"}}]',
          ];
        final events = await streamGemma(
          engine,
          _model(),
          _context(tools: [_bashTool]),
        ).toList();

        expect(events.whereType<TextDeltaEvent>(), isEmpty);
        expect(events.whereType<TextStartEvent>(), isEmpty);

        final start = events.whereType<ToolCallStartEvent>().single;
        expect(start.contentIndex, 0);

        final delta = events.whereType<ToolCallDeltaEvent>().single;
        expect(delta.contentIndex, 0);
        expect(delta.delta, '{"cmd": "ls"}');
        // Partial-first: the delta's snapshot carries the raw arguments JSON.
        final partialCall = delta.partial.content[0] as ToolCall;
        expect(partialCall.name, 'bash');
        expect(partialCall.partialArguments, '{"cmd": "ls"}');
        expect(partialCall.arguments, isEmpty);
        // The plugin's tool calls carry no id — one is synthesized.
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
        expect(events.last, same(done));
      },
    );

    test('text before the tool call streams, then the call follows', () async {
      final engine = FakeGemmaEngine()
        ..chunks = ['Let me check.']
        ..toolCallsPayloads = [
          '[{"index": 0, "type": "function", '
              '"function": {"name": "bash", "arguments": "{\\"cmd\\": \\"ls\\"}"}}]',
        ];
      final events = await streamGemma(
        engine,
        _model(),
        _context(tools: [_bashTool]),
      ).toList();

      expect(events.whereType<TextDeltaEvent>().map((e) => e.delta), [
        'Let me check.',
      ]);
      // The tool call lives behind the text block (contentIndex 1).
      final start = events.whereType<ToolCallStartEvent>().single;
      expect(start.contentIndex, 1);
      final end = events.whereType<ToolCallEndEvent>().single;
      expect(end.contentIndex, 1);

      final done = events.whereType<DoneEvent>().single;
      expect(done.reason, StopReason.toolUse);
      expect(done.message.content.map((b) => b.runtimeType.toString()), [
        'TextContent',
        'ToolCall',
      ]);
    });

    test('multiple tool calls keep stream order and distinct ids', () async {
      final engine = FakeGemmaEngine()
        ..toolCallsPayloads = [
          '['
              '{"index": 0, "type": "function", "function": '
              '{"name": "bash", "arguments": "{\\"cmd\\": \\"ls\\"}"}},'
              '{"index": 1, "type": "function", "function": '
              '{"name": "read", "arguments": "{\\"path\\": \\"a.txt\\"}"}}'
              ']',
        ];
      final events = await streamGemma(
        engine,
        _model(),
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
      final engine = FakeGemmaEngine()..toolCallsPayloads = ['[]'];
      final events = await streamGemma(
        engine,
        _model(),
        _context(tools: [_bashTool]),
      ).toList();

      expect(events.whereType<ToolCallStartEvent>(), isEmpty);
      final done = events.whereType<DoneEvent>().single;
      expect(done.reason, StopReason.stop);
      expect(done.message.content, isEmpty);
    });
  });

  group('convertGemmaMessages', () {
    test('system prompt is not a message (travels as systemInstruction)', () {
      final messages = convertGemmaMessages(
        _context(systemPrompt: 'You are fah.'),
      );
      expect(messages.single, (role: 'user', content: 'hi', toolName: null));
    });

    test('assistant text and tool calls become separate messages', () {
      final messages = convertGemmaMessages(
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
            ]),
          ],
        ),
      );

      expect(messages.map((m) => m.role), ['user', 'assistant', 'tool_call']);
      expect(messages[1].content, 'Let me check.');
      // The OpenAI-style assistant JSON the plugin's history replay stores.
      expect(
        messages[2].content,
        '{"role":"assistant","tool_calls":[{"type":"function","function":'
        '{"name":"bash","arguments":"{\\"cmd\\":\\"ls\\"}"}}]}',
      );
    });

    test('tool results carry the tool name', () {
      final messages = convertGemmaMessages(
        _context(
          messages: [
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
      expect(messages.single, (
        role: 'tool_result',
        content: 'a.txt',
        toolName: 'bash',
      ));
    });

    test('empty tool results become a placeholder', () {
      final messages = convertGemmaMessages(
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
      expect(messages.single.content, '(no output)');
    });

    test('images degrade to an omission note (text-only build)', () {
      final messages = convertGemmaMessages(
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
      final messages = convertGemmaMessages(
        _context(messages: [UserMessage.text('   '), UserMessage.text('real')]),
      );
      expect(messages.single, (role: 'user', content: 'real', toolName: null));
    });
  });

  group('gemmaModelPresets', () {
    test('E2B is the default; every preset is a litert-community URL', () {
      expect(gemmaModelPresets.first.id, 'gemma-4-E2B-it');
      for (final preset in gemmaModelPresets) {
        expect(preset.url, contains('litert-community'));
        expect(preset.filename, endsWith('.litertlm'));
        expect(findGemmaPreset(preset.id), same(preset));
      }
      expect(findGemmaPreset('nope'), isNull);
    });
  });
}
