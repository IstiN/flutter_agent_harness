/// Tests for the MCP manager: background connect, per-server status,
/// namespaced tool registration, startup-failure isolation, reconnect with
/// backoff, the not-connected call path, and the prompt section.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'fake_mcp_server.dart';

McpConfig configOf(Map<String, McpServerConfig> servers) =>
    McpConfig(servers: servers);

McpStdioServerConfig stdio(String name) =>
    McpStdioServerConfig(name: name, command: 'fake');

/// Polls [predicate] until it holds (or the test times out).
Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within 5s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakeMcpServerFactory factory;
  late McpManager manager;
  var changeCount = 0;

  setUp(() {
    factory = FakeMcpServerFactory();
    changeCount = 0;
  });

  tearDown(() async {
    await manager.dispose();
  });

  McpManager startManager(
    Map<String, McpServerConfig> servers, {
    Duration reconnectBaseDelay = const Duration(milliseconds: 10),
    Duration reconnectMaxDelay = const Duration(milliseconds: 50),
  }) {
    manager = McpManager(
      config: configOf(servers),
      cwd: '/tmp',
      transportFactory: factory.call,
      reconnectBaseDelay: reconnectBaseDelay,
      reconnectMaxDelay: reconnectMaxDelay,
    )..onChanged = () => changeCount += 1;
    manager.start();
    return manager;
  }

  test('connects in the background and registers namespaced tools', () async {
    factory.onSpawn = (server) {
      server.tools = [
        {'name': 'ping', 'description': 'Ping.'},
      ];
    };
    startManager({'a': stdio('a'), 'b': stdio('b')});
    await until(
      () => manager.states.values.every(
        (s) => s.status == McpServerStatus.connected,
      ),
    );
    final names = manager.tools.map((t) => t.name).toList();
    expect(names, containsAll(['mcp__a__ping', 'mcp__b__ping']));
    expect(changeCount, greaterThan(0));
    // Both servers were initialized exactly once.
    expect(factory.spawned, hasLength(2));
    expect(factory.spawned.every((s) => s.initializeCount == 1), isTrue);
  });

  test(
    'a failed server does not block the others (startup isolation)',
    () async {
      factory.onSpawn = (server) {
        server.tools = [
          {'name': 'ok'},
        ];
      };
      // 'broken' always fails to spawn; 'good' connects normally. A factory
      // that fails by server name keeps the reconnect loop from healing the
      // failure mid-test.
      final inner = factory.call;
      manager = McpManager(
        config: configOf({'broken': stdio('broken'), 'good': stdio('good')}),
        cwd: '/tmp',
        transportFactory: (server, cwd) => server.name == 'broken'
            ? Future<McpTransport>.error(
                const McpServerUnavailableException('spawn exploded'),
              )
            : inner(server, cwd),
        reconnectBaseDelay: const Duration(milliseconds: 10),
        reconnectMaxDelay: const Duration(milliseconds: 50),
      )..onChanged = () => changeCount += 1;
      manager.start();
      await until(
        () => manager.states['good']?.status == McpServerStatus.connected,
      );
      await until(
        () => manager.states['broken']?.status == McpServerStatus.failed,
      );
      expect(manager.tools.map((t) => t.name), ['mcp__good__ok']);
      expect(manager.states['broken']!.error, contains('spawn exploded'));
    },
  );

  test('stdio without a transport factory reports a clean note', () async {
    manager = McpManager(
      config: configOf({'local': stdio('local')}),
      cwd: '/tmp',
      reconnectBaseDelay: const Duration(milliseconds: 10),
      reconnectMaxDelay: const Duration(milliseconds: 50),
    )..start();
    await until(
      () => manager.states['local']?.status == McpServerStatus.failed,
    );
    expect(
      manager.states['local']!.error,
      contains('not supported on this host'),
    );
  });

  test(
    'callTool routes through the manager and returns converted content',
    () async {
      factory.onSpawn = (server) {
        server.tools = [
          {'name': 'echo'},
        ];
        server.requestHandler = (method, params) {
          if (method == 'initialize') {
            return {'protocolVersion': mcpProtocolVersion};
          }
          if (method == 'tools/list') return {'tools': server.tools};
          if (method == 'tools/call') {
            return {
              'content': [
                {'type': 'text', 'text': 'hello back'},
              ],
            };
          }
          return null;
        };
      };
      startManager({'srv': stdio('srv')});
      await until(
        () => manager.states['srv']?.status == McpServerStatus.connected,
      );
      final tool = manager.tools.single;
      final result = await tool.execute({'q': 'hi'}, null, null);
      expect((result.content.single as TextContent).text, 'hello back');
    },
  );

  test('callTool on a down server throws an actionable error', () async {
    factory.failAlways = StateError('nope');
    startManager({'down': stdio('down')});
    await until(() => manager.states['down']?.status == McpServerStatus.failed);
    expect(
      () => manager.callTool('down', 'x', const {}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('not connected'), contains('try again shortly')),
        ),
      ),
    );
  });

  test(
    'a crashed server reconnects with backoff and re-registers tools',
    () async {
      factory.onSpawn = (server) {
        server.tools = [
          {'name': 'ping'},
        ];
      };
      startManager(
        {'flaky': stdio('flaky')},
        reconnectBaseDelay: const Duration(milliseconds: 200),
        reconnectMaxDelay: const Duration(milliseconds: 200),
      );
      await until(
        () => manager.states['flaky']?.status == McpServerStatus.connected,
      );
      expect(factory.spawned, hasLength(1));

      await factory.spawned.single.simulateCrash();
      await until(
        () => manager.states['flaky']?.status != McpServerStatus.connected,
      );
      // The tools drop while the server is down (the 200ms reconnect window
      // makes this observable)...
      await until(() => manager.tools.isEmpty);
      // ...and a fresh spawn brings them back.
      await until(
        () => manager.states['flaky']?.status == McpServerStatus.connected,
      );
      expect(factory.spawned.length, greaterThanOrEqualTo(2));
      expect(manager.tools.map((t) => t.name), ['mcp__flaky__ping']);
    },
  );

  test('promptSection renders one line per server status', () async {
    factory.onSpawn = (server) {
      server.tools = [
        {'name': 'a'},
        {'name': 'b'},
      ];
    };
    final inner = factory.call;
    manager = McpManager(
      config: configOf({'broken': stdio('broken'), 'good': stdio('good')}),
      cwd: '/tmp',
      transportFactory: (server, cwd) => server.name == 'broken'
          ? Future<McpTransport>.error(StateError('dead'))
          : inner(server, cwd),
      reconnectBaseDelay: const Duration(milliseconds: 10),
      reconnectMaxDelay: const Duration(milliseconds: 50),
    )..onChanged = () => changeCount += 1;
    manager.start();
    await until(
      () =>
          manager.states['good']?.status == McpServerStatus.connected &&
          manager.states['broken']?.status == McpServerStatus.failed,
    );
    final section = manager.promptSection();
    expect(section, contains('## MCP servers'));
    expect(section, contains('`good` (connected): 2 tool(s)'));
    expect(section, contains('`broken` (failed: Bad state: dead)'));
    expect(section, contains('mcp__good__*'));
  });

  test('duplicate sanitized tool names register first-wins', () async {
    factory.onSpawn = (server) {
      server.tools = [
        {'name': 'a b'},
        {'name': 'a_b'}, // sanitizes to the same mcp__srv__a_b
      ];
    };
    startManager({'srv': stdio('srv')});
    await until(
      () => manager.states['srv']?.status == McpServerStatus.connected,
    );
    expect(manager.tools.map((t) => t.name), ['mcp__srv__a_b']);
  });

  group('live reload (issue #396)', () {
    setUp(() {
      factory.onSpawn = (server) {
        server.tools = [
          {'name': 'ping'},
        ];
      };
    });

    test('an untouched server keeps its live connection', () async {
      startManager({'a': stdio('a'), 'b': stdio('b')});
      await until(() => factory.spawned.length == 2);
      await until(
        () => manager.states.values.every(
          (s) => s.status == McpServerStatus.connected,
        ),
      );

      await manager.applyConfig(configOf({'a': stdio('a'), 'b': stdio('b')}));
      // Nobody respawned: value-equal entries keep their connections.
      expect(factory.spawned, hasLength(2));
      expect(
        manager.states.values.every(
          (s) => s.status == McpServerStatus.connected,
        ),
        isTrue,
      );
      expect(manager.tools.map((t) => t.name).toSet(), {
        'mcp__a__ping',
        'mcp__b__ping',
      });
    });

    test('a changed server reconnects, the rest stay up', () async {
      startManager({
        'keep': stdio('keep'),
        'move': const McpStdioServerConfig(
          name: 'move',
          command: 'fake',
          args: ['-x'],
        ),
      });
      await until(() => factory.spawned.length == 2);
      await until(
        () => manager.states.values.every(
          (s) => s.status == McpServerStatus.connected,
        ),
      );

      await manager.applyConfig(
        configOf({
          'keep': stdio('keep'),
          'move': const McpStdioServerConfig(
            name: 'move',
            command: 'fake',
            args: ['-y'],
          ),
        }),
      );
      await until(() => factory.spawned.length == 3);
      await until(
        () => manager.states['move']?.status == McpServerStatus.connected,
      );
      // The untouched server keeps its original fake; the touched one
      // got a fresh connection and its new entry is the live config.
      expect(manager.states['keep']?.status, McpServerStatus.connected);
      expect((manager.config.servers['move']! as McpStdioServerConfig).args, [
        '-y',
      ]);
    });

    test('a removed server stops; an added one connects', () async {
      startManager({'a': stdio('a')});
      await until(
        () => manager.states['a']?.status == McpServerStatus.connected,
      );

      await manager.applyConfig(configOf({'b': stdio('b')}));
      await until(
        () => manager.states['b']?.status == McpServerStatus.connected,
      );
      expect(manager.states.containsKey('a'), isFalse);
      expect(manager.tools.map((t) => t.name), ['mcp__b__ping']);
      expect(manager.config.servers.keys, ['b']);

      await manager.applyConfig(configOf({}));
      expect(manager.states, isEmpty);
      expect(manager.tools, isEmpty);
      expect(manager.promptSection(), isEmpty);
    });

    test('a tool-call-timeout change restarts every server', () async {
      startManager({'a': stdio('a'), 'b': stdio('b')});
      await until(
        () => manager.states.values.every(
          (s) => s.status == McpServerStatus.connected,
        ),
      );
      expect(factory.spawned, hasLength(2));

      await manager.applyConfig(
        McpConfig(
          servers: {'a': stdio('a'), 'b': stdio('b')},
          toolCallTimeout: const Duration(seconds: 5),
        ),
      );
      await until(() => factory.spawned.length == 4);
      expect(manager.config.toolCallTimeout, const Duration(seconds: 5));
      await until(
        () => manager.states.values.every(
          (s) => s.status == McpServerStatus.connected,
        ),
      );
    });

    test('restartServer reconnects just the named server', () async {
      startManager({'a': stdio('a'), 'b': stdio('b')});
      await until(
        () => manager.states.values.every(
          (s) => s.status == McpServerStatus.connected,
        ),
      );
      expect(factory.spawned, hasLength(2));

      await manager.restartServer('b');
      await until(() => factory.spawned.length == 3);
      await until(
        () => manager.states['b']?.status == McpServerStatus.connected,
      );
      // `a` never respawned and stays connected throughout.
      expect(manager.states['a']?.status, McpServerStatus.connected);
    });

    test('server configs are value-equal field by field', () {
      const a = McpStdioServerConfig(
        name: 's',
        command: 'fake',
        args: ['-x'],
        env: {'K': 'v'},
      );
      expect(a, a);
      expect(a, isNot(const McpStdioServerConfig(name: 's', command: 'x')));
      expect(
        a,
        isNot(
          const McpStdioServerConfig(name: 's', command: 'fake', args: ['-y']),
        ),
      );
      expect(
        a,
        isNot(
          const McpStdioServerConfig(
            name: 's',
            command: 'fake',
            env: {'K': 'w'},
          ),
        ),
      );
      const h = McpHttpServerConfig(
        name: 'r',
        url: 'http://x',
        transport: McpHttpTransportKind.sse,
        headers: {'A': 'b'},
      );
      expect(
        h,
        const McpHttpServerConfig(
          name: 'r',
          url: 'http://x',
          transport: McpHttpTransportKind.sse,
          headers: {'A': 'b'},
        ),
      );
      expect(
        h,
        isNot(
          const McpHttpServerConfig(
            name: 'r',
            url: 'http://x',
            transport: McpHttpTransportKind.streamableHttp,
          ),
        ),
      );
      expect(
        h,
        isNot(
          const McpHttpServerConfig(
            name: 'r',
            url: 'http://x',
            transport: McpHttpTransportKind.sse,
            headers: {'A': 'c'},
          ),
        ),
      );
      // Cross-shape never equals, same name or not.
      expect(
        a == const McpHttpServerConfig(name: 's', url: 'http://x'),
        isFalse,
      );
    });
  });
}
