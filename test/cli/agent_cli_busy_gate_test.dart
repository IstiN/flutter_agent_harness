import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_attach_test.dart' show waitForTrue;
import 'agent_cli_test_support.dart';

/// A stream function that blocks one chosen call on a gate: the deterministic
/// way to freeze the CLI inside the pre-flight auto-compaction await.
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
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    final events = turns.removeAt(0);
    var done = false;
    void emit(List<AssistantMessageEvent> turn) {
      if (done) return;
      done = true;
      for (final event in turn) {
        stream.push(event);
      }
      stream.end();
    }

    if (calls == gateOnCall) {
      // gh-2168: the provider contract — a cancelled token surfaces as an
      // aborted completion, whichever lands first (the gate or the abort).
      unawaited(gate.future.then((_) => emit(events)));
      unawaited(
        cancelToken?.onCancel.then(
          (_) => emit([
            ErrorEvent(
              reason: StopReason.aborted,
              error: testAssistant(
                stopReason: StopReason.aborted,
                errorMessage: 'Request was aborted',
              ),
            ),
          ]),
        ),
      );
    } else {
      emit(events);
    }
    return stream;
  }
}

/// The busy gate of the CLI run lifecycle: a run must count as busy from the
/// moment it is STARTED — not from the first streamed byte. The pre-flight
/// auto-compaction awaits an LLM summary BEFORE `Agent.prompt` flips
/// `isStreaming`, and the inbox watcher used to read `isBusy == false` in
/// that window and start a parallel run — observed in a live session as
/// `Bad state: Agent is already processing a prompt` right after
/// `[auto-compacted]`.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  test(
    'inbox mail during pre-flight compaction never starts a parallel run',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // Three ~100k-token answers in a 400k window, compaction pinned by
      // EXPLICIT settings (reserve 130k → trigger 270k): the transcript
      // alone decides the fire turn — after the third one only, with ~50k
      // tokens of margin on each edge. The former 40k/10k script rode the
      // unanchored request estimate, which also prices the system-prompt +
      // tool-schema overhead (~20k tokens that drift with every surface
      // change); tier 2's larger compact_expand description + `action`
      // schema tipped it over the trigger one turn early, the compaction's
      // own summarizer call consumed this fake's gated slot (call 4) inside
      // the second run's bracket, and that run busy-waited on the gate
      // until the wait expired.
      final big = 'x' * 400000;
      const tiny = Model(
        id: 'sized-window',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 400000,
        maxTokens: 4096,
      );
      final stream = _GatedStream([
        textTurn(big),
        textTurn(big),
        textTurn(big),
        textTurn('summary of older context'),
        textTurn('mail answer'),
      ], gateOnCall: 4);
      final fabric = FileMessagingRepository(
        env: env,
        root: '/sessions/--work--/messages',
      );
      final cli = AgentCli(
        config: AgentCliConfig(
          model: tiny,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 130000,
            keepRecentTokens: 20000,
          ),
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      await waitForTrue(() async {
        final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
        return (await repo.list(cwd: '/work')).isNotEmpty;
      });
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessionId = (await repo.list(cwd: '/work')).first.id;

      io.sendLine('one');
      await waitForIt(() => stream.calls >= 1 && !cli.isBusy);
      io.sendLine('two');
      await waitForIt(() => stream.calls >= 2 && !cli.isBusy);
      io.sendLine('three');
      await waitForIt(() => stream.calls >= 3);

      // The third turn's post-run auto-compaction fires and blocks on the
      // gate: the CLI is inside a run, but no prompt stream is active.
      await waitForIt(() => stream.calls >= 4);
      expect(
        cli.isBusy,
        isTrue,
        reason:
            'compaction is part of the run — nothing may start in '
            'parallel (the pre-fix isBusy only watched isStreaming)',
      );

      // Inter-agent mail lands mid-compaction. The idle watcher (2s tick)
      // must NOT interpret the compaction window as idle and start a second
      // run — pre-fix it did: a second summarization + prompt ran while the
      // first run was still frozen.
      await fabric.send(
        AgentMessage(
          id: newMessageId(),
          fromId: 'other',
          toId: '$sessionId/main',
          text: 'ping',
          sentAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      expect(
        stream.calls,
        4,
        reason: 'no parallel run started while the first was compacting',
      );
      stream.gate.complete();

      await waitForIt(() => !cli.isBusy, reason: 'run settles after the gate');
      io.sendLine('/exit');
      await run;

      expect(
        io.out.toString(),
        isNot(contains('Bad state')),
        reason: 'no parallel run crashed into the active one',
      );
    },
  );

  test(
    'slash commands typed while streaming execute instead of steering',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // The user report: /settings (and any slash command) typed during a
      // streaming run was steered into the agent as chat text — the settings
      // stayed unreachable until the stream ended.
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('second answer'),
      ], gateOnCall: 1);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'test-model',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 100000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      io.sendLine('start');
      await waitForIt(
        () => stream.calls >= 1 && cli.isBusy,
        reason: 'first run is gated mid-stream',
      );

      // Busy: the command must run NOW (the line-mode summary prints), not
      // ride along as a steered user message.
      io.sendLine('/settings');
      await waitForTrue(() async => io.out.toString().contains('provider:'));

      stream.gate.complete();
      await waitForIt(() => !cli.isBusy, reason: 'run settles after the gate');
      // The fix means there is nothing to steer: the run finishes on its own
      // single turn (the buggy behavior produced a follow-up turn carrying
      // the steered '/settings').
      expect(stream.calls, 1);
      io.sendLine('/exit');
      await run;

      // No steered '/settings' may appear in any later model context.
      for (final context in stream.contexts.skip(1)) {
        final steered = context.messages.whereType<UserMessage>().any(
          (m) => (m.content as String).contains('/settings'),
        );
        expect(steered, isFalse, reason: 'slash command was steered, not run');
      }
      expect(
        io.out.toString(),
        contains('change via /provider'),
        reason: 'the /settings summary printed while the run was streaming',
      );
    },
  );

  test(
    'line-mode /exit during a run aborts the run and exits bounded '
    '(gh-2168 bounded-exit)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // Regression anchor: `/exit` mid-run fires the in-flight run's
      // cancel token (pi's shutdown semantics — quitting never waits out
      // the stream), the teardown drains the aborted settle with the
      // normal close order (drain → usage fold → seal → exit), and run()
      // returns bounded. The gate never opens: the abort alone must
      // settle the run. `bye` stays the observable farewell.
      final stream = _GatedStream([textTurn('slow answer')], gateOnCall: 1);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      await waitForTrue(() async {
        final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
        return (await repo.list(cwd: '/work')).isNotEmpty;
      });
      io.sendLine('hello');
      await waitForIt(() => stream.calls >= 1);
      await waitForIt(() => cli.isBusy, reason: 'gated run in flight');

      final wall = Stopwatch()..start();
      io.sendLine('/exit');
      await io.out.waitUntilContains('bye');
      await run; // must return bounded — the gate never opened
      wall.stop();

      expect(cli.isBusy, isFalse, reason: 'the run aborted on exit');
      expect(
        wall.elapsed,
        lessThan(const Duration(seconds: 20)),
        reason: 'exit settles bounded — the watchdog floor is 8 minutes',
      );
      final session = cli.sessionForTest;
      expect(session, isNotNull);
      expect(session!.isSealed, isTrue, reason: 'the quit seals the session');
    },
  );
}
