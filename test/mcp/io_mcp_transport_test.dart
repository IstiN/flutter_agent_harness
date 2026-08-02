/// Tests for the io-side process transport (`IoMcpByteChannel` +
/// `McpStdioTransport`), using a real child process running the echo
/// fixture. These run in the default suite (no network, no external
/// binaries — the child is the same Dart VM).
@Timeout(Duration(seconds: 30))
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  final fixturePath = File(
    'test/mcp/fixtures/echo_mcp_server.dart',
  ).absolute.path;

  McpStdioServerConfig echoConfig({Map<String, String> env = const {}}) {
    return McpStdioServerConfig(
      name: 'echo',
      command: Platform.resolvedExecutable,
      args: [fixturePath],
      env: env,
    );
  }

  group('ioMcpTransportFactory', () {
    test('a missing binary throws McpServerUnavailableException', () {
      expect(
        () => ioMcpTransportFactory(
          const McpStdioServerConfig(
            name: 'nope',
            command: 'definitely-not-a-real-binary-xyz',
          ),
          Directory.current.path,
        ),
        throwsA(isA<McpServerUnavailableException>()),
      );
    });

    test('rejects non-stdio configs', () {
      expect(
        () => ioMcpTransportFactory(
          const McpHttpServerConfig(name: 'remote', url: 'https://x'),
          Directory.current.path,
        ),
        throwsA(isA<McpServerUnavailableException>()),
      );
    });

    test('runs a full MCP session over real stdio', () async {
      final transport = await ioMcpTransportFactory(
        echoConfig(),
        Directory.current.path,
      );
      final client = McpClient(serverName: 'echo', transport: transport);
      try {
        final info = await client.initialize();
        expect(info.serverName, 'echo-mcp');

        final tools = await client.listTools();
        expect(tools.map((t) => t.name), ['echo']);
        expect(tools.single.inputSchema?['type'], 'object');

        final result = await client.callTool('echo', {'text': 'hi there'});
        final content = result['content'] as List;
        expect((content.single as Map)['text'], 'echo:hi there');
      } finally {
        await client.close();
      }
    });

    test('a server exiting mid-session closes the client', () async {
      // `dart --version` prints and exits immediately: a dead stdio server.
      final transport = await ioMcpTransportFactory(
        McpStdioServerConfig(
          name: 'dead',
          command: Platform.resolvedExecutable,
          args: const ['--version'],
        ),
        Directory.current.path,
      );
      final client = McpClient(
        serverName: 'dead',
        transport: transport,
        requestTimeout: const Duration(seconds: 5),
      );
      await client.closed;
      expect(client.status, McpClientStatus.closed);
    });
  });
}
