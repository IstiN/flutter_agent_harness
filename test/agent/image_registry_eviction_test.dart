// gh-1934 — compaction image eviction + 413 strip, the payload-only
// rewrite pieces of the request build:
//
// - image blocks OUTSIDE the kept region — first seen before the LAST
//   renumbering boundary (compaction summary / branch summary / trim
//   valve / structured marker) — evict to an
//   `[image dropped: <key preview>]` text placeholder (AC2). Kept-region
//   images ride on under the normal caps (gh-195 F2 pins their recency
//   selection); the current user message keeps riding its images in
//   place (I3);
// - the recovery strip-all (413 ladder pass 2) evicts EVERY image block
//   period, current message included;
// - session-latched evicted keys never ride again;
// - placeholders count in token accounting (the rewritten payload's
//   estimate drops with the bytes);
// - the input messages are never mutated (AC3 — the session JSONL keeps
//   the bytes).

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _boundaryText = '$compactionSummaryPrefix'
    'Earlier work happened.$compactionSummarySuffix';

UserMessage _imageUser(String data, {DateTime? timestamp}) => UserMessage(
  content: [ImageContent(data: data, mimeType: 'image/png')],
  timestamp: timestamp ?? DateTime.utc(2026),
);

ToolResultMessage _imageResult(String id, String data) => ToolResultMessage(
  toolCallId: id,
  toolName: 'read',
  content: [ImageContent(data: data, mimeType: 'image/png')],
  isError: false,
  timestamp: DateTime.utc(2026, 1, 1),
);

/// Every text payload of the request, joined (Message has no
/// content-bearing toString).
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
      _ => const <String>[],
    },
].join('\n');

List<ImageContent> _imagesOf(List<Message> messages) => [
  for (final message in messages)
    ...switch (message) {
      UserMessage(:final content) when content is List<ContentBlock> =>
        content.whereType<ImageContent>(),
      ToolResultMessage(:final content) => content.whereType<ImageContent>(),
      _ => <ImageContent>[],
    },
];

