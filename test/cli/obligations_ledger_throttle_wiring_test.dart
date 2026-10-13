// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1590 (review IMPORTANT) — the `obligations_ledger` writer is
/// rate-bounded like the other latest-snapshot-wins ledgers: the
/// per-message ingest coalesces inside the persist window behind the
/// trailing flush, and the REPL teardown force-flushes the final state.
///
/// Before the bound, every classifying user message appended one full
/// snapshot — one record per message, each re-serializing EVERY entry,
/// so a long session grew the ledger quadratically.
///
/// The persist window is pinned through the CLI's `ledgerClock` seam
/// (frozen), so the record counts are deterministic — a CI stall cannot
/// open a second window mid-test (the same wall-clock hazard the
/// shell-job wiring test's review flagged).
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Five classifying user messages — each carries an explicit ask the
/// rule classifier ingests (five entries total).
const _asks = [
  'please file the incident report',
  'please update the dashboard too',
  'please ping the on-call rotation',
  'please archive the stale branch',
  'please rotate the staging keys',
];

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
        await probe(cli!);
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
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
    ),
    io: io,
    streamFunction: stream.call,
    // The frozen clock pins the persist window: every ingest after the
    // first lands inside ONE window no matter how long the runner takes
    // between turns.
    ledgerClock: () => DateTime(2026, 10, 13, 12),
  );
  stream.cli = cli;
  return cli;
}

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
  return const [];
}

/// The raw `obligations_ledger` records of the run's session, in file
/// order.
Future<List<CustomRecord>> _ledgerRecords(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final sessions = await repo.list(cwd: '/work');
  final session = await repo.open(sessions.first);
  return repo.readCustomRecordsOfType(await session.getMetadata(), {
    obligationsLedgerRecordType,
  });
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  test(
    'N classifying user messages leave a small constant of '
    'obligations_ledger records; the teardown flush lands every entry '
    '(gh-1590)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _ProbedStream([
        for (var i = 0; i <= _asks.length; i++)
          (const [], textTurn('ack ${i + 1}')),
      ]);
      await _runConversation(env, io, stream, userLines: ['begin', ..._asks]);

      final records = await _ledgerRecords(env);
      expect(records, isNotEmpty, reason: 'the first ingest persisted');
      // gh-1590 acceptance: five in-window ingests coalesce — one
      // snapshot plus the teardown flush, not one record per message.
      expect(
        records.length,
        lessThanOrEqualTo(2),
        reason:
            'ingests inside the persist window coalesce; the '
            'teardown flush lands the final state',
      );
      // The FINAL state reached the file: every ask is a durable open
      // entry (a resumed session must still owe them).
      final latest = ObligationsLedger.fromPayload(records.last.data);
      final openTexts = latest.open.map((e) => e.text).toSet();
      for (final ask in _asks) {
        expect(
          openTexts,
          contains(ask),
          reason: 'the flush lands the coalesced entry verbatim',
        );
      }
    },
  );

  test(
    'a session that classifies nothing grows zero obligations_ledger '
    'records (the teardown flush must not append empty snapshots)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _ProbedStream([
        (const [], textTurn('plain reply one')),
        (const [], textTurn('plain reply two')),
      ]);
      await _runConversation(env, io, stream, userLines: ['hello', 'again']);

      final records = await _ledgerRecords(env);
      expect(
        records,
        isEmpty,
        reason:
            'an empty ledger must never append — a no-ledger '
            'session would otherwise grow one `[]` record per exit',
      );
    },
  );
}
