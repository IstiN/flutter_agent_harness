import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Async-condition waitForIt: polls a future predicate until true.
Future<void> waitForTrue(Future<bool> Function() condition) async {
  for (var i = 0; i < 5000; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: async condition');
}

/// The live-session presence + attached-input wiring of the CLI REPL:
/// heartbeats appear while `run()` is alive, disappear on `/exit`, and a
/// `user`-kind fabric message from an attached client lands as the user's
/// own words.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  test('presence registers on run and unregisters on /exit', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final presence = FileSessionPresenceStore(env: env, root: '/sessions');
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        presenceStore: presence,
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();
    // The session materializes lazily; wait until presence sees it.
    await waitForTrue(() async => (await presence.list()).isNotEmpty);
    expect(await presence.list(), hasLength(1));

    io.sendLine('/exit');
    await run;

    expect(await presence.list(), isEmpty, reason: 'clean exit unregisters');
  });

  test(
    'a user-kind fabric message wakes the CLI and lands as user input',
    () async {
      final fake = FakeStreamFunction([textTurn('cli answer')]);
      // The CLI colocates the fabric with the project's sessions:
      // <sessionRoot>/<cwd-slug>/messages.
      final fabric = FileMessagingRepository(
        env: env,
        root: '/sessions/--work--/messages',
      );
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      // Wait for the CLI's session + mailbox prefix to exist, then send
      // attached input to its main mailbox (what the Fa app does).
      await waitForTrue(() async {
        final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
        return (await repo.list(cwd: '/work')).isNotEmpty;
      });
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessionId = (await repo.list(cwd: '/work')).first.id;
      await fabric.send(
        AgentMessage(
          id: newMessageId(),
          fromId: 'app',
          toId: '$sessionId/main',
          text: 'typed in the app',
          sentAt: DateTime.now().toUtc().toIso8601String(),
          kind: AgentMessageKind.user,
        ),
      );

      // The idle watcher (2s) wakes the agent; the message is delivered
      // as the user's own words and the model answers.
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final context = fake.contexts.single;
      final userMessages = context.messages
          .whereType<UserMessage>()
          .map((m) => m.content is String ? m.content as String : '')
          .toList();
      expect(
        userMessages,
        contains(contains('[from app] typed in the app')),
        reason: 'attached input lands as the user’s own words',
      );
      // And it persisted into the session transcript like a typed turn.
      final session = await repo.open((await repo.list(cwd: '/work')).first);
      final storedText = (await session.getEntries())
          .whereType<MessageRecord>()
          .map((r) => r.message.toJson())
          .toList();
      expect(
        storedText.any((m) => '${m['content']}'.contains('typed in the app')),
        isTrue,
        reason: 'attached input persists into the session JSONL',
      );
    },
  );
}
