// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-210 — the bounded working set: the goal recitation slot (a
/// latest-snapshot-wins `custom` ledger the agent updates through
/// `goal_recite`) and the recently-touched-file path references,
/// re-injected at the context tail after a compact, with enforced
/// budgets. Pure-derivation unit tests; the projection/hide-protection
/// integration lives in `working_set_projection_test.dart`.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) =>
    AssistantMessage(
      content: [
        TextContent(text: text),
        ...?calls,
      ],
      api: 'anthropic-messages',
      provider: 'p',
      model: 'm1',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    );

ToolResultMessage _result(String callId, String name, String text) =>
    ToolResultMessage(
      toolCallId: callId,
      toolName: name,
      content: [TextContent(text: text)],
      isError: false,
      timestamp: DateTime.utc(2026),
    );

void main() {
  group('goal recitation records', () {
    test('payload round-trips through the tolerant parse', () {
      final payload = goalRecitationPayload('ship the parser fix');
      final parsed = goalRecitationFromPayload(payload);
      expect(parsed, isNotNull);
      expect(parsed!.goal, 'ship the parser fix');
      expect(parsed.updatedAt, isNot(DateTime.fromMillisecondsSinceEpoch(0)));
      // Re-parsing the parsed record's payload is stable.
      expect(
        goalRecitationFromPayload(parsed.toPayload())!.goal,
        'ship the parser fix',
      );
      // Debug aid stays honest.
      expect(parsed.toString(), contains('${parsed.goal.length} chars'));
      // A junk updatedAt falls back to the epoch, never throws.
      final junkTime = goalRecitationFromPayload(const {
        'goal': 'fix',
        'updatedAt': 'not-a-date',
      });
      expect(junkTime!.updatedAt, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('junk payloads parse to null, never throw', () {
      expect(goalRecitationFromPayload(null), isNull);
      expect(goalRecitationFromPayload('nope'), isNull);
      expect(goalRecitationFromPayload(42), isNull);
      expect(goalRecitationFromPayload(const {}), isNull);
      expect(goalRecitationFromPayload(const {'goal': 42}), isNull);
      // Blank goal = the agent cleared the slot (still not a goal).
      expect(goalRecitationFromPayload(const {'goal': '   '}), isNull);
    });

    test('latest snapshot wins in file order', () {
      final records = <SessionRecord>[
        CustomRecord(
          id: 'a',
          parentId: null,
          timestamp: DateTime.utc(2026),
          customType: goalRecitationRecordType,
          data: goalRecitationPayload('first goal'),
        ),
        CustomRecord(
          id: 'b',
          parentId: 'a',
          timestamp: DateTime.utc(2026),
          customType: 'obligations_ledger',
          data: <Object?>[],
        ),
        CustomRecord(
          id: 'c',
          parentId: 'b',
          timestamp: DateTime.utc(2026),
          customType: goalRecitationRecordType,
          data: goalRecitationPayload('second goal'),
        ),
      ];
      expect(latestGoalRecitationIn(records)!.goal, 'second goal');
      expect(latestGoalRecitationIn(<SessionRecord>[]), isNull);
    });

    test('a cleared (empty-goal) latest snapshot clears the slot', () {
      final records = <SessionRecord>[
        CustomRecord(
          id: 'a',
          parentId: null,
          timestamp: DateTime.utc(2026),
          customType: goalRecitationRecordType,
          data: goalRecitationPayload('first goal'),
        ),
        CustomRecord(
          id: 'b',
          parentId: 'a',
          timestamp: DateTime.utc(2026),
          customType: goalRecitationRecordType,
          data: goalRecitationPayload(''),
        ),
      ];
      expect(latestGoalRecitationIn(records), isNull);
    });
  });

  group('recentlyTouchedPaths', () {
    test('collects write/edit call paths, newest-last, distinct', () {
      final path = <SessionRecord>[
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: _assistant(
            'writing',
            calls: [
              ToolCall(
                id: 'c1',
                name: 'write',
                arguments: {'path': 'lib/a.dart', 'content': 'x'},
              ),
            ],
          ),
        ),
        MessageRecord(
          id: 'r2',
          parentId: 'r1',
          timestamp: DateTime.utc(2026),
          message: _assistant(
            'editing',
            calls: [
              ToolCall(id: 'c2', name: 'edit', arguments: {'path': './b.dart'}),
            ],
          ),
        ),
        MessageRecord(
          id: 'r3',
          parentId: 'r2',
          timestamp: DateTime.utc(2026),
          message: _result('c2', 'edit', 'ok'),
        ),
        // A re-mention moves the path to the newest position.
        MessageRecord(
          id: 'r4',
          parentId: 'r3',
          timestamp: DateTime.utc(2026),
          message: _assistant(
            'again',
            calls: [
              ToolCall(
                id: 'c3',
                name: 'write',
                arguments: {'path': 'lib/a.dart', 'content': 'y'},
              ),
            ],
          ),
        ),
      ];
      expect(recentlyTouchedPaths(path), ['./b.dart', 'lib/a.dart']);
    });

    test('ignores read-class calls, pathless calls and non-call records', () {
      final path = <SessionRecord>[
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: _assistant(
            'mix',
            calls: [
              ToolCall(id: 'c1', name: 'read', arguments: {'path': 'x.dart'}),
              ToolCall(id: 'c2', name: 'bash', arguments: {'command': 'ls'}),
              ToolCall(id: 'c3', name: 'edit', arguments: {}),
              ToolCall(id: 'c4', name: 'write', arguments: {'path': '  '}),
            ],
          ),
        ),
        MessageRecord(
          id: 'r2',
          parentId: 'r1',
          timestamp: DateTime.utc(2026),
          message: _assistant('plain text'),
        ),
        CustomRecord(
          id: 'r3',
          parentId: 'r2',
          timestamp: DateTime.utc(2026),
          customType: 'whatever',
          data: null,
        ),
      ];
      expect(recentlyTouchedPaths(path), isEmpty);
    });
  });

  group('hasCompactionBoundary', () {
    test('false on a plain transcript', () {
      final path = <SessionRecord>[
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('hi'),
        ),
      ];
      expect(hasCompactionBoundary(path), isFalse);
    });

    test('true for a hide, a checkpoint and a classic compaction', () {
      bool withRecord(SessionRecord record) => hasCompactionBoundary([
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('hi'),
        ),
        record,
      ]);
      expect(
        withRecord(
          HiddenRangeRecord(
            id: 'h',
            parentId: 'r1',
            timestamp: DateTime.utc(2026),
            recordIds: const ['r1'],
          ),
        ),
        isTrue,
      );
      expect(
        withRecord(
          CompactCheckpointRecord(
            id: 'c',
            parentId: 'r1',
            timestamp: DateTime.utc(2026),
            firstRecordId: 'r1',
            lastRecordId: 'r1',
            text: 'summary',
            coversRecordIds: const ['r1'],
            flattenedRecordIds: const [],
          ),
        ),
        isTrue,
      );
      expect(
        withRecord(
          CompactionRecord(
            id: 'k',
            parentId: 'r1',
            timestamp: DateTime.utc(2026),
            summary: 'classic summary',
            firstKeptEntryId: 'r1',
            tokensBefore: 100,
          ),
        ),
        isTrue,
      );
    });
  });

  group('renderWorkingSetBlock', () {
    test('no recitation and no compaction boundary renders nothing', () {
      final path = <SessionRecord>[
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('hi'),
        ),
      ];
      expect(renderWorkingSetBlock(path), isEmpty);
    });

    test('a recitation alone renders the goal section', () {
      final path = <SessionRecord>[
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('hi'),
        ),
      ];
      final block = renderWorkingSetBlock(
        path,
        recitation: GoalRecitation(
          goal: 'fix the parser, then update docs',
          updatedAt: DateTime.utc(2026),
        ),
      );
      expect(block, startsWith('<system-notice>'));
      expect(block, endsWith('</system-notice>'));
      expect(block, contains('goal: fix the parser, then update docs'));
      // No compaction boundary → no files section.
      expect(block, isNot(contains('recently touched files')));
    });

    test('post-compaction paths render the files section', () {
      final path = <SessionRecord>[
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: _assistant(
            'w',
            calls: [
              ToolCall(
                id: 'c1',
                name: 'write',
                arguments: {'path': 'lib/a.dart', 'content': 'x'},
              ),
            ],
          ),
        ),
        HiddenRangeRecord(
          id: 'h',
          parentId: 'r1',
          timestamp: DateTime.utc(2026),
          recordIds: const ['r1'],
        ),
      ];
      final block = renderWorkingSetBlock(path);
      expect(block, contains('recently touched files'));
      expect(block, contains('- lib/a.dart'));
      expect(block, isNot(contains('goal:')));
    });

    test('both sections render together', () {
      final path = <SessionRecord>[
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: _assistant(
            'w',
            calls: [
              ToolCall(
                id: 'c1',
                name: 'write',
                arguments: {'path': 'lib/a.dart', 'content': 'x'},
              ),
            ],
          ),
        ),
        HiddenRangeRecord(
          id: 'h',
          parentId: 'r1',
          timestamp: DateTime.utc(2026),
          recordIds: const ['r1'],
        ),
      ];
      final block = renderWorkingSetBlock(
        path,
        recitation: GoalRecitation(
          goal: 'the goal',
          updatedAt: DateTime.utc(2026),
        ),
      );
      expect(block, contains('goal: the goal'));
      expect(block, contains('- lib/a.dart'));
    });

    test('the file count is capped with an explicit counting tail', () {
      final path = <SessionRecord>[];
      final records = <SessionRecord>[];
      for (var i = 0; i < 10; i++) {
        records.add(
          MessageRecord(
            id: 'r$i',
            parentId: i == 0 ? null : 'r${i - 1}',
            timestamp: DateTime.utc(2026),
            message: _assistant(
              'w$i',
              calls: [
                ToolCall(
                  id: 'c$i',
                  name: 'write',
                  arguments: {'path': 'f$i.dart', 'content': 'x'},
                ),
              ],
            ),
          ),
        );
      }
      records.add(
        HiddenRangeRecord(
          id: 'h',
          parentId: 'r9',
          timestamp: DateTime.utc(2026),
          recordIds: const ['r0'],
        ),
      );
      path.addAll(records);
      final block = renderWorkingSetBlock(path);
      // The 8 NEWEST paths render (f2..f9); the two oldest are counted.
      expect(block, contains('- f9.dart'));
      expect(block, contains('- f2.dart'));
      expect(block, isNot(contains('- f1.dart')));
      expect(block, contains('… and 2 more touched files'));
    });

    test('the char budget drops the oldest files, never the newest', () {
      final records = <SessionRecord>[];
      for (var i = 0; i < 6; i++) {
        records.add(
          MessageRecord(
            id: 'r$i',
            parentId: i == 0 ? null : 'r${i - 1}',
            timestamp: DateTime.utc(2026),
            message: _assistant(
              'w$i',
              calls: [
                ToolCall(
                  id: 'c$i',
                  name: 'write',
                  arguments: {
                    'path': 'very/long/path/number/$i/some_file.dart',
                    'content': 'x',
                  },
                ),
              ],
            ),
          ),
        );
      }
      records.add(
        HiddenRangeRecord(
          id: 'h',
          parentId: 'r5',
          timestamp: DateTime.utc(2026),
          recordIds: const ['r0'],
        ),
      );
      final block = renderWorkingSetBlock(records, budgetChars: 260);
      expect(block.length, lessThanOrEqualTo(260));
      // The newest file always survives; the oldest are counted away.
      expect(block, contains('number/5/some_file.dart'));
      expect(block, isNot(contains('number/0/some_file.dart')));
      expect(block, contains('… and 4 more touched files'));
    });

    test('a zero budget disables the whole block', () {
      final path = <SessionRecord>[
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: _assistant(
            'w',
            calls: [
              ToolCall(
                id: 'c1',
                name: 'write',
                arguments: {'path': 'a.dart', 'content': 'x'},
              ),
            ],
          ),
        ),
        HiddenRangeRecord(
          id: 'h',
          parentId: 'r1',
          timestamp: DateTime.utc(2026),
          recordIds: const ['r1'],
        ),
      ];
      expect(
        renderWorkingSetBlock(
          path,
          recitation: GoalRecitation(goal: 'g', updatedAt: DateTime.utc(2026)),
          budgetChars: 0,
        ),
        isEmpty,
      );
    });

    test('an oversized goal is clipped with an explicit marker', () {
      final path = <SessionRecord>[
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('hi'),
        ),
      ];
      final block = renderWorkingSetBlock(
        path,
        recitation: GoalRecitation(
          goal: 'g' * (goalRecitationBudgetChars + 500),
          updatedAt: DateTime.utc(2026),
        ),
      );
      expect(block.length, lessThan(goalRecitationBudgetChars + 500));
      expect(block, contains('[clipped'));
      // The render flattens the goal to one line.
      expect(
        block.split('\n').where((l) => l.startsWith('goal: ')),
        hasLength(1),
      );
    });

    test('multi-line goals render as one flattened line', () {
      final path = <SessionRecord>[
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('hi'),
        ),
      ];
      final block = renderWorkingSetBlock(
        path,
        recitation: GoalRecitation(
          goal: 'line one\nline two\n\nline three',
          updatedAt: DateTime.utc(2026),
        ),
      );
      expect(block, contains('goal: line one line two line three'));
    });
  });
}
