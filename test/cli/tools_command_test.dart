/// `/tools` command tests (issue #19 AC14/AC15): the line-mode listing
/// (id, tier, state, scope, reason), scoped enable/disable persistence
/// (project file, session tools.yaml, global via the host hook), and the
/// unknown-id warning that leaves other tools untouched (AC5).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late FakeStreamFunction fake;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor({
    String sessionRoot = '/sessions',
    String? homeDir,
    Future<void> Function()? onToolsConfigChanged,
  }) {
    fake = FakeStreamFunction([
      textTurn('one'),
      textTurn('two'),
      textTurn('three'),
      textTurn('four'),
      textTurn('five'),
      textTurn('six'),
    ]);
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: sessionRoot,
        homeDir: homeDir,
        onToolsConfigChanged: onToolsConfigChanged,
        webSearchConfig: WebSearchConfig(),
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: fake.call,
    );
  }

  Future<void> waitForOutput(String expected) async {
    for (var i = 0; i < 300; i++) {
      if (io.out.toString().contains(expected)) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('timed out waiting for: $expected');
  }

  Future<void> settle(String line, String expected) async {
    io.sendLine(line);
    await waitForOutput(expected);
  }

  Set<String> offeredTools(AgentCli cli) =>
      cli.agent.state.tools.map((tool) => tool.name).toSet();

  test(
    '/tools lists every known id with tier, state, scope, and reason',
    () async {
      final cli = cliFor();
      final run = cli.run();
      await settle('/tools', 'bash');
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      for (final id in ['read', 'write', 'edit', 'ls', 'bash', 'checkpoint']) {
        expect(output, contains(id));
      }
      expect(output, contains('builtin'));
      expect(output, contains('off'), reason: 'unwired capabilities list off');
      expect(
        output,
        contains('SQLite engine not wired by this host'),
        reason: 'the reason column carries the absent note',
      );
    },
  );

  test('/tools disable <id> project persists the config section and hides '
      'the tool from the next turn; enable restores', () async {
    final cli = cliFor();
    final run = cli.run();

    await settle(
      '/tools disable web_search project',
      'disabled web_search (scope: project)',
    );
    // The project file now carries the section.
    final project = (await env.readTextFile(
      '/work/.fah/config.yaml',
    )).valueOrNull;
    expect(project, contains('tools:'));
    expect(project, contains('web_search: false'));

    expect(offeredTools(cli), isNot(contains('web_search')));
    expect(offeredTools(cli), contains('bash'));

    await settle('/tools enable web_search', 'enabled web_search');
    expect(offeredTools(cli), contains('web_search'));

    io.sendLine('/exit');
    await run;
  });

  test('/tools disable <id> global routes through the host hook', () async {
    final seen = <Map<String, bool>>[];
    late final AgentCli cli;
    cli = cliFor(
      onToolsConfigChanged: () async {
        seen.add(Map.of(cli.globalTools!.tools));
      },
    );
    final run = cli.run();

    await settle('/tools disable bash global', 'disabled bash (scope: global)');
    expect(seen, hasLength(1));
    expect(seen.single, containsPair('bash', false));

    expect(offeredTools(cli), isNot(contains('bash')));

    io.sendLine('/exit');
    await run;
  });

  test(
    '/tools disable <id> session writes tools.yaml next to the session',
    () async {
      final cli = cliFor();
      final run = cli.run();

      await settle('/tools disable ls session', 'disabled ls (scope: session)');

      // The session scope file is per-session:
      // <sessionRoot>/<encodedCwd>/.tools/<sessionId>.yaml.
      final rootEntries = (await env.listDir('/sessions')).valueOrNull!;
      final dotTools = [
        for (final dir in rootEntries)
          ...?((await env.listDir('${dir.path}/.tools')).valueOrNull),
      ];
      expect(dotTools, hasLength(1));
      expect(dotTools.single.name, endsWith('.yaml'));
      final content = (await env.readTextFile(
        dotTools.single.path,
      )).valueOrNull;
      expect(content, contains('tools:'));
      expect(content, contains('ls: false'));

      await settle('/tools enable ls session', 'enabled ls (scope: session)');
      expect(offeredTools(cli), contains('ls'));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'unknown tool id warns and leaves the other tools alone (AC5)',
    () async {
      final cli = cliFor();
      final run = cli.run();

      await settle('/tools disable nosuchtool', 'unknown tool id "nosuchtool"');
      expect(offeredTools(cli), contains('bash'));
      expect(offeredTools(cli), contains('read'));

      io.sendLine('/exit');
      await run;
    },
  );

  test('a broken scope file errors instead of changing state (AC15)', () async {
    await env.writeFile('/work/.fah/config.yaml', 'tools: [not-a-map\n');
    final cli = cliFor();
    final run = cli.run();

    await settle('/tools disable web_search project', 'tools:');
    final output = io.out.toString();
    expect(output, contains('project scope'));
    // No state change: web_search stays offered.
    expect(offeredTools(cli), contains('web_search'));

    io.sendLine('/exit');
    await run;
  });

  test(
    'settings Tools flow disables then re-enables a tool (project scope)',
    () async {
      final cli = cliFor();
      final run = cli.run();

      final flow = cli.startToolsFlow();
      await waitForOutput('tools — pick a tool');
      await waitForOutput('type a number:');
      io.sendLine('1'); // read
      await waitForOutput('tools — read');
      await waitForOutput('type a number:');
      io.sendLine('2'); // disable
      await waitForOutput('tools — disable read in');
      await waitForOutput('type a number:');
      io.sendLine('1'); // project
      await waitForOutput('tools: disabled read (scope: project)');
      expect(offeredTools(cli), isNot(contains('read')));
      var project = (await env.readTextFile(
        '/work/.fah/config.yaml',
      )).valueOrNull;
      expect(project, contains('read: false'));

      // The loop comes back around; flip it back and exit via `done`
      // (option 25 = 24 known ids + done — the browser family added two).
      await waitForOutput('tools — pick a tool');
      io.sendLine('1'); // read
      await waitForOutput('tools — read');
      io.sendLine('1'); // enable
      await waitForOutput('tools — enable read in');
      io.sendLine('1'); // project
      await waitForOutput('tools: enabled read (scope: project)');
      expect(offeredTools(cli), contains('read'));

      await waitForOutput('tools — pick a tool');
      io.sendLine('25'); // done
      await flow;

      project = (await env.readTextFile('/work/.fah/config.yaml')).valueOrNull;
      expect(project, contains('read: true'));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'settings Tools flow cancelled at the scope pick pins nothing',
    () async {
      final cli = cliFor();
      final run = cli.run();

      final flow = cli.startToolsFlow();
      await waitForOutput('tools — pick a tool');
      await waitForOutput('type a number:');
      io.sendLine('1'); // read
      await waitForOutput('tools — read');
      await waitForOutput('type a number:');
      io.sendLine('1'); // enable
      await waitForOutput('tools — enable read in');
      await waitForOutput('type a number:');
      io.interrupt();
      await flow;

      expect(offeredTools(cli), contains('read'));
      final project = (await env.readTextFile(
        '/work/.fah/config.yaml',
      )).valueOrNull;
      expect(project, isNull);

      io.sendLine('/exit');
      await run;
    },
  );
}
