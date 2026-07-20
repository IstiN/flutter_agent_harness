/// Tests for the io-side process transport (`IoLspTransport`), using a real
/// child process running the echo fixture. These run in the default suite
/// (no network, no external binaries — the child is the same Dart VM).
@Timeout(Duration(seconds: 30))
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  final fixturePath = File(
    'test/lsp/fixtures/echo_lsp_server.dart',
  ).absolute.path;

  final echoConfig = LspServerConfig(
    name: 'echo',
    command: Platform.resolvedExecutable,
    args: [fixturePath],
    fileTypes: const ['.dart'],
    rootMarkers: const ['.'],
  );

  group('IoLspTransport', () {
    test('a missing binary throws LspServerUnavailableException', () {
      expect(
        () => ioLspTransportFactory(
          const LspServerConfig(
            name: 'missing',
            command: 'definitely-not-a-real-binary-xyz',
            fileTypes: ['.dart'],
            rootMarkers: ['.'],
          ),
          Directory.current.path,
        ),
        throwsA(
          isA<LspServerUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('definitely-not-a-real-binary-xyz'),
          ),
        ),
      );
    });

    test('spawn, handshake, request round trip, graceful shutdown', () async {
      final transport = await ioLspTransportFactory(
        echoConfig,
        Directory.current.path,
      );
      final client = LspClient(
        config: echoConfig,
        rootPath: Directory.current.path,
        transport: transport,
        processId: pid,
      );

      await client.initialize();
      expect(client.status, LspClientStatus.ready);
      expect(client.serverCapabilities?['textDocumentSync'], 1);

      final result = await client.request('textDocument/hover', {
        'textDocument': {'uri': 'file:///x.dart'},
      });
      expect(result, {
        'echo': 'textDocument/hover',
        'params': {
          'textDocument': {'uri': 'file:///x.dart'},
        },
      });

      await client.shutdown();
      // The fixture exits 0 on the `exit` notification; shutdown awaited it.
      expect(client.status, LspClientStatus.closed);
    });

    test('kill ends the process and closes the client', () async {
      final transport = await ioLspTransportFactory(
        echoConfig,
        Directory.current.path,
      );
      var exits = 0;
      final client = LspClient(
        config: echoConfig,
        rootPath: Directory.current.path,
        transport: transport,
        onExit: () => exits++,
      );
      await client.initialize();
      transport.kill();
      final code = await transport.exitCode;
      expect(code, isNot(0));
      await pumpEventQueue();
      expect(client.status, LspClientStatus.closed);
      expect(exits, 1);
    });
  });
}
