import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:yaml/yaml.dart' as yaml;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

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
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        modelsConfig: modelsConfig,
        onModelsConfigChanged: onModelsConfigChanged,
        customProviders: customProviders,
        secureKeys: secureKeys,
        envVarValue: envVarValue,
        modelsFetcher: modelsFetcher,
        modelsHttpClient: modelsHttpClient,
        modelRolesResolver: modelRolesResolver,
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
    await waitForIt(() => io.out.toString().contains('change via /provider'));
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
      await waitForIt(
        () => io.out.toString().contains('chat model — provider'),
      );
      io.sendLine('1'); // the saved entry (listed before the catalog)
      await waitForIt(
        () => io.out.toString().contains("model id (empty keeps 'm2')"),
      );
      io.sendLine('llama3.2');
      await waitForIt(
        () => io.out.toString().contains('switched provider to openai'),
      );
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
      await waitForIt(
        () => io.out.toString().contains('chat model — provider'),
      );
      io.sendLine('1'); // openrouter — first catalog entry
      await waitForIt(() => io.out.toString().contains('chat model — model'));
      // The active model is in the list, so it carries the (current) marker.
      await waitForIt(
        () =>
            io.out.toString().contains('2) test-model — ✗ text-only (current)'),
      );
      io.sendLine('1'); // m1
      await waitForIt(
        () => io.out.toString().contains('switched provider to openrouter'),
      );
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
      await waitForIt(
        () => io.out.toString().contains('chat model — provider'),
      );
      io.sendLine('1'); // openrouter
      await waitForIt(() => io.out.toString().contains('2) + enter manually'));
      io.sendLine('2'); // the manual-entry escape
      await waitForIt(
        () => io.out.toString().contains("model id (empty keeps 'test-model')"),
      );
      io.sendLine(''); // empty keeps the current model
      await waitForIt(
        () => io.out.toString().contains('switched provider to openrouter'),
      );
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
      await waitForIt(() => io.out.toString().contains('type a number:'));
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
      await waitForIt(
        () => io.out.toString().contains('chat model — provider'),
      );
      io.sendLine('1');
      await waitForIt(
        () => io.out.toString().contains("model id (empty keeps 'test-model')"),
      );
      io.interrupt();
      await flow;
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.provider, 'test-provider');
      expect(io.out.toString(), isNot(contains('switched provider')));
      expect(fake.calls, 0);
    },
  );

  test('media-slot flow pins the override and persists it', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final models = ModelsConfig();
    var persisted = 0;
    // A saved entry exercises the openai-compatible filter on saved entries;
    // it is listed before the catalog providers.
    final registry = CustomProviderRegistry([
      CustomProviderEntry(
        name: 'my-ollama',
        apiType: 'openai',
        baseUrl: 'http://localhost:11434/v1',
        modelId: 'm2',
        keyName: 'MY_OLLAMA_KEY',
      ),
    ]);
    final cli = cliFor(
      fake.call,
      modelsConfig: models,
      onModelsConfigChanged: () => persisted++,
      customProviders: registry,
      envVarValue: (_) => null,
      modelsFetcher: (baseUrl, {required apiKey}) async => const [],
    );
    final run = cli.run();

    final flow = cli.startMediaSlotFlow();
    await waitForIt(() => io.out.toString().contains('media slot'));
    // No overrides yet: every slot falls back to the main connection.
    await waitForIt(
      () => io.out.toString().contains('1) imageGeneration — main connection'),
    );
    io.sendLine('1'); // imageGeneration
    await waitForIt(
      () => io.out.toString().contains('media imageGeneration — provider'),
    );
    await waitForIt(() => io.out.toString().contains('1) my-ollama'));
    // Catalog order is openrouter, kimi, openai, ... — openai is #4 after
    // the saved entry.
    await waitForIt(() => io.out.toString().contains('4) openai'));
    io.sendLine('4'); // openai
    await waitForIt(
      () => io.out.toString().contains("model id (empty keeps 'test-model')"),
    );
    io.sendLine('dall-e-3');
    await waitForIt(
      () => io.out.toString().contains(
        'slot imageGeneration → dall-e-3 @ https://api.openai.com/v1 '
        '(openai-completions)',
      ),
    );
    await flow;
    io.sendLine('/exit');
    await run;

    final override = models.slots['imageGeneration'];
    expect(override?.modelId, 'dall-e-3');
    expect(override?.baseUrl, 'https://api.openai.com/v1');
    expect(override?.providerKind, 'openai-completions');
    expect(persisted, 1);
    // The media provider list hides non-openai wire kinds.
    expect(io.out.toString(), isNot(contains('chatgpt-codex')));
    expect(fake.calls, 0);
  });

  test('media-slot flow: saved entry propagates its keyName', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final models = ModelsConfig();
    final registry = CustomProviderRegistry([
      CustomProviderEntry(
        name: 'minimax',
        apiType: 'minimax',
        baseUrl: 'https://api.minimax.io/v1',
        modelId: 'MiniMax-M3',
        keyName: 'FA_KEY_API_MINIMAX_IO_MINIMAX',
      ),
    ]);
    final cli = cliFor(
      fake.call,
      modelsConfig: models,
      customProviders: registry,
      envVarValue: (_) => null,
      modelsFetcher: (baseUrl, {required apiKey}) async => const [],
    );
    final run = cli.run();

    final flow = cli.startMediaSlotFlow();
    await waitForIt(() => io.out.toString().contains('media slot'));
    io.sendLine('4'); // videoGeneration
    await waitForIt(
      () => io.out.toString().contains('media videoGeneration — provider'),
    );
    await waitForIt(() => io.out.toString().contains('1) minimax'));
    io.sendLine('1'); // minimax
    await waitForIt(
      () => io.out.toString().contains("model id (empty keeps 'MiniMax-M3')"),
    );
    io.sendLine('MiniMax-H3');
    await waitForIt(
      () => io.out.toString().contains(
        'slot videoGeneration → MiniMax-H3 @ https://api.minimax.io/v1',
      ),
    );
    await flow;
    io.sendLine('/exit');
    await run;

    final override = models.slots['videoGeneration'];
    expect(override?.modelId, 'MiniMax-H3');
    expect(override?.baseUrl, 'https://api.minimax.io/v1');
    expect(override?.apiKeyName, 'FA_KEY_API_MINIMAX_IO_MINIMAX');
    expect(fake.calls, 0);
  });

  test('media-slot flow shows an existing override in the slot list', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final models = ModelsConfig()
      ..setSlotOverride(
        'imageGeneration',
        const MediaSlotModelConfig(
          providerKind: 'openai-completions',
          baseUrl: 'http://img.local/v1',
          modelId: 'img-v1',
        ),
      );
    final cli = cliFor(fake.call, modelsConfig: models);
    final run = cli.run();

    final flow = cli.startMediaSlotFlow();
    await waitForIt(
      () => io.out.toString().contains(
        '1) imageGeneration — img-v1 @ http://img.local/v1',
      ),
    );
    io.interrupt(); // cancel the slot pick
    await flow;
    io.sendLine('/exit');
    await run;

    expect(models.slots['imageGeneration']?.modelId, 'img-v1');
    expect(fake.calls, 0);
  });

  test(
    'media-slot flow reports when the models config is unavailable',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      await cli.startMediaSlotFlow();
      io.sendLine('/exit');
      await run;

      expect(
        io.out.toString(),
        contains('models config is unavailable on this host'),
      );
      expect(fake.calls, 0);
    },
  );

  test('media-slot flow cancelled at the provider pick pins nothing', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final models = ModelsConfig();
    var persisted = 0;
    final cli = cliFor(
      fake.call,
      modelsConfig: models,
      onModelsConfigChanged: () => persisted++,
      envVarValue: (_) => null,
    );
    final run = cli.run();

    final flow = cli.startMediaSlotFlow();
    await waitForIt(() => io.out.toString().contains('media slot'));
    io.sendLine('1'); // imageGeneration
    await waitForIt(
      () => io.out.toString().contains('media imageGeneration — provider'),
    );
    await waitForIt(() => io.out.toString().contains('type a number:'));
    io.interrupt();
    await flow;
    io.sendLine('/exit');
    await run;

    expect(models.slots, isEmpty);
    expect(persisted, 0);
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
    await waitForIt(() => io.out.toString().contains('chat model — provider'));
    io.sendLine('1'); // the saved my-dial entry
    await waitForIt(
      () => io.out.toString().contains(
        'fetching models from https://dial.example.com',
      ),
    );
    await waitForIt(() => io.out.toString().contains('2) terra-2'));
    io.sendLine('2'); // terra-2
    await waitForIt(
      () => io.out.toString().contains('switched provider to dial'),
    );
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
      await waitForIt(
        () => io.out.toString().contains('2) Subagents model (subagent)'),
      );
      io.sendLine('2'); // the subagent role
      await waitForIt(() => io.out.toString().contains('1) Pick a model'));
      io.sendLine('1'); // set (not clear)
      await waitForIt(
        () => io.out.toString().contains(
          'agent Subagents model (subagent) — provider',
        ),
      );
      io.sendLine('1'); // the saved my-dial entry
      await waitForIt(() => io.out.toString().contains('1) terra-1'));
      io.sendLine('1'); // terra-1
      await waitForIt(
        () => io.out.toString().contains(
          'role subagent → terra-1 @ https://dial.example.com',
        ),
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
    await waitForIt(
      () => io.out.toString().contains(
        '1) Quick model (smol) — openrouter/m-fast',
      ),
    );
    io.sendLine('1'); // the smol role
    await waitForIt(() => io.out.toString().contains('2) Use the main model'));
    io.sendLine('2'); // clear
    await waitForIt(() => io.out.toString().contains('role smol → main model'));
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
    }) => (ok: ok, url: url, name: name, agentId: agentId);

    test('view renders the injected snapshot', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, dapHubState: () async => snapshot());
      final run = cli.run();

      final flow = cli.startDapHubFlow();
      await waitForIt(() => io.out.toString().contains('dap / hub'));
      io.sendLine('1'); // view
      await waitForIt(
        () => io.out.toString().contains('dap hub url: ws://hub.test:8787/ws'),
      );
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
      await waitForIt(() => io.out.toString().contains('dap / hub'));
      io.sendLine('1'); // view
      await waitForIt(
        () => io.out.toString().contains('dap: hub state unavailable'),
      );
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
      await waitForIt(() => io.out.toString().contains('dap / hub'));
      io.sendLine('2'); // set hub url
      await waitForIt(
        () => io.out.toString().contains(
          "hub url (empty keeps 'ws://127.0.0.1:8787/ws')",
        ),
      );
      io.sendLine('ws://hub.test:8787/ws');
      await waitForIt(
        () => io.out.toString().contains(
          'dap: saved hub url ws://hub.test:8787/ws',
        ),
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
      await waitForIt(() => io.out.toString().contains('dap / hub'));
      io.sendLine('3'); // set agent name
      await waitForIt(
        () => io.out.toString().contains(
          "agent name (empty keeps 'hostname default')",
        ),
      );
      io.sendLine('telemetry-bot');
      await waitForIt(
        () => io.out.toString().contains('dap: saved agent name telemetry-bot'),
      );
      io.sendLine('6'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      expect(persisted.single.name, 'telemetry-bot');
      expect(persisted.single.url, isNull);
      expect(fake.calls, 0);
    });

    test('opt-out appends hub: false and round-trips as yaml', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      await env.writeFile(
        '/work/.fah/packages.yaml',
        'tools:\n  keep: yes\ninspect_image: {}\n',
      );
      final cli = cliFor(fake.call);
      final run = cli.run();

      final flow = cli.startDapHubFlow();
      await waitForIt(() => io.out.toString().contains('dap / hub'));
      io.sendLine('5'); // opt out
      await waitForIt(
        () => io.out.toString().contains(
          'dap: hub plugin disabled in /work/.fah/packages.yaml',
        ),
      );
      io.sendLine('6'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      final read = await env.readTextFile('/work/.fah/packages.yaml');
      expect(read, isA<Ok<String, FileError>>());
      // Round-trip through the same mechanism the plugin loader reads.
      final doc = yaml.loadYaml((read as Ok<String, FileError>).value) as Map;
      expect(doc['hub'], false);
      expect(doc['tools'], {'keep': 'yes'});
      expect(doc['inspect_image'], {});
      expect(fake.calls, 0);
    });

    test('opt-out replaces an existing hub section in place', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      await env.writeFile(
        '/work/.fah/packages.yaml',
        'hub:\n  url: ws://old:8787/ws\n  name: previous\ntools:\n  keep: yes\n',
      );
      final cli = cliFor(fake.call);
      final run = cli.run();

      final flow = cli.startDapHubFlow();
      await waitForIt(() => io.out.toString().contains('dap / hub'));
      io.sendLine('5'); // opt out
      await waitForIt(
        () => io.out.toString().contains('dap: hub plugin disabled'),
      );
      io.sendLine('6'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      final read = await env.readTextFile('/work/.fah/packages.yaml');
      final doc = yaml.loadYaml((read as Ok<String, FileError>).value) as Map;
      expect(doc['hub'], false);
      expect(doc['tools'], {'keep': 'yes'});
      expect(fake.calls, 0);
    });
    test('test connection reports success and failure via the seam', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      var snap = snapshot();
      final cli = cliFor(fake.call, dapHubState: () async => snap);
      final run = cli.run();

      final flow = cli.startDapHubFlow();
      await waitForIt(() => io.out.toString().contains('dap / hub'));
      io.sendLine('4'); // test connection
      await waitForIt(
        () => io.out.toString().contains(
          'dap: connected to ws://hub.test:8787/ws as abcd1234abcd1234',
        ),
      );
      // The re-rendered menu went out before the flip; the NEXT pick is
      // what reads the fresh (disconnected) snapshot.
      snap = snapshot(ok: false, agentId: null);
      io.sendLine('4'); // test connection again
      await waitForIt(
        () => io.out.toString().contains(
          'dap: not connected to ws://hub.test:8787/ws',
        ),
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
      await waitForIt(
        () => io.out.toString().contains('dap: ws://hub.test:8787/ws'),
      );
      io.sendLine('/exit');
      await run;
      expect(fake.calls, 0);
    });
  });
}
