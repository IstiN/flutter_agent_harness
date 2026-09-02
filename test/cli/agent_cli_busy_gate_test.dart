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
    void emit() {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }

    if (calls == gateOnCall) {
      unawaited(gate.future.then((_) => emit()));
    } else {
      emit();
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
      // Three ~10k-token answers in a 40k window: compaction only crosses
      // the 16384-token reserve threshold after the third turn.
      final big = 'x' * 40000;
      const tiny = Model(
        id: 'tiny-window',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 40000,
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
}
