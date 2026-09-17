import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A stream function that blocks one chosen call on a gate AND settles
/// that call on abort (the #514 restart path must end a wedged run the
/// way a wedged provider does: cancelled token → aborted turn). Calls
/// below the gate replay immediately; later calls replay remaining turns.
class _WedgeStream {
  _WedgeStream(this.turns, {required this.gateOnCall});

  final List<List<AssistantMessageEvent>> turns;
  final int gateOnCall;
  final gate = Completer<void>();
  final contexts = <Context>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final stream = AssistantMessageEventStream();
    void emit(List<AssistantMessageEvent> events) {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }

    if (calls == gateOnCall) {
      unawaited(() async {
        // Watch BOTH the gate and the cancel token: a restart aborts
        // without completing the gate, and the run must still settle.
        while (!(cancelToken?.isCancelled ?? false)) {
          if (gate.isCompleted) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final cancelled = cancelToken?.isCancelled ?? false;
        emit(cancelled ? _abortedTurn() : turns.removeAt(0));
      }());
    } else if (turns.isEmpty) {
      stream.end();
    } else {
      emit(turns.removeAt(0));
    }
    return stream;
  }
}

/// Polls an async [condition]: 25s of 5ms polling.
Future<void> waitForItAsync(
  Future<bool> Function() condition, {
  String? reason,
}) async {
  for (var i = 0; i < 5000; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}

/// An aborted completion (the provider-contract abort surface).
List<AssistantMessageEvent> _abortedTurn() {
  final empty = testAssistant();
  final partial = testAssistant(
    content: const [TextContent(text: '')],
    stopReason: StopReason.aborted,
  );
  return [
    StartEvent(partial: empty),
    DoneEvent(reason: StopReason.aborted, message: partial),
  ];
}

/// Waits for the CLI to persist its session (boot complete).
Future<void> waitForSessions(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  for (var i = 0; i < 5000; i++) {
    if ((await repo.list(cwd: '/work')).isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: session persisted');
}

/// The steering-consumed custom records of the first session.
Future<List<CustomRecord>> consumedMarkers(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final sessions = await repo.list(cwd: '/work');
  final session = await repo.open(sessions.first);
  final records = await session.getEntries();
  return [
    for (final record in records)
      if (record is CustomRecord && record.customType == 'steering_consumed')
        record,
  ];
}

/// Issue #514: a wedged run reads as ONE state everywhere.
///
/// - AC1: the shared stall classifier drives the banner, the steering
///   panel label (`queued (agent stalled)`, never a bare `dead`) and the
///   busy row — and offers a recovery affordance (`/restart`).
/// - AC2: `/restart` aborts the wedged run and re-runs the saved
///   steering as a fresh turn (delivered, consumed once).
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() async {
    await io.close();
  });

  AgentCli buildCli(
    _WedgeStream stream, {
    Duration steeringStaleAfter = const Duration(minutes: 2),
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: const Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 128000,
          maxTokens: 4096,
        ),
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        steeringStaleAfter: steeringStaleAfter,
      ),
      io: io,
      streamFunction: stream.call,
    );
  }

  test(
    'AC1: a wedged run reads stalled everywhere — one classifier drives '
    'the banner (with the /restart affordance), the panel label and the '
    'busy-row state',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _WedgeStream([textTurn('first answer')], gateOnCall: 1);
      final cli = buildCli(
        stream,
        steeringStaleAfter: const Duration(milliseconds: 80),
      );
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);

      io.sendLine('/exit');
      // Outlast the stale threshold with no events flowing (the gated
      // stream is silent): the run is stalled — not "working", not dead.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      cli.checkPendingSteeringHealthForTest();

      // The classifier flipped, and every consumer reads it.
      expect(cli.runStalledForTest, isTrue);
      // The banner names the state, the cause, and BOTH affordances.
      final out = io.out.toString();
      expect(out, contains('agent stalled'));
      expect(out, contains('info: agent stalled'));
      expect(out, contains('no response for'));
      expect(out, contains('/restart'));
      expect(out, contains('esc aborts'));
      expect(out, isNot(contains('saved to the session')));
      // The #437 cryptic copy is gone.
      expect(out, isNot(contains('agent not responding')));
      // Edge, not per-tick: a second watchdog pass prints no new banner.
      final printed = io.out.toString().length;
      cli.checkPendingSteeringHealthForTest();
      expect(io.out.toString().length, printed);

      // Cleanup: end the wedge so the run settles before /exit.
      stream.gate.complete();
      await waitForIt(() => !cli.isBusy);
      io.sendLine('/exit');
      await run;
    },
  );

  test('/restart is a registered slash command and refuses politely while '
      'idle', () async {
    final stream = _WedgeStream([textTurn('answer')], gateOnCall: -1);
    final cli = buildCli(stream);
    final run = cli.run();
    await waitForSessions(env);

    io.sendLine('/restart');
    await waitForIt(() => io.out.toString().contains('nothing to restart'));

    io.sendLine('/exit');
    await run;
  });

  test(
    'AC2: /restart aborts the wedged run and delivers the saved steering '
    'into a fresh turn (delivered + consumed exactly once)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _WedgeStream([
        textTurn('first answer'),
        textTurn('steered answer'),
      ], gateOnCall: 1);
      final cli = buildCli(
        stream,
        steeringStaleAfter: const Duration(milliseconds: 80),
      );
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      cli.steerForTest('hold this thought');
      cli.checkPendingSteeringHealthForTest();
      expect(cli.runStalledForTest, isTrue);

      // The recovery affordance: restart the stalled run.
      cli.restartRunForTest();
      // The wedged call settles aborted, the run re-runs the saved
      // steering as a fresh turn, and that turn answers.
      await waitForIt(() => !cli.isBusy);
      await waitForItAsync(
        () async => (await consumedMarkers(env)).length == 1,
        reason: 'the steered text delivered into the fresh run',
      );
      final out = io.out.toString();
      expect(out, contains('[btw] steering from you → delivered'));
      expect(out, isNot(contains('dropped steering')));
      // The stall state cleared with the wedge.
      expect(cli.runStalledForTest, isFalse);

      io.sendLine('/exit');
      await run;
    },
  );
}
