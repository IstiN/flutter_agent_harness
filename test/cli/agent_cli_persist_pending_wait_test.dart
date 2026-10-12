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

/// Drives the LIVE afterToolCall watcher (attached at construction,
/// composing the phase-labels hook) with a hand-built context — the
/// branch-exhaustive drive for the hook's own logic; the full-run tests
/// above cover the schedule_message wiring end to end.
Future<AfterToolCallResult?> _driveWatcher(
  AgentCli cli, {
  required String toolName,
  required bool isError,
  required String resultText,
  Map<String, dynamic> arguments = const {},
}) async {
  final hook = cli.agent.afterToolCall!;
  return hook(
    AfterToolCallContext(
      assistantMessage: testAssistant(),
      toolCall: ToolCall(id: 't1', name: toolName, arguments: arguments),
      result: ToolExecutionResult.text(resultText),
      isError: isError,
      context: const Context(messages: []),
    ),
    null,
  );
}

/// A session whose metadata probe always fails: the shape behind the
/// watcher's swallow branch — `_obligationsWriterFor`'s snapshot scan
/// rehydrates through `_repo` and must survive the crash.
final class _ThrowingMetadataStorage implements SessionStorage {
  @override
  Future<SessionMetadata> getMetadata() async =>
      throw StateError('session file vanished mid-scan');

  @override
  Future<String?> getLeafId() async => null;

  @override
  Future<void> setLeafId(String? leafId) async {}

  @override
  Future<String> createEntryId() async => 'fake-id';

  @override
  Future<void> appendEntry(SessionRecord record) async {}

  @override
  Future<SessionRecord?> getEntry(String id) async => null;

  @override
  Future<List<SessionRecord>> findEntries(String type) async => const [];

  @override
  Future<String?> getLabel(String id) async => null;

  @override
  Future<List<SessionRecord>> getPathToRoot(String? leafId) async => const [];

  @override
  Future<List<SessionRecord>> getEntries() async => const [];
}

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

  test('the live watcher records a schedule_message hit into the ledger',
      () async {
    final cli = _bootCli(env: env, io: io, stream: _ProbedStream(const []));
    cli.sessionForTest = await JsonlSessionRepo(
      fs: env,
      sessionsRoot: '/sessions',
    ).create(JsonlSessionCreateOptions(cwd: '/work'));

    final result = await _driveWatcher(
      cli,
      toolName: 'schedule_message',
      isError: false,
      resultText: _scheduleResult('sm-live-1'),
      arguments: {'text': _reason},
    );

    // A clean recording stays silent: no `[obligations]` note on io.
    expect(result, isNull);
    expect(io.out.toString(), isNot(contains('[obligations]')));
    final ledger = await _latestLedger(env);
    expect(ledger.entries.single.kind, ObligationKind.pendingWait);
    expect(ledger.entries.single.text, _reason);
    expect(ledger.entries.single.sourceRecordId, 'sm-live-1');
  });

  test('error results and foreign tools never reach the ledger', () async {
    final cli = _bootCli(env: env, io: io, stream: _ProbedStream(const []));
    cli.sessionForTest = await JsonlSessionRepo(
      fs: env,
      sessionsRoot: '/sessions',
    ).create(JsonlSessionCreateOptions(cwd: '/work'));

    await _driveWatcher(
      cli,
      toolName: 'read',
      isError: false,
      resultText: 'file body',
      arguments: {'path': 'x.txt'},
    );
    await _driveWatcher(
      cli,
      toolName: 'schedule_message',
      isError: true,
      resultText: _scheduleResult('sm-err-1'),
      arguments: {'text': _reason},
    );

    expect(io.out.toString(), isNot(contains('[obligations]')));
    expect((await _latestLedger(env)).entries, isEmpty);
  });

  test('a schedule result without a scheduled id is reported on io',
      () async {
    final cli = _bootCli(env: env, io: io, stream: _ProbedStream(const []));
    cli.sessionForTest = await JsonlSessionRepo(
      fs: env,
      sessionsRoot: '/sessions',
    ).create(JsonlSessionCreateOptions(cwd: '/work'));

    await _driveWatcher(
      cli,
      toolName: 'schedule_message',
      isError: false,
      resultText: 'error: text is required',
    );

    expect(
      io.out.toString(),
      contains('[obligations] pending-wait not recorded:'),
    );
    expect(io.out.toString(), contains('did not carry a scheduled id'));
    expect((await _latestLedger(env)).entries, isEmpty);
  });

  test('a ledger crash cannot fail the tool call the schedule succeeded',
      () async {
    // The throw needs a REAL repo behind `_repo` (the snapshot scan
    // rehydrates through it), so boot one full turn first; the swapped
    // session's metadata probe then crashes the scan inside the hook.
    final stream = _ProbedStream([
      ([], textTurn('warmup')),
    ]);
    final cli = _bootCli(env: env, io: io, stream: stream);
    await _runConversation(env, io, stream, userLines: ['hello']);
    cli.sessionForTest = Session(_ThrowingMetadataStorage());

    final result = await _driveWatcher(
      cli,
      toolName: 'schedule_message',
      isError: false,
      resultText: _scheduleResult('sm-crash-1'),
      arguments: {'text': _reason},
    );

    // The swallow: no exception surfaced, the prior chain still ran,
    // and the failure is NOT misreported as a recording note.
    expect(result, isNull);
    expect(io.out.toString(), isNot(contains('[obligations]')));
  });
}
