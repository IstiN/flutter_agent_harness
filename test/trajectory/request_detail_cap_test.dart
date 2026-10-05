import 'package:flutter_agent_harness/src/trajectory/trajectory_blobs.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_record.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

TrajectoryRequestDetail detailWith(int messageCount, {int blockChars = 0}) {
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
          blocks: blockChars == 0
              ? const []
              : [
                  TrajectoryRequestMessageBlock(
                    type: 'text',
                    chars: blockChars * 4,
                    text: 'b' * blockChars,
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

    test('a 1000-message request keeps only the newest summaries in full',
        () {
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
      expect(full.first.preview, contains('${1000 - requestSummaryMaxMessages}'));
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
      final capped = capTrajectoryRequestDetail(detailWith(200, blockChars: 8192));
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
  });

  group('request capture wiring (gh-1073)', () {
    test('trajectoryRequestBlocks stays bounded per block (existing cap)',
        () {
      final blocks = trajectoryRequestBlocks([
        TextContent(text: 'x' * (requestBlockChars * 2)),
      ]);
      expect(blocks.single.truncated, isTrue);
      expect(blocks.single.text.length, requestBlockChars + 1);
    });
  });
}
