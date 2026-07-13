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

UserMessage _user(String id, int chars) => UserMessage.text('$id${'a' * chars}');

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
      expect(
        shouldCompact(83616, 100000, defaultCompactionSettings),
        isFalse,
      );
      expect(shouldCompact(83617, 100000, defaultCompactionSettings), isTrue);
    });
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
            ToolCall(
              id: '1',
              name: 'read',
              arguments: {'path': '/a.dart'},
            ),
            ToolCall(
              id: '2',
              name: 'write',
              arguments: {'path': '/b.dart'},
            ),
            ToolCall(
              id: '3',
              name: 'edit',
              arguments: {'path': '/c.dart'},
            ),
            ToolCall(
              id: '4',
              name: 'bash',
              arguments: {'command': 'ls'},
            ),
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
        startsWith('You are a context summarization assistant.'),
      );
      expect(summarizationSystemPrompt, contains('Do NOT continue the conversation'));
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
        contains('Preserve exact file paths, function names, and error messages.'),
      );
    });

    test('update prompt references the previous summary tags', () {
      expect(updateSummarizationPrompt, contains('<previous-summary>'));
      expect(updateSummarizationPrompt, contains('PRESERVE all existing information'));
    });

    test('turn prefix prompt describes the split-turn situation', () {
      expect(turnPrefixSummarizationPrompt, contains('PREFIX of a turn'));
      expect(turnPrefixSummarizationPrompt, contains('## Original Request'));
    });
  });
}
