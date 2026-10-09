// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #1380 AC5 — the pending-wait lifecycle, end to end: a successful
/// `schedule_message` arms a timer, the afterToolCall watcher records the
/// `pending-wait` obligation with the timer's reason, and the snapshot
/// persists + renders at level 0. Classic-engine sessions never grow the
/// record (E3).
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _reason = 're-arm the merge-train watch in 25m';

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
  CompactionEngine? engine,
}) {
  final cli = AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      compactionEngine: engine,
    ),
    io: io,
    streamFunction: stream.call,
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
  return stream.results;
}

/// The `schedule_message` tool's own result shape — the watcher parses
/// the scheduled id from it, so the test quotes it verbatim.
String _scheduleResult(String id) =>
    'scheduled $id for 2026-10-09T16:00:00.000Z — it will arrive as '
    '[scheduled] mail';

Future<ObligationsLedger> _latestLedger(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final sessions = await repo.list(cwd: '/work');
  final session = await repo.open(sessions.first);
  final records = await repo.readCustomRecordsOfType(
    await session.getMetadata(),
    {obligationsLedgerRecordType},
  );
  return records.isEmpty
      ? const ObligationsLedger([])
      : ObligationsLedger.fromPayload(records.last.data);
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
    'a schedule_message result arms a pending-wait that persists and renders',
    () async {
      final stream = _ProbedStream([
        // Turn 1: the timer arms; the watcher writes the ledger snapshot.
        (
          [
            (cli) async => cli.recordPendingWait(
              resultText: _scheduleResult('sm-abc-1'),
              arguments: const {'text': _reason, 'delay': '25m'},
            ),
          ],
          textTurn('timer armed'),
        ),
      ]);
      final results = await _runConversation(
        env,
        io,
        stream,
        userLines: ['arm the watch'],
      );
      expect(results.single, contains('pending-wait recorded'));
      final ledger = await _latestLedger(env);
      final entry = ledger.entries.single;
      expect(entry.kind, ObligationKind.pendingWait);
      expect(entry.status, ObligationStatus.open);
      expect(entry.text, _reason);
      expect(entry.sourceRecordId, 'sm-abc-1');
      expect(renderObligationsBlock(ledger), contains(_reason));
    },
  );

  test('re-arming the same timer is a no-op, not a duplicate', () async {
    final stream = _ProbedStream([
      (
        [
          (cli) async => cli.recordPendingWait(
            resultText: _scheduleResult('sm-abc-2'),
            arguments: const {'text': _reason},
          ),
          (cli) async => cli.recordPendingWait(
            resultText: _scheduleResult('sm-abc-2'),
            arguments: const {'text': 'a different reason'},
          ),
        ],
        textTurn('armed twice'),
      ),
    ]);
    final results = await _runConversation(
      env,
      io,
      stream,
      userLines: ['arm the watch'],
    );
    expect(results[1], contains('already recorded'));
    final ledger = await _latestLedger(env);
    expect(ledger.entries, hasLength(1));
    expect(ledger.entries.single.text, _reason);
  });

  test('a result line without a scheduled id is reported, not written',
      () async {
    final stream = _ProbedStream([
      (
        [
          (cli) async => cli.recordPendingWait(
            resultText: 'error: text is required',
            arguments: const {},
          ),
        ],
        textTurn('ack'),
      ),
    ]);
    final results = await _runConversation(
      env,
      io,
      stream,
      userLines: ['arm the watch'],
    );
    expect(results.single, contains('did not carry a scheduled id'));
    expect((await _latestLedger(env)).entries, isEmpty);
  });

  test('classic-engine sessions never grow the ledger (E3)', () async {
    final stream = _ProbedStream([
      (
        [
          (cli) async => cli.recordPendingWait(
            resultText: _scheduleResult('sm-abc-3'),
            arguments: const {'text': _reason},
          ),
        ],
        textTurn('ack'),
      ),
    ]);
    final cli = _bootCli(
      env: env,
      io: io,
      stream: stream,
      engine: CompactionEngine.classic,
    );
    final run = cli.run();
    await waitForIt(() async {
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      return (await repo.list(cwd: '/work')).isNotEmpty;
    }, reason: 'the session to materialize');
    io.sendLine('arm the watch');
    await waitForIt(() => stream.calls >= 1, reason: 'the turn to run');
    io.sendLine('/exit');
    await run;
    expect(stream.results.single, contains('classic engine'));
    expect((await _latestLedger(env)).entries, isEmpty);
  });
}
