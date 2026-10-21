// Issue #1750 ITs — the adaptive image-cap latch in the agent loop:
// a Google-shaped image-count 400 latches the learned cap and re-sends
// ONCE through the registry at the smaller cap (AC3); a second refusal
// surfaces the error exactly as today (AC4); non-matching errors never
// re-send (AC5); the kill switch keeps the legacy byte shape with no
// recovery (AC6); the latch is scoped per (provider, model) pair (E2);
// a degenerate learned cap never re-sends (E3); the re-send rebuilds
// fresh through the registry (E5).

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _refusal =
    'error: 400: too many images: maximum allowed for model '
    'undocumented-vision is 10, got 15';

Model _model(String id, {int? maxImages}) => Model(
  id: id,
  api: 'test-api',
  provider: 'copilot',
  baseUrl: 'https://example.test',
  input: const ['text', 'image'],
  contextWindow: 100000,
  maxTokens: 4096,
  maxImages: maxImages,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
}) => AssistantMessage(
  content: content,
  api: 'test-api',
  provider: 'copilot',
  model: 'undocumented-vision',
  usage: Usage.zero,
  stopReason: stopReason,
  errorMessage: errorMessage,
  timestamp: DateTime.utc(2026),
);

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

List<AssistantMessageEvent> _imageCapRefusalTurn(String error) {
  final msg = _assistant(stopReason: StopReason.error, errorMessage: error);
  return [
    StartEvent(partial: msg),
    ErrorEvent(reason: StopReason.error, error: msg),
  ];
}

class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// 12 unique images in history (below the global default 20, above the
/// provider's real cap 10).
List<Message> _imageHistory(int count) => [
  for (var i = 0; i < count; i++)
    UserMessage(
      content: [ImageContent(data: 'img$i', mimeType: 'image/png')],
      timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0, i),
    ),
];

int _uniqueImageCount(List<Message> messages) {
  final datas = <String>{};
  for (final message in messages) {
    if (message is UserMessage && message.content is List<ContentBlock>) {
      for (final block in message.content as List<ContentBlock>) {
        if (block is ImageContent) datas.add(block.data);
      }
    } else if (message is ToolResultMessage) {
      for (final block in message.content) {
        if (block is ImageContent) datas.add(block.data);
      }
    }
  }
  return datas.length;
}

bool _carriesImageData(List<Message> messages, String data) {
  for (final message in messages) {
    if (message is UserMessage && message.content is List<ContentBlock>) {
      if ((message.content as List<ContentBlock>).any(
        (b) => b is ImageContent && b.data == data,
      )) {
        return true;
      }
    }
    if (message is ToolResultMessage &&
        message.content.any((b) => b is ImageContent && b.data == data)) {
      return true;
    }
  }
  return false;
}

Future<List<Message>> _run(
  _FakeStreamFunction fake, {
  Model? model,
  Map<String, int>? latches,
}) => runAgentLoop(
  prompts: [UserMessage.text('go')],
  context: Context(messages: _imageHistory(12)),
  config: AgentLoopConfig(
    model: model ?? _model('undocumented-vision'),
    imageCapLatches: latches,
  ),
  streamFunction: fake.call,
  toolExecutor: (_, _, _) async => const ToolExecutionResult(content: []),
  emit: (_) {},
);