void main() {
  group('gh-1934 AC2: compaction boundary eviction', () {
    test('a compaction summary evicts every history image to placeholders',
        () {
      final history = [
        UserMessage.text('look at this'),
        _imageResult('t1', 'a' * 1000),
        _imageUser('b' * 1000),
      ];
      final window = [
        UserMessage.text(_boundaryText),
        ...history,
        UserMessage.text('now summarize'),
      ];

      final out = rewriteHistoryImages(window);

      expect(_imagesOf(out), isEmpty,
          reason: 'ZERO image bytes ride after compaction (AC2)');
      expect(
        out.any(
          (m) =>
              m is ToolResultMessage &&
              m.content.any(
                (b) =>
                    b is TextContent &&
                    b.text.startsWith('[image dropped: '),
              ),
        ),
        isTrue,
        reason: 'the evicted read image becomes the placeholder text',
      );
      // The placeholder names the content-key preview the /images surface
      // uses — same identifier, no silent rebinding (AC7).
      expect(
        out.any(
          (m) =>
              m is UserMessage &&
              m.content is List<ContentBlock> &&
              (m.content as List<ContentBlock>).any(
                (b) =>
                    b is TextContent &&
                    RegExp(r'^\[image dropped: [0-9a-f]{8}\]$').hasMatch(b.text),
              ),
        ),
        isTrue,
      );
    });

    test('the current user message still rides its images in place (I3)', () {
      final window = [
        UserMessage.text(_boundaryText),
        _imageResult('t1', 'a' * 1000),
        _imageUser('current-image'),
      ];

      final out = rewriteHistoryImages(window);

      final last = out.whereType<UserMessage>().last;
      expect(
        (last.content as List<ContentBlock>).whereType<ImageContent>().single.data,
        'current-image',
      );
      // The history occurrence of the same payload would be evicted; the
      // current one carries its fresh [Image N] label (F3) — first-seen
      // order makes the current image index 1 (the evicted one is 0).
      expect(
        (last.content as List<ContentBlock>)
            .whereType<TextContent>()
            .any((b) => b.text == '[Image 1]'),
        isTrue,
      );
    });

    test('no boundary in the window — history images ride as before', () {
      final window = [
        _imageUser('a' * 1000, timestamp: DateTime.utc(2026, 1, 1)),
        UserMessage.text('go'),
      ];

      final out = rewriteHistoryImages(window);

      expect(_imagesOf(out), hasLength(1), reason: 'first ride via carrier');
    });

    test('eviction is reported, never silent (evicted reason)', () {
      final window = [
        UserMessage.text(_boundaryText),
        _imageResult('t1', 'a' * 1000),
        UserMessage.text('go'),
      ];
      ImageDropReport? report;
      rewriteHistoryImages(window, onReport: (r) => report = r);

      expect(report, isNotNull);
      expect(report!.drops, hasLength(1));
      expect(report!.drops.single.reason, ImageDropReason.evicted);
      expect(report!.evictedCount, 1);
    });

    test('structured markers and local-trim notes evict too', () {
      for (final boundary in [
        UserMessage.text('[context trimmed locally: tokens]'),
        UserMessage.text(
          '$branchSummaryPrefix branch work$branchSummarySuffix',
        ),
      ]) {
        final window = [
          boundary,
          _imageUser('a' * 1000),
          UserMessage.text('go'),
        ];
        final out = rewriteHistoryImages(window);
        expect(_imagesOf(out), isEmpty, reason: 'boundary: ${boundary.content}');
      }
    });
  });

  group('gh-1934: recovery strip-all (ladder pass 2)', () {
    test('stripAll evicts every image period, current message included', () {
      final window = [
        UserMessage.text(_boundaryText),
        _imageResult('t1', 'a' * 1000),
        _imageUser('current-image'),
        UserMessage.text('retry'),
      ];

      final out = rewriteHistoryImages(window, stripAll: true);

      expect(_imagesOf(out), isEmpty);
      // No carriers were inserted: the message count is unchanged.
      expect(out.length, window.length);
    });

    test('stripAll is reported with the stripped count', () {
      final window = [
        _imageResult('t1', 'a' * 1000),
        _imageUser('b' * 1000),
        _imageUser('b' * 1000), // duplicate payload — unique count is 2
        UserMessage.text('retry'),
      ];
      ImageDropReport? report;
      rewriteHistoryImages(window, stripAll: true, onReport: (r) => report = r);

      expect(report!.strippedCount, 2, reason: 'unique images, not blocks');
    });

    test('mentions degrade to the note — no silent rebinding (AC7)', () {
      final window = [
        _imageUser('a' * 1000),
        UserMessage.text('what does [Image 0] show?'),
      ];

      final out = rewriteHistoryImages(window, stripAll: true);

      expect(
        out.whereType<UserMessage>().last.content,
        contains(unavailableImageNote),
      );
      expect(_texts(out), isNot(contains('[Image 0]')));
    });
  });

  group('gh-1934: session-latched evicted keys', () {
    test('an evicted key never rides again, boundary or not', () {
      final key = imageContentKey(ImageContent(data: 'a' * 1000, mimeType: 'image/png'));
      final window = [
        _imageUser('a' * 1000, timestamp: DateTime.utc(2026, 1, 1)),
        _imageUser('b' * 1000, timestamp: DateTime.utc(2026, 1, 2)),
        UserMessage.text('go'),
      ];

      final out = rewriteHistoryImages(window, evictedKeys: {key});

      expect(_imagesOf(out).map((i) => i.data), ['b' * 1000]);
      expect(_texts(out), contains('[image dropped: '));
    });
  });

  group('gh-1934 AC3: payload-only — inputs are never mutated', () {
    test('eviction + strip leave every input message untouched', () {
      final window = [
        UserMessage.text(_boundaryText),
        _imageResult('t1', 'a' * 1000),
        _imageUser('b' * 1000),
        UserMessage.text('go'),
      ];
      final snapshot = [
        for (final m in window)
          switch (m) {
            UserMessage(:final content, :final timestamp) =>
              UserMessage(content: content, timestamp: timestamp),
            ToolResultMessage(
              :final toolCallId,
              :final toolName,
              :final content,
              :final isError,
              :final timestamp,
            ) =>
              ToolResultMessage(
                toolCallId: toolCallId,
                toolName: toolName,
                content: content,
                isError: isError,
                timestamp: timestamp,
              ),
            _ => m,
          },
      ];

      rewriteHistoryImages(window, stripAll: true);

      expect(window.length, snapshot.length);
      for (var i = 0; i < window.length; i++) {
        expect(window[i].runtimeType, snapshot[i].runtimeType);
        expect(
          window[i].toString().contains('ImageContent'),
          snapshot[i].toString().contains('ImageContent'),
          reason: 'message $i kept its block shape',
        );
      }
      expect(_imagesOf(window), hasLength(2));
    });
  });

  group('gh-1934 AC2: token accounting counts the placeholder', () {
    test('the rewritten payload estimates far lighter than the raw window',
        () {
      final big = 'x' * 400000; // ~100k tokens of base64 per image at chars/4
      final poisoned = [
        for (var i = 0; i < 8; i++)
          _imageResult('t$i', big),
        UserMessage.text('plain text question'),
      ];
      final boundaryWindow = [
        UserMessage.text(_boundaryText),
        ...poisoned,
      ];

      final rewritten = rewriteHistoryImages(boundaryWindow);
      final after = estimateRequestTokens(rewritten);
      final before = estimateRequestTokens(boundaryWindow);

      expect(after, lessThan(before ~/ 10),
          reason: 'placeholders cost text tokens, not image bytes');
    });
  });
}
