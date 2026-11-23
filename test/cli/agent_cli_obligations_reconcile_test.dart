// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #2384 — the obligations-ledger reconciliation at the CLI
/// boundaries. A resumed session's zombies resolve WITHOUT an explicit
/// `obligation_mark_done`:
///
/// - AC1: a pending-wait whose scheduled message FIRED (a `delivered`
///   receipt on the persisted trail) auto-closes at the boot pass;
/// - AC2: open entries past `obligationStaleAfterDays` age to `stale`
///   and the discovery listing flags them `aged N days — verify or
///   close` (the close path itself still works on them — AC5);
/// - AC3: the merge direction is FILE-WINS for entries memory did not
///   mutate since seed — an external cleanup snapshot survives the next
///   writer append, and a closed entry is never resurrected.
///
/// All passes ride the frozen `ledgerClock` seam (the gh-1590 pattern),
/// so ages and record counts are deterministic.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

String get _receiptsPath =>
    '/sessions/${encodeSessionCwd('/work')}/messages/_scheduled/receipts.jsonl';

final class _ProbedStream {
  _ProbedStream(this.turns);

  /// One turn per model call; probes run before the turn's events.
  final List<
    (List<Future<String> Function(AgentCli)>, List<AssistantMessageEvent>)
  >
  turns;

  AgentCli? cli;

  int get calls => _calls;
  int _calls = 0;

  final results = <String>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final (probes, events) = turns.removeAt(0);
    _calls++;
    final stream = AssistantMessageEventStream();
    unawaited(() async {
      for (final probe in probes) {
        results.add(await probe(cli!));
      }
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }());
    return stream;
  }
}

AgentCli _bootCli({
  required MemoryExecutionEnv env,
  required FakeCliIO io,
  required _ProbedStream stream,
}) {
  final cli = AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      // Resume the seeded session (fa --session ledger-zombies).
      sessionName: 'ledger-zombies',
      providerKind: 'openai-completions',
    ),
    io: io,
    streamFunction: stream.call,
    // The frozen clock pins every reconciliation age: 2026-10-13 12:00 UTC.
    ledgerClock: () => DateTime(2026, 10, 13, 12),
  );
  stream.cli = cli;
  return cli;
}

/// Runs one scripted conversation over the seeded resume: the first user
/// line goes out once the session has materialized, each next line after
/// the previous model call settled, then the session ends cleanly.
Future<List<String>> _runConversation(
  MemoryExecutionEnv env,
  FakeCliIO io,
  _ProbedStream stream, {
  required List<String> userLines,
}) async {
  final run = _bootCli(env: env, io: io, stream: stream).run();
  await waitForIt(() async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    return (await repo.list(cwd: '/work')).isNotEmpty;
  }, reason: 'the session to materialize');
  for (var i = 0; i < userLines.length; i++) {
    if (i > 0) {
      await waitForIt(
        () => stream.calls >= i,
        reason: 'turn $i to settle before the next user line',
      );
    }
    io.sendLine(userLines[i]);
  }
  await waitForIt(
    () => stream.calls >= userLines.length,
    reason: 'every scripted turn to run',
  );
  io.sendLine('/exit');
  await run;
  return stream.results;
}

/// One ledger snapshot entry map (the persisted payload spelling).
Map<String, Object?> _entry(
  String id, {
  required String kind,
  required DateTime createdAt,
  String status = 'open',
  String? source,
}) => {
  'id': id,
  'kind': kind,
  'text': 'quote of $id',
  'sourceRecordId': source ?? 'rec-$id',
  'createdAt': createdAt.toIso8601String(),
  'status': status,
};

/// Seeds a NAMED resume session (`fa --session ledger-zombies`) carrying
/// [entries] as its latest obligations snapshot and [receipts] as the
/// persisted scheduled-message receipt trail.
Future<MemoryExecutionEnv> _seedSession(
  List<Map<String, Object?>> entries, {
  Map<String, Map<String, Object?>> receipts = const {},
}) async {
  final env = MemoryExecutionEnv(cwd: '/work');
  // Suppress session-start memory maintenance (suite pattern).
  await env.writeFile('/work/.fah/memory/.last_maintenance', '');
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final seed = await repo.create(
    JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
  );
  await seed.appendSessionName('ledger-zombies');
  if (entries.isNotEmpty) {
    await seed.appendCustomEntry(
      customType: obligationsLedgerRecordType,
      data: entries,
    );
  }
  if (receipts.isNotEmpty) {
    final trail = StringBuffer();
    for (final receipt in receipts.values) {
      trail.writeln(jsonEncode(receipt));
    }
    await env.writeFile(_receiptsPath, trail.toString());
  }
  return env;
}

