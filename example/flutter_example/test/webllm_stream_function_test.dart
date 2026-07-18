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
    void Function()? onDone,
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
      if (completeStream) onDone?.call();
    }
    return () => jsStreamCancelled = true;
  }

  @override
  Future<void> interrupt() async {
    interruptCount++;
  }
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
          (role: 'system', content: 'You are fah.'),
          (role: 'user', content: 'hi'),
        ]);
        expect(engine.lastMaxTokens, 1024);
      },
    );

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

  group('convertWebLlmMessages', () {
    test('system prompt becomes the leading system message', () {
      final messages = convertWebLlmMessages(
        _context(systemPrompt: 'You are fah.'),
      );
      expect(messages.first, (role: 'system', content: 'You are fah.'));
      expect(messages.last, (role: 'user', content: 'hi'));
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
      expect(messages.single, (role: 'user', content: 'real'));
    });
  });
}
