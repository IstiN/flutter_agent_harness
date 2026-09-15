import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A stream function that blocks one chosen call on a gate (copied from
/// the busy-gate test): the deterministic way to hold a run open while
/// the test steers mid-run input. [gateOnCall] below zero disables the
/// gate (every call replays its turn immediately).
class _GatedStream {
  _GatedStream(this.turns, {required this.gateOnCall});

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
    final stream = AssistantMessageEventStream();
    void emit(List<AssistantMessageEvent> events) {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }

    if (calls == gateOnCall) {
      unawaited(
        gate.future.then((_) {
          emit(
            (cancelToken?.isCancelled ?? false)
                ? _abortedTurn()
                : turns.removeAt(0),
          );
        }),
      );
    } else {
      emit(turns.removeAt(0));
    }
    return stream;
  }
}

/// Polls an async [condition] like [waitForIt]: 25s of 5ms polling.
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

/// The text of a user message (string or content-block content).
String _messageText(UserMessage message) {
  final content = message.content;
  if (content is String) return content;
  return [
    for (final block in content as List<ContentBlock>)
      if (block is TextContent) block.text,
  ].join();
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

/// The steering custom_message records of the first session, in file order.
Future<List<CustomMessageRecord>> steeringRecords(
  MemoryExecutionEnv env,
) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final sessions = await repo.list(cwd: '/work');
  final session = await repo.open(sessions.first);
  final records = await session.getEntries();
  return [
    for (final record in records)
      if (record is CustomMessageRecord && record.customType == 'steering')
        record,
  ];
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

/// Issue #437: composer steering persistence + honest panel lifecycle.
///
/// - B1: steering accepted via the btw panel path lands in the session
///   JSONL the moment it is accepted (a user-role record attributed
///   `[steering from user]`) — visible, auditable, recoverable.
/// - B2: the panel lifecycle follows DELIVERY (pending → delivered, or
///   dead when the consumer is gone), never an optimistic `complete`.
/// - Recovery: an unconsumed persisted steering record re-enters the
///   queue at session load and wakes the idle agent (idempotent by
///   record id across restarts).
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
    _GatedStream stream, {
    Duration steeringStaleAfter = const Duration(minutes: 2),
    String? sessionName,
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
        sessionName: sessionName,
      ),
      io: io,
      streamFunction: stream.call,
    );
  }

  test(
    'AC1: steering accepted mid-run persists a user-role record '
    'immediately, attributed [steering from user]',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('steered answer'),
      ], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      cli.steerForTest('hold this thought');

      // The record must land while the run is still busy — before any
      // delivery, before the run settles.
      await waitForItAsync(
        () async => (await steeringRecords(env)).length == 1,
        reason: 'the steering record persists at accept time',
      );
      final record = (await steeringRecords(env)).single;
      expect(record.content, contains('[steering from user]'));
      expect(record.content, contains('hold this thought'));
      expect(cli.isBusy, isTrue, reason: 'nothing delivered yet');

      // The panel shows the honest pending state while undelivered.
      expect(io.out.toString(), contains('steering from you · pending'));

      stream.gate.complete();
      await waitForIt(() => stream.calls >= 2);
      await waitForIt(() => !cli.isBusy, reason: 'steered run settles');

      // Delivered: the panel says so, never `complete`.
      expect(
        io.out.toString(),
        contains('[btw] steering from you → delivered'),
      );
      final steered = [
        for (final message in stream.contexts[1].messages)
          if (message is UserMessage) _messageText(message),
      ].join('\n');
      expect(steered, contains('[steering from user] hold this thought'));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'E2: three rapid steers keep order, each with its own record and '
    'delivery state',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('steered answer'),
      ], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      cli.steerForTest('one');
      cli.steerForTest('two');
      cli.steerForTest('three');

      await waitForItAsync(
        () async => (await steeringRecords(env)).length == 3,
        reason: 'three records, one per steer',
      );
      final contents = [
        for (final record in await steeringRecords(env)) record.content,
      ].join('|');
      expect(contents, contains('[steering from user] one'));
      expect(contents, contains('[steering from user] two'));
      expect(contents, contains('[steering from user] three'));
      // Order preserved: `one` lands before `three` in the file.
      expect(contents.indexOf('one') < contents.indexOf('three'), isTrue);

      stream.gate.complete();
      await waitForIt(() => stream.calls >= 2);
      await waitForIt(() => !cli.isBusy);

      final steered = [
        for (final message in stream.contexts[1].messages)
          if (message is UserMessage) _messageText(message),
      ];
      final ordered = [
        for (final text in steered)
          if (text.contains('[steering from user]')) text,
      ];
      expect(ordered, hasLength(3));
      expect(ordered[0], contains('one'));
      expect(ordered[1], contains('two'));
      expect(ordered[2], contains('three'));
      expect(
        '→ delivered'.allMatches(io.out.toString()).length,
        greaterThanOrEqualTo(3),
        reason: 'each steer gets its own delivered transition',
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC3: steering into a wedged consumer (stale heartbeat) marks the '
    'panel dead with the not-responding warning, never complete',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _GatedStream([
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
      // Outlast the stale threshold with no events flowing (the gated
      // stream is silent): the consumer looks dead.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      cli.steerForTest('anyone there?');

      expect(io.out.toString(), contains('steering from you · dead'));
      expect(io.out.toString(), contains('agent not responding'));
      expect(io.out.toString(), contains('saved to session'));
      expect(
        io.out.toString(),
        isNot(contains('steering from you → complete')),
      );

      // The message is still saved to the session for recovery/resend.
      await waitForItAsync(
        () async => (await steeringRecords(env)).length == 1,
        reason: 'dead-consumer steering is still persisted',
      );

      // When the wedge clears, the steer still delivers (late delivery
      // from dead — honest recovery, not a lie).
      stream.gate.complete();
      await waitForIt(() => stream.calls >= 2);
      await waitForIt(() => !cli.isBusy);
      expect(
        io.out.toString(),
        contains('[btw] steering from you → delivered'),
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC5+E1: a persisted-but-unconsumed steering record is recovered at '
    'session load, wakes the agent, and is consumed exactly once',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      // Session 1: seed a named session, then leave an unconsumed
      // steering record behind (the 19:40:57 crash residue).
      final stream1 = _GatedStream([textTurn('seed answer')], gateOnCall: -1);
      final cli1 = buildCli(stream1, sessionName: 'steer-recover');
      final run1 = cli1.run();
      await waitForSessions(env);
      io.sendLine('seed the session');
      await waitForIt(() => !cli1.isBusy);
      io.sendLine('/exit');
      await run1;

      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessions = await repo.list(cwd: '/work');
      final persisted = await repo.open(sessions.first);
      await persisted.appendCustomMessageEntry(
        customType: 'steering',
        content: '[steering from user] recovered-please-ack',
        display: true,
      );

      // Restart 1: the record is unconsumed — recovery must surface it,
      // queue it, and wake the idle agent into a run that delivers it.
      io = FakeCliIO();
      final stream2 = _GatedStream([
        textTurn('recovered answer'),
      ], gateOnCall: -1);
      final cli2 = buildCli(stream2, sessionName: 'steer-recover');
      final run2 = cli2.run();
      await waitForIt(
        () => io.out.toString().contains('recovered'),
        reason: 'recovery notice prints at load',
      );
      // Wake semantics: the recovered steering starts a turn on its own.
      await waitForIt(
        () => stream2.calls >= 1,
        reason: 'recovered steering wakes the idle agent',
      );
      await waitForIt(() => !cli2.isBusy, reason: 'recovery run settles');
      expect(
        [
          for (final message in stream2.contexts.first.messages)
            if (message is UserMessage) _messageText(message),
        ].join('\n'),
        contains('recovered-please-ack'),
      );

      // Idempotent by record id: the residue was consumed, not duplicated.
      final records = await steeringRecords(env);
      expect(records, hasLength(1), reason: 'no duplicate steering record');
      final markers = await consumedMarkers(env);
      expect(markers, hasLength(1));
      expect(
        (markers.single.data as Map)['id'],
        records.single.id,
        reason: 'the marker references the original record id',
      );

      io.sendLine('/exit');
      await run2;

      // Restart 2: the same record must NOT re-enter the queue.
      io = FakeCliIO();
      final stream3 = _GatedStream([textTurn('third answer')], gateOnCall: -1);
      final cli3 = buildCli(stream3, sessionName: 'steer-recover');
      final run3 = cli3.run();
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(io.out.toString(), isNot(contains('recovered')));
      expect(stream3.calls, 0, reason: 'no wake without unconsumed steering');
      io.sendLine('/exit');
      await run3;
    },
  );
}
