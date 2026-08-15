@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Cross-instance messaging: two Fa CLIs (two "terminals") sharing one
/// session repo exchange messages through the file messaging fabric.
void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
  });

  AgentCli cliFor(FakeCliIO io, FakeStreamFunction fake) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
    ),
    io: io,
    streamFunction: fake.call,
  );

  test('a message from instance B lands in instance A main inbox, is injected '
      'at the next turn and persisted in A history', () async {
    final ioA = FakeCliIO();
    final ioB = FakeCliIO();
    final fakeA = FakeStreamFunction([textTurn('got your message')]);
    final cliA = cliFor(ioA, fakeA);
    final cliB = cliFor(ioB, FakeStreamFunction([]));

    final runA = cliA.run();
    final runB = cliB.run();
    // Both instances booted → session ids became the mailbox prefixes.
    await waitForIt(
      () =>
          cliA.subagentManager.mailboxPrefix.isNotEmpty &&
          cliB.subagentManager.mailboxPrefix.isNotEmpty,
    );
    final prefixA = cliA.subagentManager.mailboxPrefix;
    final prefixB = cliB.subagentManager.mailboxPrefix;
    expect(prefixA, isNot(prefixB));

    // Instance B messages instance A's main agent (absolute mailbox).
    await cliB.subagentManager.enqueueMessage(
      '$prefixA/main',
      SubagentMessage(
        fromId: 'main',
        text: 'hello from B',
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
    // A sees the pending message in its /agents panel.
    expect(await cliA.subagentManager.pendingInboxCount('main'), 1);

    // A's next turn starts with the message as a steering user message.
    ioA.sendLine('anything');
    await waitForIt(() => fakeA.calls == 1);
    final seen = fakeA.contexts[0].messages
        .whereType<UserMessage>()
        .map((m) => m.content)
        .join('\n');
    expect(seen, contains('from $prefixB/main: hello from B'));

    // The message is part of A's persisted history (visible on resume).
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    Session? sessionA;
    for (final metadata in sessions) {
      if (metadata.id == prefixA) sessionA = await repo.open(metadata);
    }
    expect(sessionA, isNotNull);
    final entries = await sessionA!.getEntries();
    final persisted = entries
        .whereType<MessageRecord>()
        .map((r) => r.message)
        .whereType<UserMessage>()
        .map((m) => m.content)
        .join('\n');
    expect(persisted, contains('from $prefixB/main: hello from B'));

    ioA.sendLine('/exit');
    ioB.sendLine('/exit');
    await runA;
    await runB;
    await ioA.close();
    await ioB.close();
  });

  test(
    'unknown absolute mailboxes are deliverable; local unknown ids are not',
    () async {
      final io = FakeCliIO();
      final cli = cliFor(io, FakeStreamFunction([]));
      final run = cli.run();
      await waitForIt(() => cli.subagentManager.mailboxPrefix.isNotEmpty);

      // Absolute cross-instance address: no local handle needed.
      await cli.subagentManager.enqueueMessage(
        'other-session/main',
        SubagentMessage(
          fromId: 'main',
          text: 'cross-instance note',
          sentAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      final fabric = cli.subagentManager.messaging!;
      expect(await fabric.peek('other-session/main'), hasLength(1));

      // Bare unknown id: rejected as before.
      expect(
        () => cli.subagentManager.enqueueMessage(
          'ghost',
          SubagentMessage(
            fromId: 'main',
            text: 'x',
            sentAt: DateTime.now().toUtc().toIso8601String(),
          ),
        ),
        throwsStateError,
      );

      io.sendLine('/exit');
      await run;
      await io.close();
    },
  );
}
