import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  Usage usage = Usage.zero,
}) {
  return AssistantMessage(
    content: content,
    api: 'openai-completions',
    provider: 'openrouter',
    model: 'm1',
    usage: usage,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

void main() {
  group('estimateTokens (pi chars/4 heuristic)', () {
    test('user message with plain string content', () {
      expect(estimateTokens(UserMessage.text('a' * 100)), 25);
      // Rounds up, never down.
      expect(estimateTokens(UserMessage.text('a' * 5)), 2);
    });

    test('user message with text and image blocks (image ≈ 1200 tokens)', () {
      final message = UserMessage(
        content: [
          TextContent(text: 'a' * 40),
          const ImageContent(data: 'AAAA', mimeType: 'image/png'),
        ],
        timestamp: DateTime.utc(2026),
      );
      // (40 + 4800) / 4 = 1210.
      expect(estimateTokens(message), 1210);
    });

    test('assistant message sums text, thinking and tool calls', () {
      final args = {'path': '/foo/bar.dart', 'limit': 10};
      final message = _assistant(
        content: [
          TextContent(text: 'a' * 40),
          ThinkingContent(thinking: 'b' * 20),
          ToolCall(id: 'c1', name: 'read', arguments: args),
        ],
      );
      final chars = 40 + 20 + 'read'.length + jsonEncode(args).length;
      expect(estimateTokens(message), (chars / 4).ceil());
    });

    test('tool result message counts text and images', () {
      final message = ToolResultMessage(
        toolCallId: 'c1',
        toolName: 'read',
        content: [
          TextContent(text: 'a' * 8),
          const ImageContent(data: 'AAAA', mimeType: 'image/png'),
        ],
        isError: false,
        timestamp: DateTime.utc(2026),
      );
      // (8 + 4800) / 4 = 1202.
      expect(estimateTokens(message), 1202);
    });
  });

  group('calculateContextTokens', () {
    test('prefers totalTokens when reported', () {
      const usage = Usage(
        input: 10,
        output: 20,
        cacheRead: 30,
        cacheWrite: 40,
        totalTokens: 999,
        cost: UsageCost(),
      );
      expect(calculateContextTokens(usage), 999);
    });

    test('sums components when totalTokens is zero', () {
      const usage = Usage(
        input: 10,
        output: 20,
        cacheRead: 30,
        cacheWrite: 40,
        totalTokens: 0,
        cost: UsageCost(),
      );
      expect(calculateContextTokens(usage), 100);
    });
  });

  group('estimateContextTokens', () {
    test('no assistant usage: pure heuristic over all messages', () {
      final messages = [
        UserMessage.text('a' * 100),
        _assistant(content: [TextContent(text: 'b' * 100)]),
      ];
      final estimate = estimateContextTokens(messages);
      expect(estimate.tokens, 50);
      expect(estimate.usageTokens, 0);
      expect(estimate.trailingTokens, 50);
      expect(estimate.lastUsageIndex, isNull);
    });

    test('uses the last valid assistant usage plus trailing estimate', () {
      const usage = Usage(
        input: 5000,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 5000,
        cost: UsageCost(),
      );
      final messages = [
        UserMessage.text('a' * 100),
        _assistant(
          content: [TextContent(text: 'b' * 100)],
          usage: usage,
        ),
        UserMessage.text('c' * 200),
      ];
      final estimate = estimateContextTokens(messages);
      expect(estimate.usageTokens, 5000);
      expect(estimate.trailingTokens, 50);
      expect(estimate.tokens, 5050);
      expect(estimate.lastUsageIndex, 1);
    });

    test('ignores usage from errored or aborted assistant messages', () {
      const usage = Usage(
        input: 5000,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 5000,
        cost: UsageCost(),
      );
      final messages = [
        UserMessage.text('a' * 100),
        _assistant(
          content: [TextContent(text: 'b' * 100)],
          usage: usage,
          stopReason: StopReason.error,
        ),
      ];
      final estimate = estimateContextTokens(messages);
      expect(estimate.lastUsageIndex, isNull);
      expect(estimate.tokens, 50);
    });

    test('ignores zero-valued usage blocks', () {
      final messages = [
        _assistant(content: [TextContent(text: 'b' * 100)]),
      ];
      expect(estimateContextTokens(messages).lastUsageIndex, isNull);
    });
  });

  group('SettledContextEstimate', () {
    test('memoizes on the list identity + length — one estimator run for '
        'repeated calls', () {
      final memo = SettledContextEstimate();
      final messages = [UserMessage.text('a' * 100)];
      expect(memo.settled(messages), 25);
      expect(memo.settled(messages), 25);
      expect(memo.estimatorCalls, 1);
    });

    test('recomputes when the list grows (length key)', () {
      final memo = SettledContextEstimate();
      final messages = [UserMessage.text('a' * 100)];
      memo.settled(messages);
      messages.add(UserMessage.text('b' * 100));
      expect(memo.settled(messages), 50);
      expect(memo.estimatorCalls, 2);
    });

    test('recomputes for a same-length REPLACEMENT list (compaction '
        'swaps identity)', () {
      final memo = SettledContextEstimate();
      memo.settled([UserMessage.text('a' * 100), _assistant()]);
      expect(memo.settled([UserMessage.text('c' * 100), _assistant()]), 25);
      expect(memo.estimatorCalls, 2);
    });

    test('the settled memo has no streaming input — in-flight stream '
        'content never invalidates it (the typing-lag fix)', () {
      // The whole point: the key carries nothing about the stream message,
      // so per-delta callers cost one O(stream) estimateTokens on top of
      // the memo hit, never an O(context) re-scan.
      final memo = SettledContextEstimate();
      final messages = [UserMessage.text('a' * 100)];
      memo.settled(messages);
      memo.settled(messages);
      memo.settled(messages);
      expect(memo.estimatorCalls, 1);
    });
  });

  group('resetLoadedUsageAnchors', () {
    test('zeroes assistant usage; user/tool messages pass through', () {
      final stale = _assistant(
        content: [TextContent(text: 'hi')],
        usage: Usage.zero.copyWith(input: 183902, totalTokens: 183944),
      );
      final user = UserMessage.text('hello');
      final reset = resetLoadedUsageAnchors([stale, user]);

      final assistant = reset[0] as AssistantMessage;
      expect(assistant.usage.totalTokens, 0);
      expect(assistant.usage.input, 0);
      // The message itself is preserved (same content), only the anchor
      // goes — and non-assistant messages are the SAME instances.
      expect((assistant.content.single as TextContent).text, 'hi');
      expect(identical(reset[1], user), isTrue);
    });

    test('a zero anchor is left as the same instance (no copy churn)', () {
      final fresh = _assistant(usage: Usage.zero);
      final reset = resetLoadedUsageAnchors([fresh]);
      expect(identical(reset[0], fresh), isTrue);
    });
  });
}
