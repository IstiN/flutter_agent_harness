// gh-1934 ITs — the 413 image-payload recovery ladder in the agent loop:
//
// - AC1: a provider with a 5MB cap rejecting an 8-image (~23MB) payload
//   recovers on the ladder's pass 1 (drop oldest until under the adaptive
//   budget); the turn completes and the model sees the recovery note;
// - AC2: a poisoned session behind a compaction boundary sends ZERO image
//   bytes on its first request (the eviction rides the request build);
// - AC4: the ladder is bounded at 2 recovery passes; each 413 halves the
//   adaptive budget; a still-failing provider yields ONE actionable
//   failure notice and the error surfaces;
// - AC5: the learned budget rides SUBSEQUENT requests of the same session
//   state (config honored when lower);
// - AC6: text-only sessions never engage the ladder.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _tooLarge = 'error: 413: Request Entity Too Large';

/// A provider whose real payload cap is 5MB: any request whose IMAGE bytes
/// exceed it is refused with the 413; everything else succeeds.
class _CappedProvider {
  _CappedProvider(this.capBytes);

  final int capBytes;
  final contexts = <Context>[];
  final errors = <String>[];

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
    final imageBytes = _imageBytes(context.messages);
    final stream = AssistantMessageEventStream();
    if (imageBytes > capBytes) {
      errors.add('$imageBytes');
      final msg = _assistant(
        stopReason: StopReason.error,
        errorMessage: _tooLarge,
      );
      stream
        ..push(StartEvent(partial: msg))
        ..push(ErrorEvent(reason: StopReason.error, error: msg));
    } else {
      final empty = _assistant();
      final partial = _assistant(content: [const TextContent(text: 'done')]);
      stream
        ..push(StartEvent(partial: empty))
        ..push(TextStartEvent(contentIndex: 0, partial: empty))
        ..push(TextDeltaEvent(contentIndex: 0, delta: 'done', partial: partial))
        ..push(DoneEvent(reason: StopReason.stop, message: partial));
    }
    stream.end();
    return stream;
  }
}

Model _model() => Model(
  id: 'vision',
  api: 'test-api',
  provider: 'copilot',
  baseUrl: 'https://example.test',
  input: const ['text', 'image'],
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
}) => AssistantMessage(
  content: content,
  api: 'test-api',
  provider: 'copilot',
  model: 'vision',
  usage: Usage.zero,
  stopReason: stopReason,
  errorMessage: errorMessage,
  timestamp: DateTime.utc(2026),
);

/// 8 synthetic inline PNG blocks with realistic byte counts (~3MB of
/// base64 each — the original repro's shape), riding as tool results the
/// way `read` delivers screenshots.
List<Message> _poisonedHistory({int count = 8, int bytes = 3 * 1000 * 1000}) => [
  for (var i = 0; i < count; i++)
    ToolResultMessage(
      toolCallId: 't$i',
      toolName: 'read',
      content: [ImageContent(data: 'x' * bytes, mimeType: 'image/png')],
      isError: false,
      timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0, i * 1000),
    ),
];

int _imageBytes(List<Message> messages) {
  var total = 0;
  for (final message in messages) {
    final blocks = switch (message) {
      UserMessage(:final content) when content is List<ContentBlock> =>
        content,
      ToolResultMessage(:final content) => content,
      _ => const <ContentBlock>[],
    };
    for (final block in blocks) {
      if (block is ImageContent) total += block.data.length;
    }
  }
  return total;
}

/// Every text payload of the request, joined — the assertion surface for
/// notes and placeholders (Message has no content-bearing toString).
String _texts(List<Message> messages) => [
  for (final message in messages)
    ...switch (message) {
      UserMessage(:final content) when content is String => [content],
      UserMessage(:final content) when content is List<ContentBlock> => [
        for (final b in content)
          if (b is TextContent) b.text,
      ],
      ToolResultMessage(:final content) => [
        for (final b in content)
          if (b is TextContent) b.text,
      ],
      AssistantMessage(:final content) => [
        for (final b in content)
          if (b is TextContent) b.text,
      ],
      _ => const <String>[],
    },
].join('\n');

Future<List<Message>> _run(
  _CappedProvider provider, {
  List<Message>? history,
  ImagePayloadRecoveryState? recovery,
  ImageRegistryConfig? config,
  bool always413 = false,
}) => runAgentLoop(
  prompts: [UserMessage.text('continue')],
  context: Context(messages: history ?? _poisonedHistory()),
  config: AgentLoopConfig(
    model: _model(),
    imageRecovery: recovery,
  ),
  streamFunction: always413 ? _always413(provider) : provider.call,
  toolExecutor: (_, _, _) async => const ToolExecutionResult(content: []),
  emit: (_) {},
);

