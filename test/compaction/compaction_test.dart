import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

MessageRecord _record(String id, Message message) {
  return MessageRecord(
    id: id,
    parentId: null,
    timestamp: DateTime.utc(2026),
    message: message,
  );
}

UserMessage _user(String id, int chars) =>
    UserMessage.text('$id${'a' * chars}');

AssistantMessage _assistant(int chars, {List<ContentBlock>? content}) {
  return AssistantMessage(
    content: content ?? [TextContent(text: 'b' * chars)],
    api: 'openai-completions',
    provider: 'openrouter',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

ToolResultMessage _toolResult(int chars) {
  return ToolResultMessage(
    toolCallId: 'c1',
    toolName: 'read',
    content: [TextContent(text: 'r' * chars)],
    isError: false,
    timestamp: DateTime.utc(2026),
  );
}

void main() {
  group('settings and shouldCompact', () {
    test('defaults match pi (reserve 16384, keep 20000, enabled)', () {
      expect(defaultCompactionSettings.enabled, isTrue);
      expect(defaultCompactionSettings.reserveTokens, 16384);
      expect(defaultCompactionSettings.keepRecentTokens, 20000);
    });

    test('disabled settings never compact', () {
      const settings = CompactionSettings(
        enabled: false,
        reserveTokens: 16384,
        keepRecentTokens: 20000,
      );
      expect(shouldCompact(999999, 100000, settings), isFalse);
    });

    test('compacts only when tokens exceed window minus reserve', () {
      // 100000 - 16384 = 83616; strictly greater required (pi semantics).
      expect(shouldCompact(83616, 100000, defaultCompactionSettings), isFalse);
      expect(shouldCompact(83617, 100000, defaultCompactionSettings), isTrue);
    });
  });

  group('CompactionSettings.forWindow', () {
    test('reproduces pi defaults at hosted-model windows', () {
      for (final window in [100000, 128000, 200000]) {
        final settings = CompactionSettings.forWindow(window);
        expect(settings.enabled, isTrue, reason: 'window $window');
        expect(settings.reserveTokens, 16384, reason: 'window $window');
        expect(settings.keepRecentTokens, 20000, reason: 'window $window');
      }
    });

    test('scales to small on-device windows (quarter reserve, half keep)', () {
      final s8192 = CompactionSettings.forWindow(8192);
      expect(s8192.reserveTokens, 2048);
      expect(s8192.keepRecentTokens, 4096);

      final s4096 = CompactionSettings.forWindow(4096);
      expect(s4096.reserveTokens, 1024);
      expect(s4096.keepRecentTokens, 2048);

      final s16384 = CompactionSettings.forWindow(16384);
      expect(s16384.reserveTokens, 4096);
      expect(s16384.keepRecentTokens, 8192);
    });

    test(
      'degenerate tiny windows: reserve never eats half, keep never all',
      () {
        final s2048 = CompactionSettings.forWindow(2048);
        expect(s2048.reserveTokens, 512);
        expect(s2048.keepRecentTokens, 1024);

        final s1024 = CompactionSettings.forWindow(1024);
        expect(s1024.reserveTokens, 256);
        expect(s1024.keepRecentTokens, 512);

        final s512 = CompactionSettings.forWindow(512);
        expect(s512.reserveTokens, 128);
        expect(s512.keepRecentTokens, 256);
      },
    );

    test('invariants hold across the whole range', () {
      for (var window = 512; window <= 200000; window += 512) {
        final settings = CompactionSettings.forWindow(window);
        expect(settings.enabled, isTrue, reason: 'window $window');
        expect(
          settings.reserveTokens,
          greaterThan(0),
          reason: 'window $window',
        );
        expect(
          settings.reserveTokens,
          lessThan(window ~/ 2),
          reason: 'window $window: reserve must stay under half the window',
        );
        expect(
          settings.keepRecentTokens,
          lessThan(window),
          reason: 'window $window: kept region must leave room to free',
        );
        expect(
          settings.reserveTokens,
          lessThanOrEqualTo(settings.keepRecentTokens),
          reason: 'window $window',
        );
      }
    });
  });

  group('owner cap math (issues #273/#729)', () {
    test('effectiveContextWindow clamps down below the catalog window', () {
      expect(effectiveContextWindow(1000000, 256000), 256000);
      // Absent (or non-positive) cap = the raw window, byte-identical.
      expect(effectiveContextWindow(100000, null), 100000);
      expect(effectiveContextWindow(100000, 0), 100000);
    });

    test(
      'UT-W1: a cap above the catalog window RAISES the effective window '
      '(issue #729)',
      () {
        // The repro: a glm endpoint serving ~1M under a 200k catalog id —
        // the owner override raises the meter/threshold/guard basis to the
        // served truth instead of falsely overflowing at 200k.
        expect(effectiveContextWindow(200000, 1000000), 1000000);
        expect(effectiveContextWindow(200000, 200001), 200001);
        // The raise composes with the clamp-down: the override wins in
        // whichever direction it points.
        expect(effectiveContextWindow(200000, 16384), 16384);
      },
    );

    test('UT-W1: the raise feeds the compaction threshold and trigger', () {
      // At the raised basis a 347k-token branch is UNDER the trigger; at
      // the raw catalog window it is over. Same estimator, same settings
      // rule — only the effective window differs.
      final raised = effectiveContextWindow(200000, 1000000);
      final raw = effectiveContextWindow(200000, null);
      expect(
        shouldCompact(
          347000,
          raised,
          CompactionSettings.forWindow(raised),
        ),
        isFalse,
      );
      expect(
        shouldCompact(347000, raw, CompactionSettings.forWindow(raw)),
        isTrue,
      );
    });

    test('the compaction threshold rides the capped window', () {
      // A 1M-window model under a 256k cap triggers at the 256k basis
      // (forWindow reserve 16384 → trigger 239616), never at the 1M one;
      // uncapped, the same model triggers at 983616. The meter, the
      // threshold and the loop guard all consume the same
      // effectiveContextWindow basis.
      final capped = effectiveContextWindow(1000000, 256000);
      final uncapped = effectiveContextWindow(1000000, null);
      expect(
        shouldCompact(240000, capped, CompactionSettings.forWindow(capped)),
        isTrue,
      );
      expect(
        shouldCompact(240000, uncapped, CompactionSettings.forWindow(uncapped)),
        isFalse,
      );
    });
  });

  group('fit-the-window compaction payloads (issue #729)', () {
    // The repro basis: a 200k window with the default reserve leaves a
    // 183644-token payload budget.
    final budget = summarizationPayloadBudget(
      200000,
      CompactionSettings.forWindow(200000),
    );

    /// A ~1000-token user message (4000 chars of serialized text).
    UserMessage fat(String tag) => UserMessage.text('$tag${'a' * 4000}');

    /// A recording fake summarizer that always succeeds with [text].
    ({SummarizeFn call, List<String> prompts}) recorder(String text) {
      final prompts = <String>[];
      Future<SummarizationResult> call(SummarizationRequest request) async {
        prompts.add(request.prompt);
        return SummarizationResult.success(text);
      }
      return (call: call, prompts: prompts);
    }

    test('UT-C1: the chunk planner bounds a 347k region to the budget', () {
      // 347 fat messages ≈ 347k tokens — the over-window resume's dropped
      // region. Every planned chunk's serialized text must estimate under
      // the payload budget, and the chunks must cover the region in order.
      final messages = [for (var i = 0; i < 347; i++) fat('u$i-')];
      expect(
        estimateStringTokens(serializeConversation(messages)),
        greaterThan(200000),
      ); // genuinely over-window

      final chunks = chunkSummarizableMessages(messages, budget - 4096);
      expect(chunks, hasLength(greaterThan(1)));
      for (final chunk in chunks) {
        expect(
          estimateStringTokens(serializeConversation(chunk)),
          lessThanOrEqualTo(budget),
        );
      }
      // Order preserved, nothing lost: the flatten of the chunks is the
      // original sequence, message for message.
      expect(
        [for (final chunk in chunks) ...chunk],
        equals(messages),
      );
    });

    test('UT-C1: a single message bigger than the budget is one chunk', () {
      final giant = UserMessage.text('g' * (budget * 4 + 8000));
      final chunks = chunkSummarizableMessages([fat('u'), giant], budget);
      expect(chunks, hasLength(2));
      expect(chunks[1], hasLength(1));
    });

    test('summarizationPayloadBudget floors at half the window', () {
      // A tiny summarizer window under a big main window's reserve must
      // still leave room to summarize into, never go negative.
      expect(
        summarizationPayloadBudget(
          8192,
          const CompactionSettings(
            enabled: true,
            reserveTokens: 16384,
            keepRecentTokens: 20000,
          ),
        ),
        4096,
      );
    });

    test(
      'IT-C1: an over-budget region is summarized chunk-wise; every '
      'outbound prompt stays under the payload budget',
      () async {
        final fake = recorder('FOLD');
        final messages = [for (var i = 0; i < 347; i++) fat('u$i-')];

        final summary = await generateSummary(
          messages,
          summarize: fake.call,
          maxPromptTokens: budget,
        );

        expect(summary, 'FOLD');
        expect(fake.prompts, hasLength(greaterThan(1)));
        // The #729 invariant: every recorded outbound prompt fits the
        // summarizer's window minus the reserve.
        for (final prompt in fake.prompts) {
          expect(
            estimateStringTokens(prompt),
            lessThanOrEqualTo(budget),
            reason: 'outbound payload exceeded the budget',
          );
        }
        // The fold: chunk 0 uses the summary prompt, later chunks the
        // update prompt threading the running summary.
        expect(fake.prompts.first, isNot(contains('<previous-checkpoint>')));
        for (var i = 1; i < fake.prompts.length; i++) {
          expect(fake.prompts[i], contains('<previous-checkpoint>'));
        }
      },
    );

    test('under-budget payloads ride the legacy prompt byte-identically',
        () async {
      final fake = recorder('S');
      final legacy = <String>[];
      final messages = [fat('u1'), fat('u2')];

      final bounded = await generateSummary(
        messages,
        summarize: fake.call,
        maxPromptTokens: budget,
      );
      final unbounded = await generateSummary(
        messages,
        summarize: (request) async {
          legacy.add(request.prompt);
          return SummarizationResult.success('S');
        },
      );

      expect(fake.prompts, hasLength(1)); // one call, no chunking
      expect(legacy.single, fake.prompts.single);
      expect(bounded, 'S');
      expect(unbounded, 'S');
    });

    test(
      'a single message bigger than the whole budget is truncated with an '
      'explicit note, and the prompt still fits',
      () async {
        final fake = recorder('S');
        // A giant ASSISTANT message: no candidate line (#81 keeps user
        // asks uncapped), so the fit helper is what bounds the payload.
        final giant = AssistantMessage(
          content: [TextContent(text: 'g' * (budget * 4 + 8000))],
          api: 'openai-completions',
          provider: 'openrouter',
          model: 'm1',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        );

        final summary = await generateSummary(
          [giant],
          summarize: fake.call,
          maxPromptTokens: budget,
        );

        expect(summary, 'S');
        expect(
          estimateStringTokens(fake.prompts.single),
          lessThanOrEqualTo(budget),
        );
        expect(fake.prompts.single, contains('more characters truncated'));
      },
    );
  });

  group('findCutPoint', () {
    test('keeps approximately keepRecentTokens, cutting on a user boundary', () {
      // Six messages of 100 tokens each (400 chars / 4).
      final entries = [
        _record('m1', _user('u', 400)),
        _record('m2', _assistant(400)),
        _record('m3', _user('u', 400)),
        _record('m4', _assistant(400)),
        _record('m5', _user('u', 400)),
        _record('m6', _assistant(400)),
      ];
      // Walking back: m6 (100), m5 (200), m4 (300), m3 (400 >= 350) -> cut m3.
      final cut = findCutPoint(entries, 0, entries.length, 350);
      expect(entries[cut.firstKeptEntryIndex].id, 'm3');
      expect(cut.isSplitTurn, isFalse);
      expect(cut.turnStartIndex, -1);
    });

    test('never cuts at a tool result', () {
      final entries = [
        _record('m1', _user('u', 400)),
        _record('m2', _assistant(400)),
        _record('m3', _toolResult(400)),
        _record('m4', _user('u', 400)),
        _record('m5', _assistant(400)),
      ];
      // m5 (100), m4 (200), m3 (300 >= 250) -> budget exhausts at the tool
      // result, but the cut must move forward to m4.
      final cut = findCutPoint(entries, 0, entries.length, 250);
      expect(entries[cut.firstKeptEntryIndex].id, 'm4');
      expect(cut.isSplitTurn, isFalse);
    });

    test('split turn: budget exhausts mid-turn', () {
      final entries = [
        _record('m1', _user('u', 400)),
        _record('m2', _assistant(400)),
        _record('m3', _toolResult(400)),
        _record('m4', _assistant(400)),
      ];
      // m4 (100), m3 (200 >= 150) -> cut at m4 (assistant, mid-turn).
      final cut = findCutPoint(entries, 0, entries.length, 150);
      expect(entries[cut.firstKeptEntryIndex].id, 'm4');
      expect(cut.isSplitTurn, isTrue);
      expect(entries[cut.turnStartIndex].id, 'm1');
    });

    test('pulls the cut back over non-message records', () {
      final tlc = ThinkingLevelChangeRecord(
        id: 'tlc',
        parentId: null,
        timestamp: DateTime.utc(2026),
        thinkingLevel: 'high',
      );
      final entries = [
        _record('m1', _user('u', 400)),
        tlc,
        _record('m2', _user('u', 400)),
        _record('m3', _assistant(400)),
      ];
      // m3 (100), m2 (200 >= 150) -> cut at m2, then pulled back over tlc.
      final cut = findCutPoint(entries, 0, entries.length, 150);
      expect(entries[cut.firstKeptEntryIndex].id, 'tlc');
    });

    test('no valid cut points: keeps everything from startIndex', () {
      final entries = [
        _record('m1', _toolResult(400)),
        _record('m2', _toolResult(400)),
      ];
      final cut = findCutPoint(entries, 0, entries.length, 100);
      expect(cut.firstKeptEntryIndex, 0);
      expect(cut.isSplitTurn, isFalse);
      expect(cut.turnStartIndex, -1);
    });

    test('respects startIndex and endIndex bounds', () {
      final entries = [
        _record('m1', _user('u', 400)),
        _record('m2', _user('u', 400)),
        _record('m3', _user('u', 400)),
        _record('m4', _user('u', 400)),
      ];
      // Only m2..m3 are in range; budget exceeds both -> cut stays at m2.
      final cut = findCutPoint(entries, 1, 3, 500);
      expect(entries[cut.firstKeptEntryIndex].id, 'm2');
    });

    test('branch summary records are valid cut points', () {
      final branch = BranchSummaryRecord(
        id: 'bs',
        parentId: null,
        timestamp: DateTime.utc(2026),
        fromId: 'x',
        summary: 's',
      );
      final entries = [
        _record('m1', _user('u', 400)),
        branch,
        _record('m2', _user('u', 400)),
        _record('m3', _assistant(400)),
      ];
      // m3 (100), m2 (200 >= 150) -> cut at m2, pulled back over bs.
      final cut = findCutPoint(entries, 0, entries.length, 150);
      expect(entries[cut.firstKeptEntryIndex].id, 'bs');
    });

    test('branch summary and custom message records are turn starts', () {
      final branch = BranchSummaryRecord(
        id: 'bs',
        parentId: null,
        timestamp: DateTime.utc(2026),
        fromId: 'x',
        summary: 's',
      );
      final custom = CustomMessageRecord(
        id: 'cm',
        parentId: null,
        timestamp: DateTime.utc(2026),
        customType: 'note',
        content: 'c',
        display: false,
      );
      final entries = [branch, custom, _record('m1', _assistant(400))];
      expect(findTurnStartIndex(entries, 2, 0), 1);
      expect(findTurnStartIndex(entries, 1, 0), 1);
      expect(findTurnStartIndex(entries, 0, 0), 0);
      // No turn start at all.
      final lonely = [_record('m1', _assistant(400))];
      expect(findTurnStartIndex(lonely, 0, 0), -1);
    });
  });

  group('findCutPoint pairing boundaries (AC4, issue #85)', () {
    AssistantMessage callOf(String id, int chars) => AssistantMessage(
      content: [
        TextContent(text: 'b' * chars),
        ToolCall(id: id, name: 'bash', arguments: const {}),
      ],
      api: 'openai-completions',
      provider: 'openrouter',
      model: 'm1',
      usage: Usage.zero,
      stopReason: StopReason.toolUse,
      timestamp: DateTime.utc(2026),
    );

    ToolResultMessage resultOf(String id, int chars) => ToolResultMessage(
      toolCallId: id,
      toolName: 'bash',
      content: [TextContent(text: 'r' * chars)],
      isError: false,
      timestamp: DateTime.utc(2026),
    );

    /// The post-compaction message view the pipeline builds: summaries
    /// project to user messages, kept MessageRecords pass through.
    List<Message> rebuiltAt(List<SessionRecord> entries, int cutIndex) => [
      UserMessage.text('HISTORY SUMMARY'),
      for (final entry in entries.sublist(cutIndex))
        if (entry is MessageRecord) entry.message,
    ];

    test('across every budget, the kept region never starts at a tool '
        'result and never orphans one', () {
      final entries = [
        _record('u1', _user('u1', 400)),
        _record('a1', callOf('c1', 400)),
        _record('r1', resultOf('c1', 400)),
        _record('u2', _user('u2', 400)),
        _record('a2', callOf('c2', 400)),
        _record('r2', resultOf('c2', 400)),
        _record('u3', _user('u3', 400)),
        _record('a3', callOf('c3', 400)),
        _record('r3', resultOf('c3', 400)),
      ];
      var checked = 0;
      for (var budget = 0; budget <= 1300; budget += 25) {
        final cut = findCutPoint(entries, 0, entries.length, budget);
        // The kept region never STARTS at a tool result: a cut to a
        // toolResult record would orphan it by construction.
        expect(
          entries[cut.firstKeptEntryIndex].message.role,
          isNot('toolResult'),
          reason: 'budget $budget',
        );
        // Whatever the boundary, the request boundary can restore wire
        // validity: an orphaned result (steering cuts) is dropped with a
        // note, never silently shipped.
        final rebuilt = rebuiltAt(entries, cut.firstKeptEntryIndex);
        final repaired = repairToolPairing(rebuilt);
        expect(
          validateToolPairing(repaired.messages),
          isEmpty,
          reason:
              'budget $budget: violations before repair = '
              '${validateToolPairing(rebuilt)}',
        );
        checked++;
      }
      expect(checked, greaterThan(20));
    });

    test('a cut that lands on steering text between call and result '
        'orphans the result — the repair drops it with a note (AC4)', () {
      final entries = [
        _record('u1', _user('u1', 400)),
        _record('a1', callOf('c1', 400)),
        _record('r1', resultOf('c1', 400)),
        _record('u2', _user('u2', 400)),
        _record('a2', callOf('c2', 400)),
        // 100 (r2) < budget <= 102 (r2 + steer) exhausts exactly here.
        _record('steer', UserMessage.text('steer!')),
        _record('r2', resultOf('c2', 400)),
      ];
      final cut = findCutPoint(entries, 0, entries.length, 101);
      expect(entries[cut.firstKeptEntryIndex].id, 'steer');

      final rebuilt = rebuiltAt(entries, cut.firstKeptEntryIndex);
      final violations = validateToolPairing(rebuilt);
      expect(violations.single.kind, ToolPairingViolationKind.orphanedResult);
      expect(violations.single.toolCallId, 'c2');

      final repaired = repairToolPairing(rebuilt);
      expect(validateToolPairing(repaired.messages), isEmpty);
      expect(repaired.report.droppedResultIds, ['c2']);
      // The note replaces the dropped result so the model is not gaslit.
      final note = repaired.messages.last as UserMessage;
      expect(note.content, contains('context note'));
    });
  });

  group('serializeConversation', () {
    test('serializes user, assistant and tool result messages', () {
      final messages = [
        UserMessage.text('hello there'),
        _assistant(
          0,
          content: [
            const ThinkingContent(thinking: 'let me think'),
            const TextContent(text: 'the answer'),
            ToolCall(
              id: 'c1',
              name: 'read',
              arguments: {'path': '/x', 'limit': 3},
            ),
          ],
        ),
        _toolResult(20),
      ];
      final text = serializeConversation(messages);
      expect(text, contains('[User]: hello there'));
      expect(text, contains('[Assistant thinking]: let me think'));
      expect(text, contains('[Assistant]: the answer'));
      expect(
        text,
        contains('[Assistant tool calls]: read(path="/x", limit=3)'),
      );
      expect(text, contains('[Tool result]: ${'r' * 20}'));
    });

    test('joins user text blocks and skips images', () {
      final message = UserMessage(
        content: [
          const TextContent(text: 'part1'),
          const ImageContent(data: 'AAAA', mimeType: 'image/png'),
          const TextContent(text: 'part2'),
        ],
        timestamp: DateTime.utc(2026),
      );
      expect(serializeConversation([message]), '[User]: part1part2');
    });

    test('truncates tool results beyond 2000 chars (pi limit)', () {
      final text = serializeConversation([_toolResult(2500)]);
      expect(text, contains('r' * 2000));
      expect(text, contains('[... 500 more characters truncated]'));
      expect(text, isNot(contains('r' * 2001)));
    });
  });

  group('file operations', () {
    test('extracts read/write/edit paths from assistant tool calls', () {
      final ops = createFileOps();
      extractFileOpsFromMessage(
        _assistant(
          0,
          content: [
            ToolCall(id: '1', name: 'read', arguments: {'path': '/a.dart'}),
            ToolCall(id: '2', name: 'write', arguments: {'path': '/b.dart'}),
            ToolCall(id: '3', name: 'edit', arguments: {'path': '/c.dart'}),
            ToolCall(id: '4', name: 'bash', arguments: {'command': 'ls'}),
            ToolCall(id: '5', name: 'read', arguments: const {}),
          ],
        ),
        ops,
      );
      expect(ops.read, {'/a.dart'});
      expect(ops.written, {'/b.dart'});
      expect(ops.edited, {'/c.dart'});
    });

    test('ignores non-assistant messages', () {
      final ops = createFileOps();
      extractFileOpsFromMessage(UserMessage.text('read /a.dart'), ops);
      expect(ops.read, isEmpty);
    });

    test('computeFileLists splits read-only from modified, sorted', () {
      final ops = createFileOps()
        ..read.addAll(['/z.dart', '/a.dart', '/b.dart'])
        ..written.add('/b.dart')
        ..edited.add('/c.dart');
      final lists = computeFileLists(ops);
      expect(lists.readFiles, ['/a.dart', '/z.dart']);
      expect(lists.modifiedFiles, ['/b.dart', '/c.dart']);
    });

    test('formatFileOperations renders pi metadata tags', () {
      expect(formatFileOperations([], []), '');
      final text = formatFileOperations(['/a.dart'], ['/b.dart']);
      expect(
        text,
        '\n\n<read-files>\n/a.dart\n</read-files>\n\n'
        '<modified-files>\n/b.dart\n</modified-files>',
      );
      expect(formatFileOperations(['/a.dart'], []), contains('<read-files>'));
      expect(
        formatFileOperations(['/a.dart'], []),
        isNot(contains('<modified-files>')),
      );
    });
  });

  group('summary prompts (ported verbatim from pi)', () {
    test('system prompt forbids continuing the conversation', () {
      expect(
        summarizationSystemPrompt,
        startsWith('You are a context checkpoint assistant.'),
      );
      expect(
        summarizationSystemPrompt,
        contains('Do NOT continue the conversation'),
      );
    });

    test('structured prompt contains all pi sections', () {
      for (final section in [
        '## Goal',
        '## Constraints & Preferences',
        '## Progress',
        '### Done',
        '### In Progress',
        '### Blocked',
        '## Key Decisions',
        '## Next Steps',
        '## Critical Context',
      ]) {
        expect(summarizationPrompt, contains(section));
      }
      expect(
        summarizationPrompt,
        contains(
          'Preserve exact file paths, function names, and error messages.',
        ),
      );
    });

    test('update prompt references the previous summary tags', () {
      expect(updateSummarizationPrompt, contains('<previous-checkpoint>'));
      expect(
        updateSummarizationPrompt,
        contains('PRESERVE all existing information'),
      );
    });

    test('turn prefix prompt describes the split-turn situation', () {
      expect(turnPrefixSummarizationPrompt, contains('PREFIX of a turn'));
      expect(turnPrefixSummarizationPrompt, contains('## Original Request'));
    });
  });
}
