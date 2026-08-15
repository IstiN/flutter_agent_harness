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
      final childRepo = JsonlSessionRepo(
        fs: env,
        sessionsRoot: '/sessions',
      );
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

    test('/agents open <id> without a session file reports unavailability',
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
    });
}