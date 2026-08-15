@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor() => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
    ),
    io: io,
    streamFunction: FakeStreamFunction([]).call,
  );

  SubagentHandle handle({
    String id = 'a1',
    SubagentStatus status = SubagentStatus.completed,
    String agentType = 'explore',
    String task = 'scout files',
    int tokens = 100,
  }) {
    final h = SubagentHandle(
      id: id,
      name: id,
      agentType: agentType,
      sessionId: '/work/sessions/$id.jsonl',
      createdAt: '2026-01-01T00:00:00Z',
      task: task,
    );
    h.status = status;
    h.tokens = tokens;
    return h;
  }

  Future<void> registerHandles(
    AgentCli cli,
    List<SubagentHandle> handles,
  ) async {
    for (final handle in handles) {
      await cli.subagentManager.register(
        id: handle.id,
        name: handle.name,
        agentType: handle.agentType,
        task: handle.task,
      );
      await cli.subagentManager.update(
        handle.id,
        status: handle.status,
        tokens: handle.tokens,
      );
    }
  }

  Future<void> sendAndWait(String line) async {
    io.sendLine(line);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  group('/agents command', () {
    test('types lists the built-in types', () async {
      final cli = cliFor();
      final run = cli.run();
      await sendAndWait('/agents types');
      await sendAndWait('/exit');
      await run;
      final output = io.out.toString();
      expect(output, contains('agent types:'));
      expect(output, contains('task (built-in)'));
      expect(output, contains('explore (built-in)'));
      expect(output, contains('review (built-in)'));
    });

    test('bare prints the live tree with main and children', () async {
      final cli = cliFor();
      await registerHandles(cli, [
        handle(),
        handle(id: 'b2', status: SubagentStatus.running),
      ]);
      final run = cli.run();
      await sendAndWait('/agents');
      await sendAndWait('/exit');
      await run;
      final output = io.out.toString();
      expect(output, contains('main (orchestrator)'));
      expect(output, contains('✅ explore:a1'));
      expect(output, contains('🔄 explore:b2'));
    });

    test('bare prints the empty state when no children', () async {
      final cli = cliFor();
      final run = cli.run();
      await sendAndWait('/agents');
      await sendAndWait('/exit');
      await run;
      expect(io.out.toString(), contains('(no subagents yet)'));
    });

    test(
      '/agents <id> observes the child; unknown id lists available',
      () async {
        final cli = cliFor();
        await registerHandles(cli, [handle()]);
        final run = cli.run();
        await sendAndWait('/agents ghost');
        await sendAndWait('/agents a1');
        await sendAndWait('/exit');
        await run;
        final output = io.out.toString();
        expect(output, contains('no subagent "ghost"'));
        expect(output, contains('a1'));
        expect(output, contains('✅ explore:a1'));
      },
    );

    test('/agents <id> notes an unavailable transcript', () async {
      final cli = cliFor();
      await registerHandles(cli, [handle()]);
      final run = cli.run();
      await sendAndWait('/agents a1');
      await sendAndWait('/exit');
      await run;
      expect(io.out.toString(), contains('(session transcript unavailable)'));
    });
  });

  test('/agents open <id> switches into the child session', () async {
    final cli = cliFor();
    await registerHandles(cli, [handle()]);
    // Give the child a real session file (the completion-time factory
    // path) so the open action has something to switch into.
    final childRepo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final childSession = await childRepo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {'agent': 'subagent', 'id': 'a1'},
      ),
    );
    await childSession.appendMessage(UserMessage.text('child transcript'));
    final childPath = (await childSession.getMetadata()).path;
    await cli.subagentManager.attachSession('a1', childPath);

    final run = cli.run();
    await sendAndWait('/agents open a1');
    await sendAndWait('/exit');
    await run;
    final output = io.out.toString();
    expect(output, contains("switched to session 'subagent explore:a1'"));
    expect(output, contains('child transcript'));
  });

  test(
    '/agents open <id> without a session file reports unavailability',
    () async {
      final cli = cliFor();
      await registerHandles(cli, [handle()]);
      final run = cli.run();
      await sendAndWait('/agents open a1');
      await sendAndWait('/exit');
      await run;
      expect(
        io.out.toString(),
        contains('cannot open session for "a1" (unavailable)'),
      );
    },
  );

  AgentCli namedCli(String sessionName, FakeCliIO cliIo) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      sessionName: sessionName,
    ),
    io: cliIo,
    streamFunction: FakeStreamFunction([]).call,
  );

  test(
    'registry persists into the session and rehydrates in a fresh instance',
    () async {
      // Instance 1: register an agent once the session exists (the sink
      // persists `subagent_registry` custom records into it).
      final io1 = FakeCliIO();
      final first = namedCli('one', io1);
      final run1 = first.run();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await first.subagentManager.register(
        id: 'a1',
        name: 'a1',
        agentType: 'explore',
        task: 'scout files',
      );
      // Registry persistence is fire-and-forget — let the write land.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      io1.sendLine('/exit');
      await run1;
      await io1.close();

      // Instance 2: same env + sessions root, resumes the same session —
      // the agent is visible without any re-registration (a second FakeCliIO:
      // the line stream is single-subscription).
      final io2 = FakeCliIO();
      final second = namedCli('one', io2);
      final run2 = second.run();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      io2.sendLine('/agents');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      io2.sendLine('/exit');
      await run2;
      expect(io2.out.toString(), contains('explore:a1'));
      await io2.close();
    },
  );

  test(
    'pending inbox messages show ✉ markers in the tree and observe',
    () async {
      final cli = cliFor();
      final run = cli.run();
      // Register after boot so the fabric namespace (session id) is active.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await cli.subagentManager.register(
        id: 'a1',
        name: 'a1',
        agentType: 'explore',
        task: 'scout files',
      );
      await cli.subagentManager.enqueueMessage(
        'a1',
        SubagentMessage(
          fromId: 'main',
          text: 'inbox note',
          sentAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      await sendAndWait('/agents');
      await sendAndWait('/agents a1');
      await sendAndWait('/exit');
      await run;
      final output = io.out.toString();
      expect(output, contains('✉1'));
      expect(output, contains('✉ inbox (1):'));
      expect(output, contains('inbox note'));
    },
  );

  test('switching sessions reloads the target session registry', () async {
    final cli = namedCli('one', io);
    final run = cli.run();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await cli.subagentManager.register(
      id: 'a1',
      name: 'a1',
      agentType: 'explore',
      task: 'scout files',
    );
    // Registry persistence is fire-and-forget — let the write land.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // A different session owns no agents…
    await sendAndWait('/session two');
    await sendAndWait('/agents');
    // …and switching back rehydrates the original session's registry.
    await sendAndWait('/session one');
    await sendAndWait('/agents');
    await sendAndWait('/exit');
    await run;
    final output = io.out.toString();
    final emptyIdx = output.indexOf('(no subagents yet)');
    final backIdx = output.lastIndexOf('explore:a1');
    expect(emptyIdx, greaterThan(-1));
    expect(backIdx, greaterThan(emptyIdx));
  });
}
