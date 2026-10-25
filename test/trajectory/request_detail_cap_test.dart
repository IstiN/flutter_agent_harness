import 'dart:convert';

import 'package:flutter_agent_harness/src/trajectory/trajectory_blobs.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_record.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

TrajectoryRequestDetail detailWith(int messageCount, {int blockChars = 0}) {
  // One shared immutable text for every block: the scale under test is
  // still messageCount × blockChars of payload; distinct string instances
  // per message only added ~64 MB of fixture garbage per call
  // (issue #1850 AC3 — the cap test's old-space growth was the fixture,
  // not the cap).
  final blockText = blockChars == 0 ? null : 'b' * blockChars;
  return TrajectoryRequestDetail(
    messageCount: messageCount,
    systemPromptChars: 1200,
    toolCount: 2,
    toolNames: const ['read', 'bash'],
    messages: [
      for (var i = 0; i < messageCount; i++)
        TrajectoryRequestMessageSummary(
          role: i.isEven ? 'user' : 'assistant',
          chars: 500 + i,
          preview: 'message $i preview',
          blocks: blockText == null
              ? const []
              : [
                  TrajectoryRequestMessageBlock(
                    type: 'text',
                    chars: blockChars * 4,
                    text: blockText,
                  ),
                ],
        ),
    ],
  );
}

