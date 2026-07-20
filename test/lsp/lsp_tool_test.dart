@Timeout(Duration(seconds: 10))
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'fake_lsp_server.dart';

void main() {
  const mainDart = '''
import 'b.dart';

void main() {
  final greeter = Greeter();
  greeter.greet('world');
}
''';
  const bDart = '''
class Greeter {
  void greet(String name) {
    print('Hello, ');
  }
}
''';

  late MemoryExecutionEnv env;
  late FakeLspServerFactory factory;
  late LspClientManager manager;
  late AgentTool tool;

  setUp(() async {
    env = MemoryExecutionEnv(cwd: '/ws');
    await env.writeFile('/ws/pubspec.yaml', 'name: ws\n');
    await env.writeFile('/ws/lib/main.dart', mainDart);
    await env.writeFile('/ws/lib/b.dart', bDart);
    factory = FakeLspServerFactory();
    manager = LspClientManager(
      env: env,
      config: LspConfig.defaults(),
      transportFactory: factory.call,
      idleTimeout: Duration.zero,
    );
    tool = lspTool(
      env,
      config: LspToolConfig(
        transportFactory: factory.call,
        manager: manager,
        diagnosticsWait: const Duration(milliseconds: 100),
      ),
    );
  });

  tearDown(() => manager.shutdownAll());

  FakeLspServer fakeServer() => factory.spawned.single;

  Future<String> run(Map<String, dynamic> args) async {
    final result = await tool.execute(args, null, null);
    return result.content.whereType<TextContent>().map((c) => c.text).join();
  }

  group('registration gating', () {
    test('builtinTools leaves lsp out without a config', () {
      final names = builtinTools(MemoryExecutionEnv()).map((t) => t.name);
      expect(names, isNot(contains('lsp')));
    });

    test('builtinTools registers lsp with a config', () {
      final names = builtinTools(
        MemoryExecutionEnv(),
        lsp: LspToolConfig(transportFactory: factory.call),
      ).map((t) => t.name);
      expect(names, contains('lsp'));
    });

    test('the tool is declared at the write tier (rename mutates)', () {
      expect(tool.tier, ApprovalTier.write);
    });
  });

  group('diagnostics', () {
    test('OK for a clean file', () async {
      final output = await run({'op': 'diagnostics', 'path': 'lib/main.dart'});
      expect(output, 'OK');
      // The server saw the file open with its content.
      final uri = fileToUri('/ws/lib/main.dart');
      expect(fakeServer().openedDocuments[uri]?['text'], mainDart);
      expect(fakeServer().openedDocuments[uri]?['languageId'], 'dart');
    });

    test('renders severity-sorted issues with a summary', () async {
      factory.onSpawn = (server) {
        server.diagnosticsToPublish[fileToUri('/ws/lib/main.dart')] = [
          {
            'range': {
              'start': {'line': 5, 'character': 2},
              'end': {'line': 5, 'character': 9},
            },
            'severity': 2,
            'source': 'analyzer',
            'message': 'unused import',
          },
          {
            'range': {
              'start': {'line': 4, 'character': 9},
              'end': {'line': 4, 'character': 16},
            },
            'severity': 1,
            'message': 'undefined name',
          },
        ];
      };
      final output = await run({'op': 'diagnostics', 'path': 'lib/main.dart'});
      expect(
        output,
        'lib/main.dart: 1 error(s), 1 warning(s):\n'
        '  L5:10 [error] undefined name\n'
        '  L6:3 [warning] unused import (analyzer)',
      );
    });

    test(
      'falls back to cached diagnostics when nothing is published',
      () async {
        factory.onSpawn = (server) {
          server.autoPublishDiagnostics = false;
        };
        // diagnosticsWait is 100ms in this harness; the wait elapses silently.
        final output = await run({
          'op': 'diagnostics',
          'path': 'lib/main.dart',
        });
        expect(output, 'OK');
      },
    );
  });

  group('definition', () {
    test('renders locations with the source line', () async {
      factory.onSpawn = (server) {
        server.requestHandler = (method, params) {
          if (method == 'initialize') return {'capabilities': {}};
          return [
            {
              'uri': fileToUri('/ws/lib/b.dart'),
              'range': {
                'start': {'line': 1, 'character': 7},
                'end': {'line': 1, 'character': 14},
              },
            },
          ];
        };
      };
      final output = await run({
        'op': 'definition',
        'path': 'lib/main.dart',
        'line': 4,
        'character': 16,
      });
      expect(
        output,
        'Found 1 definition(s):\n'
        '  lib/b.dart:2:8\n'
        '    void greet(String name) {',
      );

      // The wire position was converted to 0-indexed.
      final request = fakeServer().requests.last;
      expect(request.method, 'textDocument/definition');
      final params = request.params! as Map<String, dynamic>;
      expect(params['position'], {'line': 3, 'character': 15});
    });

    test('accepts LocationLink results', () async {
      factory.onSpawn = (server) {
        server.requestHandler = (method, params) {
          if (method == 'initialize') return {'capabilities': {}};
          return [
            {
              'targetUri': fileToUri('/ws/lib/b.dart'),
              'targetRange': {
                'start': {'line': 0, 'character': 0},
                'end': {'line': 2, 'character': 0},
              },
              'targetSelectionRange': {
                'start': {'line': 0, 'character': 6},
                'end': {'line': 0, 'character': 13},
              },
            },
          ];
        };
      };
      final output = await run({'op': 'definition', 'path': 'lib/main.dart'});
      expect(output, contains('lib/b.dart:1:7'));
    });

    test('no definition found', () async {
      factory.onSpawn = (server) {
        server.requestHandler = (method, params) {
          if (method == 'initialize') return {'capabilities': {}};
          return null;
        };
      };
      final output = await run({'op': 'definition', 'path': 'lib/main.dart'});
      expect(output, 'No definitions found');
    });
  });

  group('references', () {
    test('sends includeDeclaration and renders all locations', () async {
      factory.onSpawn = (server) {
        server.requestHandler = (method, params) {
          if (method == 'initialize') return {'capabilities': {}};
          return [
            {
              'uri': fileToUri('/ws/lib/b.dart'),
              'range': {
                'start': {'line': 0, 'character': 6},
                'end': {'line': 0, 'character': 13},
              },
            },
            {
              'uri': fileToUri('/ws/lib/main.dart'),
              'range': {
                'start': {'line': 3, 'character': 15},
                'end': {'line': 3, 'character': 22},
              },
            },
          ];
        };
      };
      final output = await run({
        'op': 'references',
        'path': 'lib/b.dart',
        'line': 1,
        'character': 7,
      });
      expect(output, contains('Found 2 reference(s):'));
      expect(output, contains('lib/b.dart:1:7'));
      expect(output, contains('lib/main.dart:4:16'));

      final params = fakeServer().requests.last.params! as Map<String, dynamic>;
      expect(params['context'], {'includeDeclaration': true});
    });
  });

  group('rename', () {
    test('requires newName', () async {
      final output = await run({'op': 'rename', 'path': 'lib/b.dart'});
      expect(output, contains('newName is required'));
      expect(factory.spawned, isEmpty); // no server started for a bad call
    });

    test('applies a multi-file workspace edit atomically', () async {
      factory.onSpawn = (server) {
        server.requestHandler = (method, params) {
          if (method == 'initialize') return {'capabilities': {}};
          return {
            'documentChanges': [
              {
                'textDocument': {
                  'uri': fileToUri('/ws/lib/b.dart'),
                  'version': 1,
                },
                'edits': [
                  {
                    'range': {
                      'start': {'line': 0, 'character': 6},
                      'end': {'line': 0, 'character': 13},
                    },
                    'newText': 'Welcomer',
                  },
                ],
              },
              {
                'textDocument': {'uri': fileToUri('/ws/lib/main.dart')},
                'edits': [
                  {
                    'range': {
                      'start': {'line': 3, 'character': 18},
                      'end': {'line': 3, 'character': 25},
                    },
                    'newText': 'Welcomer',
                  },
                ],
              },
            ],
          };
        };
      };
      final output = await run({
        'op': 'rename',
        'path': 'lib/b.dart',
        'line': 1,
        'character': 7,
        'newName': 'Welcomer',
      });

      expect(
        output,
        'Applied rename to 2 file(s):\n'
        '  Applied 1 edit(s) to lib/b.dart\n'
        '  Applied 1 edit(s) to lib/main.dart',
      );
      expect(
        (await env.readTextFile('/ws/lib/b.dart')).valueOrNull,
        bDart.replaceFirst('Greeter', 'Welcomer'),
      );
      expect(
        (await env.readTextFile('/ws/lib/main.dart')).valueOrNull,
        mainDart.replaceFirst('Greeter()', 'Welcomer()'),
      );

      // The open file was synced back to the server with a bumped version.
      final bUri = fileToUri('/ws/lib/b.dart');
      expect(fakeServer().documentVersions[bUri], 2);
    });

    test('rename with no edits reports so', () async {
      factory.onSpawn = (server) {
        server.requestHandler = (method, params) {
          if (method == 'initialize') return {'capabilities': {}};
          return {'changes': <String, dynamic>{}};
        };
      };
      final output = await run({
        'op': 'rename',
        'path': 'lib/b.dart',
        'newName': 'Nope',
      });
      expect(output, 'Rename returned no edits');
    });

    test('a stale server version rejects the edit without writing', () async {
      factory.onSpawn = (server) {
        server.requestHandler = (method, params) {
          if (method == 'initialize') return {'capabilities': {}};
          return {
            'documentChanges': [
              {
                'textDocument': {
                  'uri': fileToUri('/ws/lib/b.dart'),
                  'version': 99,
                },
                'edits': [
                  {
                    'range': {
                      'start': {'line': 0, 'character': 6},
                      'end': {'line': 0, 'character': 13},
                    },
                    'newText': 'Welcomer',
                  },
                ],
              },
            ],
          };
        };
      };
      final call = run({
        'op': 'rename',
        'path': 'lib/b.dart',
        'newName': 'Welcomer',
      });
      await expectLater(
        call,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('stale LSP edit'),
          ),
        ),
      );
      expect((await env.readTextFile('/ws/lib/b.dart')).valueOrNull, bDart);
    });
  });

  group('errors', () {
    test('unknown op throws', () async {
      await expectLater(
        run({'op': 'hover', 'path': 'lib/b.dart'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unknown lsp op'),
          ),
        ),
      );
    });

    test('no server for the file is a clean result, not a crash', () async {
      await env.writeFile('/ws/notes.txt', 'hi\n');
      final output = await run({'op': 'diagnostics', 'path': 'notes.txt'});
      expect(output, contains('No LSP server configured'));
      expect(output, contains('.fah/lsp.json'));
    });

    test('a missing server binary is a clean result', () async {
      final brokenManager = LspClientManager(
        env: env,
        config: LspConfig.defaults(),
        transportFactory: (config, cwd) =>
            throw const LspServerUnavailableException(
              'cannot start LSP server `dart`: not on PATH',
            ),
        idleTimeout: Duration.zero,
      );
      addTearDown(brokenManager.shutdownAll);
      final brokenTool = lspTool(
        env,
        config: LspToolConfig(
          transportFactory: factory.call,
          manager: brokenManager,
        ),
      );
      final result = await brokenTool.execute(
        {'op': 'diagnostics', 'path': 'lib/main.dart'},
        null,
        null,
      );
      final output = result.content
          .whereType<TextContent>()
          .map((c) => c.text)
          .join();
      expect(output, contains('LSP server unavailable'));
      expect(output, contains('not on PATH'));
    });

    test('a protocol error surfaces as an LSP error', () async {
      factory.onSpawn = (server) {
        server.requestHandler = (method, params) {
          if (method == 'initialize') return {'capabilities': {}};
          return const FakeLspError('content modified', code: -32801);
        };
      };
      await expectLater(
        run({'op': 'definition', 'path': 'lib/main.dart'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('LSP error: LSP error: content modified'),
          ),
        ),
      );
    });

    test('a missing file throws like the read tool', () async {
      await expectLater(
        run({'op': 'diagnostics', 'path': 'lib/gone.dart'}),
        throwsA(isA<StateError>()),
      );
    });
  });
}
