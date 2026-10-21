import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Same-cwd switches must not re-boot the shell stack (gh-1734 root
/// cause 1): config/providers/MCP/plugins/prompt are already live — a
/// switch that keeps the session's working directory reloads neither the
/// skill tree nor the project context. A switch that ADOPTS a different
/// cwd still reloads, so the system prompt matches the session's project.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late JsonlSessionRepo repo;

  setUp(() async {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    await env.writeFile('/work/AGENTS.md', 'work-project-marker\n');
    await env.createDir('/other', recursive: true);
    await env.writeFile('/other/AGENTS.md', 'other-project-marker\n');
  });

  tearDown(() => io.close());

  Future<void> seedSession(String name, String cwd) async {
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: cwd, metadata: {'agent': 'cli'}),
    );
    await session.appendSessionName(name);
  }

  AgentCli cliFor(StreamFunction streamFunction) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  test('a same-cwd switch keeps the live prompt (no project reload)',
      () async {
    await seedSession('alpha', '/work');
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    expect(cli.systemPrompt, contains('work-project-marker'));

    // The project context file changed on disk AFTER boot; a same-cwd
    // switch re-opens a session of the SAME project — the prompt must
    // stay the already-live one, not re-read the tree.
    await env.writeFile('/work/AGENTS.md', 'rotated-project-marker\n');

    io.sendLine('/session alpha');
    await waitForIt(
      () => io.out.toString().contains("switched to session 'alpha'"),
    );
    expect(cli.systemPrompt, contains('work-project-marker'));
    expect(cli.systemPrompt, isNot(contains('rotated-project-marker')));

    io.sendLine('/exit');
    await run;
  });

  test('a different-cwd switch reloads the session project', () async {
    await seedSession('alpha', '/work');
    await seedSession('beta', '/other');
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    expect(cli.systemPrompt, contains('work-project-marker'));

    io.sendLine('/session beta');
    await waitForIt(
      () => io.out.toString().contains("switched to session 'beta'"),
    );
    expect(cli.systemPrompt, contains('other-project-marker'));

    // And back: adopting /work again reloads ITS project context.
    io.sendLine('/session alpha');
    await waitForIt(
      () =>
          io.out.toString().contains("switched to session 'alpha'") &&
          cli.systemPrompt.contains('work-project-marker'),
    );

    io.sendLine('/exit');
    await run;
  });
}
