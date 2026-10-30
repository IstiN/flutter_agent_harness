import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

DateTime _ts() => DateTime.utc(2026);

ToolResultMessage _videoResult(String id, {required bool withVideo}) =>
    ToolResultMessage(
      toolCallId: id,
      toolName: 'read',
      isError: false,
      content: [
        const TextContent(text: '[Video: clip.mp4]'),
        if (withVideo)
          const VideoContent(data: 'aGk=', mimeType: 'video/mp4'),
      ],
      timestamp: _ts(),
    );

void main() {
  test('AC7 — a video payload reports as carrying image bytes', () {
    final messages = [
      UserMessage.text('read it', timestamp: _ts()),
      _videoResult('call_1', withVideo: true),
    ];
    expect(payloadCarriesImageBytes(messages), isTrue);
  });

  test('text-only payloads still report no image bytes', () {
    final messages = [
      UserMessage.text('plain', timestamp: _ts()),
      _videoResult('call_2', withVideo: false),
    ];
    expect(payloadCarriesImageBytes(messages), isFalse);
  });

  test('AC7 — a video-only session keeps the image-free fast path: the '
      'caller list is returned untouched (same instance)', () {
    final messages = <Message>[
      UserMessage.text('read it', timestamp: _ts()),
      _videoResult('call_3', withVideo: true),
    ];
    final rewritten = rewriteHistoryImages(messages);
    expect(identical(rewritten, messages), isTrue);
    expect(
      rewritten.whereType<ToolResultMessage>().single.content
          .whereType<VideoContent>(),
      hasLength(1),
    );
  });

  test('AC7 — the strip-all latch strips video blocks with the '
      '[image dropped] placeholder and stops the payload from carrying '
      'media bytes', () {
    final messages = <Message>[
      UserMessage.text('read it', timestamp: _ts()),
      _videoResult('call_4', withVideo: true),
    ];
    ImageDropReport? report;
    final rewritten = rewriteHistoryImages(
      messages,
      stripAll: true,
      onReport: (r) => report = r,
    );
    expect(report, isNotNull); // the rewrite engaged
    expect(report!.drops, isEmpty); // videos never pool — no image drops
    final toolResult = rewritten.whereType<ToolResultMessage>().single;
    expect(toolResult.content.whereType<VideoContent>(), isEmpty);
    expect(
      toolResult.content
          .whereType<TextContent>()
          .any((block) => block.text.contains('tool video omitted')),
      isTrue,
    );
    expect(payloadCarriesImageBytes(rewritten), isFalse);
  });

  test('AC7 — strip-all with both an image and a video strips BOTH', () {
    final messages = <Message>[
      UserMessage(
        content: const [ImageContent(data: 'aW1n', mimeType: 'image/png')],
        timestamp: _ts(),
      ),
      _videoResult('call_5', withVideo: true),
    ];
    final rewritten = rewriteHistoryImages(messages, stripAll: true);
    expect(payloadCarriesImageBytes(rewritten), isFalse);
    expect(
      rewritten.whereType<UserMessage>().any(
            (message) =>
                message.content is List &&
                (message.content as List)
                    .whereType<ImageContent>()
                    .isNotEmpty,
          ),
      isFalse,
    );
  });
}
