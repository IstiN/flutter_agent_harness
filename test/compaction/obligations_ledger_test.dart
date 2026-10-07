// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #1380 A1 (slice 1) — the obligations ledger: rule-based
/// derivation, verbatim entries, the snapshot record, and the level-0
/// context block that no hide/compact/flatten depth can sink.
library;

import 'dart:math';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _ruleText = 'always run tests before pushing';
const _askText = 'can you also fix the flake, please';

AssistantMessage _assistant(String text) {
  return AssistantMessage(
    content: [TextContent(text: text)],
    api: 'anthropic-messages',
    provider: 'p',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

/// A message-record id pool of a small synthetic session: alternating
/// user (rule/ask/neutral) and assistant turns. Returns the record ids in
/// append order (line numbers are these + 1).
Future<List<String>> _seedSession(Session session) async {
  final ids = <String>[];
  Future<void> user(String text) async {
    ids.add(await session.appendMessage(UserMessage.text(text)));
  }

  Future<void> reply(String text) async {
    ids.add(await session.appendMessage(_assistant(text)));
  }

  await user('$_ruleText and never skip the changelog');
  await reply('understood');
  await user(_askText);
  await reply('on it');
  await user('what did we decide about the WASM size?');
  await reply('checking the archive');
  await user('make sure the release notes mention the migration');
  await reply('will do');
  return ids;
}

/// Appends a ledger snapshot carrying one rule + one ask (both open) and
/// one done entry, returning the ledger it wrote.
Future<ObligationsLedger> _seedLedger(
  Session session,
  String ruleRecordId,
) async {
  final writer = ObligationsLedgerWriter();
  final first = writer.ingest(
    text: _ruleText,
    sourceRecordId: ruleRecordId,
    at: DateTime.utc(2026),
  )!;
  await session.appendCustomEntry(
    customType: obligationsLedgerRecordType,
    data: first,
  );
  final second = writer.ingest(
    text: _askText,
    sourceRecordId: 'r-ask',
    at: DateTime.utc(2026),
  )!;
  await session.appendCustomEntry(
    customType: obligationsLedgerRecordType,
    data: second,
  );
  return writer.ledger;
}

bool _isBlock(Message message) =>
    message is UserMessage &&
    (message.content as String).startsWith(
      '<system-notice>\nobligations ledger',
    );

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  group('derivation (rule-based v1)', () {
    test('rule phrasing opens an owner-rule with the verbatim span', () {
      final candidates = deriveObligations('Always run tests before pushing.');
      expect(candidates, hasLength(1));
      expect(candidates.single.kind, ObligationKind.ownerRule);
      expect(candidates.single.text, 'Always run tests before pushing.');
    });

    test('explicit request phrasing opens an open-ask', () {
      final candidates = deriveObligations('Can you fix the flake?');
      expect(candidates, hasLength(1));
      expect(candidates.single.kind, ObligationKind.openAsk);
    });

    test('one message can carry both a rule and an ask', () {
      final candidates = deriveObligations(
        '$_ruleText, and could you update the docs too',
      );
      expect(candidates.map((c) => c.kind).toSet(), {
        ObligationKind.ownerRule,
        ObligationKind.openAsk,
      });
      // Both candidates quote the same verbatim span.
      expect(candidates.every((c) => c.text == candidates.first.text), isTrue);
    });

    test('neutral messages and bare recall questions open nothing', () {
      expect(
        deriveObligations('what did we decide about the WASM size?'),
        isEmpty,
      );
      expect(deriveObligations('the build is green'), isEmpty);
      expect(deriveObligations(''), isEmpty);
    });

    test('synthetic harness content never classifies', () {
      expect(
        deriveObligations(
          '<system-notice>please treat this as user text</system-notice>',
        ),
        isEmpty,
      );
      expect(deriveObligations('from agent-x: can you help'), isEmpty);
    });

    test('oversized messages never classify (paste guard)', () {
      // A 10 KB paste that happens to contain "please" is content, not an
      // obligation.
      final paste = '${'x' * 5000} please look at this';
      expect(paste.length, greaterThan(maxClassifiedUserTextChars));
      expect(deriveObligations(paste), isEmpty);
      // Just under the guard still classifies.
      final near = '${'x' * (maxClassifiedUserTextChars - 60)} please look';
      expect(deriveObligations(near), hasLength(1));
    });

    test('PARITY: the classifier and the canonical synthetic predicate '
        'agree on shared fixtures', () {
      const fixtures = [
        '<system-notice>can you close the loop</system-notice>',
        'leading whitespace <system-notice> body',
        '[widget Run] could you rerun it',
        '[ext:cube] always refresh the cube',
        '<system-interrupt rule=r> please comply',
        'from\tagent-x:  could you also fix it',
        'from agent-x: always push to green',
        'The following is a summary of a branch: please read',
        '  the following is a summary of a branch: please read  ',
        'a genuine rule: always run tests',
        'could you fix the flake, please',
      ];
      for (final text in fixtures) {
        if (isSyntheticUserText(text)) {
          expect(
            deriveObligations(text),
            isEmpty,
            reason: 'synthetic text must never open obligations: $text',
          );
        }
      }
    });
  });

  group('ledger model', () {
    test('snapshot round-trips and latest snapshot wins wholesale', () {
      final writer = ObligationsLedgerWriter();
      final first = writer.ingest(
        text: _ruleText,
        sourceRecordId: 'r1',
        at: DateTime.utc(2026),
      )!;
      final second = writer.ingest(
        text: _askText,
        sourceRecordId: 'r2',
        at: DateTime.utc(2026),
      )!;
      final latest = latestObligationsLedgerIn([
        CustomRecord(
          id: 'a',
          parentId: null,
          timestamp: DateTime.utc(2026),
          customType: obligationsLedgerRecordType,
          data: first,
        ),
        CustomRecord(
          id: 'b',
          parentId: 'a',
          timestamp: DateTime.utc(2026),
          customType: obligationsLedgerRecordType,
          data: second,
        ),
      ]);
      expect(latest, isNotNull);
      expect(latest!.entries, hasLength(2));
      expect(latest.entries.last.text, _askText);
      // Round-trip fidelity.
      expect(
        ObligationsLedger.fromPayload(latest.toPayload()).toPayload(),
        latest.toPayload(),
      );
    });

    test('ingest is idempotent per source record (a record never opens '
        'twice)', () {
      final writer = ObligationsLedgerWriter();
      expect(
        writer.ingest(
          text: _ruleText,
          sourceRecordId: 'r1',
          at: DateTime.utc(2026),
        ),
        isNotNull,
      );
      expect(
        writer.ingest(
          text: _ruleText,
          sourceRecordId: 'r1',
          at: DateTime.utc(2026),
        ),
        isNull,
      );
      expect(writer.ledger.entries, hasLength(1));
    });

    test('neutral messages persist nothing', () {
      final writer = ObligationsLedgerWriter();
      expect(
        writer.ingest(
          text: 'thanks, looks good',
          sourceRecordId: 'r1',
          at: DateTime.utc(2026),
        ),
        isNull,
      );
      expect(writer.ledger.isEmpty, isTrue);
    });

    test('lifecycle keeps the entry and flips the status (E2)', () {
      final writer = ObligationsLedgerWriter();
      writer.ingest(
        text: _ruleText,
        sourceRecordId: 'r1',
        at: DateTime.utc(2026),
      );
      final id = writer.ledger.entries.single.id;
      final payload = writer.markStatus(id, ObligationStatus.superseded)!;
      expect(writer.ledger.entries, hasLength(1));
      expect(writer.ledger.entries.single.status, ObligationStatus.superseded);
      expect(payload.single['status'], 'superseded');
      // Unknown ids persist nothing.
      expect(writer.markStatus('nope', ObligationStatus.done), isNull);
    });

    test('tolerant parse: missing fields default, junk never throws (E6)', () {
      final ledger = ObligationsLedger.fromPayload([
        {'text': 'legacy entry'},
        'junk-string',
        {
          'kind': 'brand-new-kind',
          'text': 'future entry',
          'status': 'brand-new-status',
        },
        {'kind': 'pending-wait', 'text': 'armed watch', 'status': 'open'},
        // Junk maps: no text AND no source pointer — skipped, never
        // permanent level-0 garbage lines (review round 2).
        {},
        {'kind': 'x'},
      ]);
      expect(ledger.entries, hasLength(3));
      final legacy = ledger.entries[0];
      expect(legacy.kind, ObligationKind.openAsk);
      expect(legacy.status, ObligationStatus.open);
      expect(legacy.id, isNotEmpty);
      expect(legacy.sourceRecordId, isEmpty);
      expect(legacy.createdAt, DateTime.fromMillisecondsSinceEpoch(0));
      final future = ledger.entries[1];
      expect(future.kind, ObligationKind.openAsk);
      expect(future.status, ObligationStatus.open);
      expect(ledger.entries[2].kind, ObligationKind.pendingWait);
      // Non-list payloads parse empty.
      expect(ObligationsLedger.fromPayload('junk').isEmpty, isTrue);
      expect(ObligationsLedger.fromPayload(null).isEmpty, isTrue);
    });

    test('id-less entries get a DETERMINISTIC id (addressable, round-trip '
        'stable)', () {
      const payload = [
        {'text': 'legacy entry'},
      ];
      final first = ObligationsLedger.fromPayload(payload);
      final second = ObligationsLedger.fromPayload(payload);
      // Two parses agree — the id is a content hash, not a fresh uuid.
      expect(first.entries.single.id, second.entries.single.id);
      expect(first.entries.single.id, startsWith('obl-'));
      // And the round-trip payload is byte-stable.
      expect(
        ObligationsLedger.fromPayload(first.toPayload()).toPayload(),
        first.toPayload(),
      );
      // Distinct entries hash apart.
      final other = ObligationsLedger.fromPayload([
        {'text': 'a different entry'},
      ]);
      expect(other.entries.single.id, isNot(first.entries.single.id));
    });

    test('budget: closed entries evict oldest-first, open never drop (E1)', () {
      ObligationEntry seed(String id, ObligationStatus status, String text) =>
          ObligationEntry(
            id: id,
            kind: ObligationKind.ownerRule,
            text: text,
            sourceRecordId: 'r-$id',
            createdAt: DateTime.utc(2026),
            status: status,
          );

      final longOpen = 'open obligation ${'x' * 200}';
      final ledger = ObligationsLedger([
        seed('c1', ObligationStatus.done, 'oldest closed ${'y' * 100}'),
        seed('c2', ObligationStatus.done, 'middle closed ${'y' * 100}'),
        seed('c3', ObligationStatus.superseded, 'newest closed ${'y' * 100}'),
        seed('o1', ObligationStatus.open, longOpen),
      ]);
      // A budget that fits the open entry plus only the NEWEST closed
      // line: the OLDEST closed entries evict first (E1). The budget is
      // derived from the full render so the test pins the eviction ORDER,
      // not the format's arithmetic.
      final full = renderObligationsBlock(ledger);
      final olderLines = full
          .split('\n')
          .where(
            (l) => l.contains('oldest closed') || l.contains('middle closed'),
          )
          .toList();
      expect(olderLines, hasLength(2));
      final block = renderObligationsBlock(
        ledger,
        maxChars: full.length - olderLines[0].length - olderLines[1].length - 2,
      );
      expect(block, contains(longOpen));
      expect(block, contains('[open] owner-rule: $longOpen'));
      expect(block, isNot(contains('oldest closed')));
      expect(block, isNot(contains('middle closed')));
      expect(block, contains('newest closed'));

      // Budget bound: with only closed entries over budget, the render
      // never exceeds maxChars (the envelope is counted, not assumed).
      final closedOnly = ObligationsLedger([
        for (var i = 0; i < 10; i++)
          seed('c$i', ObligationStatus.done, 'closed entry $i ${'y' * 80}'),
      ]);
      final bounded = renderObligationsBlock(closedOnly, maxChars: 900);
      expect(bounded.length, lessThanOrEqualTo(900));
      expect(bounded, contains('closed entry 9'));
      expect(bounded, isNot(contains('closed entry 0')));

      // Open entries render newest-last, capped at maxRenderedOpenEntries
      // with an honest counting tail — never silently dropped (review
      // round-2 guardrail).
      final manyOpen = ObligationsLedger([
        for (var i = 0; i < 20; i++)
          seed('o$i', ObligationStatus.open, 'open obligation number $i'),
      ]);
      final capped = renderObligationsBlock(manyOpen, maxChars: 100);
      expect(capped, contains('open obligation number 19'));
      expect(capped, isNot(contains('open obligation number 7 (')));
      expect(capped, contains('… and 8 more open obligations'));

      // Per-entry display clip: a giant verbatim span renders clipped —
      // the full span stays on the record (AC2 at record level).
      final giant = ObligationsLedger([
        seed('g1', ObligationStatus.open, 'giant rule ${'z' * 500}'),
      ]);
      final clipped = renderObligationsBlock(giant);
      expect(clipped, isNot(contains('z' * 400)));
      expect(clipped, contains('…'));
      expect(clipped, contains('record r-g1)'));
    });

    test('empty ledger renders no block', () {
      expect(renderObligationsBlock(const ObligationsLedger([])), isEmpty);
    });
  });

  group('level-0 projection', () {
    test(
      'block rides at the context tail across hide + checkpoint spans',
      () async {
        final session = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        final ids = await _seedSession(session);
        final ledger = await _seedLedger(session, ids[0]);

        await session.appendHiddenRange(recordIds: [ids[2]]);
        await session.appendCompactCheckpoint(
          firstRecordId: ids[4],
          lastRecordId: ids[6],
          text: 'checkpoint of the middle span',
          coversRecordIds: [ids[4], ids[5], ids[6]],
          flattenedRecordIds: const [],
        );

        final messages = await session.buildContextMessages();
        expect(_isBlock(messages.last), isTrue);
        final block = (messages.last as UserMessage).content as String;
        // Every open obligation is visible at level 0 (AC1).
        expect(block, contains(_ruleText));
        expect(block, contains(_askText));
        expect(
          block,
          contains('record ${ids[0]})'),
          reason: 'pointer to the source record id',
        );
        // Wire stays valid with the appended user message (issue #85).
        expect(validateToolPairing(messages), isEmpty);
        expect(ledger.entries, hasLength(2));
      },
    );

    test(
      'classic compaction cannot sink the block (level 0 over the cut)',
      () async {
        final session = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        final ids = await _seedSession(session);
        await _seedLedger(session, ids[0]);

        // The classic cut drops everything before ids[4] — including the
        // ledger snapshot record itself. The projection still reads it from
        // the file: the ledger is session-level, never branch state.
        await session.appendCompaction(
          summary: 'prefix summary',
          firstKeptEntryId: ids[4],
          tokensBefore: 9000,
        );

        final messages = await session.buildContextMessages();
        expect(messages.where(_isBlock), hasLength(1));
        final block = (messages.last as UserMessage).content as String;
        expect(block, contains(_ruleText));
        expect(validateToolPairing(messages), isEmpty);
      },
    );

    test(
      'WINDOWED REGRESSION (review-blocking): a snapshot below the '
      'windowed tail still renders, and the scan finds the latest state',
      () async {
        final session = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        final ids = await _seedSession(session);
        final writer = ObligationsLedgerWriter();
        // Snapshot 1: rule + ask open.
        final p1 = writer.ingest(
          text: _ruleText,
          sourceRecordId: ids[0],
          at: DateTime.utc(2026),
        )!;
        await session.appendCustomEntry(
          customType: obligationsLedgerRecordType,
          data: p1,
        );
        final p2 = writer.ingest(
          text: _askText,
          sourceRecordId: 'r-ask',
          at: DateTime.utc(2026),
        )!;
        await session.appendCustomEntry(
          customType: obligationsLedgerRecordType,
          data: p2,
        );
        // Snapshot 2: the ask closes. LATEST-WINS state: rule open, ask done.
        final p3 = writer.markStatus(
          writer.ledger.entries.last.id,
          ObligationStatus.done,
        )!;
        await session.appendCustomEntry(
          customType: obligationsLedgerRecordType,
          data: p3,
        );

        // Fill past the residency cap (defaultResidentRecords = 600): all
        // three snapshots now lie BELOW the windowed tail — the exact #488
        // shape where the resident view silently loses the ledger.
        for (var i = 0; i < 650; i++) {
          await session.appendMessage(UserMessage.text('filler $i'));
        }
        final meta = await session.getMetadata();
        final windowed = await repo.open(meta, windowed: true);

        // Sanity: the resident view has NO ledger snapshot at all.
        expect(latestObligationsLedgerIn(await windowed.getEntries()), isNull);

        // The projection still renders the block — raw-scan fallback — and
        // from the LATEST snapshot's state (ask done), not snapshot 1's.
        final messages = await windowed.buildContextMessages();
        expect(_isBlock(messages.last), isTrue);
        final block = (messages.last as UserMessage).content as String;
        expect(block, contains(_ruleText));
        expect(block, contains('[done]'));
        expect(block, contains(_askText));

        // The writer-side rehydration mechanism: the raw scan sees the full
        // chain and the latest snapshot wins — a writer built from this
        // never erases the earlier entries.
        final records = await repo.readCustomRecordsOfType(meta, {
          obligationsLedgerRecordType,
        });
        expect(records, hasLength(3));
        final latest = ObligationsLedger.fromPayload(records.last.data);
        expect(latest.entries, hasLength(2));
        // Only the rule is still open; the ask closed in the latest state.
        expect(latest.open.single.text, _ruleText);
        expect(
          latest.entries.firstWhere((e) => e.text == _askText).status,
          ObligationStatus.done,
        );
        expect(validateToolPairing(messages), isEmpty);
      },
    );

    test('a session without ledger records projects unchanged (E3)', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final ids = await _seedSession(session);
      await session.appendHiddenRange(recordIds: [ids[2]]);

      final messages = await session.buildContextMessages();
      expect(messages.where(_isBlock), isEmpty);
      // 9 records -> 9 projected entries (the hidden one as a marker).
      expect(messages, hasLength(ids.length));
    });

    test('AC1 property: any hide/checkpoint/classic sequence keeps every '
        'open obligation visible', () async {
      final random = Random(1380);
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final ids = await _seedSession(session);
      final ledger = await _seedLedger(session, ids[0]);
      final openTexts = [
        for (final entry in ledger.entries)
          if (entry.status == ObligationStatus.open) entry.text,
      ];

      String? firstKept = ids.first;
      for (var step = 0; step < 12; step++) {
        switch (random.nextInt(3)) {
          case 0: // hide a random contiguous span
            final start = random.nextInt(ids.length);
            final span = ids.sublist(
              start,
              start + 1 + random.nextInt(ids.length - start),
            );
            await session.appendHiddenRange(recordIds: span);
          case 1: // checkpoint a random contiguous span
            final start = random.nextInt(ids.length - 1);
            final end = start + 1 + random.nextInt(ids.length - 1 - start);
            await session.appendCompactCheckpoint(
              firstRecordId: ids[start],
              lastRecordId: ids[end],
              text: 'ckpt $step',
              coversRecordIds: ids.sublist(start, end + 1),
              flattenedRecordIds: const [],
            );
          default: // classic cut (flatten-style fallback)
            firstKept = ids[random.nextInt(ids.length)];
            await session.appendCompaction(
              summary: 'summary $step',
              firstKeptEntryId: firstKept,
              tokensBefore: 9000 + step,
            );
        }

        final messages = await session.buildContextMessages();
        expect(_isBlock(messages.last), reason: 'step $step', isTrue);
        final block = (messages.last as UserMessage).content as String;
        for (final text in openTexts) {
          expect(block, contains(text), reason: 'step $step');
        }
        expect(validateToolPairing(messages), isEmpty, reason: 'step $step');
      }
    });

    test(
      'AC2 property: every derived entry byte-matches its source record',
      () async {
        final random = Random(20261007);
        final session = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        final writer = ObligationsLedgerWriter();
        const stems = [
          'always',
          'never commit to main directly,',
          'could you',
          'please',
          'whenever the gate is red,',
        ];
        for (var i = 0; i < 16; i++) {
          final text =
              '${stems[random.nextInt(stems.length)]} message $i '
              '${random.nextInt(1 << 32)}';
          final recordId = await session.appendMessage(UserMessage.text(text));
          writer.ingest(text: text, sourceRecordId: recordId);
        }
        // The verbatim invariant: each entry's text IS the byte span of its
        // persisted source record — never a paraphrase, never a cap.
        expect(writer.ledger.entries, isNotEmpty);
        for (final entry in writer.ledger.entries) {
          final record = await session.getEntry(entry.sourceRecordId);
          expect(record, isA<MessageRecord>());
          final message = (record as MessageRecord).message;
          expect(message, isA<UserMessage>());
          expect(userMessageText((message as UserMessage).content), entry.text);
        }
      },
    );
  });
}