void main() {
  group('capTrajectoryRequestDetail (gh-1073)', () {
    test('a small detail round-trips untouched', () {
      final detail = detailWith(3);
      final capped = capTrajectoryRequestDetail(detail);
      expect(capped.messageCount, 3);
      expect(capped.messages.length, 3);
      expect(capped.messages.every((m) => m.preview.isNotEmpty), isTrue);
    });

    test('a 1000-message request keeps only the newest summaries in full', () {
      final capped = capTrajectoryRequestDetail(detailWith(1000));
      // The request SIZE stays truthful — only the per-message detail is
      // bounded.
      expect(capped.messageCount, 1000);
      expect(capped.toolNames, ['read', 'bash']);
      expect(capped.systemPromptChars, 1200);
      final full = capped.messages
          .where((m) => m.preview.isNotEmpty)
          .toList(growable: false);
      expect(full.length, requestSummaryMaxMessages);
      // The KEPT messages are the newest ones (the tail the Request tab
      // is actually scrolled to).
      expect(
        full.first.preview,
        contains('${1000 - requestSummaryMaxMessages}'),
      );
      expect(full.last.preview, contains('999'));
      // Everything older degrades to a size-only stub.
      final stubs = capped.messages
          .where((m) => m.preview.isEmpty)
          .toList(growable: false);
      expect(stubs.length, 1000 - requestSummaryMaxMessages);
      expect(stubs.first.chars, 500);
      expect(stubs.last.blocks, isEmpty);
      // Order is preserved: stubs first (oldest), full last (newest).
      expect(capped.messages.first.chars, 500);
      expect(capped.messages.last.preview, contains('999'));
    });

    test('the persisted record size stays under the char budget', () {
      // 200 messages × 8 KB block texts ≈ 1.6 MB unbounded.
      final capped = capTrajectoryRequestDetail(
        detailWith(200, blockChars: 8192),
      );
      final encoded = capped.toJson().toString().length;
      expect(
        encoded,
        lessThan(requestSummaryCharsBudget + (64 * 200) + 4096),
        reason: 'full summaries (≤ budget) + stub rows only',
      );
      // Every message still has a row — the shape survives, only the
      // heavy text is gone.
      expect(capped.messages.length, 200);
    });

    test('serialization round-trips through the stubs', () {
      final capped = capTrajectoryRequestDetail(detailWith(100));
      final restored = TrajectoryRequestDetail.fromJson(capped.toJson());
      expect(restored.messageCount, 100);
      expect(
        restored.messages.where((m) => m.preview.isNotEmpty).length,
        requestSummaryMaxMessages,
      );
    });

    test('a 1000-message request with huge texts stays bounded regardless '
        'of message text length (gh-1590 AC)', () {
      // 64 KB block texts — the walk fills its 256 KiB budget after a
      // handful of messages and every older message degrades to a stub,
      // so the encoded record cannot chase the message text length.
      final huge = capTrajectoryRequestDetail(
        detailWith(1000, blockChars: 64 << 10),
      );
      final tiny = capTrajectoryRequestDetail(detailWith(1000, blockChars: 1));
      final hugeEncoded = huge.toJson().toString().length;
      final tinyEncoded = tiny.toJson().toString().length;
      // Bounded: full summaries (≤ the char budget) + 936 stub rows —
      // NOT 1000 × 64 KB.
      final bound =
          requestSummaryCharsBudget +
          requestSummaryMaxMessages * (requestPreviewChars + 2048) +
          1000 * 256;
      expect(hugeEncoded, lessThan(bound));
      // Independent of text length: the 64 KB-text record lands within a
      // small constant of the 1-char-text record's size.
      expect(hugeEncoded, lessThan(tinyEncoded * 10));
      // The request description stays truthful.
      expect(huge.messageCount, 1000);
      expect(huge.messages, hasLength(1000));
    });
  });

  group('stripTrajectoryRequestDetail (issue #1882 AC1)', () {
    test('a small request keeps every stub and folds nothing', () {
      final stripped = stripTrajectoryRequestDetail(
        detailWith(10),
        spillFile: '.fah/trajectories/s/requests/1.json',
      );
      expect(stripped.messages, hasLength(10));
      expect(stripped.droppedMessagesCount, 0);
      expect(stripped.droppedMessagesChars, 0);
      // No aggregate on the wire when nothing was folded.
      expect(jsonEncode(stripped.toJson()), isNot(contains('droppedMessages')));
      expect(stripped.spillFile, '.fah/trajectories/s/requests/1.json');
    });

    test('a 1030-message request folds older stubs into the aggregate', () {
      // chars: 500 + i (same fixture as the gh-1073 group).
      final stripped = stripTrajectoryRequestDetail(
        detailWith(1030),
        spillFile: '.fah/trajectories/s/requests/2.json',
      );
      // The request DESCRIPTION stays truthful…
      expect(stripped.messageCount, 1030);
      expect(stripped.toolNames, ['read', 'bash']);
      expect(stripped.systemPromptChars, 1200);
      // …but only the newest stub tail stays in the record.
      expect(stripped.messages, hasLength(requestStubMaxMessages));
      expect(stripped.messages.first.chars, 500 + 730);
      expect(stripped.messages.last.chars, 500 + 1029);
      // The fold is exact: count and Σ chars of EVERYTHING dropped.
      expect(stripped.droppedMessagesCount, 730);
      var droppedChars = 0;
      for (var i = 0; i < 730; i++) {
        droppedChars += 500 + i;
      }
      expect(stripped.droppedMessagesChars, droppedChars);
      // The estimation basis survives: kept Σ + dropped Σ == whole Σ.
      var keptChars = 0;
      for (final message in stripped.messages) {
        keptChars += message.chars;
      }
      var wholeChars = 0;
      for (var i = 0; i < 1030; i++) {
        wholeChars += 500 + i;
      }
      expect(keptChars + stripped.droppedMessagesChars, wholeChars);
    });

    test('the stripped record stays ≤ 20 KB even with heavy metadata', () {
      // Worst realistic metadata: 100 long tool names + all blob hashes
      // + a long spill path — on top of the 1030-message stub tail.
      final heavy = TrajectoryRequestDetail(
        messageCount: 1030,
        systemPromptChars: 12000,
        toolCount: 100,
        toolNames: [
          for (var i = 0; i < 100; i++) 'aVeryLongToolName$i${'x' * 12}',
        ],
        systemPromptHash: 'blob:sha256:0123456789abcdef0123456789abcdef',
        toolManifestHash: 'blob:sha256:0123456789abcdef0123456789abcdef',
        wireDumpHash: 'blob:sha256:0123456789abcdef0123456789abcdef',
        messages: [
          for (var i = 0; i < 1030; i++)
            TrajectoryRequestMessageSummary(
              role: i.isEven ? 'user' : 'assistant',
              chars: 500 + i,
              preview: 'p' * requestPreviewChars,
            ),
        ],
      );
      final stripped = stripTrajectoryRequestDetail(
        heavy,
        spillFile:
            '.fah/trajectories/01234567-89ab-cdef-0123-456789abcdef/'
            'requests/12345.json',
      );
      final bytes = utf8.encode(jsonEncode(stripped.toJson())).length;
      expect(
        bytes,
        lessThanOrEqualTo(20 * 1024),
        reason:
            'AC1: the persisted model_request_summary record is '
            'bounded at ≤ 20 KB by default',
      );
    });

    test('round-trips through JSON with the aggregate intact', () {
      final stripped = stripTrajectoryRequestDetail(
        detailWith(400),
        spillFile: '.fah/trajectories/s/requests/3.json',
      );
      final restored = TrajectoryRequestDetail.fromJson(stripped.toJson());
      expect(restored.messages, hasLength(requestStubMaxMessages));
      expect(restored.droppedMessagesCount, 400 - requestStubMaxMessages);
      expect(restored.droppedMessagesChars, greaterThan(0));
      expect(restored.messageCount, 400);
    });

    test('a legacy record without the aggregate reads as zeros', () {
      final legacy = TrajectoryRequestDetail.fromJson({
        'messageCount': 2,
        'systemPromptChars': 10,
        'toolCount': 0,
        'toolNames': <String>[],
        'messages': [
          {'role': 'user', 'chars': 400, 'preview': ''},
          {'role': 'user', 'chars': 100, 'preview': ''},
        ],
      });
      expect(legacy.droppedMessagesCount, 0);
      expect(legacy.droppedMessagesChars, 0);
      expect(legacy.messages, hasLength(2));
    });
  });

  group('request capture wiring (gh-1073)', () {
    test('trajectoryRequestBlocks stays bounded per block (existing cap)', () {
      final blocks = trajectoryRequestBlocks([
        TextContent(text: 'x' * (requestBlockChars * 2)),
      ]);
      expect(blocks.single.truncated, isTrue);
      expect(blocks.single.text.length, requestBlockChars + 1);
    });
  });
}
