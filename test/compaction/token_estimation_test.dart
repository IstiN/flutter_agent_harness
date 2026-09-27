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

    test('repeated images charge once plus the wire replacement '
        '(issue #195 F5)', () {
      // Two DISTINCT instances carrying the same bytes: the registry
      // dedups them on the wire, so the estimate must too.
      const image = ImageContent(data: 'AAAA', mimeType: 'image/png');
      final messages = [
        UserMessage(
          content: [
            TextContent(text: 'a' * 40),
            image,
          ],
          timestamp: DateTime.utc(2026),
        ),
        UserMessage(
          content: [
            TextContent(text: 'b' * 40),
            const ImageContent(data: 'AAAA', mimeType: 'image/png'),
          ],
          timestamp: DateTime.utc(2026),
        ),
      ];
      // First occurrence: 4800 chars; the repeat: a short note/label.
      final expected = ((40 + 4800 + 40 + 32) / 4).ceil();
      expect(estimateContextTokens(messages).tokens, expected);
    });

    test('distinct images each charge full (issue #195 F5)', () {
      final messages = [
        UserMessage(
          content: [const ImageContent(data: 'AAAA', mimeType: 'image/png')],
          timestamp: DateTime.utc(2026),
        ),
        UserMessage(
          content: [const ImageContent(data: 'BBBB', mimeType: 'image/png')],
          timestamp: DateTime.utc(2026),
        ),
      ];
      expect(estimateContextTokens(messages).tokens, (2 * 4800 / 4).ceil());
    });

    test(
      'trailing repeats of anchor-era images stay cheap (issue #195 F5)',
      () {
        const usage = Usage(
          input: 5000,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 5000,
          cost: UsageCost(),
        );
        final messages = [
          UserMessage(
            content: [const ImageContent(data: 'AAAA', mimeType: 'image/png')],
            timestamp: DateTime.utc(2026),
          ),
          _assistant(
            content: [TextContent(text: 'b' * 40)],
            usage: usage,
          ),
          UserMessage(
            content: [const ImageContent(data: 'AAAA', mimeType: 'image/png')],
            timestamp: DateTime.utc(2026),
          ),
        ];
        // The trailing repeat estimates as the note, not a second image.
        expect(estimateContextTokens(messages).trailingTokens, 8);
      },
    );

    test('the content key matches the registry (drift pin, issue #195 F5)', () {
      const image = ImageContent(data: 'AAAA', mimeType: 'image/png');
      expect(estimationImageKey(image), imageContentKey(image));
    });

    test('estimateTokens without a seen set charges every occurrence', () {
      final message = UserMessage(
        content: [
          TextContent(text: 'a' * 40),
          const ImageContent(data: 'AAAA', mimeType: 'image/png'),
          const ImageContent(data: 'AAAA', mimeType: 'image/png'),
        ],
        timestamp: DateTime.utc(2026),
      );
      // (40 + 2 * 4800) / 4 = 2410 — per-message calls stay as before.
      expect(estimateTokens(message), 2410);
    });
  });

  group('estimateRequestOverheadTokens', () {
    test('counts the system prompt and tool schemas at chars/4', () {
      final tool = Tool(
        name: 'read',
        description: 'd' * 20,
        parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
      );
      final chars =
          100 + 'read'.length + 20 + jsonEncode(tool.parameters).length;
      expect(
        estimateRequestOverheadTokens('s' * 100, [tool]),
        (chars / 4).ceil(),
      );
    });

    test('a null prompt and no tools cost nothing', () {
      expect(estimateRequestOverheadTokens(null, const []), 0);
      expect(estimateRequestOverheadTokens('', const []), 0);
    });
  });

  group('estimateRequestTokens (the meter/guard shared basis)', () {
    test(
      'an unanchored transcript adds the system prompt and tool schemas',
      () {
        // 25 transcript tokens; the request additionally carries the system
        // prompt and the tool schemas, which the transcript-only estimate
        // silently drops (the resumed-session ctx-meter bug).
        final messages = [UserMessage.text('a' * 100)];
        final tools = [
          Tool(name: 't', description: 'd' * 36, parameters: const {}),
        ];
        final overhead = estimateRequestOverheadTokens('s' * 100, tools);
        expect(overhead, greaterThan(0));
        expect(
          estimateRequestTokens(
            messages,
            systemPrompt: 's' * 100,
            tools: tools,
          ),
          25 + overhead,
        );
      },
    );

    test('an anchored transcript does NOT add overhead — provider usage '
        'already prices the system prompt and tools', () {
      final anchored = _assistant(
        content: [TextContent(text: 'hi')],
        usage: Usage.zero.copyWith(input: 100, totalTokens: 120),
      );
      final messages = [UserMessage.text('a' * 100), anchored];
      // The 120-token anchor stands; the huge prompt must not be counted
      // a second time on top of it.
      expect(
        estimateRequestTokens(
          messages,
          systemPrompt: 's' * 100000,
          tools: [
            Tool(name: 't', description: 'd' * 1000, parameters: const {}),
          ],
        ),
        120,
      );
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

    test('a fresh list COPY over the same settled messages still hits the '
        'memo (the AgentState getter copies the list on every read)', () {
      final memo = SettledContextEstimate();
      final messages = [UserMessage.text('a' * 100)];
      expect(memo.settled(List.unmodifiable(messages)), 25);
      expect(memo.settled(List.unmodifiable(messages)), 25);
      expect(memo.estimatorCalls, 1);
    });

    test('settledEstimate exposes the usage anchor so callers can add '
        'request overhead only when unanchored', () {
      final memo = SettledContextEstimate();
      final unanchored = memo.settledEstimate([UserMessage.text('a' * 100)]);
      expect(unanchored.lastUsageIndex, isNull);
      final anchored = memo.settledEstimate([
        _assistant(
          content: [TextContent(text: 'hi')],
          usage: Usage.zero.copyWith(input: 100, totalTokens: 120),
        ),
      ]);
      expect(anchored.lastUsageIndex, 0);
      expect(anchored.tokens, 120);
    });
  });

  group('estimateProjectedBranchTokens (issue #503 round 3b)', () {
    MessageRecord msg(String id, String? parent, String text) => MessageRecord(
      id: id,
      parentId: parent,
      timestamp: DateTime.utc(2026),
      message: UserMessage.text(text),
    );

    test('equals the raw estimate when no structured records exist', () {
      final branch = [msg('e0', null, 'a' * 100), msg('e1', 'e0', 'b' * 40)];
      expect(
        estimateProjectedBranchTokens(branch),
        estimateSessionBranchTokens(branch),
      );
    });

    test('hidden records count as one-line markers, not full content', () {
      final branch = [
        msg('e0', null, 'a' * 100), // 25 tokens, visible
        msg('e1', 'e0', 'x' * 40000), // 10000 tokens raw — hidden
        msg('e2', 'e1', 'b' * 40), // 10 tokens, visible
        HiddenRangeRecord(
          id: 'h0',
          parentId: 'e2',
          timestamp: DateTime.utc(2026),
          recordIds: const ['e1'],
        ),
      ];
      final projected = estimateProjectedBranchTokens(branch);
      expect(projected, lessThan(25 + 10 + 40)); // markers are tiny
      expect(projected, greaterThanOrEqualTo(35)); // visible ones still count
    });

    test('covered records count zero; the checkpoint text is counted once', () {
      final branch = [
        msg('e0', null, 'a' * 100), // 25, visible
        msg('e1', 'e0', 'x' * 40000), // covered → 0
        msg('e2', 'e1', 'y' * 40000), // covered → 0
        CompactCheckpointRecord(
          id: 'k0',
          parentId: 'e2',
          timestamp: DateTime.utc(2026),
          firstRecordId: 'e1',
          lastRecordId: 'e2',
          text: 's' * 200, // 50 tokens
          coversRecordIds: const ['e1', 'e2'],
          flattenedRecordIds: const [],
        ),
      ];
      expect(estimateProjectedBranchTokens(branch), 25 + 50);
    });

    test('a checkpoint covered by a later checkpoint is skipped (D4)', () {
      final branch = [
        msg('e0', null, 'x' * 40000),
        CompactCheckpointRecord(
          id: 'k0',
          parentId: 'e0',
          timestamp: DateTime.utc(2026),
          firstRecordId: 'e0',
          lastRecordId: 'e0',
          text: 'inner' * 100,
          coversRecordIds: const ['e0'],
          flattenedRecordIds: const [],
        ),
        msg('e1', 'k0', 'y' * 40000),
        CompactCheckpointRecord(
          id: 'k1',
          parentId: 'e1',
          timestamp: DateTime.utc(2026),
          firstRecordId: 'e0',
          lastRecordId: 'e1',
          text: 'o' * 80, // 20 tokens — the outer text wins
          coversRecordIds: const ['e0', 'k0', 'e1'],
          flattenedRecordIds: const ['k0'],
        ),
      ];
      expect(estimateProjectedBranchTokens(branch), 20);
    });

    test('classic transform drops everything before firstKeptEntryId', () {
      final branch = [
        msg('e0', null, 'x' * 40000), // dropped by the transform
        msg('e1', 'e0', 'y' * 40000), // dropped
        CompactionRecord(
          id: 'c0',
          parentId: 'e1',
          timestamp: DateTime.utc(2026),
          summary: 's' * 200, // 50 tokens
          firstKeptEntryId: 'e2',
          tokensBefore: 99999,
        ),
        msg('e2', 'c0', 'a' * 100), // 25, kept
      ];
      expect(estimateProjectedBranchTokens(branch), 50 + 25);
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

  group('resumeParityBudget (gh-968 UT-BUDGET)', () {
    final tool = Tool(
      name: 'read',
      description: 'd' * 40,
      parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
    );

    test(
      'window − system+tools overhead − reserve: the meter\'s own basis',
      () {
        const window = 200000;
        const reserve = 16384;
        final budget = resumeParityBudget(
          effectiveContextWindow: window,
          reserveTokens: reserve,
          systemPrompt: 'a' * 4000, // 1000 tokens
          tools: [tool],
        );
        final overhead = estimateRequestOverheadTokens('a' * 4000, [tool]);
        // The parity identity: transcript budget + overhead + reserve must
        // reassemble the window, so the meter (transcript + overhead) can
        // never read past window − reserve on a fresh resume.
        expect(budget + overhead + reserve, window);
        // The overhead already prices the prompt in — subtracted once.
        expect(budget, window - reserve - overhead);
      },
    );

    test('no prompt and no tools: budget = window − reserve', () {
      expect(
        resumeParityBudget(effectiveContextWindow: 50000, reserveTokens: 8192),
        50000 - 8192,
      );
    });

    test(
      'an unanchored overhead is SUBTRACTED, never swallowed (the '
      'reported 127% resume priced system+tools on top of a full window)',
      () {
        const window = 32768;
        const reserve = 8192;
        final prompt = 'x' * 40000; // 10k tokens of system prompt
        final budget = resumeParityBudget(
          effectiveContextWindow: window,
          reserveTokens: reserve,
          systemPrompt: prompt,
          tools: [tool],
        );
        expect(
          budget,
          window - reserve - estimateRequestOverheadTokens(prompt, [tool]),
        );
      },
    );

    test('a clamped window (contextWindowCap) scales the budget (E4)', () {
      // The caller passes the EFFECTIVE window; the formula is honest
      // about whatever window it is given.
      expect(
        resumeParityBudget(effectiveContextWindow: 32768, reserveTokens: 8192),
        24576,
      );
      expect(
        resumeParityBudget(effectiveContextWindow: 8192, reserveTokens: 2048),
        6144,
      );
    });

    test('a system prompt alone near the window floors the budget at 0 '
        'without throwing (E6: huge AGENTS.md chain)', () {
      final budget = resumeParityBudget(
        effectiveContextWindow: 8192,
        reserveTokens: 2048,
        systemPrompt: 'x' * 40000, // 10k tokens > the whole window
      );
      expect(budget, 0);
    });
  });

  group('projectedBranchBudgetCut (gh-968 UT-OVERSHOOT)', () {
    MessageRecord msg(String id, String? parent, String text) => MessageRecord(
      id: id,
      parentId: parent,
      timestamp: DateTime.utc(2026),
      message: UserMessage.text(text),
    );

    /// 100 tokens per record (400 chars), chained e(from)..e(from+count-1).
    List<MessageRecord> msgs(int count, {int from = 0}) => [
      for (var i = 0; i < count; i++)
        msg(
          'e${from + i}',
          from + i == 0 ? null : 'e${from + i - 1}',
          'a' * 400,
        ),
    ];

    test('whole branch fits the budget → null (nothing to trim)', () {
      final branch = msgs(10); // 1000 tokens
      expect(projectedBranchBudgetCut(branch, 1000), isNull);
      expect(projectedBranchBudgetCut(branch, 1001), isNull);
      expect(projectedBranchBudgetCut(branch, 100000), isNull);
    });

    test(
      'cuts before the record that would push the kept tail PAST the '
      'budget walking backward (kept tail ≤ budget, never a blockful over)',
      () {
        final branch = msgs(20); // 2000 tokens
        final cut = projectedBranchBudgetCut(branch, 1000);
        // Walking backward: 100..1000 stay at/below budget; the record that
        // would reach 1100 is dropped, so the kept suffix prices 1000.
        expect(cut, 10);
        final kept = branch.sublist(cut!);
        expect(estimateProjectedBranchTokens(kept), 1000);
        expect(estimateProjectedBranchTokens(kept), lessThanOrEqualTo(1000));
      },
    );

    test('a whole branch exactly at the budget fits (budget is inclusive)', () {
      final branch = msgs(10); // 1000 tokens
      expect(projectedBranchBudgetCut(branch, 999), 1);
      expect(estimateProjectedBranchTokens(branch.sublist(1)), 900);
    });

    test('the overshoot is bounded by ONE record, never one block: a giant '
        'record at the crossing is dropped, not accepted', () {
      // e0..e9 (100 tokens each), a 5000-token giant, then 49 tail records
      // of 100 tokens chained onto it.
      final branch = [
        ...msgs(10),
        msg('giant', 'e9', 'g' * 20000),
        ...msgs(49, from: 10),
      ];
      for (var i = 11; i < branch.length; i++) {
        branch[i] = msg(
          branch[i].id,
          i == 11 ? 'giant' : branch[i - 1].id,
          'a' * 400,
        );
      }
      const budget = 5500;
      final cut = projectedBranchBudgetCut(branch, budget)!;
      final kept = branch.sublist(cut);
      final estimate = estimateProjectedBranchTokens(kept);
      // The giant (which alone would push the tally to 9900) is NOT
      // accepted: the walk stops BEFORE it — the kept tail is the 49
      // small records (4900). The old block-granular stop landed on
      // whatever doubling block crossed, tens of thousands of tokens
      // past the budget.
      expect(estimate, 4900);
      expect(estimate, lessThanOrEqualTo(budget));
      expect(kept, hasLength(49));
      expect(kept.any((r) => r.id == 'giant'), isFalse);
    });

    test('hidden records price as markers in the cut arithmetic (same '
        'estimator as the meter — REG-STRUCTURED)', () {
      // 20 hidden 10k-token giants + 20 visible 100-token tail records +
      // the range marker at the tail.
      final hidden = [
        for (var i = 0; i < 20; i++)
          msg('e$i', i == 0 ? null : 'e${i - 1}', 'x' * 40000),
      ];
      final tail = [
        for (var i = 20; i < 40; i++) msg('e$i', 'e${i - 1}', 'a' * 400),
      ];
      final branch = [
        ...hidden,
        ...tail,
        HiddenRangeRecord(
          id: 'h0',
          parentId: 'e39',
          timestamp: DateTime.utc(2026),
          recordIds: [for (var i = 0; i < 20; i++) 'e$i'],
        ),
      ];
      const budget = 2100;
      final cut = projectedBranchBudgetCut(branch, budget)!;
      final kept = branch.sublist(cut);
      // Hidden giants price as 10-token markers: the kept tail reaches
      // e10 (31 records). A raw tally would have stopped at e19 — 10
      // records newer — because it prices the giants' full 100k tokens.
      expect(cut, 10);
      expect(kept, hasLength(31));
      expect(estimateProjectedBranchTokens(kept), 2100);
      expect(estimateSessionBranchTokens(kept), greaterThan(100000));
    });

    test('a checkpoint-covered span prices as its checkpoint text once', () {
      final branch = [
        msg('e0', null, 'x' * 40000), // covered → 0
        msg('e1', 'e0', 'y' * 40000), // covered → 0
        CompactCheckpointRecord(
          id: 'k0',
          parentId: 'e1',
          timestamp: DateTime.utc(2026),
          firstRecordId: 'e0',
          lastRecordId: 'e1',
          text: 's' * 200, // 50 tokens
          coversRecordIds: const ['e0', 'e1'],
          flattenedRecordIds: const [],
        ),
        msg('e2', 'k0', 'a' * 400), // 100
        msg('e3', 'e2', 'b' * 400), // 100
      ];
      // Walking backward: e3 (100), e2 (200), checkpoint text (250) — the
      // covered records ride free below it. Budget 249 crosses at the
      // checkpoint → keep e2..e3 (200). Budget 250 never crosses (the
      // covered records add nothing) → nothing to trim.
      expect(projectedBranchBudgetCut(branch, 249), 3);
      expect(estimateProjectedBranchTokens(branch.sublist(3)), 200);
      expect(projectedBranchBudgetCut(branch, 250), isNull);
    });

    test('budget 0 floors at keeping the newest record (never an empty '
        'window)', () {
      final branch = msgs(5);
      expect(projectedBranchBudgetCut(branch, 0), 4);
    });

    test('the classic compaction transform bounds the cut: records below '
        'firstKeptEntryId project zero and are never the crossing', () {
      final branch = [
        msg('e0', null, 'x' * 40000), // dropped by the transform
        msg('e1', 'e0', 'y' * 40000), // dropped
        CompactionRecord(
          id: 'c0',
          parentId: 'e1',
          timestamp: DateTime.utc(2026),
          summary: 's' * 200, // 50 tokens
          firstKeptEntryId: 'e2',
          tokensBefore: 99999,
        ),
        msg('e2', 'c0', 'a' * 400), // 100
        msg('e3', 'e2', 'b' * 400), // 100
      ];
      // The kept region prices 250 (e3 + e2 + the summary): the two
      // 40k-char records below the transform line never push the tally —
      // a raw tally would have crossed ten records earlier.
      expect(projectedBranchBudgetCut(branch, 300), isNull);
      // Budget 150 crosses at e2 (200 > 150) → keep e3 only.
      expect(projectedBranchBudgetCut(branch, 150), 4);
      expect(estimateProjectedBranchTokens(branch.sublist(4)), 100);
    });
  });
}
