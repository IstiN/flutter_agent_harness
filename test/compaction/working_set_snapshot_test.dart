// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2423 C1 — the working-set SNAPSHOT: the `custom` record kind, the
/// latest-wins read rule (with the legacy `goal_recitation` fallback), the
/// system-channel block render, and the cap constant (AC1, AC2, AC4).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('working-set snapshot records', () {
    test('payload round-trips through the tolerant parse', () {
      final snapshot = WorkingSetSnapshot(
        text: 'decisions: X; red list: never Y; next: Z',
        updatedAt: DateTime.utc(2026, 11, 25, 12, 30),
      );
      final parsed = workingSetFromPayload(snapshot.toPayload());
      expect(parsed, isNotNull);
      expect(parsed!.text, snapshot.text);
      expect(parsed.chars, snapshot.text.length);
      expect(parsed.isClear, isFalse);
      expect(parsed.updatedAt, snapshot.updatedAt);
      // The payload names the size (the HEP frame / TUI line report it).
      expect(snapshot.toPayload()['chars'], snapshot.text.length);
    });

    test('junk payloads parse to null, never throw', () {
      expect(workingSetFromPayload(null), isNull);
      expect(workingSetFromPayload('x'), isNull);
      expect(workingSetFromPayload(<String, Object?>{}), isNull);
      expect(workingSetFromPayload(<String, Object?>{'text': 7}), isNull);
    });

    test('an empty text is the CLEAR snapshot (not junk)', () {
      final parsed = workingSetFromPayload(<String, Object?>{
        'text': '',
        'updatedAt': DateTime.utc(2026).toIso8601String(),
      });
      expect(parsed, isNotNull);
      expect(parsed!.isClear, isTrue);
    });

    test('latest snapshot wins in file order', () {
      final records = <SessionRecord>[
        _workingSet('first', at: 1),
        _workingSet('second', at: 2),
      ];
      expect(latestWorkingSetIn(records)!.text, 'second');
    });

    test('a cleared (empty-text) latest snapshot clears the slot', () {
      final records = <SessionRecord>[
        _workingSet('first', at: 1),
        _workingSet('', at: 2),
      ];
      final latest = latestWorkingSetIn(records);
      expect(latest, isNotNull, reason: 'the clear event is a snapshot');
      expect(latest!.isClear, isTrue);
      expect(renderWorkingSetSystemBlock(latest), isEmpty);
    });

    test('a custom record of another kind never counts', () {
      final records = <SessionRecord>[
        CustomRecord(
          id: 'a',
          parentId: null,
          timestamp: DateTime.utc(2026, 1, 1, 0, 0, 1),
          customType: 'obligations_ledger',
          data: const {'text': 'not a working set'},
        ),
      ];
      expect(latestWorkingSetIn(records), isNull);
    });
  });

  group('legacy goal_recitation fallback (gh-210 retired)', () {
    test('a legacy snapshot renders as the working set', () {
      final records = <SessionRecord>[_legacyGoal('fix the login crash')];
      final latest = latestWorkingSetIn(records);
      expect(latest, isNotNull);
      expect(latest!.text, 'fix the login crash');
      expect(latest.legacy, isTrue);
    });

    test('a working_set record supersedes every older legacy snapshot', () {
      final records = <SessionRecord>[
        _legacyGoal('old goal'),
        _workingSet('the real working set', at: 2),
      ];
      final latest = latestWorkingSetIn(records)!;
      expect(latest.text, 'the real working set');
      expect(latest.legacy, isFalse);
    });

    test('a working_set CLEAR after a legacy snapshot clears it', () {
      final records = <SessionRecord>[
        _legacyGoal('old goal'),
        _workingSet('', at: 2),
      ];
      expect(latestWorkingSetIn(records)!.isClear, isTrue);
    });

    test('the scan fallback (custom records only) applies the same rule', () {
      final scanned = <CustomRecord>[
        _legacyGoal('old goal') as CustomRecord,
        _workingSet('newer', at: 5) as CustomRecord,
      ];
      expect(latestWorkingSetIn(scanned)!.text, 'newer');
    });
  });

  group('the system-channel block', () {
    final snapshot = WorkingSetSnapshot(
      text: 'decisions: X\nred list: never Y\nnext: Z',
      updatedAt: DateTime.utc(2026, 11, 25, 12, 30),
    );

    test('renders verbatim inside the agent-sourced tag', () {
      final block = renderWorkingSetSystemBlock(snapshot);
      expect(block, startsWith('<working-set source="agent" updated="'));
      expect(block, endsWith('</working-set>'));
      expect(block, contains('\n${snapshot.text}\n'));
      // The clock is the snapshot's local HH:MM.
      final local = snapshot.updatedAt.toLocal();
      final hhmm =
          '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
      expect(block, contains('updated="$hhmm"'));
      expect(block, hasLength(lessThan(snapshot.text.length + 80)));
    });

    test('no snapshot (or a clear) renders no bytes', () {
      expect(renderWorkingSetSystemBlock(null), isEmpty);
      expect(
        renderWorkingSetSystemBlock(
          WorkingSetSnapshot(text: '', updatedAt: DateTime.utc(2026)),
        ),
        isEmpty,
      );
    });

    test('appends to the system prompt; the static prefix is byte-stable', () {
      const base = 'You are a coding agent.\n\n## Rules\n- be honest';
      final suffixed = appendWorkingSetToSystemPrompt(base, snapshot)!;
      expect(suffixed, startsWith(base));
      expect(suffixed, '$base\n${renderWorkingSetSystemBlock(snapshot)}');
      // A session without a snapshot renders the prompt byte-identically.
      expect(
        appendWorkingSetToSystemPrompt(base, null),
        same(base),
        reason: 'no snapshot ⇒ the identical string object (I3)',
      );
      expect(
        appendWorkingSetToSystemPrompt(
          base,
          WorkingSetSnapshot(
            text: 'other notes',
            updatedAt: DateTime.utc(2026),
          ),
        ),
        startsWith(base),
        reason: 'a write changes only the suffix (F1)',
      );
    });

    test('a prompt-less agent carries the block alone', () {
      final only = appendWorkingSetToSystemPrompt(null, snapshot)!;
      expect(only, renderWorkingSetSystemBlock(snapshot));
      expect(appendWorkingSetToSystemPrompt(null, null), isNull);
      expect(appendWorkingSetToSystemPrompt('', null), '');
    });
  });

  group('the cap', () {
    test('is 4096 chars (owner default OQ1), pinned by test', () {
      expect(workingSetMaxChars, 4096);
    });
  });
}

SessionRecord _workingSet(String text, {required int at}) => CustomRecord(
  id: 'ws$at',
  parentId: null,
  timestamp: DateTime.utc(2026, 1, 1, 0, 0, at),
  customType: workingSetRecordType,
  data: WorkingSetSnapshot(
    text: text,
    updatedAt: DateTime.utc(2026, 1, 1, 0, 0, at),
  ).toPayload(),
);

SessionRecord _legacyGoal(String goal) => CustomRecord(
  id: 'goal-$goal',
  parentId: null,
  timestamp: DateTime.utc(2026, 1, 1, 0, 0, 0),
  customType: goalRecitationRecordType,
  data: goalRecitationPayload(goal),
);