void main() {
  var dropNotices = <(int, String)>[];
  var learnedNotices = <(String, int)>[];
  ImageRegistryConfig? savedConfig;
  ImageDropNotice? savedDropNotice;
  ImageCapLearnedNotice? savedLearnedNotice;

  setUp(() {
    savedConfig = imageRegistryConfig;
    savedDropNotice = imageDropNotice;
    savedLearnedNotice = imageCapLearnedNotice;
    imageRegistryConfig = const ImageRegistryConfig();
    dropNotices = [];
    learnedNotices = [];
    imageDropNotice = (index, preview) => dropNotices.add((index, preview));
    imageCapLearnedNotice = (modelId, cap) =>
        learnedNotices.add((modelId, cap));
  });
  tearDown(() {
    imageRegistryConfig = savedConfig!;
    imageDropNotice = savedDropNotice;
    imageCapLearnedNotice = savedLearnedNotice;
  });

  test(
    'IT-1 (AC3): 400 → latch → exactly ONE re-send at the learned cap',
    () async {
      final fake = _FakeStreamFunction([
        _imageCapRefusalTurn(_refusal),
        _textTurn('recovered'),
      ]);
      final latches = <String, int>{};
      final messages = await _run(fake, latches: latches);

      expect(fake.calls, 2, reason: 'the refused request was retried once');
      // The latch landed for the (provider, model) pair, runtime-only.
      expect(latches, {'copilot|undocumented-vision': 10});
      // The retried payload carries ≤ the learned cap of unique images.
      expect(_uniqueImageCount(fake.contexts.last.messages), 10);
      // The drop is never silent: 2 drops + the learned-cap notice.
      expect(dropNotices, hasLength(2));
      expect(learnedNotices, [('undocumented-vision', 10)]);
      final assistant = messages.whereType<AssistantMessage>().last;
      expect(assistant.stopReason, StopReason.stop);
      expect(assistant.errorMessage, isNull);
    },
  );

  test(
    'IT-2 (AC4): a second refusal at the learned cap surfaces the error',
    () async {
      final fake = _FakeStreamFunction([
        _imageCapRefusalTurn(_refusal),
        _imageCapRefusalTurn(
          'error: 400: too many images: maximum allowed for model '
          'undocumented-vision is 10, got 11',
        ),
      ]);
      final messages = await _run(fake);

      expect(fake.calls, 2, reason: 'no third send — the retry is one-shot');
      final assistant = messages.whereType<AssistantMessage>().last;
      expect(assistant.stopReason, StopReason.error);
      expect(assistant.errorMessage, contains('too many images'));
    },
  );

  test(
    'IT-3 (AC5): a near-miss 400 without the refusal family never re-sends',
    () async {
      for (final error in [
        // The cap text WITHOUT "too many images" — the issue's named
        // near-miss.
        'error: 400: maximum allowed for model undocumented-vision is 10, '
            'got 15',
        '500: internal provider error',
        '429: rate limit exceeded',
      ]) {
        final fake = _FakeStreamFunction([
          _imageCapRefusalTurn(error),
          _textTurn('unreachable'),
        ]);
        final messages = await _run(fake);
        expect(fake.calls, 1, reason: 'error: $error');
        expect(learnedNotices, isEmpty);
        final assistant = messages.whereType<AssistantMessage>().last;
        expect(assistant.stopReason, StopReason.error);
      }
    },
  );

  test('IT-4 (AC6): images.registry:false — no cap logic, no re-send, '
      'legacy request shape', () async {
    imageRegistryConfig = const ImageRegistryConfig(enabled: false);
    final fake = _FakeStreamFunction([
      _imageCapRefusalTurn(_refusal),
      _textTurn('unreachable'),
    ]);
    final latches = <String, int>{};
    final history = _imageHistory(12);
    final messages = await _run(fake, latches: latches);

    expect(fake.calls, 1, reason: 'no recovery under the kill switch');
    expect(latches, isEmpty, reason: 'no cap logic at all');
    // Byte-identical legacy shape: every original image rides raw, no
    // `[Image N]` assembly happened.
    final sent = fake.contexts.single.messages;
    expect(_uniqueImageCount(sent), 12);
    // The 12 history messages plus the current 'go' prompt, untouched.
    expect(sent.length, history.length + 1);
    expect(_carriesImageData(sent, 'img0'), isTrue);
    expect(_carriesImageData(sent, 'img11'), isTrue);
    expect(learnedNotices, isEmpty);
    final assistant = messages.whereType<AssistantMessage>().last;
    expect(assistant.stopReason, StopReason.error);
  });

  test('IT-5 (E2): a latch for model A never constrains model B', () async {
    final fake = _FakeStreamFunction([
      _imageCapRefusalTurn(_refusal),
      _textTurn('recovered'),
    ]);
    final latches = <String, int>{};
    await _run(fake, latches: latches);
    expect(latches, {'copilot|undocumented-vision': 10});

    // A mid-run /model switch to another pair: the same run-lifetime map.
    final otherFake = _FakeStreamFunction([_textTurn('ok')]);
    await _run(otherFake, model: _model('other-vision'), latches: latches);
    expect(
      _uniqueImageCount(otherFake.contexts.single.messages),
      12,
      reason: 'the new model rides the global default, not model A latch',
    );
  });

  test('IT-6 (E3): a degenerate learned cap (is 0) never re-sends', () async {
    final fake = _FakeStreamFunction([
      _imageCapRefusalTurn(
        'error: 400: too many images: maximum allowed for model '
        'undocumented-vision is 0, got 15',
      ),
      _textTurn('unreachable'),
    ]);
    final messages = await _run(fake);

    expect(fake.calls, 1, reason: 'cap < 1 is refusal-family only');
    final assistant = messages.whereType<AssistantMessage>().last;
    expect(assistant.stopReason, StopReason.error);
  });

  test('IT-7 (E5): the re-send rebuilds through the registry at the latched '
      'cap, never a stale payload', () async {
    final fake = _FakeStreamFunction([
      _imageCapRefusalTurn(_refusal),
      _textTurn('recovered'),
    ]);
    // An image arriving between the first send and the re-send: the
    // transform hook injects it into the SECOND request build only.
    var builds = 0;
    Future<List<Message>> transform(
      List<Message> messages,
      CancelToken? token,
    ) async {
      builds++;
      if (builds == 2) {
        return [
          ...messages,
          UserMessage(
            content: [ImageContent(data: 'late', mimeType: 'image/png')],
            timestamp: DateTime.utc(2026, 1, 2),
          ),
        ];
      }
      return messages;
    }

    final messages = await runAgentLoop(
      prompts: [UserMessage.text('go')],
      context: Context(messages: _imageHistory(12)),
      config: AgentLoopConfig(
        model: _model('undocumented-vision'),
        transformContext: transform,
      ),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => const ToolExecutionResult(content: []),
      emit: (_) {},
    );

    expect(fake.calls, 2);
    // The late image rode the re-send (fresh rebuild, not a stale copy)
    // and the payload still respects the learned cap of 10 uniques.
    final sent = fake.contexts.last.messages;
    expect(_carriesImageData(sent, 'late'), isTrue);
    expect(_uniqueImageCount(sent), 10);
    final assistant = messages.whereType<AssistantMessage>().last;
    expect(assistant.stopReason, StopReason.stop);
  });

  test('REG-1: no config, no catalog entry — the request carries up to 20, '
      'exactly today\u2019s shape', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    await _run(fake);
    expect(fake.calls, 1);
    // 12 uniques < global default 20: all ride, no drops, no notices.
    expect(_uniqueImageCount(fake.contexts.single.messages), 12);
    expect(dropNotices, isEmpty);
    expect(learnedNotices, isEmpty);
  });
}
