@Timeout(Duration(seconds: 10))
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'fake_lsp_server.dart';

void main() {
  const serverConfig = LspServerConfig(
    name: 'fake',
    command: 'fake-server',
    fileTypes: ['.dart'],
    rootMarkers: ['pubspec.yaml'],
    initOptions: {'closingLabels': true},
    settings: {
      'dart': {'lineLength': 100},
    },
  );

  late FakeLspServer server;
  late LspClient client;

  setUp(() {
    server = FakeLspServer();
    client = LspClient(
      config: serverConfig,
      rootPath: '/ws',
      transport: server.transport,
      processId: 4242,
    );
  });

  tearDown(() async {
    await client.shutdown();
    await server.dispose();
  });

  Map<String, dynamic>? lastNotificationParams(String method) {
    for (final entry in server.notifications.reversed) {
      if (entry.method == method) return entry.params as Map<String, dynamic>?;
    }
    return null;
  }

  group('handshake', () {
    test('initialize sends params and becomes ready', () async {
      await client.initialize();

      expect(client.status, LspClientStatus.ready);
      expect(client.serverCapabilities?['definitionProvider'], isTrue);

      final init = server.requests.first;
      expect(init.method, 'initialize');
      final params = init.params! as Map<String, dynamic>;
      expect(params['processId'], 4242);
      expect(params['rootUri'], 'file:///ws');
      expect(params['initializationOptions'], {'closingLabels': true});
      expect((params['workspaceFolders'] as List).single, {
        'uri': 'file:///ws',
        'name': 'ws',
      });

      // initialized notification + settings push follow the handshake.
      expect(
        server.notifications.map((n) => n.method),
        containsAll(['initialized', 'workspace/didChangeConfiguration']),
      );
      expect(lastNotificationParams('workspace/didChangeConfiguration'), {
        'settings': {
          'dart': {'lineLength': 100},
        },
      });
    });

    test('initialize without settings skips didChangeConfiguration', () async {
      final plain = FakeLspServer();
      final plainClient = LspClient(
        config: const LspServerConfig(
          name: 'plain',
          command: 'plain',
          fileTypes: ['.dart'],
          rootMarkers: ['.'],
        ),
        rootPath: '/ws',
        transport: plain.transport,
      );
      addTearDown(() async {
        await plainClient.shutdown();
        await plain.dispose();
      });
      await plainClient.initialize();
      expect(
        plain.notifications.map((n) => n.method),
        isNot(contains('workspace/didChangeConfiguration')),
      );
    });

    test('a malformed initialize result fails the handshake', () async {
      server.requestHandler = (method, params) => 'not-a-map';
      await expectLater(
        client.initialize(),
        throwsA(
          isA<LspRequestException>().having(
            (e) => e.message,
            'message',
            contains('no response'),
          ),
        ),
      );
    });
  });

  group('requests', () {
    setUp(() => client.initialize());

    test('round trip resolves with the result', () async {
      server.requestHandler = (method, params) => [
        {
          'uri': 'file:///ws/lib/a.dart',
          'range': {
            'start': {'line': 1, 'character': 2},
            'end': {'line': 1, 'character': 5},
          },
        },
      ];
      final result = await client.request('textDocument/definition', {
        'textDocument': {'uri': 'file:///ws/lib/a.dart'},
        'position': {'line': 0, 'character': 0},
      });
      expect(result, isA<List>());
      expect(server.requests.last.method, 'textDocument/definition');
    });

    test('an error response rejects with LspRequestException', () async {
      server.autoRespond = false;
      final future = client.request('textDocument/hover', null);
      final expectation = expectLater(
        future,
        throwsA(
          isA<LspRequestException>().having(
            (e) => e.message,
            'message',
            contains('content modified'),
          ),
        ),
      );
      await pumpEventQueue();
      final pending = server.requests.last;
      expect(pending.method, 'textDocument/hover');
      server.sendMessage({
        'jsonrpc': '2.0',
        'id': 2, // initialize consumed id 1
        'error': {'code': -32801, 'message': 'content modified'},
      });
      await expectation;
    });

    test('a request without a response times out', () async {
      final silent = FakeLspServer();
      final silentClient = LspClient(
        config: serverConfig,
        rootPath: '/ws',
        transport: silent.transport,
        requestTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(() async {
        await silentClient.shutdown();
        await silent.dispose();
      });
      await silentClient.initialize();
      silent.autoRespond = false;
      await expectLater(
        silentClient.request('textDocument/hover', null),
        throwsA(
          isA<LspRequestException>().having(
            (e) => e.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
      silent.autoRespond = true; // let tearDown's shutdown complete
    });

    test('a dead server rejects in-flight requests', () async {
      await client.initialize();
      server.autoRespond = false;
      final future = client.request('textDocument/hover', null);
      final expectation = expectLater(
        future,
        throwsA(isA<LspRequestException>()),
      );
      await server.simulateCrash();
      await expectation;
      expect(client.status, LspClientStatus.closed);
    });
  });

  group('document sync', () {
    setUp(() => client.initialize());

    test('ensureOpen sends didOpen once', () async {
      client.ensureOpen('/ws/lib/a.dart', 'void main() {}', 'dart');
      client.ensureOpen('/ws/lib/a.dart', 'void main() {}', 'dart');
      await pumpEventQueue();

      final opens = server.notifications
          .where((n) => n.method == 'textDocument/didOpen')
          .toList();
      expect(opens, hasLength(1));
      final doc =
          (opens.single.params! as Map<String, dynamic>)['textDocument']
              as Map<String, dynamic>;
      expect(doc['uri'], 'file:///ws/lib/a.dart');
      expect(doc['languageId'], 'dart');
      expect(doc['version'], 1);
      expect(doc['text'], 'void main() {}');
      expect(client.openFiles['file:///ws/lib/a.dart'], 1);
    });

    test('syncContent sends didChange with a bumped version', () async {
      client.syncContent('/ws/lib/a.dart', 'v1', 'dart');
      client.syncContent('/ws/lib/a.dart', 'v2', 'dart');
      await pumpEventQueue();

      expect(
        server.notifications.where((n) => n.method == 'textDocument/didOpen'),
        hasLength(1),
      );
      final changes = server.notifications
          .where((n) => n.method == 'textDocument/didChange')
          .toList();
      expect(changes, hasLength(1));
      final params = changes.single.params! as Map<String, dynamic>;
      expect((params['textDocument'] as Map<String, dynamic>)['version'], 2);
      expect((params['contentChanges'] as List).single, {'text': 'v2'});
      expect(client.openFiles['file:///ws/lib/a.dart'], 2);
    });

    test('closeFile sends didClose and forgets the document', () async {
      client.ensureOpen('/ws/lib/a.dart', 'x', 'dart');
      client.closeFile('/ws/lib/a.dart');
      client.closeFile('/ws/lib/a.dart'); // no-op
      await pumpEventQueue();

      expect(
        server.notifications.where((n) => n.method == 'textDocument/didClose'),
        hasLength(1),
      );
      expect(client.openFiles, isEmpty);
    });
  });

  group('diagnostics', () {
    setUp(() => client.initialize());

    test('publishDiagnostics updates the cache and version', () async {
      final events = <String>[];
      final sub = client.diagnosticsStream.listen(events.add);
      addTearDown(sub.cancel);

      server.publishDiagnostics('file:///ws/lib/a.dart', [
        {
          'range': {
            'start': {'line': 0, 'character': 0},
            'end': {'line': 0, 'character': 3},
          },
          'severity': 2,
          'source': 'analyzer',
          'message': 'unused variable',
        },
      ]);
      await pumpEventQueue();

      expect(client.diagnosticsVersion, 1);
      expect(events, ['file:///ws/lib/a.dart']);
      final diags = client.diagnostics['file:///ws/lib/a.dart']!;
      expect(diags.single.severity, LspDiagnosticSeverity.warning);
      expect(diags.single.source, 'analyzer');
      expect(diags.single.message, 'unused variable');
    });
  });

  group('server-initiated requests', () {
    setUp(() => client.initialize());

    test('workspace/configuration answers from settings', () async {
      final response = await server.sendServerRequest(
        'workspace/configuration',
        {
          'items': [
            {'section': 'dart'},
            {'section': 'missing'},
          ],
        },
      );
      expect(response['result'], [
        {'lineLength': 100},
        null,
      ]);
    });

    test('workspace/workspaceFolders answers the root', () async {
      final response = await server.sendServerRequest(
        'workspace/workspaceFolders',
        null,
      );
      expect(response['result'], [
        {'uri': 'file:///ws', 'name': 'ws'},
      ]);
    });

    test('window/showDocument answers headless', () async {
      final response = await server.sendServerRequest('window/showDocument', {
        'uri': 'file:///ws/lib/a.dart',
      });
      expect(response['result'], {'success': false});
    });

    test('workspace/applyEdit declines', () async {
      final response = await server.sendServerRequest('workspace/applyEdit', {
        'edit': {},
      });
      expect((response['result'] as Map<String, dynamic>)['applied'], isFalse);
    });

    test('progress and registration requests are acknowledged', () async {
      for (final method in [
        'window/workDoneProgress/create',
        'client/registerCapability',
        'client/unregisterCapability',
        'workspace/diagnostic/refresh',
        'window/showMessageRequest',
      ]) {
        final response = await server.sendServerRequest(method, null);
        expect(response, isNot(contains('error')), reason: method);
      }
    });

    test('unknown methods get a method-not-found error', () async {
      final response = await server.sendServerRequest('made/up', null);
      expect((response['error'] as Map<String, dynamic>)['code'], -32601);
    });
  });

  group('teardown', () {
    test('crash marks closed and notifies onExit once', () async {
      var exits = 0;
      final own = FakeLspServer();
      final watched = LspClient(
        config: serverConfig,
        rootPath: '/ws',
        transport: own.transport,
        onExit: () => exits++,
      );
      await watched.initialize();
      await own.simulateCrash();
      await pumpEventQueue();
      expect(watched.status, LspClientStatus.closed);
      expect(exits, 1);
    });

    test('shutdown sends shutdown + exit and closes the stream', () async {
      await client.initialize();
      await client.shutdown();

      expect(server.requests.map((r) => r.method), contains('shutdown'));
      expect(server.notifications.map((n) => n.method), contains('exit'));
      expect(client.status, LspClientStatus.closed);
    });

    test('requests on a closed client fail immediately', () async {
      await client.initialize();
      await client.shutdown();
      await expectLater(
        client.request('textDocument/hover', null),
        throwsA(isA<LspRequestException>()),
      );
    });
  });
}
