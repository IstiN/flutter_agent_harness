@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/a2a/a2a_client.dart';
import 'package:flutter_agent_harness/src/a2a/a2a_config.dart';
import 'package:flutter_agent_harness/src/a2a/a2a_manager.dart';
import 'package:test/test.dart';

A2aManagedServer _server({
  required String name,
  String url = 'https://x.example.com',
  A2aServerConnectionStatus status = A2aServerConnectionStatus.connecting,
  AgentCard? card,
  String? error,
}) {
  final config = A2aServerConfig(name: name, url: url);
  final server = A2aManagedServer(config)
    ..status = status
    ..card = card
    ..error = error;
  return server;
}

void main() {
  group('formatA2aServerStatus', () {
    test('connecting server shows url and connecting marker', () {
      final lines = formatA2aServerStatus(_server(name: 'translator'));
      expect(lines[0], contains('translator'));
      expect(lines[0], contains('connecting'));
      expect(lines[1], contains('https://x.example.com'));
    });

    test('connected server with a card shows agent + version', () {
      final server = _server(
        name: 't',
        status: A2aServerConnectionStatus.connected,
        card: const AgentCard(
          name: 'translator',
          description: 'translates',
          url: 'https://x.example.com',
          version: '2.1.0',
        ),
      );
      final lines = formatA2aServerStatus(server);
      expect(lines[0], contains('✅ connected'));
      expect(lines[2], contains('translator v2.1.0'));
    });

    test('failed server shows the error line', () {
      final server = _server(
        name: 't',
        status: A2aServerConnectionStatus.failed,
        error: 'connection refused',
      );
      final lines = formatA2aServerStatus(server);
      expect(lines[0], contains('❌ failed'));
      expect(lines.last, contains('connection refused'));
    });

    test('a server without card or error has no extra lines', () {
      final lines = formatA2aServerStatus(_server(name: 't'));
      expect(lines, hasLength(2));
    });
  });

  group('formatA2aStatusLines', () {
    test('no servers renders the config hint', () {
      final lines = formatA2aStatusLines(A2aManager(null));
      expect(lines.single, contains('no a2a servers configured'));
    });

    test('one server renders header + block + usage hint', () {
      final manager = A2aManager(
        A2aConfig(
          servers: {
            'remote': const A2aServerConfig(
              name: 'remote',
              url: 'https://x.example.com',
            ),
          },
        ),
      );
      final lines = formatA2aStatusLines(manager);
      expect(lines.first, '[A2A servers]');
      expect(lines, contains('  remote: … connecting'));
      expect(lines.last, contains('a2a:<name>'));
    });
  });
}
