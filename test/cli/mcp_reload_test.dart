import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'agent_cli_test_support.dart';

/// A config yaml with one stdio MCP server (filesystem demo).
const _stdioConfig = '''
mcp:
  toolCallTimeoutMs: 5000
  servers:
    fs:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
''';

/// A config yaml with a remote HTTP MCP server.
const _httpConfig = '''
mcp:
  toolCallTimeoutMs: 3000
  servers:
    remote:
      url: https://example.com/mcp
''';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor({McpToolConfig? mcpConfig, String? homeDir}) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        mcpConfig: mcpConfig,
        homeDir: homeDir,
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
  }

  group('_printMcpStatus', () {
    test('shows guidance when no MCP servers configured', () async {
      final cli = cliFor();
      final run = cli.run();
      io.sendLine('/mcp');
      await waitForIt(() => io.out.toString().contains('No MCP servers'));
      expect(io.out.toString(), contains('Add servers to the mcp: section'));
      io.sendLine('/exit');
      await run;
    });

    test('lists configured servers', () async {
      final config = McpConfig.fromYaml(
        (loadYaml(_stdioConfig) as YamlMap)['mcp'],
      );
      final cli = cliFor(mcpConfig: McpToolConfig(config: config));
      final run = cli.run();
      io.sendLine('/mcp');
      await waitForIt(() => io.out.toString().contains('MCP servers:'));
      expect(io.out.toString(), contains('fs —'));
      expect(io.out.toString(), contains('npx'));
      io.sendLine('/exit');
      await run;
    });

    test('shows HTTP server url detail', () async {
      final config = McpConfig.fromYaml(
        (loadYaml(_httpConfig) as YamlMap)['mcp'],
      );
      final cli = cliFor(mcpConfig: McpToolConfig(config: config));
      final run = cli.run();
      io.sendLine('/mcp');
      await waitForIt(() => io.out.toString().contains('remote —'));
      expect(io.out.toString(), contains('https://example.com/mcp'));
      io.sendLine('/exit');
      await run;
    });
  });

  group('_reloadMcpConfig', () {
    test('warns when homeDir not set', () async {
      final cli = cliFor();
      final run = cli.run();
      io.sendLine('/mcp reload');
      await waitForIt(
        () => io.out.toString().contains('Cannot reload MCP config'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('reports nothing to reload when config absent', () async {
      await env.writeFile('/home/.fah/config.yaml', 'other: value\n');
      final cli = cliFor(homeDir: '/home');
      final run = cli.run();
      io.sendLine('/mcp reload');
      await waitForIt(() => io.out.toString().contains('nothing to reload'));
      io.sendLine('/exit');
      await run;
    });

    test('reports unchanged when config identical', () async {
      await env.writeFile('/home/.fah/config.yaml', _stdioConfig);
      final config = McpConfig.fromYaml(
        (loadYaml(_stdioConfig) as YamlMap)['mcp'],
      );
      final cli = cliFor(
        mcpConfig: McpToolConfig(config: config),
        homeDir: '/home',
      );
      final run = cli.run();
      io.sendLine('/mcp reload');
      await waitForIt(() => io.out.toString().contains('MCP config unchanged'));
      io.sendLine('/exit');
      await run;
    });

    test('reloads when config changed', () async {
      // Start with the stdio config.
      await env.writeFile('/home/.fah/config.yaml', _stdioConfig);
      final config = McpConfig.fromYaml(
        (loadYaml(_stdioConfig) as YamlMap)['mcp'],
      );
      final cli = cliFor(
        mcpConfig: McpToolConfig(config: config),
        homeDir: '/home',
      );
      final run = cli.run();

      // Rewrite the config with a different server set.
      await env.writeFile('/home/.fah/config.yaml', _httpConfig);
      io.sendLine('/mcp reload');
      await waitForIt(() => io.out.toString().contains('MCP config reloaded'));
      expect(io.out.toString(), contains('1 server(s)'));
      io.sendLine('/exit');
      await run;
    });

    test('handles invalid YAML gracefully', () async {
      await env.writeFile('/home/.fah/config.yaml', 'mcp:\n  servers: bad\n');
      final cli = cliFor(homeDir: '/home');
      final run = cli.run();
      io.sendLine('/mcp reload');
      await waitForIt(
        () =>
            io.out.toString().contains('nothing to reload') ||
            io.out.toString().contains('invalid'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('handles empty file gracefully', () async {
      await env.writeFile('/home/.fah/config.yaml', '');
      final cli = cliFor(homeDir: '/home');
      final run = cli.run();
      io.sendLine('/mcp reload');
      await waitForIt(() => io.out.toString().contains('nothing to reload'));
      io.sendLine('/exit');
      await run;
    });
  });
}
