// The pi-mode wiring gate (issue #679, card L2/L3/REG): with the mode
// resolved at boot, the tool registry pins EXACTLY read/write/edit/bash,
// every other known tool tombstones off, MCP tools (configured or
// late-arriving) stay out, the composed prompt is the bare profile, and
// the boot prints the initial-context tokens. Mode off → byte-identical
// legacy boot (no pin, no benchmark banner line).
//
// The pure-decision slices (argv, resolution ladder, config parsing) live
// in pi_args_test.dart; the settings surface in settings_flow_test.dart.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';
import '../mcp/fake_mcp_server.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction streamFunction, {
    String? agentMode,
    McpToolConfig? mcpConfig,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        agentMode: agentMode,
        mcpConfig: mcpConfig,
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  /// Boots the pi mode and waits until the availability rebuild has
  /// APPLIED the pin (the construction-time registry still carries the
  /// full surface; the rebuild is async at boot).
  Future<AgentCli> bootedPi() async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, agentMode: 'pi');
    final run = cli.run();
    await waitForIt(
      () => io.out.toString().contains('pi benchmark: initial context'),
      reason: 'pi boot print',
    );
    await waitForIt(
      () => cli.agent.state.tools.length == piToolIds.length,
      reason: 'tool-scope pin applied',
    );
    io.sendLine('/exit');
    await run;
    return cli;
  }

  McpToolConfig fakeMcpConfig(FakeMcpServerFactory factory) => McpToolConfig(
    config: McpConfig(
      servers: {'fs': const McpStdioServerConfig(name: 'fs', command: 'fake')},
    ),
    transportFactory: factory.call,
  );

  FakeMcpServerFactory pingFactory() =>
      FakeMcpServerFactory()
        ..onSpawn = (server) {
          server.tools = [
            {'name': 'ping', 'description': 'pings things'},
          ];
        };

  group('L2: the pi tool-surface pin', () {
    test('exactly read/write/edit/bash stay registered', () async {
      final cli = await bootedPi();
      expect(cli.agent.state.tools.map((t) => t.name).toSet(), piToolIds);
    });

    test(
      'every other known tool tombstones off (the /tools surface)',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, agentMode: 'pi');
        final run = cli.run();
        await waitForIt(
          () => cli.agent.state.tools.length == piToolIds.length,
          reason: 'tool-scope pin applied',
        );
        io.sendLine('/tools');
        await waitForIt(
          () => io.out.toString().contains('tool             tier'),
          reason: '/tools listing rendered',
        );
        io.sendLine('/exit');
        await run;

        final lines = io.out.toString().split('\n');
        for (final id in knownToolIds) {
          final on = piToolIds.contains(id);
          final prefix = '${id.padRight(16)} ';
          final line = lines.firstWhere(
            (l) => l.startsWith(prefix),
            orElse: () => '',
          );
          expect(line, isNotEmpty, reason: '$id must be listed by /tools');
          expect(line, contains(on ? ' on ' : ' off '), reason: '$id: $line');
        }
      },
    );

    test(
      'a configured MCP server never registers its tools in pi mode',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(
          fake.call,
          agentMode: 'pi',
          mcpConfig: fakeMcpConfig(pingFactory()),
        );
        final run = cli.run();
        // The fake server connects and reports its tools to the manager —
        // the refilter (pi branch) must still keep them off the registry.
        await waitForIt(
          () => (cli.mcpManagerForTest?.tools ?? const []).isNotEmpty,
          reason: 'fake mcp server connected',
        );
        await waitForIt(
          () => io.out.toString().contains('pi benchmark: initial context'),
          reason: 'pi boot print',
        );
        expect(
          cli.agent.state.tools.map((t) => t.name),
          isNot(contains('mcp__fs__ping')),
        );
        io.sendLine('/exit');
        await run;
      },
    );

    test(
      'the same MCP config registers its tool in default mode (control)',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, mcpConfig: fakeMcpConfig(pingFactory()));
        final run = cli.run();
        await waitForIt(
          () => cli.agent.state.tools.any((t) => t.name == 'mcp__fs__ping'),
          reason: 'mcp tool registered in default mode',
        );
        io.sendLine('/exit');
        await run;
      },
    );
  });

  group('L2: the bare prompt profile', () {
    test('pi prompt is the bare template plus project context only', () async {
      final cli = await bootedPi();
      final prompt = cli.systemPrompt;
      // Identity + the 4 tool docs + the cwd line from mode_pi.md.
      expect(prompt, contains('You are Fa'));
      expect(prompt, contains('pi benchmark mode'));
      for (final tool in piToolIds) {
        expect(prompt, contains('- $tool:'));
      }
      // The stripped sections never appear.
      expect(prompt, isNot(contains('## Agent messaging')));
      expect(prompt, isNot(contains('## MCP servers')));
      // No non-benchmark tool names leak into the prompt text.
      expect(prompt, isNot(contains('bash_job')));
      expect(prompt, isNot(contains('web_search')));
      expect(prompt, isNot(contains('inspect_image')));
    });

    test('default mode keeps the legacy prompt (REG)', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('You are Fa'),
        reason: 'default prompt composed',
      );
      io.sendLine('/exit');
      await run;
      final prompt = cli.systemPrompt;
      expect(prompt, isNot(contains('pi benchmark mode')));
      // The default profile carries sections pi strips.
      expect(prompt, contains('## Agent messaging'));
    });
  });

  group('L3: the boot print', () {
    test('pi boot prints the initial-context token estimate', () async {
      await bootedPi();
      final match = RegExp(
        r'pi benchmark: initial context ~(\d+) tokens',
      ).firstMatch(io.out.toString());
      expect(match, isNotNull);
      // The estimate is positive and sane (the bare prompt is > 0 tokens).
      expect(int.parse(match!.group(1)!), greaterThan(0));
    });

    test('default boot prints no benchmark line (REG)', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('You are Fa'),
        reason: 'default boot',
      );
      io.sendLine('/exit');
      await run;
      expect(io.out.toString(), isNot(contains('pi benchmark:')));
    });

    test('default boot leaves the full tool surface (REG)', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('You are Fa'),
        reason: 'default boot',
      );
      io.sendLine('/exit');
      await run;
      final names = cli.agent.state.tools.map((t) => t.name).toSet();
      expect(names, isNot(piToolIds));
      expect(names, containsAll(['bash', 'read']));
    });
  });
}
