import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart';
import 'package:test/test.dart';

/// gh-1412: the FinalizeGate contract + TaskLedger — the agent re-verifies
/// produced state against the task text before declaring done. These tests
/// pin the ledger model, the final-answer block parser, and the contract
/// prompt's named items (UT-1's contract-content half; the prompt-builder
/// presence half lives in test/cli/finalize_gate_prompt_test.dart).
void main() {
  const ledgerBlock = '''
```task-ledger
- requirement: create script.py in the workspace root
  command: test -f script.py
  expected: exit 0
  actual: exit 0
  status: pass
- requirement: script.py is executable
  command: test -x script.py
  expected: exit 0
  actual: exit 1
  status: fixed
```
''';

  group('parseTaskLedger', () {
    test('parses items with all fields from the fenced block', () {
      final ledger = parseTaskLedger('Preamble text.\n$ledgerBlock\nDone.');
      expect(ledger, isNotNull);
      expect(ledger!.items, hasLength(2));
      expect(
        ledger.items[0].requirement,
        'create script.py in the workspace root',
      );
      expect(ledger.items[0].command, 'test -f script.py');
      expect(ledger.items[0].expected, 'exit 0');
      expect(ledger.items[0].actual, 'exit 0');
      expect(ledger.items[0].status, TaskLedgerItemStatus.pass);
      expect(ledger.items[1].status, TaskLedgerItemStatus.fixed);
    });

    test('takes the LAST block when the message carries several', () {
      final text =
          '$ledgerBlock\nRevised after a re-check:\n'
          '```\nignored plain fence\n```\n'
          '```task-ledger\n'
          '- requirement: only item\n'
          '  status: pass\n'
          '```\n';
      final ledger = parseTaskLedger(text);
      expect(ledger!.items, hasLength(1));
      expect(ledger.items[0].requirement, 'only item');
    });

    test('missing status parses as fail (unverified never counts as pass)', () {
      final ledger = parseTaskLedger(
        '```task-ledger\n'
        '- requirement: the revert step\n'
        '  command: git status --porcelain\n'
        '```\n',
      );
      expect(ledger!.items.single.status, TaskLedgerItemStatus.fail);
      expect(ledger.items.single.verified, isFalse);
    });

    test('tolerant status tokens: pass/fixed prefixes, junk is fail', () {
      TaskLedgerItemStatus statusOf(String value) => parseTaskLedger(
        '```task-ledger\n- requirement: r\n  status: $value\n```\n',
      )!.items.single.status;
      expect(statusOf('pass'), TaskLedgerItemStatus.pass);
      expect(statusOf('PASS ✅'), TaskLedgerItemStatus.pass);
      expect(statusOf('fixed (chmod applied)'), TaskLedgerItemStatus.fixed);
      expect(statusOf('fail'), TaskLedgerItemStatus.fail);
      expect(statusOf('FAILED'), TaskLedgerItemStatus.fail);
      expect(statusOf('unknown-junk'), TaskLedgerItemStatus.fail);
    });

    test('entries without a requirement are skipped', () {
      final ledger = parseTaskLedger(
        '```task-ledger\n'
        '- command: ls\n'
        '  status: pass\n'
        '- requirement: real item\n'
        '  status: pass\n'
        '```\n',
      );
      expect(ledger!.items, hasLength(1));
      expect(ledger.items.single.requirement, 'real item');
    });

    test('no block at all parses to null (legacy answer)', () {
      expect(parseTaskLedger('just a plain final answer'), isNull);
    });

    test('an empty or requirement-less block parses to null', () {
      expect(parseTaskLedger('```task-ledger\n```\n'), isNull);
    });

    test('unterminated final block still parses (truncated answer)', () {
      final ledger = parseTaskLedger(
        '```task-ledger\n- requirement: item\n  status: pass\n',
      );
      expect(ledger!.items.single.requirement, 'item');
    });

    test('does not mistake other fenced languages for the ledger', () {
      expect(parseTaskLedger('```bash\ntest -x script.py\n```\n'), isNull);
    });
  });

  group('gh-1516: tolerant strip — near-miss ledger shapes', () {
    // The shape models actually emit when they miss the fence: an unfenced
    // `task-ledger` heading followed by plain bullet entries. The parser
    // must catch it (persist the record) and the stripper must remove it
    // (the transcript never shows the ledger, either way).
    const unfencedLedger = '''
## task-ledger
- requirement: create script.py in the workspace root
  command: test -f script.py
  expected: exit 0
  actual: exit 0
  status: pass
- requirement: script.py is executable
  command: test -x script.py
  expected: exit 0
  actual: exit 1
  status: fixed
''';

    test('parses the unfenced heading + bullet shape', () {
      final ledger = parseTaskLedger('Answer text.\n$unfencedLedger\nDone.');
      expect(ledger, isNotNull);
      expect(ledger!.items, hasLength(2));
      expect(
        ledger.items[0].requirement,
        'create script.py in the workspace root',
      );
      expect(ledger.items[0].status, TaskLedgerItemStatus.pass);
      expect(ledger.items[1].status, TaskLedgerItemStatus.fixed);
    });

    test('accepts a bold heading variant (**task-ledger**)', () {
      final ledger = parseTaskLedger(
        '**task-ledger**\n'
        '- requirement: only item\n'
        '  command: true\n'
        '  status: pass\n',
      );
      expect(ledger!.items.single.requirement, 'only item');
    });

    test(
      'a task-ledger heading without requirement bullets is not a ledger',
      () {
        expect(
          parseTaskLedger('## task-ledger\n- some unrelated note\n'),
          isNull,
        );
        // …and must not be mistaken for one in prose either.
        expect(
          parseTaskLedger('the task-ledger record is persisted hidden'),
          isNull,
        );
      },
    );

    test('the fenced block still wins when both shapes appear', () {
      final ledger = parseTaskLedger(
        '$unfencedLedger\n```task-ledger\n- requirement: fenced item\n  status: pass\n```\n',
      );
      expect(ledger!.items.single.requirement, 'fenced item');
    });

    test('stripTaskLedger removes the fenced block and its blank line', () {
      final stripped = stripTaskLedger('Answer.\n\n$ledgerBlock\n');
      expect(stripped, isNot(contains('task-ledger')));
      expect(stripped, isNot(contains('test -f script.py')));
      expect(stripped, contains('Answer.'));
      expect(stripped.trimRight(), 'Answer.');
    });

    test('stripTaskLedger removes the unfenced heading + bullets', () {
      final stripped = stripTaskLedger('Answer text.\n\n$unfencedLedger\n');
      expect(stripped, isNot(contains('task-ledger')));
      expect(stripped, isNot(contains('test -x script.py')));
      expect(stripped.trimRight(), 'Answer text.');
    });

    test('stripTaskLedger leaves plain answers byte-identical', () {
      const plain = 'just a plain final answer\nwith two lines';
      expect(stripTaskLedger(plain), plain);
    });

    test('gh-1516 review: strip collapses ONLY the seam blanks — the rest '
        'of the answer stays byte-identical', () {
      // Intentional multi-blank formatting away from the ledger must
      // survive the strip (the pre-review whole-text collapse rewrote
      // every blank run and trimmed the answer's edges).
      const withDoubleBlanks =
          'Section A\n'
          '\n'
          '\n'
          'Section B\n'
          '\n'
          '## task-ledger\n'
          '- requirement: item\n'
          '  command: true\n'
          '  status: pass\n';
      final stripped = stripTaskLedger(withDoubleBlanks);
      expect(stripped, isNot(contains('task-ledger')));
      expect(
        stripped,
        'Section A\n\n\nSection B\n',
        reason: 'mid-answer seam keeps one blank; the double blank after '
            'Section A is untouched',
      );
    });

    test('gh-1516 review: a ledger at the very start drops the leading '
        'blank edge it vacated', () {
      const leading =
          '## task-ledger\n'
          '- requirement: item\n'
          '  command: true\n'
          '  status: pass\n'
          '\n'
          'Answer text.\n';
      final stripped = stripTaskLedger(leading);
      expect(stripped, 'Answer text.\n');
    });

    test('resolveTaskLedger pairs the parsed ledger with the stripped text '
        'in one shot (single-scan entry point)', () {
      final resolution = resolveTaskLedger('Answer.\n$ledgerBlock\n');
      expect(resolution, isNotNull);
      expect(resolution!.ledger.items, hasLength(2));
      expect(resolution.strippedText, isNot(contains('task-ledger')));
      expect(resolution.strippedText.trimRight(), 'Answer.');
      // Consistent with the dedicated single-purpose delegates.
      expect(parseTaskLedger('Answer.\n$ledgerBlock\n'), resolution.ledger);
      expect(stripTaskLedger('Answer.\n$ledgerBlock\n'), resolution.strippedText);
    });
  });

  group('TaskLedger model', () {
    test('verifiedCount/failedCount/allVerified (2+ item case)', () {
      final ledger = parseTaskLedger(
        '```task-ledger\n'
        '- requirement: a\n  status: pass\n'
        '- requirement: b\n  status: fixed\n'
        '- requirement: c\n  status: fail\n'
        '```\n',
      );
      expect(ledger!.verifiedCount, 2);
      expect(ledger.failedCount, 1);
      expect(ledger.allVerified, isFalse);
      expect(ledger.items.length, 3);
    });

    test('JSON round-trip preserves items and status', () {
      final ledger = parseTaskLedger(ledgerBlock)!;
      final restored = TaskLedger.fromJson(ledger.toJson());
      expect(restored, isNotNull);
      expect(restored!.items, hasLength(2));
      expect(restored.items[0].requirement, ledger.items[0].requirement);
      expect(restored.items[0].status, ledger.items[0].status);
      expect(restored.items[1].status, TaskLedgerItemStatus.fixed);
      expect(restored.toJson(), ledger.toJson());
    });

    test('fromJson is tolerant: junk data → null, partial items survive', () {
      expect(TaskLedger.fromJson('not a map'), isNull);
      expect(TaskLedger.fromJson(null), isNull);
      expect(TaskLedger.fromJson(const {'items': 'nope'}), isNull);
      final partial = TaskLedger.fromJson(const {
        'items': [
          {'requirement': 'kept', 'status': 'pass'},
          {'bogus': true},
          'junk-row',
        ],
      });
      expect(partial!.items, hasLength(1));
      expect(partial.items.single.requirement, 'kept');
    });
  });

  group('formatTaskLedgerBlock round-trip', () {
    test('formatted block parses back to the same ledger', () {
      final ledger = parseTaskLedger(ledgerBlock)!;
      final formatted = formatTaskLedgerBlock(ledger);
      expect(formatted, contains('```task-ledger'));
      final reparsed = parseTaskLedger(formatted);
      expect(reparsed!.toJson(), ledger.toJson());
    });
  });

  group('FinalizeGate contract prompt (gh-1412 UT-1 content)', () {
    const contract = finalizeGateContractPrompt;

    test('names the contract and the ledger record block', () {
      expect(contract, contains('FinalizeGate'));
      expect(contract, contains('task-ledger'));
    });

    test('enumerates the named checklist items', () {
      // The capability surface items the ticket pins: executable bit,
      // final-state discipline, canonical artifacts, credential hunt,
      // content-not-existence verification.
      expect(contract, contains('test -x'));
      expect(contract, contains('Final state'));
      expect(contract, contains('Canonical artifacts'));
      expect(contract, contains('Credential hunt'));
      expect(contract, contains('request_secret'));
    });

    test('mandates command-verified state, never memory', () {
      expect(contract, contains('real command'));
    });

    test('pins the ledger status vocabulary', () {
      expect(contract, contains('status: pass|fixed|fail'));
    });
  });

  test('record type constant is the session record discriminator', () {
    expect(taskLedgerRecordType, 'task_ledger');
  });
}
