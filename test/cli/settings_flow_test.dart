import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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
        contains('fetching models from http://localhost:11434/v1/models'),
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
    io.sendLine('3'); // openai (after the saved entry and openrouter)
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
}
