import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart' show YamlMap, loadYaml;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  // The process-wide catalog singleton some media-flow tests reseed —
  // restored after every test so the suite stays order-independent.
  late RemoteCatalogEnrichment originalEnrichment;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    originalEnrichment = remoteCatalogEnrichment;
  });

  tearDown(() {
    io.close();
    setRemoteCatalogEnrichmentForTesting(originalEnrichment);
  });

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
        dapHubState: dapHubState,
        onDapHubConfigChanged: onDapHubConfigChanged,
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  test('/settings prints the line-mode summary (bare and with args)', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/settings');
    await io.out.waitUntilContains('change via /provider');
    io.sendLine('/settings extra');
    await waitForIt(
      () => 'provider: test-provider'.allMatches(io.out.toString()).length == 2,
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('model: test-model'));
    expect(output, contains('approval: yolo'));
    expect(output, contains('mode: code'));
    // Issue #287: the summary names the engine — 'structured' when no
    // config states a choice (the 2.0 default flip).
    expect(output, contains('compaction: structured'));
    expect(
      output,
      contains('change via /provider, /model, /approval, /mode, /key, /mcp'),
    );
    expect(fake.calls, 0, reason: 'no summary line may leak into a run');
  });

  test(
    'chat-model flow: saved provider by number, then manual model entry',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'my-ollama',
          apiType: 'openai',
          baseUrl: 'http://localhost:11434/v1',
          modelId: 'm2',
          keyName: 'MY_OLLAMA_KEY',
        ),
      ]);
      final store = FakeSecureKeyStore()
        ..map['MY_OLLAMA_KEY'] = 'sk-ollama-key';
      final cache = SecureKeyCache(store);
      await cache.preload(const ['MY_OLLAMA_KEY']);
      final cli = cliFor(
        fake.call,
        customProviders: registry,
        secureKeys: cache,
        envVarValue: (_) => null,
        modelsFetcher: (baseUrl, {required apiKey}) async => const [],
      );
      final run = cli.run();

      final flow = cli.startChatModelFlow();
      await io.out.waitUntilContains('chat model — provider');
      io.sendLine('1'); // the saved entry (listed before the catalog)
      await io.out.waitUntilContains("model id (empty keeps 'm2')");
      io.sendLine('llama3.2');
      await io.out.waitUntilContains('switched provider to openai');
      await flow;
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('my-ollama — http://localhost:11434/v1 · m2'));
      expect(
        output,
        contains('fetching models from http://localhost:11434/v1'),
      );
      final model = cli.agent.state.model;
      expect(model.id, 'llama3.2');
      expect(model.baseUrl, 'http://localhost:11434/v1');
      // The flow bypasses _switchModel, so it syncs the entry itself.
      expect(registry.find('my-ollama')!.modelId, 'llama3.2');
      expect(output, isNot(contains('sk-ollama-key')));
      expect(fake.calls, 0);
    },
  );

  test(
    'chat-model flow: catalog provider, model picked from the endpoint list',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        modelsFetcher: (baseUrl, {required apiKey}) async => [
          'm1',
          'test-model',
        ],
      );
      final run = cli.run();

      final flow = cli.startChatModelFlow();
      await io.out.waitUntilContains('chat model — provider');
      io.sendLine('2'); // openrouter — AIIN now takes the first slot
      await io.out.waitUntilContains('chat model — model');
      // The active model is in the list, so it carries the (current) marker.
      await io.out.waitUntilContains('2) test-model — ✗ text-only (current)');
      io.sendLine('1'); // m1
      await io.out.waitUntilContains('switched provider to openrouter');
      await flow;
      io.sendLine('/exit');
      await run;

      final model = cli.agent.state.model;
      expect(model.id, 'm1');
      expect(model.provider, 'openrouter');
      expect(model.baseUrl, 'https://openrouter.ai/api/v1');
      expect(fake.calls, 0);
    },
  );

  test(
    'chat-model flow: "+ enter manually" and an empty id keeps the model',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        modelsFetcher: (baseUrl, {required apiKey}) async => ['other-model'],
      );
      final run = cli.run();

      final flow = cli.startChatModelFlow();
      await io.out.waitUntilContains('chat model — provider');
      io.sendLine('2'); // openrouter (AIIN takes the first slot)
      await io.out.waitUntilContains('2) + enter manually');
      io.sendLine('2'); // the manual-entry escape
      await io.out.waitUntilContains("model id (empty keeps 'test-model')");
      io.sendLine(''); // empty keeps the current model
      await io.out.waitUntilContains('switched provider to openrouter');
      await flow;
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.id, 'test-model');
      expect(cli.agent.state.model.provider, 'openrouter');
      expect(io.out.toString(), contains('model unchanged: test-model'));
      expect(fake.calls, 0);
    },
  );

  test(
    'chat-model flow cancelled at the provider pick changes nothing',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, envVarValue: (_) => null);
      final run = cli.run();

      final flow = cli.startChatModelFlow();
      await io.out.waitUntilContains('type a number:');
      io.interrupt();
      await flow;
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.provider, 'test-provider');
      expect(io.out.toString(), isNot(contains('switched provider')));
      expect(fake.calls, 0);
    },
  );

  test(
    'chat-model flow cancelled at the manual entry changes nothing',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        modelsFetcher: (baseUrl, {required apiKey}) async => const [],
      );
      final run = cli.run();

      final flow = cli.startChatModelFlow();
      await io.out.waitUntilContains('chat model — provider');
      io.sendLine('1');
      await io.out.waitUntilContains("model id (empty keeps 'test-model')");
      io.interrupt();
      await flow;
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.provider, 'test-provider');
      expect(io.out.toString(), isNot(contains('switched provider')));
      expect(fake.calls, 0);
    },
  );

  test('aiin chat pick offers the fetched /models ids (#2068)', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      modelsFetcher: (baseUrl, {required apiKey}) async => const [
        'aiin/aiin_free',
        'aiin/aiin_flash',
      ],
    );
    final run = cli.run();

    final flow = cli.startChatModelFlow();
    await io.out.waitUntilContains('chat model — provider');
    await waitForIt(() => RegExp(r'\d\) aiin').hasMatch(io.out.toString()));
    io.sendLine('1'); // aiin (first catalog row)
    await io.out.waitUntilContains(
      'fetching models from https://api.aiin.by/v1 ...',
    );
    // The fetched chat ids are offered with the manual-entry escape.
    await io.out.waitUntilContains('aiin/aiin_flash');
    await io.out.waitUntilContains('+ enter manually');
    io.interrupt();
    await flow;
    io.sendLine('/exit');
    await run;

    expect(fake.calls, 0);
  });

  /// A saved DIAL provider on the secure store + a mock `/openai/models`.
  Future<(AgentCli, CustomProviderRegistry)> dialCli(
    FakeStreamFunction fake, {
    void Function()? onModelsConfigChanged,
    ModelRolesResolver? modelRolesResolver,
  }) async {
    final registry = CustomProviderRegistry([
      CustomProviderEntry(
        name: 'my-dial',
        apiType: 'dial',
        baseUrl: 'https://dial.example.com',
        modelId: 'gpt-terra',
        keyName: 'MY_DIAL_KEY',
      ),
    ]);
    final store = FakeSecureKeyStore()..map['MY_DIAL_KEY'] = 'sk-dial-key';
    final cache = SecureKeyCache(store);
    await cache.preload(const ['MY_DIAL_KEY']);
    final cli = cliFor(
      fake.call,
      customProviders: registry,
      secureKeys: cache,
      envVarValue: (_) => null,
      onModelsConfigChanged: onModelsConfigChanged,
      modelRolesResolver: modelRolesResolver,
      modelsHttpClient: http_testing.MockClient((request) async {
        expect(
          request.url.toString(),
          'https://dial.example.com/openai/models',
        );
        expect(request.headers['Api-Key'], 'sk-dial-key');
        return http.Response(
          '{"data":[{"id":"terra-1"},{"id":"terra-2"}]}',
          200,
        );
      }),
    );
    return (cli, registry);
  }

  test('chat-model flow lists DIAL deployments for a dial provider', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final (cli, _) = await dialCli(fake);
    final run = cli.run();

    final flow = cli.startChatModelFlow();
    await io.out.waitUntilContains('chat model — provider');
    io.sendLine('1'); // the saved my-dial entry
    await io.out.waitUntilContains(
      'fetching models from https://dial.example.com',
    );
    await io.out.waitUntilContains('2) terra-2');
    io.sendLine('2'); // terra-2
    await io.out.waitUntilContains('switched provider to dial');
    await flow;
    io.sendLine('/exit');
    await run;

    final model = cli.agent.state.model;
    expect(model.id, 'terra-2');
    expect(model.provider, 'dial');
    expect(model.baseUrl, 'https://dial.example.com');
    expect(io.out.toString(), isNot(contains('sk-dial-key')));
    expect(fake.calls, 0);
  });

  test(
    'agent-models flow pins the subagent role to a listed DIAL deployment',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      var persisted = 0;
      final (cli, _) = await dialCli(
        fake,
        onModelsConfigChanged: () => persisted++,
      );
      final run = cli.run();

      final flow = cli.startAgentModelFlow();
      await io.out.waitUntilContains('2) Subagents model (subagent)');
      io.sendLine('2'); // the subagent role
      await io.out.waitUntilContains('1) Pick a model');
      io.sendLine('1'); // set (not clear)
      await io.out.waitUntilContains(
        'agent Subagents model (subagent) — provider',
      );
      io.sendLine('1'); // the saved my-dial entry
      await io.out.waitUntilContains('1) terra-1');
      io.sendLine('1'); // terra-1
      await io.out.waitUntilContains(
        'role subagent → terra-1 @ https://dial.example.com',
      );
      await flow;
      io.sendLine('/exit');
      await run;

      // The resolver was created on demand and the chain pinned + persisted.
      final resolver = cli.config.modelRolesResolver;
      expect(resolver, isNotNull);
      final chain = resolver!.config.roles['subagent'];
      expect(chain, hasLength(1));
      expect(chain!.first.provider, 'dial');
      expect(chain.first.modelId, 'terra-1');
      expect(chain.first.baseUrl, 'https://dial.example.com');
      expect(chain.first.apiKeyName, 'MY_DIAL_KEY');
      expect(persisted, 1);
      // And it resolves end-to-end (the key snapshot feeds the ring).
      expect(resolver.resolveRole('subagent')?.model.id, 'terra-1');
      // The default role stays unconfigured — legacy wiring untouched.
      expect(resolver.resolveRole('default'), isNull);
      expect(fake.calls, 0);
    },
  );

  test('agent-models flow: clear drops the role chain', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final resolver = ModelRolesResolver(
      config: ModelRolesConfig(
        roles: const {
          'smol': [ModelRef(provider: 'openrouter', modelId: 'm-fast')],
        },
      ),
      secrets: const {'OPENROUTER_API_KEY': 'sk-or'},
    );
    var persisted = 0;
    final cli = cliFor(
      fake.call,
      modelRolesResolver: resolver,
      onModelsConfigChanged: () => persisted++,
      envVarValue: (_) => null,
    );
    final run = cli.run();

    final flow = cli.startAgentModelFlow();
    await io.out.waitUntilContains('1) Quick model (smol) — openrouter/m-fast');
    io.sendLine('1'); // the smol role
    await io.out.waitUntilContains('2) Use the main model');
    io.sendLine('2'); // clear
    await io.out.waitUntilContains('role smol → main model');
    await flow;
    io.sendLine('/exit');
    await run;

    expect(resolver.config.roles, isEmpty);
    expect(persisted, 1);
    expect(fake.calls, 0);
  });

  group('dap hub flow', () {
    DapHubSnapshot snapshot({
      bool ok = true,
      String url = 'ws://hub.test:8787/ws',
      String? name = 'cli-agent',
      String? agentId = 'abcd1234abcd1234',
    }) => DapHubSnapshot(
      supported: true,
      url: url,
      channels: const [],
      name: name,
      agentId: agentId,
      connected: ok,
    );

    test('view renders the injected snapshot', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, dapHubState: () async => snapshot());
      final run = cli.run();

      final flow = cli.startDapHubFlow();
      await io.out.waitUntilContains('dap / hub');
      io.sendLine('1'); // view
      await io.out.waitUntilContains('dap hub url: ws://hub.test:8787/ws');
      io.sendLine('6'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('dap agent name: cli-agent'));
      expect(output, contains('dap connection: connected as abcd1234abcd1234'));
      expect(fake.calls, 0);
    });

    test('view without hub wiring reports the state as unavailable', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      final flow = cli.startDapHubFlow();
      await io.out.waitUntilContains('dap / hub');
      io.sendLine('1'); // view
      await io.out.waitUntilContains('dap: hub state unavailable');
      io.sendLine('6'); // done
      await flow;
      io.sendLine('/exit');
      await run;
    });

    test('set hub url persists through the hook', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      var snap = snapshot(
        ok: false,
        url: 'ws://127.0.0.1:8787/ws',
        name: null,
        agentId: null,
      );
      final persisted = <({String? url, String? name})>[];
      final cli = cliFor(
        fake.call,
        dapHubState: () async => snap,
        onDapHubConfigChanged: ({url, name}) async {
          persisted.add((url: url, name: name));
          snap = snapshot(ok: false, url: url!, name: name);
        },
      );
      final run = cli.run();

      final flow = cli.startDapHubFlow();
      await io.out.waitUntilContains('dap / hub');
      io.sendLine('2'); // set hub url
      await waitForIt(
        () => io.out.toString().contains(
          "hub url (empty keeps 'ws://127.0.0.1:8787/ws')",
        ),
      );
      io.sendLine('ws://hub.test:8787/ws');
      await io.out.waitUntilContains(
        'dap: saved hub url ws://hub.test:8787/ws',
      );
      io.sendLine('6'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      expect(persisted.single.url, 'ws://hub.test:8787/ws');
      expect(persisted.single.name, isNull);
      // The flow re-read the snapshot after persisting, so the re-rendered
      // menu shows the new url as current.
      expect(
        io.out.toString(),
        contains('2) Set hub URL — ws://hub.test:8787/ws'),
      );
      expect(fake.calls, 0);
    });

    test('set agent name persists through the hook', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final persisted = <({String? url, String? name})>[];
      final cli = cliFor(
        fake.call,
        dapHubState: () async => snapshot(name: null),
        onDapHubConfigChanged: ({url, name}) async {
          persisted.add((url: url, name: name));
        },
      );
      final run = cli.run();

      final flow = cli.startDapHubFlow();
      await io.out.waitUntilContains('dap / hub');
      io.sendLine('3'); // set agent name
      await waitForIt(
        () => io.out.toString().contains(
          "agent name (empty keeps 'hostname default')",
        ),
      );
      io.sendLine('telemetry-bot');
      await io.out.waitUntilContains('dap: saved agent name telemetry-bot');
      io.sendLine('6'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      expect(persisted.single.name, 'telemetry-bot');
      expect(persisted.single.url, isNull);
      expect(fake.calls, 0);
    });

    test(
      'set hub url notes when a higher-precedence value shadows it',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(
          fake.call,
          // The seam keeps returning the env-resolved url no matter what was
          // persisted — the saved value stays shadowed.
          dapHubState: () async => snapshot(url: 'ws://env.hub:8787/ws'),
          onDapHubConfigChanged: ({url, name}) async {},
        );
        final run = cli.run();

        final flow = cli.startDapHubFlow();
        await io.out.waitUntilContains('dap / hub');
        io.sendLine('2'); // set hub url
        await waitForIt(
          () => io.out.toString().contains(
            "hub url (empty keeps 'ws://env.hub:8787/ws')",
          ),
        );
        io.sendLine('ws://mine:8787/ws');
        await io.out.waitUntilContains('dap: saved hub url ws://mine:8787/ws');
        await io.out.waitUntilContains(
          'dap: effective stays ws://env.hub:8787/ws',
        );
        io.sendLine('6'); // done
        await flow;
        io.sendLine('/exit');
        await run;
        expect(fake.calls, 0);
      },
    );

    test(
      'set url without a persistence hook refuses before prompting',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, dapHubState: () async => snapshot());
        final run = cli.run();

        final flow = cli.startDapHubFlow();
        await io.out.waitUntilContains('dap / hub');
        io.sendLine('2'); // set hub url
        await io.out.waitUntilContains('dap: no hub config hook on this host');
        io.sendLine('6'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        // The prompt never ran — nothing was collected and discarded.
        expect(io.out.toString(), isNot(contains('hub url (empty keeps')));
        expect(fake.calls, 0);
      },
    );

    /// Builds a CLI over a REAL temp directory so the opt-out round-trip
    /// can assert through the production consumer (`loadPackagesConfig` +
    /// `resolveEnabledPlugins`), not a hand-parsed map. Empty [packagesYaml]
    /// seeds no file.
    Future<(AgentCli, String)> realEnvCli(
      FakeStreamFunction fake,
      String packagesYaml,
    ) async {
      final tmp = await Directory.systemTemp.createTemp('fah_dap_optout');
      // The cli's run() leaves the unawaited ScheduledMessageQueue startup
      // (an async createDir under the messages root) plus its re-arming
      // timer running — nothing stops them on exit — so a plain delete can
      // race a late createDir into ENOTEMPTY. Retry briefly; a swallowed
      // leftover in systemTemp must not fail CI.
      addTearDown(() async {
        for (var attempt = 1; ; attempt++) {
          try {
            await tmp.delete(recursive: true);
            return;
          } on FileSystemException catch (error) {
            if (attempt >= 3) {
              print('teardown left ${tmp.path} behind: $error');
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      });
      final realEnv = LocalExecutionEnv(cwd: tmp.path);
      if (packagesYaml.isNotEmpty) {
        await realEnv.writeFile('${tmp.path}/.fah/packages.yaml', packagesYaml);
      }
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: realEnv,
          sessionRoot: '${tmp.path}/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: fake.call,
      );
      return (cli, tmp.path);
    }

    /// Drives the flow straight to the opt-out action and back out.
    Future<void> runOptOut(AgentCli cli) async {
      final run = cli.run();
      final flow = cli.startDapHubFlow();
      await io.out.waitUntilContains('dap / hub');
      io.sendLine('5'); // opt out
      await io.out.waitUntilContains('dap: hub plugin disabled');
      io.sendLine('6'); // done
      await flow;
      io.sendLine('/exit');
      await run;
    }

    test(
      'opt-out appends hub: false; the real loader opts the plugin out',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final (cli, root) = await realEnvCli(
          fake,
          'tools:\n  keep: yes\ninspect_image: {}\n',
        );
        await runOptOut(cli);

        // The production consumer: file on disk → loadPackagesConfig →
        // resolveEnabledPlugins. Entry loading itself is pinned too (before
        // the loader fix every entry was dropped as inert).
        final loaded = await loadPackagesConfig(LocalExecutionEnv(cwd: root));
        final enabled = resolveEnabledPlugins(const [], loaded);
        expect(enabled, contains('inspect_image'));
        expect(enabled, isNot(contains('hub')));
        expect(loaded['tools'], {'keep': 'yes'});
        expect(fake.calls, 0);
      },
    );

    test('opt-out replaces an existing hub section in place', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final (cli, root) = await realEnvCli(
        fake,
        'hub:\n  url: ws://old:8787/ws\n  name: previous\ntools:\n  keep: yes\n',
      );
      await runOptOut(cli);

      final loaded = await loadPackagesConfig(LocalExecutionEnv(cwd: root));
      expect(loaded['hub'], false);
      expect(resolveEnabledPlugins(const [], loaded), isNot(contains('hub')));
      expect(loaded['tools'], {'keep': 'yes'});
      expect(fake.calls, 0);
    });

    test('opt-out creates the file when none exists yet', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final (cli, root) = await realEnvCli(fake, '');
      await runOptOut(cli);

      expect(File('$root/.fah/packages.yaml').existsSync(), isTrue);
      expect(
        (await loadPackagesConfig(LocalExecutionEnv(cwd: root)))['hub'],
        false,
      );
      expect(fake.calls, 0);
    });
    test('test connection reports success and failure via the seam', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      var snap = snapshot();
      final cli = cliFor(fake.call, dapHubState: () async => snap);
      final run = cli.run();

      final flow = cli.startDapHubFlow();
      await io.out.waitUntilContains('dap / hub');
      io.sendLine('4'); // test connection
      await io.out.waitUntilContains(
        'dap: connected to ws://hub.test:8787/ws as abcd1234abcd1234',
      );
      // The re-rendered menu went out before the flip; the NEXT pick is
      // what reads the fresh (disconnected) snapshot.
      snap = snapshot(ok: false, agentId: null);
      io.sendLine('4'); // test connection again
      await io.out.waitUntilContains(
        'dap: not connected to ws://hub.test:8787/ws',
      );
      io.sendLine('6'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      expect(fake.calls, 0);
    });

    test('/settings summary carries the dap line', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, dapHubState: () async => snapshot());
      final run = cli.run();

      io.sendLine('/settings');
      await io.out.waitUntilContains('dap: ws://hub.test:8787/ws');
      io.sendLine('/exit');
      await run;
      expect(fake.calls, 0);
    });
  });

  group('compaction engine flow (issue #288)', () {
    test(
      'session scope switches the live engine without touching files',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call);
        final run = cli.run();

        final flow = cli.startCompactionEngineFlow();
        await io.out.waitUntilContains('compaction engine');
        io.sendLine('2'); // structured
        await io.out.waitUntilContains('compaction engine — scope');
        io.sendLine('1'); // session
        await io.out.waitUntilContains(
          'compaction engine → structured (this session',
        );
        await flow;
        io.sendLine('/settings');
        await io.out.waitUntilContains('compaction: structured');
        io.sendLine('/exit');
        await run;

        expect(cli.config.liveCompactionEngine, CompactionEngine.structured);
        // No config file was created for a session-scoped switch.
        final untouched = await env.readTextFile('/work/.fah/config.yaml');
        expect(untouched.valueOrNull, isNull);
        expect(fake.calls, 0);
      },
    );

    test(
      'project scope writes the validated yaml section and goes live',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call);
        final run = cli.run();

        final flow = cli.startCompactionEngineFlow();
        await io.out.waitUntilContains('compaction engine');
        io.sendLine('2'); // structured
        await io.out.waitUntilContains('compaction engine — scope');
        io.sendLine('2'); // project
        await io.out.waitUntilContains(
          'compaction.engine = structured → /work/.fah/config.yaml',
        );
        await flow;
        io.sendLine('/exit');
        await run;

        expect(cli.config.liveCompactionEngine, CompactionEngine.structured);
        final written = (await env.readTextFile(
          '/work/.fah/config.yaml',
        )).valueOrNull;
        expect(written, isNotNull);
        // The written file parses through the REAL boot parser.
        final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
        expect(parsed.compactionEngine, CompactionEngine.structured);
        expect(fake.calls, 0);
      },
    );

    test(
      'the session-scoped engine is never persisted by the host save hook',
      () {
        // Ratchet over bin/fah.dart (a script — not importable here): the
        // whole-file config save must NEVER carry liveCompactionEngine.
        // The session scope promises "no file change", and the
        // project/global scopes write their yaml through the targeted
        // upsert already — persisting the live override would leak a
        // session pick (or a project pick!) into ~/.fah/config.yaml on
        // the next boot or change hook. The on-disk `compaction:` block
        // survives the whole-file rewrite via saveCliConfig's disk-block
        // preservation instead.
        final host = File('bin/fah.dart').readAsStringSync();
        expect(
          host,
          isNot(contains('liveCompactionEngine')),
          reason:
              'bin/fah.dart persists liveCompactionEngine — the '
              'session-scope "no file change" promise leaks through the '
              'boot/change-hook config save',
        );
      },
    );

    test('cancelled at the engine pick changes nothing', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      final flow = cli.startCompactionEngineFlow();
      await io.out.waitUntilContains('compaction engine');
      io.interrupt();
      await flow;
      io.sendLine('/exit');
      await run;

      expect(cli.config.liveCompactionEngine, isNull);
      // The scope prompt never ran.
      expect(io.out.toString(), isNot(contains('compaction engine — scope')));
      final untouched = await env.readTextFile('/work/.fah/config.yaml');
      expect(untouched.valueOrNull, isNull);
      expect(fake.calls, 0);
    });

    test('cancelled at the scope pick changes nothing', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      final flow = cli.startCompactionEngineFlow();
      await io.out.waitUntilContains('compaction engine');
      io.sendLine('1'); // classic
      await io.out.waitUntilContains('compaction engine — scope');
      io.interrupt();
      await flow;
      io.sendLine('/exit');
      await run;

      expect(cli.config.liveCompactionEngine, isNull);
      final untouched = await env.readTextFile('/work/.fah/config.yaml');
      expect(untouched.valueOrNull, isNull);
      expect(fake.calls, 0);
    });

    test('global scope writes the user config and goes live', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startCompactionEngineFlow();
      await io.out.waitUntilContains('compaction engine');
      io.sendLine('2'); // structured
      await io.out.waitUntilContains('compaction engine — scope');
      io.sendLine('3'); // global
      await io.out.waitUntilContains(
        'compaction.engine = structured → /home/u/.fah/config.yaml',
      );
      await flow;
      io.sendLine('/exit');
      await run;

      expect(cli.config.liveCompactionEngine, CompactionEngine.structured);
      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      expect(written, isNotNull);
      // The written file parses through the REAL boot parser.
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(parsed.compactionEngine, CompactionEngine.structured);
      // The project config is untouched by a global-scope pick.
      final project = await env.readTextFile('/work/.fah/config.yaml');
      expect(project.valueOrNull, isNull);
      expect(fake.calls, 0);
    });

    test('global scope without a home directory refuses to save', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call); // homeDir is null in the test config
      final run = cli.run();

      final flow = cli.startCompactionEngineFlow();
      await io.out.waitUntilContains('compaction engine');
      io.sendLine('2'); // structured
      await io.out.waitUntilContains('compaction engine — scope');
      io.sendLine('3'); // global
      await io.out.waitUntilContains(
        'compaction: no user config on this host — not saved',
      );
      await flow;
      io.sendLine('/exit');
      await run;

      // Refused before any write — nothing went live, nothing on disk.
      expect(cli.config.liveCompactionEngine, isNull);
      final untouched = await env.readTextFile('/work/.fah/config.yaml');
      expect(untouched.valueOrNull, isNull);
      expect(fake.calls, 0);
    });

    test(
      'project scope keeps the live engine when the config read fails',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call);
        final run = cli.run();
        // A directory where the project config should be — the upsert
        // must refuse to clobber it and must not go live.
        await env.createDir('/work');
        await env.createDir('/work/.fah');
        await env.createDir('/work/.fah/config.yaml');

        final flow = cli.startCompactionEngineFlow();
        await io.out.waitUntilContains('compaction engine');
        io.sendLine('2'); // structured
        await io.out.waitUntilContains('compaction engine — scope');
        io.sendLine('2'); // project
        await io.out.waitUntilContains('cannot read /work/.fah/config.yaml');
        await flow;
        io.sendLine('/exit');
        await run;

        expect(cli.config.liveCompactionEngine, isNull);
        expect(fake.calls, 0);
      },
    );
  });

  group('memory stores flow (issue #288)', () {
    test('sets the project memory path in the project config', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        memoryConfig: const MemoryConfig(projectPath: './memory'),
      );
      final run = cli.run();

      final flow = cli.startMemoryStoresFlow();
      await io.out.waitUntilContains('memory stores');
      await io.out.waitUntilContains('1) Project memory — /work/memory');
      io.sendLine('1'); // projectPath
      await waitForIt(
        () => io.out.toString().contains(
          "project memory path (empty keeps '/work/memory')",
        ),
      );
      io.sendLine('./longterm');
      await io.out.waitUntilContains(
        'memory.projectPath = ./longterm → /work/.fah/config.yaml',
      );
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/work/.fah/config.yaml',
      )).valueOrNull;
      expect(written, isNotNull);
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(parsed.memory?.projectPath, './longterm');
      expect(fake.calls, 0);
    });

    test(
      'user path without a home directory refuses before prompting',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call); // homeDir is null in the test config
        final run = cli.run();

        final flow = cli.startMemoryStoresFlow();
        await io.out.waitUntilContains('memory stores');
        io.sendLine('2'); // userPath
        await io.out.waitUntilContains(
          'memory: no user config on this host — not saved',
        );
        await flow;
        io.sendLine('/exit');
        await run;

        // The prompt never ran — nothing was collected and discarded.
        expect(io.out.toString(), isNot(contains('user memory path')));
        expect(fake.calls, 0);
      },
    );
  });

  group('ttsr rules flow (issue #392)', () {
    const seedConfig = '''
model: test-model
ttsr:
  enabled: true
  contextMode: keep
  repeatMode: after-gap
  repeatGap: 4
  maxInjectionsPerTurn: 2
  retryDelayMs: 25
  rules:
    - name: no-secrets
      pattern: 'sk-[a-zA-Z0-9]{8}'
      body: Never echo secrets.
      enabled: false
      scope: ['text', 'thinking']
    - name: no-french
      pattern: 'faux pas'
      body: Speak English only.
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

    test(
      'AC1: hub picker row and line-mode summary carry the ttsr value',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(
          fake.call,
          homeDir: '/home/u',
          ttsr: const TtsrConfig(
            rules: [
              TtsrRule(name: 'live-one', patterns: ['boom'], body: 'b'),
            ],
          ),
        );
        expect(cli.ttsr, isNotNull, reason: 'boot wires a live engine');

        final run = cli.run();
        io.sendLine('/settings');
        await io.out.waitUntilContains('ttsr:');
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(output, contains('ttsr: 1 rule · live'));
        final rows = cli.settingsHubItemsForTest();
        final ttsrRow = rows.where((item) => item.key == 'ttsr').toList();
        expect(ttsrRow, hasLength(1));
        expect(ttsrRow.single.label, 'Stream rules (TTSR)');
        expect(ttsrRow.single.description, contains('1 rule'));
        expect(
          cli.settingsPickerHandlerKeysForTest(),
          contains('ttsr'),
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
      await io.out.waitUntilContains('ttsr:');
      io.sendLine('/exit');
      await run;
      expect(io.out.toString(), contains('ttsr: not configured'));
      expect(fake.calls, 0);
    });

    test(
      'AC2: toggle round-trips every field and keeps other sections',
      () async {
        await seed(seedConfig);
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        final flow = cli.startTtsrRulesFlow();
        await render(1); // main menu
        await io.out.waitUntilContains('off · sk-[a-zA-Z0-9]{8}');
        io.sendLine('1'); // no-secrets (disabled first)
        await render(2); // the rule submenu
        io.sendLine('1'); // toggle → enable
        await io.out.waitUntilContains('ttsr saved → /home/u/.fah/config.yaml');
        await render(3); // the submenu exited; the main menu re-rendered
        io.sendLine('4'); // done (1=no-secrets, 2=no-french, 3=add, 4=done)
        await flow;
        io.sendLine('/exit');
        await run;

        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, isNotNull);
        // Surgical: everything outside the ttsr block is byte-identical.
        expect(written!, startsWith('model: test-model\nttsr:'));
        expect(written, endsWith('memory:\n  projectPath: ./mem\n'));
        // The real boot parser re-reads the file.
        final parsed = CliConfig.fromYaml(loadYaml(written) as YamlMap);
        final ttsr = parsed.ttsr!;
        // Settings round-trip untouched.
        expect(ttsr.settings.enabled, isTrue);
        expect(ttsr.settings.contextMode, TtsrContextMode.keep);
        expect(ttsr.settings.repeatMode, TtsrRepeatMode.afterGap);
        expect(ttsr.settings.repeatGap, 4);
        expect(ttsr.settings.maxInjectionsPerTurn, 2);
        expect(ttsr.settings.retryDelay, const Duration(milliseconds: 25));
        // Rules round-trip field by field.
        expect(ttsr.rules, hasLength(2));
        final noSecrets = ttsr.rules.singleWhere((r) => r.name == 'no-secrets');
        expect(noSecrets.patterns, ['sk-[a-zA-Z0-9]{8}']);
        expect(noSecrets.body, 'Never echo secrets.');
        expect(noSecrets.enabled, isTrue, reason: 'the toggle flipped it');
        expect(noSecrets.scope.allowText, isTrue);
        expect(noSecrets.scope.allowThinking, isTrue);
        expect(noSecrets.scope.allowAnyTool, isFalse);
        final noFrench = ttsr.rules.singleWhere((r) => r.name == 'no-french');
        expect(noFrench.enabled, isTrue);
        expect(noFrench.scope.allowText, isTrue);
        expect(noFrench.scope.allowAnyTool, isTrue);
        expect(fake.calls, 0);
      },
    );

    test(
      'AC2: add persists a new rule with guards through the real parser',
      () async {
        await seed('memory:\n  projectPath: ./mem\n');
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        final flow = cli.startTtsrRulesFlow();
        await render(1); // main menu (no rules yet)
        io.sendLine('1'); // add (no rules yet → first option)
        await io.out.waitUntilContains('rule name:');
        io.sendLine('no-doom');
        await io.out.waitUntilContains('pattern (regex):');
        io.sendLine('doomsday clock');
        await io.out.waitUntilContains('body:');
        io.sendLine('Stop summoning doomsday.');
        await io.out.waitUntilContains('scope');
        io.sendLine('thinking');
        await io.out.waitUntilContains('ttsr saved → /home/u/.fah/config.yaml');
        await render(2); // the main menu re-rendered with the new rule
        io.sendLine('3'); // done (1=no-doom, 2=add, 3=done)
        await flow;
        io.sendLine('/exit');
        await run;

        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, isNotNull);
        expect(written!, contains('ttsr:'));
        // The absent block appends: memory stays first, ttsr lands last.
        expect(written, startsWith('memory:\n  projectPath: ./mem\n'));
        final parsed = CliConfig.fromYaml(loadYaml(written) as YamlMap);
        final rule = parsed.ttsr!.rules.single;
        expect(rule.name, 'no-doom');
        expect(rule.patterns, ['doomsday clock']);
        expect(rule.body, 'Stop summoning doomsday.');
        expect(rule.enabled, isTrue);
        expect(rule.scope.allowThinking, isTrue);
        expect(rule.scope.allowText, isFalse);
        expect(fake.calls, 0);
      },
    );

    test('AC2: delete removes only the picked rule', () async {
      await seed(seedConfig);
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startTtsrRulesFlow();
      await render(1); // main menu
      io.sendLine('2'); // no-french
      await render(2); // the rule submenu
      io.sendLine('2'); // delete
      await io.out.waitUntilContains('ttsr saved → /home/u/.fah/config.yaml');
      await render(3); // the submenu exited; the main menu re-rendered
      io.sendLine('3'); // done (1=no-secrets, 2=add, 3=done)
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(parsed.ttsr!.rules.map((r) => r.name), ['no-secrets']);
      expect(written, endsWith('memory:\n  projectPath: ./mem\n'));
      expect(fake.calls, 0);
    });

    test('AC3: a live engine applies the same diff and says so', () async {
      await seed(seedConfig);
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        homeDir: '/home/u',
        ttsr: const TtsrConfig(
          rules: [
            TtsrRule(name: 'boot-rule', patterns: ['alpha'], body: 'b1'),
            // Matches the on-disk seed: disabled at boot, so only
            // boot-rule registers until the flow's toggle flips it.
            TtsrRule(
              name: 'no-secrets',
              patterns: ['sk-x'],
              body: 'b2',
              enabled: false,
            ),
          ],
        ),
      );
      expect(cli.ttsr, isNotNull);
      final run = cli.run();

      final flow = cli.startTtsrRulesFlow();
      await render(1); // main menu
      // The live engine booted with the section's rules: no-secrets is
      // disabled on disk, so only boot-rule registered.
      expect(cli.ttsr!.manager.rules.map((r) => r.name), ['boot-rule']);
      io.sendLine('1'); // no-secrets (disabled, first in the list)
      await render(2); // the rule submenu
      io.sendLine('1'); // toggle → enable + register live
      await io.out.waitUntilContains('rule edits apply live');
      await render(3); // the submenu exited; the main menu re-rendered
      io.sendLine('4'); // done (1=no-secrets, 2=no-french, 3=add, 4=done)
      await flow;
      io.sendLine('/exit');
      await run;

      expect(
        cli.ttsr!.manager.rules.map((r) => r.name),
        containsAll(['boot-rule', 'no-secrets']),
      );
      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(
        parsed.ttsr!.rules.singleWhere((r) => r.name == 'no-secrets').enabled,
        isTrue,
      );
      expect(fake.calls, 0);
    });

    test('AC3: without a live engine the flow names the next boot', () async {
      await seed(
        'ttsr:\n  rules:\n    - name: a\n      pattern: x\n      body: b\n',
      );
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      expect(cli.ttsr, isNull, reason: 'no ttsr config at boot');
      final run = cli.run();

      final flow = cli.startTtsrRulesFlow();
      await render(1); // main menu
      io.sendLine('1'); // rule a
      await render(2); // the rule submenu
      io.sendLine('1'); // toggle off
      await io.out.waitUntilContains('applies at next boot');
      await render(3); // the submenu exited; the main menu re-rendered
      io.sendLine('3'); // done (1=rule a, 2=add, 3=done)
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(parsed.ttsr!.rules.single.enabled, isFalse);
      expect(fake.calls, 0);
    });

    test(
      'AC4: a malformed section shows the verbatim error, writes nothing',
      () async {
        final text = await seed('model: kept\nttsr: 42\nmemory: kept-too\n');
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        await cli.startTtsrRulesFlow();
        await io.out.waitUntilContains('"ttsr" must be a map');
        io.sendLine('/exit');
        await run;

        expect(io.out.toString(), isNot(contains('Add a rule')));
        expect(
          (await env.readTextFile('/home/u/.fah/config.yaml')).valueOrNull,
          text,
          reason: 'nothing may be written',
        );
        expect(fake.calls, 0);
      },
    );

    test(
      'E1: absent section offers defaults and writes a fresh block',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        final flow = cli.startTtsrRulesFlow();
        await render(1); // main menu (no rules → add is the first option)
        io.sendLine('1'); // add
        await io.out.waitUntilContains('rule name:');
        io.sendLine('first');
        await io.out.waitUntilContains('pattern (regex):');
        io.sendLine('boom');
        await io.out.waitUntilContains('body:');
        io.sendLine('Watch out.');
        await io.out.waitUntilContains('scope (empty');
        io.sendLine(''); // default scope
        await io.out.waitUntilContains('ttsr saved → /home/u/.fah/config.yaml');
        await render(2); // the main menu re-rendered with the new rule
        io.sendLine('3'); // done (1=first, 2=add, 3=done)
        await flow;
        io.sendLine('/exit');
        await run;

        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
        expect(parsed.ttsr!.rules.single.name, 'first');
        expect(parsed.ttsr!.settings.enabled, isTrue);
        expect(fake.calls, 0);
      },
    );

    test('E2: an unwritable config file refuses with a clear error', () async {
      await env.createDir('/home/u/.fah/config.yaml');
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      await cli.startTtsrRulesFlow();
      await io.out.waitUntilContains('cannot read /home/u/.fah/config.yaml');
      io.sendLine('/exit');
      await run;
      expect(fake.calls, 0);
    });

    test('E3: every action re-reads — a concurrent edit survives', () async {
      await seed(
        'ttsr:\n  rules:\n    - name: a\n      pattern: x\n      body: b\n',
      );
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startTtsrRulesFlow();
      await render(1); // main menu
      io.sendLine('1'); // rule a
      await render(2); // the rule submenu
      // A concurrent edit lands while the flow sits in the submenu.
      await env.writeFile(
        '/home/u/.fah/config.yaml',
        'ttsr:\n  rules:\n    - name: a\n      pattern: x\n      body: b\n'
            '    - name: concurrent\n      pattern: y\n      body: c\n',
      );
      io.sendLine('1'); // toggle a off
      await io.out.waitUntilContains('ttsr saved → /home/u/.fah/config.yaml');
      await render(3); // the submenu exited; the main menu re-rendered
      await io.out.waitUntilContains('concurrent');
      io.sendLine('4'); // done (1=a, 2=concurrent, 3=add, 4=done)
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(
        parsed.ttsr!.rules.map((r) => r.name),
        contains('concurrent'),
        reason: 'reload-before-write',
      );
      expect(
        parsed.ttsr!.rules.singleWhere((r) => r.name == 'a').enabled,
        isFalse,
      );
      expect(fake.calls, 0);
    });
  });
  group('redaction flow (issue #391)', () {
    /// A pipeline wired like the host startup builds one (defaults, no
    /// secrets) so the flow's live-install paths have a real pipeline.
    RedactionPipeline pipeline() =>
        RedactionPipeline(registeredSecrets: const []);

    /// Seeds the USER config (the machine-level file the redact: section
    /// belongs in, mirroring `fa config set redact…` global scope) and
    /// returns the cli over it.
    Future<AgentCli> seededCli(
      FakeStreamFunction fake, {
      RedactionPipeline? redactionPipeline,
      String yaml = 'provider: openrouter\nmodel: m1\n',
    }) async {
      await env.writeFile('/home/u/.fah/config.yaml', yaml);
      return cliFor(
        fake.call,
        homeDir: '/home/u',
        redactionPipeline: redactionPipeline,
      );
    }

    test(
      'AC1: the hub picker and the /settings summary carry redaction',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, redactionPipeline: pipeline());
        final run = cli.run();

        io.sendLine('/settings');
        await io.out.waitUntilContains('redact: on, block');
        io.sendLine('/exit');
        await run;

        // The hub row exists with the current effective pipeline state.
        final row = cli.settingsHubItems().firstWhere(
          (item) => item.key == 'redact',
        );
        expect(row.label, 'Redaction');
        expect(row.description, contains('on, block off'));
        expect(io.out.toString(), contains('redact: on, block off'));
        expect(fake.calls, 0);
      },
    );

    test('AC1: summary reads off when the boot disabled redaction', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call); // no pipeline — enabled: false boot
      final run = cli.run();

      io.sendLine('/settings');
      await io.out.waitUntilContains('redact: off');
      io.sendLine('/exit');
      await run;

      final row = cli.settingsHubItems().firstWhere(
        (item) => item.key == 'redact',
      );
      expect(row.description, 'off');
      expect(fake.calls, 0);
    });

    test('every hub row has a dispatch target (Enter never no-ops)', () {
      final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
      final keys = cli.settingsHubItems().map((item) => item.key).toSet()
        ..remove('mcp'); // pre-existing main gap — `/mcp` has no picker yet
      expect(
        keys.difference(cli.settingsPickerHandlerKeysForTest()),
        isEmpty,
        reason: 'a hub row without a handler closes silently on Enter',
      );
    });

    test(
      'AC2: every section field round-trips through the yaml file',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = await seededCli(
          fake,
          redactionPipeline: pipeline(),
          yaml:
              '# machine policy\nprovider: openrouter\nredact:\n'
              '  enabled: true\n',
        );
        final run = cli.run();

        final flow = cli.startRedactionFlow();
        await io.out.waitUntilContains('redaction');
        // allowlist: two comma-separated regexes → a yaml block list.
        io.sendLine('5');
        await io.out.waitUntilContains('Allowlist regexes');
        io.sendLine(r'sha-[0-9a-f]{40}, \b[0-9a-f-]{36}\b');
        await io.out.waitUntilContains('redact.allowlist');
        // minEntropy + minLength scalars.
        io.sendLine('3');
        await io.out.waitUntilContains('min entropy');
        io.sendLine('3.2');
        await io.out.waitUntilContains('redact.minEntropy = 3.2');
        io.sendLine('4');
        await io.out.waitUntilContains('min token length');
        io.sendLine('40');
        await io.out.waitUntilContains('redact.minLength = 40');
        // toolDeny list.
        io.sendLine('7');
        await io.out.waitUntilContains('tool deny');
        io.sendLine('bash, read_file');
        await io.out.waitUntilContains('redact.toolDeny');
        // Layer toggle: pii (index 9 → picker row 10) off → on, then out.
        io.sendLine('8');
        await io.out.waitUntilContains('redaction layers');
        await io.out.waitUntilContains('10) pii');
        io.sendLine('10');
        await io.out.waitUntilContains('redact.layers.pii = true');
        io.sendLine('12'); // done — out of the layers submenu
        // blockMode quick toggle off → on.
        io.sendLine('2');
        await io.out.waitUntilContains('redact.blockMode = true');
        io.sendLine('10'); // done — out of the redaction menu
        await flow;
        io.sendLine('/exit');
        await run;

        // The real boot parser re-reads the file.
        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, isNotNull);
        final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
        final redact = parsed.redact!;
        expect(redact.enabled, isTrue);
        expect(redact.blockMode, isTrue);
        expect(redact.minEntropy, 3.2);
        expect(redact.minLength, 40);
        expect(redact.allowlistRegexes.map((r) => r.pattern), [
          'sha-[0-9a-f]{40}',
          r'\b[0-9a-f-]{36}\b',
        ]);
        expect(redact.toolDeny, {'bash', 'read_file'});
        expect(redact.isLayerEnabled(RedactionLayer.pii), isTrue);
        // Surgical write: the other sections survive byte-for-byte.
        expect(written, contains('# machine policy\nprovider: openrouter\n'));
        // The live pipeline reloaded the saved section from disk.
        final live = cli.config.redactionPipeline!.config;
        expect(live.blockMode, isTrue);
        expect(live.minEntropy, 3.2);
        expect(live.minLength, 40);
        expect(live.allowlistRegexes, hasLength(2));
        expect(live.toolDeny, {'bash', 'read_file'});
        expect(live.isLayerEnabled(RedactionLayer.pii), isTrue);
        expect(fake.calls, 0);
      },
    );

    test(
      'AC3: with a pipeline the write applies live; without, next boot',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = await seededCli(fake, redactionPipeline: pipeline());
        final run = cli.run();

        final flow = cli.startRedactionFlow();
        await io.out.waitUntilContains('redaction');
        io.sendLine('2'); // blockMode toggle
        await io.out.waitUntilContains('(applies live');
        io.sendLine('10'); // done
        await flow;
        io.sendLine('/exit');
        await run;
        expect(fake.calls, 0);
      },
    );

    test(
      'AC3: a pipeline-less boot states the change waits for next boot',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = await seededCli(fake); // no pipeline
        final run = cli.run();

        final flow = cli.startRedactionFlow();
        await io.out.waitUntilContains('redaction');
        io.sendLine('2'); // blockMode toggle
        await io.out.waitUntilContains('(applies at next boot)');
        io.sendLine('10'); // done
        await flow;
        io.sendLine('/exit');
        await run;
        expect(fake.calls, 0);
      },
    );

    test(
      'AC4: an invalid allowlist regex shows the parser error, no write',
      () async {
        const seed = 'provider: openrouter\nredact:\n  enabled: true\n';
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = await seededCli(
          fake,
          redactionPipeline: pipeline(),
          yaml: seed,
        );
        final run = cli.run();

        final flow = cli.startRedactionFlow();
        await io.out.waitUntilContains('redaction');
        io.sendLine('5'); // allowlist
        await io.out.waitUntilContains('Allowlist regexes');
        io.sendLine('[unclosed');
        await io.out.waitUntilContains('Unterminated character class');
        io.sendLine('10'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        expect(io.out.toString(), contains('not saved:'));
        // Byte-identical: nothing was written.
        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, seed);
        // And the live pipeline keeps its previous config.
        expect(cli.config.redactionPipeline!.config.allowlistRegexes, isEmpty);
        expect(fake.calls, 0);
      },
    );

    test('E1: absent section — the flow writes a fresh block', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u'); // no file, no pipeline
      final run = cli.run();

      final flow = cli.startRedactionFlow();
      await io.out.waitUntilContains('redaction');
      io.sendLine('2'); // blockMode toggle
      await io.out.waitUntilContains('redact.blockMode = true');
      io.sendLine('10'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(parsed.redact!.blockMode, isTrue);
      expect(fake.calls, 0);
    });

    test('E2: unreadable config — clear error, pipeline untouched', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        homeDir: '/home/u',
        redactionPipeline: pipeline(),
      );
      final run = cli.run();
      // A directory where the user config should be.
      await env.createDir('/home/u');
      await env.createDir('/home/u/.fah');
      await env.createDir('/home/u/.fah/config.yaml');

      final flow = cli.startRedactionFlow();
      await io.out.waitUntilContains('redaction');
      io.sendLine('1'); // toggle enabled
      await io.out.waitUntilContains('cannot read /home/u/.fah/config.yaml');
      io.sendLine('10'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      expect(cli.config.redactionPipeline!.config.enabled, isTrue);
      expect(fake.calls, 0);
    });

    test('E3: reload-after-write picks up a concurrent hand edit', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = await seededCli(
        fake,
        redactionPipeline: pipeline(),
        yaml: 'redact:\n  minEntropy: 4.5\n',
      );
      final run = cli.run();

      final flow = cli.startRedactionFlow();
      await io.out.waitUntilContains('redaction');
      // A concurrent editor (the agent's own config save) lands between
      // the menu render and the flow's write.
      await env.writeFile(
        '/home/u/.fah/config.yaml',
        'redact:\n  minEntropy: 2.0\n',
      );
      io.sendLine('2'); // blockMode toggle
      await io.out.waitUntilContains('redact.blockMode = true');
      io.sendLine('10'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      // The reload installed what the file now holds: BOTH the concurrent
      // edit and the flow's own write.
      final live = cli.config.redactionPipeline!.config;
      expect(live.minEntropy, 2.0);
      expect(live.blockMode, isTrue);
      expect(fake.calls, 0);
    });

    test('reset stats zeroes the pipeline counters', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final redaction = pipeline()
        ..registerSecret('supersecrettoken1')
        ..redact('leak: supersecrettoken1 done');
      expect(redaction.stats.total, greaterThan(0));
      final cli = await seededCli(fake, redactionPipeline: redaction);
      final run = cli.run();

      final flow = cli.startRedactionFlow();
      await io.out.waitUntilContains('redaction');
      io.sendLine('9'); // reset stats
      await io.out.waitUntilContains('redaction stats reset');
      io.sendLine('10'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      expect(redaction.stats.total, 0);
      expect(redaction.stats.byLayer, isEmpty);
      expect(fake.calls, 0);
    });

    test('cancelled at the menu writes nothing', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        homeDir: '/home/u',
        redactionPipeline: pipeline(),
      );
      final run = cli.run();

      final flow = cli.startRedactionFlow();
      await io.out.waitUntilContains('redaction');
      io.interrupt();
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      expect(written, isNull);
      expect(fake.calls, 0);
    });
  });

  group('context cap flow (issue #394)', () {
    /// Seeds the USER config (the machine-level file the agent: section
    /// belongs in, mirroring `fa config set agent…` global scope) and
    /// returns the cli over it.
    Future<AgentCli> seededCli(
      FakeStreamFunction fake, {
      String yaml = 'provider: openrouter\nmodel: m1\n',
      int? contextWindowCap,
    }) async {
      await env.writeFile('/home/u/.fah/config.yaml', yaml);
      return cliFor(
        fake.call,
        homeDir: '/home/u',
        contextWindowCap: contextWindowCap,
      );
    }

    test(
      'AC1: the hub picker and the /settings summary carry the cap',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, contextWindowCap: 64000);
        final run = cli.run();

        io.sendLine('/settings');
        await io.out.waitUntilContains('ctx cap:');
        io.sendLine('/exit');
        await run;

        // The hub row exists with the raw window vs the effective cap.
        final row = cli.settingsHubItems().firstWhere(
          (item) => item.key == 'context-cap',
        );
        expect(row.label, 'Context cap');
        expect(row.description, '100000 → 64000');
        expect(io.out.toString(), contains('ctx cap: 100000 → 64000'));
        expect(fake.calls, 0);
      },
    );

    test('AC1: the summary reads off when no cap is set', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call); // uncapped boot
      final run = cli.run();

      io.sendLine('/settings');
      await io.out.waitUntilContains('ctx cap: off');
      io.sendLine('/exit');
      await run;

      final row = cli.settingsHubItems().firstWhere(
        (item) => item.key == 'context-cap',
      );
      expect(row.description, 'off (window 100000)');
      expect(fake.calls, 0);
    });

    test('every hub row has a dispatch target (Enter never no-ops)', () {
      final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
      final keys = cli.settingsHubItems().map((item) => item.key).toSet()
        ..remove('mcp'); // pre-existing main gap — `/mcp` has no picker yet
      expect(
        keys.difference(cli.settingsPickerHandlerKeysForTest()),
        isEmpty,
        reason: 'a hub row without a handler closes silently on Enter',
      );
    });

    test('AC2: setting the cap round-trips through the yaml file', () async {
      const seed = '# owner knobs\nprovider: openrouter\n';
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = await seededCli(fake, yaml: seed);
      final run = cli.run();

      final flow = cli.startContextCapFlow();
      await io.out.waitUntilContains('context cap');
      io.sendLine('1'); // set
      await io.out.waitUntilContains('context cap in tokens');
      io.sendLine('32768');
      await io.out.waitUntilContains('agent.contextWindowCap = 32768');
      io.sendLine('3'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      // The real boot parser re-reads the file.
      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      expect(written, isNotNull);
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(parsed.contextWindowCap, 32768);
      // Surgical write: the other sections survive byte-for-byte.
      expect(written, contains('# owner knobs\nprovider: openrouter\n'));
      expect(fake.calls, 0);
    });

    test('AC2: clearing the cap removes the whole agent block', () async {
      const seed = 'provider: openrouter\nagent:\n  contextWindowCap: 32768\n';
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = await seededCli(fake, yaml: seed, contextWindowCap: 32768);
      final run = cli.run();

      final flow = cli.startContextCapFlow();
      await io.out.waitUntilContains('context cap');
      io.sendLine('2'); // clear
      await io.out.waitUntilContains('agent.contextWindowCap removed');
      io.sendLine('3'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      expect(written, isNotNull);
      // The bare `agent:` would fail the strict diagnostics validator —
      // the whole one-key block is gone.
      expect(written, isNot(contains('agent:')));
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(parsed.contextWindowCap, isNull);
      expect(written, contains('provider: openrouter'));
      expect(fake.calls, 0);
    });

    test(
      'AC2: clearing the cap keeps the sibling agent keys (gh-1572)',
      () async {
        // gh-1572 makes `agent.mode`/`agent.misuseBreaker`/`stuckTool`
        // first-class persisted keys — the clear must drop ONLY the cap
        // line (the whole block goes when the cap was its last member, see
        // the one-key test above).
        const seed =
            'provider: openrouter\n'
            'agent:\n'
            '  mode: pi\n'
            '  contextWindowCap: 32768\n'
            '  misuseBreaker: false\n';
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = await seededCli(fake, yaml: seed, contextWindowCap: 32768);
        final run = cli.run();

        final flow = cli.startContextCapFlow();
        await io.out.waitUntilContains('context cap');
        io.sendLine('2'); // clear
        await io.out.waitUntilContains('agent.contextWindowCap removed');
        io.sendLine('3'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, isNotNull);
        expect(written, isNot(contains('contextWindowCap')));
        expect(written, contains('  mode: pi\n'));
        expect(written, contains('  misuseBreaker: false\n'));
        expect(written, contains('provider: openrouter'));
        final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
        expect(parsed.contextWindowCap, isNull);
        expect(parsed.agentLoadMode, 'pi');
        expect(parsed.misuseBreaker, isFalse);
        expect(fake.calls, 0);
      },
    );

    test('AC3: the flow states the change waits for the next boot', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = await seededCli(fake);
      final run = cli.run();

      final flow = cli.startContextCapFlow();
      await io.out.waitUntilContains('context cap');
      io.sendLine('1'); // set
      await io.out.waitUntilContains('context cap in tokens');
      io.sendLine('16384');
      await io.out.waitUntilContains('(applies at next boot');
      io.sendLine('3'); // done
      await flow;
      io.sendLine('/exit');
      await run;
      expect(fake.calls, 0);
    });

    test(
      'AC4: below the floor shows the parser error, writes nothing',
      () async {
        const seed =
            'provider: openrouter\nagent:\n  contextWindowCap: 32768\n';
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = await seededCli(fake, yaml: seed);
        final run = cli.run();

        final flow = cli.startContextCapFlow();
        await io.out.waitUntilContains('context cap');
        io.sendLine('1'); // set
        await io.out.waitUntilContains('context cap in tokens');
        io.sendLine('16383'); // one below the compaction reserve
        await io.out.waitUntilContains('must be at least 16384');
        io.sendLine('3'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        expect(io.out.toString(), contains('not saved:'));
        // Byte-identical: nothing was written.
        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, seed);
        expect(fake.calls, 0);
      },
    );

    test('AC4: a non-integer shows the parser error, writes nothing', () async {
      const seed = 'provider: openrouter\n';
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = await seededCli(fake, yaml: seed);
      final run = cli.run();

      final flow = cli.startContextCapFlow();
      await io.out.waitUntilContains('context cap');
      io.sendLine('1'); // set
      await io.out.waitUntilContains('context cap in tokens');
      io.sendLine('big');
      await io.out.waitUntilContains('must be a positive integer (tokens)');
      io.sendLine('3'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      expect(io.out.toString(), contains('not saved:'));
      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      expect(written, seed);
      expect(fake.calls, 0);
    });

    test(
      'a cap at or above the model window warns it clamps nothing',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = await seededCli(fake); // testModel window: 100000
        final run = cli.run();

        final flow = cli.startContextCapFlow();
        await io.out.waitUntilContains('context cap');
        io.sendLine('1'); // set
        await io.out.waitUntilContains('context cap in tokens');
        io.sendLine('200000');
        await io.out.waitUntilContains('the cap clamps nothing');
        io.sendLine('3'); // done
        await flow;
        io.sendLine('/exit');
        await run;
        expect(fake.calls, 0);
      },
    );

    test('E1: absent section — the flow writes a fresh block', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u'); // no file at all
      final run = cli.run();

      final flow = cli.startContextCapFlow();
      await io.out.waitUntilContains('context cap');
      io.sendLine('1'); // set
      await io.out.waitUntilContains('context cap in tokens');
      io.sendLine('16384');
      await io.out.waitUntilContains('agent.contextWindowCap = 16384');
      io.sendLine('3'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(parsed.contextWindowCap, 16384);
      expect(fake.calls, 0);
    });

    test('E2: unreadable config — clear error, nothing written', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        homeDir: '/home/u',
        contextWindowCap: 32768,
      );
      final run = cli.run();
      // A directory where the user config should be.
      await env.createDir('/home/u');
      await env.createDir('/home/u/.fah');
      await env.createDir('/home/u/.fah/config.yaml');

      final flow = cli.startContextCapFlow();
      await io.out.waitUntilContains('context cap');
      io.sendLine('1'); // set
      await io.out.waitUntilContains('context cap in tokens');
      io.sendLine('16384');
      await io.out.waitUntilContains('cannot read /home/u/.fah/config.yaml');
      io.sendLine('2'); // clear — the same read error on the clear branch
      await waitForIt(
        () => 'cannot read'.allMatches(io.out.toString()).length == 2,
      );
      io.sendLine('3'); // done
      await flow;
      io.sendLine('/exit');
      await run;
      expect(fake.calls, 0);
    });

    test('clearing with no cap set is a no-op', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u'); // uncapped
      final run = cli.run();

      final flow = cli.startContextCapFlow();
      await io.out.waitUntilContains('context cap');
      io.sendLine('2'); // clear
      // The handler output, not the menu row's `already off` description.
      await io.out.waitUntilContains('nothing to clear');
      io.sendLine('3'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      expect(written, isNull);
      expect(fake.calls, 0);
    });

    test('cancelled at the menu writes nothing', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startContextCapFlow();
      await io.out.waitUntilContains('context cap');
      io.interrupt();
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      expect(written, isNull);
      expect(fake.calls, 0);
    });
  });
}