AssistantMessageEventStream Function(Model, Context, {CancelToken?})
_always413(_CappedProvider provider) => (model, context, {cancelToken}) {
  final stream = AssistantMessageEventStream();
  provider.contexts.add(context);
  final msg = _assistant(
    stopReason: StopReason.error,
    errorMessage: _tooLarge,
  );
  stream
    ..push(StartEvent(partial: msg))
    ..push(ErrorEvent(reason: StopReason.error, error: msg));
  stream.end();
  return stream;
};

void main() {
  var savedConfig = const ImageRegistryConfig();
  ImageRecoveryNotice? savedNotice;
  final recoveryEvents = <ImageRecoveryEvent>[];

  setUp(() {
    savedConfig = imageRegistryConfig;
    savedNotice = imageRecoveryNotice;
    imageRegistryConfig = const ImageRegistryConfig();
    recoveryEvents.clear();
    imageRecoveryNotice = recoveryEvents.add;
  });
  tearDown(() {
    imageRegistryConfig = savedConfig;
    imageRecoveryNotice = savedNotice;
  });

  test('IT-1 (AC1): the 5MB-capped ladder converges — drop pass, recovery '
      'note rides the retry', () async {
    final provider = _CappedProvider(5 * 1000 * 1000);
    final recovery = ImagePayloadRecoveryState();
    final messages = await _run(provider, recovery: recovery);

    // Converged: the turn completed.
    final assistant = messages.whereType<AssistantMessage>().last;
    expect(assistant.stopReason, StopReason.stop);
    expect(assistant.errorMessage, isNull);

    // Requests stopped carrying >5MB of images from the first retry on.
    for (final context in provider.contexts.skip(1)) {
      expect(_imageBytes(context.messages), lessThanOrEqualTo(5 * 1000 * 1000));
    }
    // Pass 1 halved 8MB → 4MB; one ~3MB image still fits.
    expect(provider.contexts, hasLength(2));
    expect(_imageBytes(provider.contexts.last.messages), lessThanOrEqualTo(4 * 1000 * 1000));

    // The recovery note rode the retry payload (AC1: the assistant answer
    // can note the recovery).
    expect(
      _texts(provider.contexts.last.messages),
      contains('recovered from 413'),
    );
    // The host notice fired once for pass 1 with real counts.
    expect(recoveryEvents, hasLength(1));
    expect(recoveryEvents.single.pass, 1);
    expect(recoveryEvents.single.dropped, 7);
    expect(recoveryEvents.single.stripped, 0);
    expect(recoveryEvents.single.failed, isFalse);
  });

  test('IT-2 (AC2): a compacted poisoned session sends ZERO image bytes',
      () async {
    final provider = _CappedProvider(5 * 1000 * 1000);
    final boundary =
        '$compactionSummaryPrefixOld work.$compactionSummarySuffix';
    final history = [
      UserMessage.text(boundary),
      ..._poisonedHistory(),
    ];
    await _run(provider, history: history);

    expect(provider.contexts, hasLength(1));
    expect(
      _imageBytes(provider.contexts.single.messages),
      0,
      reason: 'the boundary evicts every history image from the payload',
    );
    expect(
      _texts(provider.contexts.single.messages),
      contains('[image dropped: '),
      reason: 'placeholders replace the bytes',
    );
  });

  test('IT-3 (AC3): the transcript messages are never mutated by recovery',
      () async {
    final provider = _CappedProvider(5 * 1000 * 1000);
    final history = _poisonedHistory();
    final imageCount = _imageBytes(history);

    await _run(provider, history: history, recovery: ImagePayloadRecoveryState());

    expect(_imageBytes(history), imageCount,
        reason: 'the live transcript keeps the bytes (session JSONL invariant)');
  });

  test('IT-4 (AC4): the ladder is bounded — 2 passes, halved budget, ONE '
      'actionable failure, then a latched image-free session', () async {
    final provider = _CappedProvider(5 * 1000 * 1000);
    final recovery = ImagePayloadRecoveryState();
    final messages = await _run(
      provider,
      recovery: recovery,
      always413: true,
    );

    // Original + pass 1 + pass 2 = 3 sends, never a fourth.
    expect(provider.contexts, hasLength(3));
    final assistant = messages.whereType<AssistantMessage>().last;
    expect(assistant.stopReason, StopReason.error);
    expect(assistant.errorMessage, contains('413'));

    // Each 413 halved the budget: 8MB → 4MB → 2MB.
    expect(
      recovery.effectiveByteBudget(imageRegistryConfig.maxBytesPerRequest),
      2 * 1000 * 1000,
    );
    // Pass 2 latched the strip-all.
    expect(recovery.stripAll, isTrue);
    // The last payload carried zero image bytes.
    expect(_imageBytes(provider.contexts.last.messages), 0);

    // ONE actionable failure notice; pass notices for 1 and 2.
    final failed = recoveryEvents.where((e) => e.failed).toList();
    expect(failed, hasLength(1));
    expect(failed.single.providerError, contains('413'));
    expect(
      recoveryEvents.where((e) => !e.failed).map((e) => e.pass),
      [1, 2],
    );

    // A follow-up turn in the SAME session state rides the latch: no
    // images on the wire, no ladder, no new failure notice (no
    // compaction⇄413 cycles).
    final countBefore = recoveryEvents.length;
    final followUp = _CappedProvider(5 * 1000 * 1000);
    final followUpMessages = await _run(
      followUp,
      history: [UserMessage.text('still there?')],
      recovery: recovery,
    );
    expect(followUp.contexts, hasLength(1));
    expect(_imageBytes(followUp.contexts.single.messages), 0);
    expect(recoveryEvents, hasLength(countBefore));
    final done = followUpMessages.whereType<AssistantMessage>().last;
    expect(done.stopReason, StopReason.stop);
  });

  test('IT-5 (AC5): the learned budget rides subsequent requests — config '
      'still honored when lower', () async {
    final provider = _CappedProvider(5 * 1000 * 1000);
    final recovery = ImagePayloadRecoveryState();
    await _run(provider, recovery: recovery);
    // Learned: half of the configured 8MB.
    expect(
      recovery.effectiveByteBudget(imageRegistryConfig.maxBytesPerRequest),
      4 * 1000 * 1000,
    );

    // A later request with a heavier image than the learned budget drops
    // it pre-emptively (byte drop, no 413 needed).
    final later = _CappedProvider(5 * 1000 * 1000);
    var drops = <ImageDropEvent>[];
    final saved = imageDropReportNotice;
    imageDropReportNotice = (r) => drops = r.drops;
    try {
      await _run(
        later,
        history: [
          ToolResultMessage(
            toolCallId: 't0',
            toolName: 'read',
            content: [
              ImageContent(data: 'y' * (5 * 1000 * 1000), mimeType: 'image/png'),
            ],
            isError: false,
            timestamp: DateTime.utc(2026, 1, 1),
          ),
        ],
        recovery: recovery,
      );
    } finally {
      imageDropReportNotice = saved;
    }
    expect(_imageBytes(later.contexts.single.messages),
        lessThanOrEqualTo(4 * 1000 * 1000));
    expect(drops.map((d) => d.reason), everyElement(ImageDropReason.bytes));

    // A LOWER configured value wins over the learned budget (AC5).
    expect(recovery.effectiveByteBudget(1024), 1024);
    // A disabled (0) configured budget cannot raise the learned one.
    expect(recovery.effectiveByteBudget(0), 4 * 1000 * 1000);
  });

  test('IT-6 (AC6): a text-only session never engages the ladder', () async {
    final provider = _CappedProvider(5 * 1000 * 1000);
    final messages = await _run(
      provider,
      history: [UserMessage.text('plain text only')],
      recovery: ImagePayloadRecoveryState(),
      always413: true,
    );

    expect(provider.contexts, hasLength(1), reason: 'no recovery passes');
    final assistant = messages.whereType<AssistantMessage>().last;
    expect(assistant.stopReason, StopReason.error);
    expect(recoveryEvents, isEmpty);
  });

  test('the kill switch disables the ladder entirely', () async {
    imageRegistryConfig = const ImageRegistryConfig(enabled: false);
    final provider = _CappedProvider(5 * 1000 * 1000);
    final messages = await _run(
      provider,
      recovery: ImagePayloadRecoveryState(),
      always413: true,
    );

    expect(provider.contexts, hasLength(1));
    final assistant = messages.whereType<AssistantMessage>().last;
    expect(assistant.stopReason, StopReason.error);
    expect(recoveryEvents, isEmpty);
  });
}
