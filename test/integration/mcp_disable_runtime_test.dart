/// Per-server MCP gating at runtime (issue #19 AC13):
/// `tools: mcp:<server>: false` unregisters that server's tools and drops it from
/// the prompt section; re-enabling re-registers them WITHOUT restarting
/// the server (the fake transport factory spawns exactly once).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';
import '../mcp/fake_mcp_server.dart';

void main() {
  test('warm probe', () async {}, skip: true);
  late FakeMcpServerFactory factory;
  late FakeCliIO io;
  late MemoryExecutionEnv env;

  setUp(() {
    factory = FakeMcpServerFactory();
    io = FakeCliIO();
    env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    factory.onSpawn = (server) {
      server.tools = [
        {
          'name': 'echo',
          'description': 'echo it back',
          'inputSchema': {'type': 'object', 'properties': const {}},
        },
      ];
    };
  });

  tearDown(() async {
    await io.close();
  });

  Future<(AgentCli, Future<void>)> boot() async {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        mcpConfig: McpToolConfig(
          config: McpConfig(
            servers: {
              'fake': const McpStdioServerConfig(name: 'fake', command: 'x'),
            },
          ),
          transportFactory: factory.call,
        ),
      ),
      io: io,
      streamFunction: FakeStreamFunction([
        textTurn('one'),
        textTurn('two'),
      ]).call,
    );
    final run = cli.run();
    // The background connect registers the namespaced tool.
    for (var i = 0; i < 200; i++) {
      if (cli.agent.state.tools.any((tool) => tool.name == 'mcp__fake__echo')) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return (cli, run);
  }

  /// Local poller: waits for a NEW occurrence of [expected] (the string
  /// may already be in the transcript from an earlier command).
  Future<void> settle(String line, String expected) async {
    int count(String out) => expected.allMatches(out).length;
    final before = count(io.out.toString());
    io.sendLine(line);
    for (var i = 0; i < 300; i++) {
      if (count(io.out.toString()) > before) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('timed out waiting for: $expected');
  }

  test('disable hides the server tools and prompt section; enable '
      're-registers without a restart', () async {
    final (cli, run) = await boot();

    expect(cli.systemPrompt, contains('## MCP servers'));
    expect(cli.systemPrompt, contains('`fake` (connected)'));

    await settle('/tools disable mcp:fake', 'disabled mcp:fake');

    final names = cli.agent.state.tools.map((tool) => tool.name).toSet();
    expect(names, isNot(contains('mcp__fake__echo')));
    expect(
      cli.systemPrompt,
      isNot(contains('## MCP servers')),
      reason: 'the only server is filtered out of the prompt section',
    );

    // (Executor tombstoning for disabled MCP families is covered by
    // test/tools/availability_gate_test.dart.)

    await settle('/tools enable mcp:fake', 'enabled mcp:fake');
    await waitForIt(
      () => cli.agent.state.tools.any((tool) => tool.name == 'mcp__fake__echo'),
      reason: 'mcp tool re-registered',
    );
    expect(cli.systemPrompt, contains('`fake` (connected)'));
    // AC13: no server restart — exactly one transport spawn ever happened.
    expect(factory.spawned, hasLength(1));

    io.sendLine('/exit');
    // The REPL's exit path can outlive the asserts (background reconnect
    // timers); bound it — everything under test already completed.
    await run.timeout(const Duration(seconds: 5), onTimeout: () {});
  }, timeout: const Timeout(Duration(seconds: 90)));
}
