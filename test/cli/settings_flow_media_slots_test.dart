// The /settings hub's Media models flow: slot pick → how served (a
// provider/model pin, the explicit main-connection opt-in, or the #2085
// unsupported opt-out), the media eligibility lists (#2068 openai-wire
// kinds), and the live availability rebuild after each pin. Split out of
// settings_flow_test.dart for the repo's 2800-line test-scope gate.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
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
    await io.out.waitUntilContains('media slot');
    // No overrides yet: every slot shows unconfigured (never an inherited
    // main endpoint — gh-1844).
    await io.out.waitUntilContains('1) imageGeneration — not configured');
    io.sendLine('1'); // imageGeneration
    // The #2085 action step: pick a model → the provider list.
    await io.out.waitUntilContains('Pick a model');
    io.sendLine('1');
    await io.out.waitUntilContains('media imageGeneration — provider');
    await io.out.waitUntilContains('1) my-ollama');
    // Catalog order is aiin, openrouter, kimi, openai, ... — openai is #5
    // after the saved entry and aiin (issue #2068 added aiin to the media
    // list; it now precedes the shared-kind entries in catalog order).
    await io.out.waitUntilContains('5) openai');
    io.sendLine('5'); // openai
    await io.out.waitUntilContains("model id (empty keeps 'test-model')");
    io.sendLine('dall-e-3');
    await io.out.waitUntilContains(
      'slot imageGeneration → dall-e-3 @ https://api.openai.com/v1 '
      '(openai-completions)',
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
    await io.out.waitUntilContains('media slot');
    io.sendLine('4'); // videoGeneration
    // The #2085 action step: pick a model → the provider list.
    await io.out.waitUntilContains('Pick a model');
    io.sendLine('1');
    await io.out.waitUntilContains('media videoGeneration — provider');
    await io.out.waitUntilContains('1) minimax');
    io.sendLine('1'); // minimax
    await io.out.waitUntilContains("model id (empty keeps 'MiniMax-M3')");
    io.sendLine('MiniMax-H3');
    await io.out.waitUntilContains(
      'slot videoGeneration → MiniMax-H3 @ https://api.minimax.io/v1',
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

  /// Drives ONE media-slot flow to the provider pick (a fresh REPL —
  /// [FakeCliIO.lines] is single-subscription, one run per test) and
  /// asserts the openai-wire own-kind rows (aiin, zai) render.
  Future<void> expectMediaSlotListsOpenAiWireKinds(
    String slotKey,
    String title,
  ) async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final models = ModelsConfig();
    final cli = cliFor(
      fake.call,
      modelsConfig: models,
      envVarValue: (_) => null,
      modelsFetcher: (baseUrl, {required apiKey}) async => const [],
    );
    final run = cli.run();
    final flow = cli.startMediaSlotFlow();
    await io.out.waitUntilContains('media slot');
    io.sendLine(slotKey);
    // The #2085 action step: pick a model → the provider list.
    await io.out.waitUntilContains('Pick a model');
    io.sendLine('1');
    // The prompt and its option list render in one write burst — assert
    // both off the whole (fresh-io) buffer.
    await io.out.waitUntilContains(title);
    await waitForIt(
      () => RegExp(r'\d\) aiin').hasMatch(io.out.toString()),
      reason: 'aiin row in the $title list',
    );
    await waitForIt(
      () => RegExp(r'\d\) zai').hasMatch(io.out.toString()),
      reason: 'zai row in the $title list',
    );
    io.interrupt(); // cancel the provider pick
    await flow;
    io.sendLine('/exit');
    await run;
    expect(models.slots, isEmpty);
    expect(fake.calls, 0);
  }

  // Slot pick numbers: 1 imageGeneration, 2 audioTts, 3 musicGeneration,
  // 4 videoGeneration, 5 vision, 6 transcription. The incident slot is
  // imageGeneration; the AC covers the image/video/tts/asr pickers alike.
  test(
    'aiin is selectable in the imageGeneration media pick (#2068)',
    () async {
      await expectMediaSlotListsOpenAiWireKinds(
        '1',
        'media imageGeneration — provider',
      );
    },
  );

  test('aiin is selectable in the audioTts media pick (#2068)', () async {
    await expectMediaSlotListsOpenAiWireKinds('2', 'media audioTts — provider');
  });

  test(
    'aiin is selectable in the videoGeneration media pick (#2068)',
    () async {
      await expectMediaSlotListsOpenAiWireKinds(
        '4',
        'media videoGeneration — provider',
      );
    },
  );

  test('aiin is selectable in the transcription media pick (#2068)', () async {
    await expectMediaSlotListsOpenAiWireKinds(
      '6',
      'media transcription — provider',
    );
  });

  test(
    'media flow: openai-wire saved entry listed, anthropic entry not',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final models = ModelsConfig();
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'my-relay',
          apiType: 'openai',
          baseUrl: 'https://relay.example/v1',
          modelId: 'm1',
          keyName: 'MY_RELAY_KEY',
        ),
        CustomProviderEntry(
          name: 'my-claude',
          apiType: 'anthropic',
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-sonnet-4-6',
          keyName: 'MY_CLAUDE_KEY',
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
      await io.out.waitUntilContains('media slot');
      io.sendLine('1'); // imageGeneration
      // The #2085 action step: pick a model → the provider list.
      await io.out.waitUntilContains('Pick a model');
      io.sendLine('1');
      await io.out.waitUntilContains('media imageGeneration — provider');
      // The saved entry's spec api (openai-completions) keeps it eligible;
      // the anthropic-wire entry stays hidden.
      await io.out.waitUntilContains('my-relay');
      io.interrupt();
      await flow;
      io.sendLine('/exit');
      await run;

      expect(io.out.toString(), isNot(contains('my-claude')));
      expect(fake.calls, 0);
    },
  );

  test(
    'aiin media pick fetches /models and lists the seeded image ids',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final models = ModelsConfig();
      final fetchedBaseUrls = <String>[];
      // Seed the process catalog with the bundled fallback (the fetch 404s —
      // the bundled aiin entry is what the picker must show).
      final enrichment = RemoteCatalogEnrichment();
      await enrichment.preload(
        client: http_testing.MockClient(
          (_) async => http.Response('nope', 404),
        ),
      );
      setRemoteCatalogEnrichmentForTesting(enrichment);
      final cli = cliFor(
        fake.call,
        modelsConfig: models,
        envVarValue: (_) => null,
        modelsFetcher: (baseUrl, {required apiKey}) async {
          fetchedBaseUrls.add(baseUrl);
          // The endpoint's real answer is a CHAT id list — the media pick
          // must replace it with the catalog's per-slot seeding (AC5).
          return const ['aiin/aiin_free', 'aiin/aiin_flash'];
        },
      );
      final run = cli.run();

      final flow = cli.startMediaSlotFlow();
      await io.out.waitUntilContains('media slot');
      io.sendLine('1'); // imageGeneration
      // The #2085 action step: pick a model → the provider list.
      await io.out.waitUntilContains('Pick a model');
      io.sendLine('1');
      await io.out.waitUntilContains('media imageGeneration — provider');
      await waitForIt(() => RegExp(r'\d\) aiin').hasMatch(io.out.toString()));
      io.sendLine('1'); // aiin (first catalog row, no saved entries)
      await io.out.waitUntilContains(
        'fetching models from https://api.aiin.by/v1 ...',
      );
      // The seeded image ids are offered; the chat answer is not.
      await io.out.waitUntilContains('google/gemini-3.1-flash-image');
      expect(io.out.toString(), isNot(contains('aiin/aiin_free')));
      await io.out.waitUntilContains('+ enter manually');
      io.sendLine('1'); // the first seeded image id
      await io.out.waitUntilContains(
        'slot imageGeneration → google/gemini-3.1-flash-image '
        '@ https://api.aiin.by/v1',
      );
      await flow;
      io.sendLine('/exit');
      await run;

      expect(fetchedBaseUrls, ['https://api.aiin.by/v1']);
      final override = models.slots['imageGeneration'];
      expect(override?.modelId, 'google/gemini-3.1-flash-image');
      expect(override?.baseUrl, 'https://api.aiin.by/v1');
      expect(override?.providerKind, 'openai-completions');
      expect(fake.calls, 0);
    },
  );

  test(
    'aiin media pick falls back to manual entry when the fetch fails',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final models = ModelsConfig();
      final cli = cliFor(
        fake.call,
        modelsConfig: models,
        envVarValue: (_) => null,
        modelsFetcher: (baseUrl, {required apiKey}) async =>
            throw StateError('endpoint down'),
      );
      final run = cli.run();

      final flow = cli.startMediaSlotFlow();
      await io.out.waitUntilContains('media slot');
      io.sendLine('1'); // imageGeneration
      // The #2085 action step: pick a model → the provider list.
      await io.out.waitUntilContains('Pick a model');
      io.sendLine('1');
      await io.out.waitUntilContains('media imageGeneration — provider');
      await waitForIt(() => RegExp(r'\d\) aiin').hasMatch(io.out.toString()));
      io.sendLine('1'); // aiin
      // The fetch failure answers an empty list — no crash, manual entry.
      await io.out.waitUntilContains("model id (empty keeps 'test-model')");
      io.sendLine('my-image-model');
      await io.out.waitUntilContains(
        'slot imageGeneration → my-image-model @ https://api.aiin.by/v1',
      );
      await flow;
      io.sendLine('/exit');
      await run;

      expect(models.slots['imageGeneration']?.modelId, 'my-image-model');
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
    await io.out.waitUntilContains(
      '1) imageGeneration — img-v1 @ http://img.local/v1',
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
    await io.out.waitUntilContains('media slot');
    io.sendLine('1'); // imageGeneration
    // The #2085 action step: pick a model → the provider list.
    await io.out.waitUntilContains('Pick a model');
    io.sendLine('1');
    await io.out.waitUntilContains('media imageGeneration — provider');
    await io.out.waitUntilContains('type a number:');
    io.interrupt();
    await flow;
    io.sendLine('/exit');
    await run;

    expect(models.slots, isEmpty);
    expect(persisted, 0);
    expect(fake.calls, 0);
  });

  test(
    'media-slot flow: main-connection action pins the opt-in (#2085)',
    () async {
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
      await io.out.waitUntilContains('media slot');
      io.sendLine('2'); // audioTts
      await io.out.waitUntilContains('Pick a model');
      io.sendLine('2'); // Use the main connection
      await io.out.waitUntilContains('slot audioTts → main connection');
      await flow;
      io.sendLine('/exit');
      await run;

      final override = models.slots['audioTts'];
      expect(override?.useMainConnection, isTrue);
      expect(override?.modelId, isEmpty);
      expect(persisted, 1);
      expect(fake.calls, 0);
    },
  );

  test(
    'media-slot flow: unsupported action removes the capability (#2085)',
    () async {
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
      await io.out.waitUntilContains('media slot');
      io.sendLine('3'); // musicGeneration
      await io.out.waitUntilContains('Pick a model');
      io.sendLine('3'); // Mark unsupported
      await io.out.waitUntilContains(
        'slot musicGeneration → unsupported (capability removed)',
      );
      await flow;
      io.sendLine('/exit');
      await run;

      final override = models.slots['musicGeneration'];
      expect(override?.unsupported, isTrue);
      expect(override?.useMainConnection, isFalse);
      expect(override?.modelId, isEmpty);
      expect(persisted, 1);
      expect(fake.calls, 0);
    },
  );

  test('media-slot list shows the four per-slot states (#2085)', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final models = ModelsConfig()
      ..setSlotOverride(
        'imageGeneration',
        const MediaSlotModelConfig(
          providerKind: 'openai-completions',
          baseUrl: 'http://img.local/v1',
          modelId: 'img-v1',
        ),
      )
      ..setSlotOverride(
        'audioTts',
        const MediaSlotModelConfig(useMainConnection: true),
      )
      ..setSlotOverride(
        'musicGeneration',
        const MediaSlotModelConfig(unsupported: true),
      );
    final cli = cliFor(fake.call, modelsConfig: models);
    final run = cli.run();

    final flow = cli.startMediaSlotFlow();
    await io.out.waitUntilContains('1) imageGeneration — img-v1');
    await io.out.waitUntilContains('2) audioTts — main connection');
    await io.out.waitUntilContains(
      '3) musicGeneration — unsupported (capability removed)',
    );
    await io.out.waitUntilContains('4) videoGeneration — not configured');
    io.interrupt(); // cancel the slot pick
    await flow;
    io.sendLine('/exit');
    await run;

    expect(fake.calls, 0);
  });
}
