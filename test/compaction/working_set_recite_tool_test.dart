// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-210 — the `recite_goal` tool: the agent's write path into the
/// goal-recitation slot. Latest-wins semantics (reciting overwrites),
/// write-side budget enforcement (an oversized goal clips with an
/// explicit marker the agent SEES in the result), and the empty-goal
/// discovery mode that reports the current slot content. The no-callback
/// host runs the same graceful cannot-execute contract as
/// `obligation_mark_done`.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('recite_goal tool', () {
    test('a cancelled token aborts before any write', () async {
      var writes = 0;
      final tool = reciteGoalTool(
        write: (goal) async {
          writes++;
          return 'ok';
        },
        current: () async => null,
      );
      final source = CancelTokenSource()..cancel();
      final token = source.token;
      await expectLater(
        tool.execute({'goal': 'x'}, token, null),
        throwsA(anything),
      );
      expect(writes, 0, reason: 'a cancelled recite must not write');
    });

    test('a null callback yields the graceful cannot-execute result', () async {
      final tool = reciteGoalTool();
      final result = await tool.execute({'goal': 'x'}, null, null);
      expect(_flat(result.content), contains('does not maintain'));
      expect(result.terminate, isFalse);
    });

    test('reciting stores the goal and reports the slot is set', () async {
      String? stored;
      final tool = reciteGoalTool(
        write: (goal) async {
          stored = goal;
          return 'ok';
        },
        current: () async => null,
      );
      final result = await tool.execute(
        {'goal': 'ship the login fix'},
        null,
        null,
      );
      expect(stored, 'ship the login fix');
      expect(_flat(result.content), contains('ok'));
    });

    test(
      'an oversized goal clips BEFORE the write, with a visible marker',
      () async {
        String? stored;
        final tool = reciteGoalTool(
          write: (goal) async {
            stored = goal;
            return 'ok';
          },
          current: () async => null,
        );
        final long = 'g' * (goalRecitationBudgetChars + 500);
        final result = await tool.execute({'goal': long}, null, null);
        // The stored goal is the bounded one…
        expect(stored!.length, lessThanOrEqualTo(goalRecitationBudgetChars));
        expect(stored, contains('[clipped — recite a shorter goal]'));
        // …and the agent is told, not left guessing.
        expect(_flat(result.content), contains('clipped'));
        expect(stored, contains('[clipped — recite a shorter goal]'));
      },
    );

    test('a multi-line goal is stored verbatim (render flattens)', () async {
      String? stored;
      final tool = reciteGoalTool(
        write: (goal) async {
          stored = goal;
          return 'ok';
        },
        current: () async => null,
      );
      await tool.execute({'goal': 'line one\nline two'}, null, null);
      expect(stored, 'line one\nline two');
    });

    test(
      'an empty/absent goal is discovery: reads via current, no write',
      () async {
        var writes = 0;
        var reads = 0;
        final tool = reciteGoalTool(
          write: (goal) async {
            writes++;
            return 'ok';
          },
          current: () async {
            reads++;
            return GoalRecitation(
              goal: 'fix the crash',
              updatedAt: DateTime.utc(2026),
            );
          },
        );
        final empty = await tool.execute({'goal': ''}, null, null);
        final absent = await tool.execute(const {}, null, null);
        expect(writes, 0, reason: 'discovery must not write');
        expect(reads, 2);
        expect(_flat(empty.content), contains('current goal: fix the crash'));
        expect(_flat(absent.content), contains('current goal: fix the crash'));
      },
    );

    test('discovery with an empty slot points at how to set one', () async {
      final tool = reciteGoalTool(
        write: (goal) async => 'ok',
        current: () async => null,
      );
      final result = await tool.execute(const {}, null, null);
      expect(_flat(result.content), contains('no goal recited'));
    });

    test(
      'latest wins: reciting overwrites the slot (no append drift)',
      () async {
        final stored = <String>[];
        final tool = reciteGoalTool(
          write: (goal) async {
            stored.add(goal);
            return 'ok';
          },
          current: () async => null,
        );
        await tool.execute({'goal': 'first'}, null, null);
        await tool.execute({'goal': 'second'}, null, null);
        expect(stored, ['first', 'second']);
      },
    );
  });

  group('recite_goal persistence', () {
    test('the persisted snapshot renders at the projection tail', () async {
      final fs = MemoryFileSystem();
      final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('hi'));
      // The persist-layer write (what closeObligation is for the ledger):
      // clip, append, report.
      final goal = reciteGoalForStorage('fix the crash');
      await session.appendCustomEntry(
        customType: goalRecitationRecordType,
        data: goalRecitationPayload(goal),
      );
      final messages = await session.buildContextMessages();
      expect(
        _flat((messages.last as UserMessage).content),
        contains('goal: fix the crash'),
      );
      // Round-trip: the slot survives a reload.
      final meta = await session.getMetadata();
      final reopened = Session(await JsonlSessionStorage.open(fs, meta.path));
      final reopenedMessages = await reopened.buildContextMessages();
      expect(
        _flat((reopenedMessages.last as UserMessage).content),
        contains('goal: fix the crash'),
      );
    });

    test('reciteGoalForStorage bounds oversized goals', () {
      final long = 'g' * (goalRecitationBudgetChars + 500);
      final clipped = reciteGoalForStorage(long);
      expect(clipped.length, lessThanOrEqualTo(goalRecitationBudgetChars));
      expect(clipped, contains('[clipped — recite a shorter goal]'));
      expect(reciteGoalForStorage('short'), 'short');
    });
  });
}

String _flat(Object? content) => content is String
    ? content
    : (content as List<Object>)
          .whereType<TextContent>()
          .map((block) => block.text)
          .join('\n');
