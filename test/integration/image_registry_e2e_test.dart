/// Session image registry (issue #171) integration tests: a real agent
/// loop over a scripted fake provider, asserting the OUTGOING request
/// shape (send-once, refs, kill switch, compaction interplay).
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 1000000,
  maxTokens: 4096,
);

AssistantMessage _assistantText(String text) => AssistantMessage(
      content: [TextContent(text: text)],
      api: 'test-api',
      provider: 'test-provider',
      model: 'test-model',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    );

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistantText('');
  final partial = _assistantText(text);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// Records every context the loop sends.
class _CapturingStream {
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(Context(
      systemPrompt: context.systemPrompt,
      messages: List.of(context.messages),
      tools: context.tools,
    ));
    final stream = AssistantMessageEventStream();
    for (final event in _textTurn('ok')) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

int _imageParts(List<Message> messages) {
  var count = 0;
  for (final message in messages) {
    if (message is UserMessage && message.content is List<ContentBlock>) {
      count += (message.content as List<ContentBlock>)
          .whereType<ImageContent>()
          .length;
    } else if (message is ToolResultMessage) {
      count += message.content.whereType<ImageContent>().length;
    }
  }
  return count;
}

int _occurrences(String haystack, String needle) {
  var count = 0;
  for (var i = haystack.indexOf(needle);
      i != -1;
      i = haystack.indexOf(needle, i + needle.length)) {
    count++;
  }
  return count;
}

String _serialized(List<Message> messages) =>
    jsonEncode([for (final m in messages) m.toJson()]);

/// A 50-turn history alternating among three unique images (the
/// photo-heavy homework thread from the card).
List<Message> _photoHeavyHistory() {
  final messages = <Message>[];
  for (var i = 0; i < 50; i++) {
    messages.add(UserMessage(
      content: [
        TextContent(text: 'problem $i'),
        ImageContent(data: 'unique${i % 3}', mimeType: 'image/png'),
      ],
      timestamp: DateTime.utc(2026, 1, 1, 0, i),
    ));
    messages.add(_assistantText('solved $i'));
  }
  return messages;
}

Future<Context> _runOnce(List<Message> history, List<UserMessage> prompts) async {
  final fake = _CapturingStream();
  await agentLoop(
    prompts: prompts,
    context: Context(systemPrompt: 'sys', messages: history),
    config: const AgentLoopConfig(model: _model),
    streamFunction: fake.call,
    toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
  ).result;
  return fake.contexts.single;
}

void main() {
  setUp(() => imageRegistryConfig = const ImageRegistryConfig());
  tearDown(() => imageRegistryConfig = const ImageRegistryConfig());

  test('photo-heavy session: each unique image rides once (AC1)', () async {
    final request = await _runOnce(_photoHeavyHistory(), [
      UserMessage.text('grade them all'),
    ]);
    // Three uniques — three image parts total, each payload exactly once.
    expect(_imageParts(request.messages), 3);
    final serialized = _serialized(request.messages);
    for (var i = 0; i < 3; i++) {
      expect(_occurrences(serialized, 'unique$i'), 1);
    }
    // History occurrences became refs; every ref resolves (I4): the label
    // count matches carriers + refs.
    expect(_occurrences(serialized, '[Image 0]'), greaterThan(1));
    expect(_occurrences(serialized, unavailableImageNote), 0);
  });

  test('current message image rides in place even when known (AC6/I3)',
      () async {
    final history = [
      UserMessage(
        content: const [
          TextContent(text: 'earlier'),
          ImageContent(data: 'same', mimeType: 'image/png'),
        ],
        timestamp: DateTime.utc(2026),
      ),
    ];
    final request = await _runOnce(history, [
      UserMessage(
        content: const [
          TextContent(text: 'this exact one again'),
          ImageContent(data: 'same', mimeType: 'image/png'),
        ],
        timestamp: DateTime.utc(2026, 1, 2),
      ),
    ]);
    expect(_imageParts(request.messages), 1);
    final last = request.messages.last as UserMessage;
    expect(
      (last.content as List<ContentBlock>).whereType<ImageContent>(),
      isNotEmpty,
    );
    // The history occurrence is a ref pointing at the current part.
    final serialized = _serialized(request.messages);
    expect(_occurrences(serialized, 'same'), 1);
    expect(_occurrences(serialized, '[Image 0]'), 1);
  });

  test('kill switch reproduces the legacy request shape byte-for-byte (AC5)',
      () async {
    final history = _photoHeavyHistory();
    final prompts = [UserMessage.text('grade them all')];

    imageRegistryConfig = const ImageRegistryConfig(enabled: false);
    final legacy = await _runOnce(history, prompts);
    expect(_imageParts(legacy.messages), 50);

    // Byte-for-byte: identical to serializing the unrewritten inputs.
    final expected = _serialized([...history, ...prompts]);
    expect(_serialized(legacy.messages), expected);
  });

  test('compaction: evicted originals leave no dangling refs (AC4)',
      () async {
    // Post-compaction window: the summary mentions an image whose
    // original is outside the kept window.
    final request = await _runOnce([
      UserMessage.text(
        'Summary of earlier turns: the user shared [Image 1] and we '
        'discussed it.',
      ),
    ], [
      UserMessage.text('continue'),
    ]);
    final serialized = _serialized(request.messages);
    expect(_occurrences(serialized, '[Image 1]'), 0);
    expect(_occurrences(serialized, unavailableImageNote), 1);
  });

  test('determinism: two loads of one JSONL build identical requests (AC2)',
      () async {
    final history = _photoHeavyHistory();
    final dump = jsonEncode([for (final m in history) m.toJson()]);
    List<Message> load() => [
          for (final json in (jsonDecode(dump) as List))
            messageFromJson(json as Map<String, dynamic>),
        ];
    final prompt = UserMessage(content: 'go', timestamp: DateTime.utc(2026, 2));
    final first = await _runOnce(load(), [prompt]);
    final second = await _runOnce(load(), [prompt]);
    expect(_serialized(second.messages), _serialized(first.messages));
  });
}
