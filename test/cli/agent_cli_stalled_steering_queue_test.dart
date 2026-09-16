import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A stream function that blocks one chosen call on a gate. When the gate
/// completes it emits a PROVIDER ABORT (not a scripted turn): the run dies
/// the way a context-wall death does — no user interrupt, no more turns —
/// leaving any mid-run steering queued for the settle.
class _DyingRunStream {
  _DyingRunStream(this.turns, {required this.gateOnCall});

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
      unawaited(gate.future.then((_) => emit(_abortedTurn())));
    } else if (turns.isEmpty) {
      // Steering mode is one-at-a-time: later boundaries in the same run
      // can outlive the scripted turns — end quietly so the run settles.
      stream.end();
    } else {
      emit(turns.removeAt(0));
    }
    return stream;
  }
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

/// Issue #488 part 1: steering saved into a dead/wedged run is
/// first-class — queued with a visible count, delivered FIFO on the next
/// live turn (the settle wake), and the warning resolves into a delivered
/// notice instead of lingering.
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

  AgentCli buildCli(_DyingRunStream stream) {
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
        steeringStaleAfter: const Duration(milliseconds: 80),
      ),
      io: io,
      streamFunction: stream.call,
    );
  }

  test(
    'AC: steering saved while the run dies delivers FIFO as the wake '
    "run's first items, each with its delivered notice",
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _DyingRunStream([textTurn('wake answer')], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      // Past the stale threshold the heartbeat looks dead: the steer is
      // saved with the dead-run warning.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      cli.steerForTest('saved while dead');
      // The AC's second message: a NEW user message into the same dead
      // run — it must join the same queue, never fork a second run.
      io.sendLine('and also this');

      // The run dies (provider abort, no user interrupt): the settle
      // must deliver BOTH queued messages as the wake run's first items.
      stream.gate.complete();
      await waitForIt(() => stream.calls >= 2, reason: 'wake run starts');
      await waitForIt(() => !cli.isBusy, reason: 'wake run settles');
      final wakeText = [
        for (final message in stream.contexts[1].messages)
          if (message is UserMessage) _messageText(message),
      ].join('\n');
      expect(wakeText, contains('[steering from user] saved while dead'));
      expect(wakeText, contains('and also this'));
      // FIFO: the older steering lands before the newer message.
      expect(
        wakeText.indexOf('saved while dead') <
            wakeText.indexOf('and also this'),
        isTrue,
        reason: 'queue order is FIFO',
      );
      expect(
        io.out.toString(),
        contains('[btw] steering from you → delivered'),
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC: the wedge warning names the queued steering count',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _DyingRunStream([textTurn('wake answer')], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      cli.steerForTest('first');
      cli.steerForTest('second');

      // The saved-while-dead face must say HOW MUCH is queued — a bare
      // per-message warning hides the queue from the owner.
      expect(
        io.out.toString(),
        contains('2 steering messages saved'),
        reason: 'the warning carries the queued count',
      );

      stream.gate.complete();
      await waitForIt(() => !cli.isBusy, reason: 'wake run settles');
      io.sendLine('/exit');
      await run;
    },
  );
}
