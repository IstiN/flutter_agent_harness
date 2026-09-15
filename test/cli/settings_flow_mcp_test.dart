import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart' show YamlMap, loadYaml;
import 'package:test/test.dart';

import '../mcp/fake_mcp_server.dart';
import 'agent_cli_test_support.dart';

/// The interactive MCP servers flow (issue #396): its own file because
/// the settings-flow suite rides the 2800-line file-size gate.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction streamFunction, {
    Model model = testModel,
    ModelsConfig? modelsConfig,
    void Function()? onModelsConfigChanged,
    CustomProviderRegistry? customProviders,
    SecureKeyCache? secureKeys,
    String? Function(String name)? envVarValue,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
    http.Client? modelsHttpClient,
    Future<DapHubSnapshot?> Function()? dapHubState,
    Future<void> Function({String? url, String? name})? onDapHubConfigChanged,
    ModelRolesResolver? modelRolesResolver,
    MemoryConfig? memoryConfig,
    String? homeDir,
    TtsrConfig? ttsr,
    McpToolConfig? mcpConfig,
    RedactionPipeline? redactionPipeline,
    int? contextWindowCap,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'test-key',
        env: env,
        homeDir: homeDir,
        ttsr: ttsr,
        redactionPipeline: redactionPipeline,
        sessionRoot: '/sessions',
        modelsConfig: modelsConfig,
        onModelsConfigChanged: onModelsConfigChanged,
        customProviders: customProviders,
        secureKeys: secureKeys,
        envVarValue: envVarValue,
        modelsFetcher: modelsFetcher,
        modelsHttpClient: modelsHttpClient,
        modelRolesResolver: modelRolesResolver,
        memoryConfig: memoryConfig,
        contextWindowCap: contextWindowCap,
        mcpConfig: mcpConfig,
        dapHubState: dapHubState,
        onDapHubConfigChanged: onDapHubConfigChanged,
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  group('mcp servers flow (issue #396)', () {
    const seedConfig = '''
model: test-model
mcp:
  servers:
    fs:
      command: npx
      args: ['-y', '@modelcontextprotocol/server-fs', '/tmp']
      env:
        FOO: bar
    remote:
      url: https://example.com/mcp
      headers:
        Authorization: Bearer x
memory:
  projectPath: ./mem
''';

    Future<String> seed(String text) =>
        env.writeFile('/home/u/.fah/config.yaml', text).then((_) => text);

    // The flow loops, so its menu text repeats in the accumulated buffer —
    // sequence steps by picker renders (`type a number:` prints once per
    // render), never by re-matching earlier text.
    Future<void> render(int n) => waitForIt(
      () => 'type a number:'.allMatches(io.out.toString()).length >= n,
    );

    FakeMcpServerFactory fakeFactory() =>
        FakeMcpServerFactory()
          ..onSpawn = (server) {
            server.tools = [
              {'name': 'ping', 'description': 'pings things'},
            ];
          };

    test(
      'AC1: hub picker row and line-mode summary carry the mcp state',
      () async {
        final factory = fakeFactory();
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(
          fake.call,
          homeDir: '/home/u',
          mcpConfig: McpToolConfig(
            config: McpConfig(
              servers: {
                'fs': const McpStdioServerConfig(name: 'fs', command: 'fake'),
              },
            ),
            transportFactory: factory.call,
          ),
        );
        expect(
          cli.mcpManagerForTest,
          isNotNull,
          reason: 'boot wires a live manager',
        );

        final run = cli.run();
        io.sendLine('/settings');
        await waitForIt(() => io.out.toString().contains('mcp:'));
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(output, contains('mcp: 1 server'));
        final rows = cli.settingsHubItemsForTest();
        final mcpRow = rows.where((item) => item.key == 'mcp').toList();
        expect(mcpRow, hasLength(1));
        expect(mcpRow.single.label, 'MCP servers');
        expect(mcpRow.single.description, contains('1 server'));
        expect(
          cli.settingsPickerHandlerKeysForTest(),
          contains('mcp'),
          reason: 'a hub row without a handler is a dead menu entry',
        );
        expect(fake.calls, 0);
      },
    );

    test('AC1: summary reports the not-configured state', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();
      io.sendLine('/settings');
      await waitForIt(() => io.out.toString().contains('mcp:'));
      io.sendLine('/exit');
      await run;
      expect(io.out.toString(), contains('mcp: not configured'));
      expect(fake.calls, 0);
    });

    test(
      'AC2: edit round-trips every stdio field and keeps other sections',
      () async {
        await seed(seedConfig);
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        final flow = cli.startMcpServersFlow();
        await render(1); // main menu
        io.sendLine('1'); // fs
        await render(2); // the server submenu (edit/delete/back)
        io.sendLine('1'); // edit
        await waitForIt(
          () => io.out.toString().contains("command (empty keeps 'npx'):"),
        );
        io.sendLine('node'); // command
        io.sendLine('srv.js, --port, 9'); // args
        io.sendLine('BAZ=qux'); // env (replaces FOO=bar)
        await waitForIt(
          () => io.out.toString().contains(
            'mcp saved → /home/u/.fah/config.yaml (applies at next boot',
          ),
        );
        await render(3); // the submenu exited; the main menu re-rendered
        io.sendLine('4'); // done (1=fs, 2=remote, 3=add, 4=done)
        await flow;
        io.sendLine('/exit');
        await run;

        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, isNotNull);
        // Surgical: everything outside the mcp block is byte-identical.
        expect(written!, startsWith('model: test-model\nmcp:'));
        expect(written, endsWith('memory:\n  projectPath: ./mem\n'));
        // The real boot parser re-reads the file.
        final parsed = CliConfig.fromYaml(loadYaml(written) as YamlMap);
        final fs = parsed.mcp!.servers['fs']! as McpStdioServerConfig;
        expect(fs.command, 'node');
        expect(fs.args, ['srv.js', '--port', '9']);
        expect(fs.env, {'BAZ': 'qux'});
        // The untouched remote entry round-trips field by field.
        final remote = parsed.mcp!.servers['remote']! as McpHttpServerConfig;
        expect(remote.url, 'https://example.com/mcp');
        expect(remote.headers, {'Authorization': 'Bearer x'});
        expect(fake.calls, 0);
      },
    );

    test('AC3: with a live manager the note names the touched server', () async {
      await seed(seedConfig);
      final factory = fakeFactory();
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        homeDir: '/home/u',
        mcpConfig: McpToolConfig(
          config: McpConfig(
            servers: {
              'fs': const McpStdioServerConfig(
                name: 'fs',
                command: 'npx',
                args: ['-y', '@modelcontextprotocol/server-fs', '/tmp'],
                env: {'FOO': 'bar'},
              ),
            },
          ),
          transportFactory: factory.call,
        ),
      );
      final run = cli.run();
      final manager = cli.mcpManagerForTest!;
      manager.start();
      await waitForIt(
        () =>
            manager.states['fs']?.status == McpServerStatus.connected &&
            factory.spawned.length == 1,
      );

      final flow = cli.startMcpServersFlow();
      await render(1); // main menu
      io.sendLine('1'); // fs
      await render(2); // the server submenu (tools/reconnect/edit/delete/back)
      io.sendLine('3'); // edit
      await waitForIt(
        () => io.out.toString().contains("command (empty keeps 'npx'):"),
      );
      io.sendLine(''); // keep command
      io.sendLine('-v'); // args: [] → ['-v']
      io.sendLine(''); // keep env (none)
      await waitForIt(
        () => io.out.toString().contains(
          'mcp saved → /home/u/.fah/config.yaml (applies live — fs reconnecting)',
        ),
      );
      await waitForIt(
        () =>
            manager.states['fs']?.status == McpServerStatus.connected &&
            factory.spawned.length == 2,
      );
      await render(3); // the submenu re-rendered after the edit
      io.sendLine('5'); // back
      await render(4); // the main menu re-rendered
      io.sendLine('4'); // done (1=fs, 2=remote, 3=add, 4=done)
      await flow;
      io.sendLine('/exit');
      await run;

      final fs = manager.config.servers['fs']! as McpStdioServerConfig;
      expect(fs.args, [
        '-v',
      ], reason: 'the section diff applied to the live manager');
      expect(fake.calls, 0);
    });

    test('live submenu: view tools and reconnect just this server', () async {
      await seed(seedConfig);
      final factory = fakeFactory();
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        homeDir: '/home/u',
        mcpConfig: McpToolConfig(
          config: McpConfig(
            servers: {
              'fs': const McpStdioServerConfig(name: 'fs', command: 'fake'),
            },
          ),
          transportFactory: factory.call,
        ),
      );
      final run = cli.run();
      final manager = cli.mcpManagerForTest!;
      manager.start();
      await waitForIt(
        () => manager.states['fs']?.status == McpServerStatus.connected,
      );

      final flow = cli.startMcpServersFlow();
      await render(1); // main menu
      io.sendLine('1'); // fs
      await render(2); // the server submenu
      io.sendLine('1'); // view tools
      await waitForIt(
        () => io.out.toString().contains('mcp__fs__ping — pings things'),
      );
      await render(3); // the submenu re-rendered
      io.sendLine('2'); // reconnect
      await waitForIt(
        () => io.out.toString().contains('mcp: "fs" reconnecting'),
      );
      await waitForIt(() => factory.spawned.length == 2);
      await render(4); // the submenu re-rendered (no view-tools: 0 tools yet)
      io.sendLine('4'); // back
      await render(5); // the main menu re-rendered
      io.sendLine('4'); // done (1=fs, 2=remote, 3=add, 4=done)
      await flow;
      io.sendLine('/exit');
      await run;
      expect(fake.calls, 0);
    });

    test(
      'AC4: an invalid transport shows the parser message, writes nothing',
      () async {
        final before = await seed(seedConfig);
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        final flow = cli.startMcpServersFlow();
        await render(1); // main menu
        io.sendLine('2'); // remote
        await render(2); // the server submenu
        io.sendLine('1'); // edit
        await waitForIt(
          () => io.out.toString().contains(
            "url (empty keeps 'https://example.com/mcp'):",
          ),
        );
        io.sendLine(''); // keep url
        io.sendLine('bogus'); // transport → the parser rejects it
        await waitForIt(
          () =>
              io.out.toString().contains('mcp: not saved:') &&
              io.out.toString().contains('unknown transport "bogus"'),
        );
        await render(3); // the main menu re-rendered (edit exits the submenu)
        io.sendLine('4'); // done (1=fs, 2=remote, 3=add, 4=done)
        await flow;
        io.sendLine('/exit');
        await run;

        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, before, reason: 'nothing may be written');
        expect(fake.calls, 0);
      },
    );

    test(
      'AC4: a malformed section reports the verbatim parser error',
      () async {
        final before = await seed(
          'model: test-model\nmcp:\n  toolCallTimeoutMs: 0\n',
        );
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        final flow = cli.startMcpServersFlow();
        await waitForIt(
          () => io.out.toString().contains(
            '"mcp.toolCallTimeoutMs" must be a positive integer',
          ),
        );
        await flow;
        io.sendLine('/exit');
        await run;

        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(
          written,
          before,
          reason: 'the flow never edits from a broken section',
        );
        expect(fake.calls, 0);
      },
    );

    test('E1: an absent section gets a new block, the rest survives', () async {
      await seed('model: test-model\nmemory:\n  projectPath: ./mem\n');
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startMcpServersFlow();
      await render(1); // main menu (no servers, just add/done)
      io.sendLine('1'); // add
      await render(2); // the kind picker
      io.sendLine('1'); // stdio
      await waitForIt(() => io.out.toString().contains('server name:'));
      io.sendLine('worker');
      await waitForIt(() => io.out.toString().contains('command: '));
      io.sendLine('run-worker');
      io.sendLine('--fast'); // args
      io.sendLine('TOKEN=x'); // env — warns about the inline credential
      await waitForIt(
        () =>
            io.out.toString().contains('mcp saved → /home/u/.fah/config.yaml'),
      );
      await render(3); // the main menu re-rendered with the new server
      io.sendLine('3'); // done (1=worker, 2=add, 3=done)
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      expect(written!, startsWith('model: test-model\n'));
      // The absent block is appended; the existing sections survive.
      expect(written, contains('mcp:\n'));
      expect(written, contains('memory:\n  projectPath: ./mem\n'));
      final parsed = CliConfig.fromYaml(loadYaml(written) as YamlMap);
      final worker = parsed.mcp!.servers['worker']! as McpStdioServerConfig;
      expect(worker.command, 'run-worker');
      expect(worker.args, ['--fast']);
      expect(worker.env, {'TOKEN': 'x'});
      expect(
        io.out.toString(),
        contains('prefer the host environment'),
        reason: 'credential-looking keys point at the key flow',
      );
      expect(fake.calls, 0);
    });

    test('E2: an unreadable config refuses with a clear error', () async {
      await env.createDir('/home/u/.fah/config.yaml');
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      await cli.startMcpServersFlow();
      await waitForIt(
        () =>
            io.out.toString().contains('cannot read /home/u/.fah/config.yaml'),
      );
      io.sendLine('/exit');
      await run;
      expect(fake.calls, 0);
    });

    test('E3: every action re-reads — a concurrent edit survives', () async {
      await seed(seedConfig);
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startMcpServersFlow();
      await render(1); // main menu
      io.sendLine('1'); // fs
      await render(2); // the server submenu
      // A concurrent edit lands while the flow sits in the submenu.
      await env.writeFile(
        '/home/u/.fah/config.yaml',
        'model: test-model\n'
            'mcp:\n'
            '  servers:\n'
            '    fs:\n'
            '      command: npx\n'
            "      args: ['-y', '@modelcontextprotocol/server-fs', '/tmp']\n"
            '      env:\n'
            '        FOO: bar\n'
            '    ghost:\n'
            '      command: ghostd\n',
      );
      io.sendLine('1'); // edit
      await waitForIt(
        () => io.out.toString().contains("command (empty keeps 'npx'):"),
      );
      io.sendLine(''); // keep command
      io.sendLine('--profiled'); // args: replace
      io.sendLine(''); // keep env
      await waitForIt(
        () =>
            io.out.toString().contains('mcp saved → /home/u/.fah/config.yaml'),
      );
      await render(3); // the main menu re-rendered — now lists ghost
      await waitForIt(() => io.out.toString().contains('ghost'));
      io.sendLine('4'); // done (1=fs, 2=ghost, 3=add, 4=done)
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(
        parsed.mcp!.servers.keys,
        containsAll(['fs', 'ghost']),
        reason: 'reload-before-write',
      );
      expect((parsed.mcp!.servers['fs']! as McpStdioServerConfig).args, [
        '--profiled',
      ]);
      expect(fake.calls, 0);
    });
  });
}