Future<List<CustomRecord>> _ledgerRecords(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final session = await repo.open((await repo.list(cwd: '/work')).first);
  return repo.readCustomRecordsOfType(await session.getMetadata(), {
    obligationsLedgerRecordType,
  });
}

ObligationEntry _entryOf(ObligationsLedger ledger, String id) =>
    ledger.entries.firstWhere((e) => e.id == id);

/// Appends an external ledger snapshot DIRECTLY to the session file —
/// the cleanup another process (or an operator script) performs while
/// the live CLI holds its own in-memory writer.
Future<void> _appendExternalSnapshot(
  MemoryExecutionEnv env,
  List<Map<String, Object?>> data,
) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final session = await repo.open((await repo.list(cwd: '/work')).first);
  await session.appendCustomEntry(
    customType: obligationsLedgerRecordType,
    data: data,
  );
}

void main() {
  // The zombie day: ~60 days before the frozen clock — the September
  // pipeline shape the issue observed.
  final zombieDay = DateTime.utc(2026, 8, 14);
  final freshDay = DateTime.utc(2026, 10, 12);

  test(
    'AC1: boot auto-closes a pending-wait whose scheduled message FIRED; '
    'the discovery listing no longer offers it',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = await _seedSession(
        [
          _entry(
            'obl-wait',
            kind: 'pending-wait',
            source: 'sched-fired',
            createdAt: zombieDay,
          ),
          _entry('obl-rule', kind: 'owner-rule', createdAt: freshDay),
        ],
        receipts: {
          'r1': {
            'ts': zombieDay.toIso8601String(),
            'event': 'scheduled',
            'id': 'sched-fired',
          },
          'r2': {
            'ts': freshDay.toIso8601String(),
            'event': 'delivered',
            'id': 'sched-fired',
            'lagMs': 4,
          },
          // An armed-but-unfired timer sits in the trail too: its wait
          // (none in this seed) must stay open.
          'r3': {
            'ts': freshDay.toIso8601String(),
            'event': 'scheduled',
            'id': 'sched-quiet',
          },
        },
      );
      final io = FakeCliIO();
      final stream = _ProbedStream([
        ([(cli) => cli.closeObligation('', 'done')], textTurn('ack')),
        (const [], textTurn('ack two')),
      ]);
      final results = await _runConversation(
        env,
        io,
        stream,
        userLines: ['hello', 'again'],
      );

      // The fired wait is GONE from the discovery listing.
      final listing = results.single;
      expect(listing, contains('obl-rule'));
      expect(listing, isNot(contains('obl-wait')));
      expect(listing, isNot(contains('pending-wait')));

      // Exactly one reconciliation snapshot landed on top of the seed.
      final records = await _ledgerRecords(env);
      expect(records, hasLength(2), reason: 'seed + the boot pass');
      final latest = ObligationsLedger.fromPayload(records.last.data);
      expect(_entryOf(latest, 'obl-wait').status, ObligationStatus.done);
      expect(_entryOf(latest, 'obl-rule').status, ObligationStatus.open);
      await io.close();
    },
  );

  test(
    'AC2: boot ages a 60-day-old open entry to stale; the listing flags '
    '"aged 60 days — verify or close"; an explicit close still works '
    '(AC5 semantics unchanged)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = await _seedSession([
        _entry('obl-old-rule', kind: 'owner-rule', createdAt: zombieDay),
        _entry('obl-fresh-ask', kind: 'open-ask', createdAt: freshDay),
      ]);
      final io = FakeCliIO();
      final staleIdBox = <String>[];
      var listingResult = '';
      final stream = _ProbedStream([
        (
          [
            (cli) async {
              listingResult = await cli.closeObligation('', 'done');
              final staleLine = listingResult
                  .split('\n')
                  .firstWhere((line) => line.contains('aged'));
              // The listing line spells `- <id> [kind] …`.
              staleIdBox.add(staleLine.split(' ')[1]);
              return listingResult;
            },
            // The close path still works on the aged entry.
            (cli) => cli.closeObligation(staleIdBox.single, 'done'),
          ],
          textTurn('ack'),
        ),
      ]);
      await _runConversation(env, io, stream, userLines: ['go']);

      // The aged entry is flagged, never silently left as [open].
      expect(listingResult, contains('aged 60 days — verify or close'));
      expect(listingResult, contains('quote of obl-old-rule'));
      // The fresh ask lists without any aged suffix (AC5).
      final freshLine = listingResult
          .split('\n')
          .firstWhere((line) => line.contains('obl-fresh-ask'));
      expect(freshLine, isNot(contains('aged')));
      // The explicit close on the STALE entry landed.
      expect(
        stream.results.last,
        contains('marked done. 1 open obligation(s) remain.'),
      );

      final records = await _ledgerRecords(env);
      expect(records, hasLength(3), reason: 'seed + boot pass + the close');
      final latest = ObligationsLedger.fromPayload(records.last.data);
      // Forward-only: the aged owner-rule closed via the tool, not by aging.
      expect(_entryOf(latest, 'obl-old-rule').status, ObligationStatus.done);
      expect(_entryOf(latest, 'obl-fresh-ask').status, ObligationStatus.open);
      await io.close();
    },
  );

  test(
    'AC3: boot never resurrects externally-closed entries — a done entry '
    'stays done across the boot pass and the teardown flush',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = await _seedSession([
        _entry(
          'obl-done',
          kind: 'open-ask',
          createdAt: freshDay,
          status: 'done',
        ),
        _entry('obl-open', kind: 'open-ask', createdAt: freshDay),
      ]);
      final io = FakeCliIO();
      final stream = _ProbedStream([
        ([(cli) => cli.closeObligation('', 'done')], textTurn('ack')),
      ]);
      final results = await _runConversation(
        env,
        io,
        stream,
        userLines: ['hello'],
      );

      final listing = results.single;
      expect(listing, contains('obl-open'));
      expect(listing, isNot(contains('obl-done')));

      final records = await _ledgerRecords(env);
      // The boot pass appended NOTHING (nothing moved): the seed plus the
      // teardown flush — no re-assert of the closed entry.
      expect(records, hasLength(2));
      final latest = ObligationsLedger.fromPayload(records.last.data);
      expect(_entryOf(latest, 'obl-done').status, ObligationStatus.done);
      expect(_entryOf(latest, 'obl-open').status, ObligationStatus.open);
      await io.close();
    },
  );

  test(
    'AC3: an external cleanup snapshot SURVIVES the next writer append — '
    'the file wins for entries memory did not mutate (no burying)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = await _seedSession([
        _entry('obl-a', kind: 'open-ask', createdAt: freshDay),
        _entry('obl-b', kind: 'open-ask', createdAt: freshDay),
      ]);
      final io = FakeCliIO();
      final stream = _ProbedStream([
        (
          [
            // Construct the writer (boot pass: nothing to move).
            (cli) => cli.closeObligation('', 'done'),
            // The external cleanup flips obl-a to done while the live
            // writer still believes it open.
            (_) async {
              await _appendExternalSnapshot(env, [
                _entry(
                  'obl-a',
                  kind: 'open-ask',
                  createdAt: freshDay,
                  status: 'done',
                ),
                _entry('obl-b', kind: 'open-ask', createdAt: freshDay),
              ]);
              return 'external cleanup appended';
            },
          ],
          textTurn('ack'),
        ),
        // The classifying message forces a writer append — the merge must
        // adopt the file's flip instead of burying it.
        (const [], textTurn('ack two')),
      ]);
      await _runConversation(
        env,
        io,
        stream,
        userLines: ['hello', 'please file the incident report'],
      );

      final records = await _ledgerRecords(env);
      // seed + external cleanup + the merged ingest (the teardown flush
      // dedupes — identical bytes).
      expect(records, hasLength(3));
      final latest = ObligationsLedger.fromPayload(records.last.data);
      expect(
        _entryOf(latest, 'obl-a').status,
        ObligationStatus.done,
        reason: 'the external flip survived — not buried',
      );
      expect(_entryOf(latest, 'obl-b').status, ObligationStatus.open);
      // The freshly classified ask is present too, still open.
      final classified = latest.entries.last;
      expect(classified.status, ObligationStatus.open);
      expect(classified.text, 'please file the incident report');
      await io.close();
    },
  );
}
