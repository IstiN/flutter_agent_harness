/// Tests for the `mcp:` config section parsing (`McpConfig.fromYaml`):
/// valid stdio/remote shapes, defaults, strict schema errors, and the
/// toYaml round-trip (config saves must never drop the section).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  McpConfig parse(String yaml) {
    final doc = loadYaml(yaml);
    return McpConfig.fromYaml((doc as YamlMap)['mcp']);
  }

  group('McpConfig.fromYaml', () {
    test('parses a stdio server with args and env', () {
      final config = parse('''
mcp:
  servers:
    filesystem:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      env:
        FOO: bar
''');
      expect(config.toolCallTimeout, const Duration(seconds: 60));
      final server = config.servers['filesystem'] as McpStdioServerConfig;
      expect(server.command, 'npx');
      expect(server.args, [
        '-y',
        '@modelcontextprotocol/server-filesystem',
        '/tmp',
      ]);
      expect(server.env, {'FOO': 'bar'});
    });

    test('parses a remote server with transport and headers', () {
      final config = parse('''
mcp:
  toolCallTimeoutMs: 5000
  servers:
    remote:
      url: https://example.com/mcp
      transport: sse
      headers:
        Authorization: Bearer x
''');
      expect(config.toolCallTimeout, const Duration(seconds: 5));
      final server = config.servers['remote'] as McpHttpServerConfig;
      expect(server.url, 'https://example.com/mcp');
      expect(server.transport, McpHttpTransportKind.sse);
      expect(server.headers, {'Authorization': 'Bearer x'});
    });

    test('defaults the remote transport to streamable-http', () {
      final config = parse('''
mcp:
  servers:
    remote:
      url: https://example.com/mcp
''');
      final server = config.servers['remote'] as McpHttpServerConfig;
      expect(server.transport, McpHttpTransportKind.streamableHttp);
      expect(server.headers, isEmpty);
    });

    test('rejects a non-map section', () {
      expect(
        () => McpConfig.fromYaml('nope'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('"mcp" must be a map'),
          ),
        ),
      );
    });

    test('rejects a missing servers map', () {
      expect(
        () => parse('mcp:\n  toolCallTimeoutMs: 1000\n'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('no "servers"'),
          ),
        ),
      );
    });

    test('rejects a bad timeout', () {
      expect(
        () => parse('mcp:\n  toolCallTimeoutMs: -5\n  servers: {}\n'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('toolCallTimeoutMs'),
          ),
        ),
      );
    });

    test('rejects an entry with neither command nor url', () {
      expect(
        () => parse('mcp:\n  servers:\n    broken:\n      args: []\n'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('mcp.servers.broken'),
          ),
        ),
      );
    });

    test('rejects an entry mixing command and url', () {
      expect(
        () => parse(
          'mcp:\n  servers:\n    broken:\n'
          '      command: npx\n      url: https://x\n',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('must not mix'),
          ),
        ),
      );
    });

    test('rejects an unknown transport label', () {
      expect(
        () => parse(
          'mcp:\n  servers:\n    remote:\n'
          '      url: https://x\n      transport: websocket\n',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('unknown transport "websocket"'),
          ),
        ),
      );
    });

    test('rejects non-string args entries', () {
      expect(
        () => parse(
          'mcp:\n  servers:\n    fs:\n      command: npx\n'
          '      args: [1, 2]\n',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('mcp.servers.fs.args entries must be strings'),
          ),
        ),
      );
    });

    test('rejects an empty command', () {
      expect(
        () => parse('mcp:\n  servers:\n    fs:\n      command: " "\n'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('toYaml round-trips through fromYaml', () {
      final config = parse('''
mcp:
  toolCallTimeoutMs: 45000
  servers:
    filesystem:
      command: npx
      args: ["-y", "server"]
      env: {FOO: bar}
    remote:
      url: https://example.com/mcp
      transport: streamable-http
      headers: {Authorization: Bearer x}
''');
      final roundTripped = McpConfig.fromYaml(
        (loadYaml(config.toYaml()) as YamlMap)['mcp'],
      );
      expect(roundTripped.toolCallTimeout, config.toolCallTimeout);
      expect(roundTripped.servers.keys, config.servers.keys);
      final fs = roundTripped.servers['filesystem'] as McpStdioServerConfig;
      expect(fs.command, 'npx');
      expect(fs.args, ['-y', 'server']);
      expect(fs.env, {'FOO': 'bar'});
      final remote = roundTripped.servers['remote'] as McpHttpServerConfig;
      expect(remote.transport, McpHttpTransportKind.streamableHttp);
      expect(remote.headers, {'Authorization': 'Bearer x'});
    });
  });
}
