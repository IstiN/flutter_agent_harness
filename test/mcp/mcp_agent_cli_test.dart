/// CLI-level MCP test: an `AgentCli` wired with an `mcp:` config connects
/// to the server in the background, registers the namespaced tools into
/// the live registry, renders the prompt section, and executes a
/// model-driven `mcp__<server>__<tool>` call end to end — the headless
/// smoke path with a scripted model.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';
import 'fake_mcp_server.dart';

void main() {
  late FakeMcpServerFactory factory;
  late FakeCliIO io;
  late MemoryExecutionEnv env;

  setUp(() {
    factory = FakeMcpServerFactory();
    io = FakeCliIO();
    env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
  });

  tearDown(() async {
    await io.close();
  });

  test('background connect registers mcp tools, the prompt section, and a '
      'model call executes through the server', () async {
    factory.onSpawn = (server) {
      server.tools = [
        {
          'name': 'echo',
          'description': 'Echoes text.',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
            'required': ['text'],
          },
        },
      ];
      server.requestHandler = (method, params) {
        if (method == 'initialize') {
          return {'protocolVersion': mcpProtocolVersion};
        }
        if (method == 'tools/list') return {'tools': server.tools};
        if (method == 'tools/call') {
          final args =
              (params! as Map<String, dynamic>)['arguments']
                  as Map<String, dynamic>;
          return {
            'content': [
              {'type': 'text', 'text': 'echo:${args['text']}'},
            ],
          };
        }
        return null;
      };
    };
    final stream = FakeStreamFunction([
      toolTurn([
        const ToolCall(
          id: 'tc-1',
          name: 'mcp__fake__echo',
          arguments: {'text': 'hello cli'},
        ),
      ]),
      textTurn('the server said hi'),
    ]);
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
      streamFunction: stream.call,
    );
    final run = cli.run();
    // The server connects in the background: the tool is not in the
    // registry at construction but arrives before the first turn ends.
    await waitForIt(
      () => cli.agent.state.tools.any((t) => t.name == 'mcp__fake__echo'),
      reason: 'mcp tool registered',
    );
    expect(cli.systemPrompt, contains('## MCP servers'));
    expect(cli.systemPrompt, contains('`fake` (connected): 1 tool(s)'));

    io.sendLine('call the echo tool');
    await waitForIt(
      () => io.out.toString().contains('the server said hi'),
      reason: 'final answer printed',
    );
    // The tool result the model received in its second turn came from the
    // MCP server (routed by the namespaced registry entry).
    final results = stream.contexts[1].messages.whereType<ToolResultMessage>();
    expect(
      results.last.content.whereType<TextContent>().map((b) => b.text).join(),
      'echo:hello cli',
    );
    // The tool executes under the exec tier (the approval gate's safest
    // default for arbitrary server actions).
    expect(
      cli.agent.state.tools.firstWhere((t) => t.name == 'mcp__fake__echo'),
      isA<AgentTool>().having((t) => t.tier, 'tier', ApprovalTier.exec),
    );
    io.sendLine('/exit');
    await run;
  });

  test(
    'a server that cannot start lands in failed status in the prompt',
    () async {
      factory.failAlways = const McpServerUnavailableException('no binary');
      final stream = FakeStreamFunction([textTurn('ok')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          mcpConfig: McpToolConfig(
            config: McpConfig(
              servers: {
                'broken': const McpStdioServerConfig(
                  name: 'broken',
                  command: 'x',
                ),
              },
            ),
            transportFactory: factory.call,
          ),
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('`broken` (failed: no binary)'),
        reason: 'failed server in the prompt',
      );
      expect(
        cli.agent.state.tools.any((t) => t.name.startsWith('mcp__')),
        isFalse,
      );
      io.sendLine('/exit');
      await run;
    },
  );
}
