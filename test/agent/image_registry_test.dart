/// Per-session image registry tests — issue #155 work package E.
///
/// Port of learn.ai's global `[Image N]` indexing: on request build, every
/// image content block except its unique carrier is replaced by a short
/// text reference, so a photo from 50 turns ago costs a reference, not a
/// re-upload. Uniqueness is exact-content dedup; priority is
/// newest-occurrence-first with a hard cap and an explicit skip note.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

UserMessage _imageMessage(
  String text,
  List<(String, String)> images, {
  DateTime? timestamp,
}) {
  return UserMessage(
    content: [
      TextContent(text: text),
      for (final (data, mime) in images)
        ImageContent(data: data, mimeType: mime),
    ],
    timestamp: timestamp ?? DateTime.utc(2026),
  );
}

ToolResultMessage _imageToolResult(String callId, String data) {
  return ToolResultMessage(
    toolCallId: callId,
    toolName: 'inspect_image',
    content: [ImageContent(data: data, mimeType: 'image/png')],
    isError: false,
    timestamp: DateTime.utc(2026),
  );
}

AssistantMessage _assistantText(String text) {
  return AssistantMessage(
    content: [TextContent(text: text)],
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

NeverCallStream neverCallStream = NeverCallStream();

class NeverCallStream {
  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) => throw StateError('not streamed in this test');
}

void main() {
  group('applyImageRegistry', () {
    test('the same image sent 3x rides exactly once', () {
      const data = 'aGVsbG8=';
      final messages = [
        _imageMessage('first', [(data, 'image/png')]),
        _assistantText('ok'),
        _imageMessage('second', [(data, 'image/png')]),
        _assistantText('ok'),
        _imageMessage('third', [(data, 'image/png')]),
      ];

      final rewritten = applyImageRegistry(messages);

      // Byte-count assert on the serialized provider payload: the base64
      // body appears exactly once across the whole context.
      final serialized = _serialize(rewritten);
      expect(_countOccurrences(serialized, data), 1);
      // One carrier label + two duplicate references.
      expect(_countOccurrences(serialized, '[Image 0]'), 3);
    });

    test('distinct images get distinct stable indexes', () {
      final messages = [
        _imageMessage('a', [('QQ==', 'image/png')]),
        _assistantText('ok'),
        _imageMessage('b', [('Ag==', 'image/jpeg')]),
      ];

      final serialized = _serialize(applyImageRegistry(messages));

      // First chronological occurrence carries the bytes, labeled; both
      // indexes assigned in first-occurrence order (stable across turns).
      expect(_countOccurrences(serialized, '[Image 0]'), 1);
      expect(_countOccurrences(serialized, '[Image 1]'), 1);
      expect(_countOccurrences(serialized, 'QQ=='), 1);
      expect(_countOccurrences(serialized, 'Ag=='), 1);
    });

    test('over the cap, newest images win and skips are reported', () {
      final messages = [
        for (var i = 0; i < 10; i++) ...[
          _imageMessage('m$i', [('BASE$i', 'image/png')]),
          _assistantText('ok'),
        ],
      ];
      final skips = <String>[];

      final rewritten = applyImageRegistry(
        messages,
        maxImages: 4,
        onSkip: skips.add,
      );

      final serialized = _serialize(rewritten);
      // The 4 newest images (6..9) ride as bytes.
      for (var i = 6; i <= 9; i++) {
        expect(_countOccurrences(serialized, 'BASE$i'), 1);
      }
      // The 6 oldest are referenced-but-absent.
      for (var i = 0; i <= 5; i++) {
        expect(_countOccurrences(serialized, 'BASE$i'), 0);
      }
      // Every drop is named — never random, never silent.
      expect(skips, hasLength(6));
      for (var i = 0; i <= 5; i++) {
        expect(skips.join('\n'), contains('[Image $i]'));
      }
    });

    test('tool-result images are deduped against user images', () {
      const data = 'QQ==';
      final messages = [
        _imageMessage('look', [(data, 'image/png')]),
        _assistantText('ok'),
        _imageToolResult('c1', data),
      ];

      final serialized = _serialize(applyImageRegistry(messages));

      expect(_countOccurrences(serialized, data), 1);
      expect(_countOccurrences(serialized, '[Image 0]'), 2);
    });

    test('a text-only context is returned unchanged', () {
      final messages = [UserMessage.text('hi', timestamp: DateTime.utc(2026))];
      final rewritten = applyImageRegistry(messages);
      expect(identical(rewritten, messages), isTrue);
    });

    test('duplicate occurrences inside one message collapse too', () {
      const data = 'QQ==';
      final messages = [
        _imageMessage('twin', [(data, 'image/png'), (data, 'image/png')]),
      ];
      final serialized = _serialize(applyImageRegistry(messages));
      expect(_countOccurrences(serialized, data), 1);
      expect(_countOccurrences(serialized, '[Image 0]'), 2);
    });
  });

  group('imageRegistryTransform', () {
    test('rewrites only the request payload, never the input list', () async {
      const data = 'QQ==';
      final transcript = <Message>[
        _imageMessage('one', [(data, 'image/png')]),
        _assistantText('ok'),
        _imageMessage('two', [(data, 'image/png')]),
      ];

      final payload = await imageRegistryTransform(transcript, null);

      // The transcript keeps both originals.
      expect(
        ((transcript[0] as UserMessage).content as List<ContentBlock>)
            .whereType<ImageContent>(),
        hasLength(1),
      );
      expect(
        ((transcript[2] as UserMessage).content as List<ContentBlock>)
            .whereType<ImageContent>(),
        hasLength(1),
      );
      // The outbound payload carries the image once.
      final serialized = _serialize(payload);
      expect(_countOccurrences(serialized, data), 1);
      expect(_countOccurrences(serialized, '[Image 0]'), 2);
    });
  });

  group('attachImageRegistry', () {
    test('installs a transformContext hook on the agent', () {
      final agent = Agent(
        model: const Model(
          id: 'm',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 100000,
          maxTokens: 4096,
        ),
        streamFunction: neverCallStream,
        toolRegistry: ToolRegistry(),
      );
      expect(agent.transformContext, isNull);
      attachImageRegistry(agent);
      expect(agent.transformContext, isNotNull);
    });

    test('chains after an existing transform hook', () async {
      var calls = 0;
      final agent = Agent(
        model: const Model(
          id: 'm',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 100000,
          maxTokens: 4096,
        ),
        streamFunction: neverCallStream,
        toolRegistry: ToolRegistry(),
        transformContext: (messages, cancelToken) async {
          calls++;
          return messages;
        },
      );
      attachImageRegistry(agent);
      const data = 'QQ==';
      final out = await agent.transformContext!(
        <Message>[
          _imageMessage('one', [(data, 'image/png')]),
          _imageMessage('two', [(data, 'image/png')]),
        ],
        null,
      );
      // The pre-existing hook ran, and the image registry still applied.
      expect(calls, 1);
      expect(_countOccurrences(_serialize(out), data), 1);
    });
  });
}

String _serialize(List<Message> messages) =>
    [for (final m in messages) jsonEncode(m.toJson())].join('\n');

int _countOccurrences(String haystack, String needle) =>
    needle.allMatches(haystack).length;
