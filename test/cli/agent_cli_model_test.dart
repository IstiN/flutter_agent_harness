import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
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
    ExecutionEnv? envOverride,
    bool Function(String name)? envVarIsSet,
    String? Function(String name)? envVarValue,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
    void Function(String providerKind, String apiKey)? onProviderChanged,
    SecureKeyCache? secureKeys,
    CustomProviderRegistry? customProviders,
    void Function(String name, String value)? onSecretStored,
    String? providerKind,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'test-key',
        env: envOverride ?? env,
        sessionRoot: '/sessions',
        envVarIsSet: envVarIsSet,
        envVarValue: envVarValue,
        modelsFetcher: modelsFetcher,
        onProviderChanged: onProviderChanged,
        secureKeys: secureKeys,
        customProviders: customProviders,
        onSecretStored: onSecretStored,
        providerKind: providerKind ?? 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  test('/model prints and switches the model', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/model');
    await waitForIt(() => io.out.toString().contains('model: test-model'));
    io.sendLine('/model new-model');
    await waitForIt(
      () => io.out.toString().contains('switched model to new-model'),
    );
    io.sendLine('go');
    await waitForIt(() => fake.calls == 1 && !cli.isBusy);
    io.sendLine('/exit');
    await run;

    expect(fake.models.single.id, 'new-model');
    expect(fake.contexts.single.systemPrompt, isNotNull);
  });

  test('/models lists known models for the active provider', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(
      fake.call,
      model: testCloudModel,
      providerKind: 'anthropic',
    );
    final run = cli.run();

    io.sendLine('/models');
    await waitForIt(() => io.out.toString().contains('claude-sonnet-4-5'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('models (provider/model):'));
    expect(output, contains('claude-sonnet-4-5'));
  });

  test('/models filters known models by substring', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(
      fake.call,
      model: testCloudModel,
      providerKind: 'anthropic',
    );
    final run = cli.run();

    io.sendLine('/models opus');
    await waitForIt(() => io.out.toString().contains('claude-opus-4'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('claude-opus-4'));
    expect(output, isNot(contains('claude-haiku-4')));
  });

  test('/model ? lists models and /model <id> switches', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(
      fake.call,
      model: testCloudModel,
      providerKind: 'anthropic',
    );
    final run = cli.run();

    io.sendLine('/model ?');
    await waitForIt(() => io.out.toString().contains('use /model'));
    io.sendLine('/model claude-opus-4');
    await waitForIt(
      () => io.out.toString().contains('switched model to claude-opus-4'),
    );
    io.sendLine('/exit');
    await run;

    expect(cli.agent.state.model.id, 'claude-opus-4');
  });

  group('parseModelsResponse', () {
    test('reads ids sorted and context windows from all known fields', () {
      final (ids, windows, _) = parseModelsResponse(
        '{"data": ['
        '{"id": "z-model", "context_length": 262144},'
        '{"id": "a-model", "context_window": 131072},'
        '{"id": "m-model", "max_context_length": 32768},'
        '{"id": "no-window"},'
        '{"id": "bad-window", "context_length": "lots"},'
        '{"id": ""}'
        ']}',
      );
      expect(ids, ['a-model', 'bad-window', 'm-model', 'no-window', 'z-model']);
      expect(windows, {'z-model': 262144, 'a-model': 131072, 'm-model': 32768});
    });

    test('reads max completion caps (flat and top_provider nested)', () {
      final (_, _, caps) = parseModelsResponse(
        '{"data": ['
        '{"id": "flat", "max_completion_tokens": 65536},'
        '{"id": "nested", "top_provider": {"max_completion_tokens": 32768}},'
        '{"id": "alt", "max_output_tokens": 16384},'
        '{"id": "none"},'
        '{"id": "nullish", "max_completion_tokens": null}'
        ']}',
      );
      expect(caps, {'flat': 65536, 'nested': 32768, 'alt': 16384});
    });

    test('tolerates an empty payload', () {
      final (ids, windows, caps) = parseModelsResponse('{"data": []}');
      expect(ids, isEmpty);
      expect(windows, isEmpty);
      expect(caps, isEmpty);
    });
  });

  group('/model-edit', () {
    test('bare shows the active limits; setting applies them', () async {
      final fake = FakeStreamFunction([textTurn('hi')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/model-edit');
      await waitForIt(() => io.out.toString().contains('contextWindow 100000'));
      io.sendLine('/model-edit contextWindow 131072');
      await waitForIt(
        () => io.out.toString().contains('model context window set to 131072'),
      );
      expect(cli.agent.state.model.contextWindow, 131072);
      expect(cli.agent.state.model.maxTokens, 4096);

      io.sendLine('/model-edit maxTokens 8192');
      await waitForIt(
        () => io.out.toString().contains('model max tokens set to 8192'),
      );
      expect(cli.agent.state.model.maxTokens, 8192);
      expect(cli.agent.state.model.contextWindow, 131072);

      io.sendLine('/exit');
      await run;
    });

    test('rejects bad input without touching the model', () async {
      final fake = FakeStreamFunction([textTurn('hi')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/model-edit contextWindow nope');
      await waitForIt(() => io.out.toString().contains('usage: /model-edit'));
      io.sendLine('/model-edit bananas 123');
      await waitForIt(() => io.out.toString().contains('usage: /model-edit'));
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.contextWindow, 100000);
      expect(cli.agent.state.model.maxTokens, 4096);
    });
  });

  group('two-step model picker', () {
    test('several providers show the provider list, not flat models', () async {
      // With saved custom providers the TUI model menu becomes two-step:
      // provider rows first (`@<name>` keys), the chosen provider's models
      // after. A provider row's filter match includes its model ids.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'work',
          apiType: 'openai',
          baseUrl: 'http://localhost:9000/v1',
          modelId: 'work-model',
        ),
        CustomProviderEntry(
          name: 'codemie.lab.epam.com',
          apiType: 'openai',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'codemie-model-1',
        ),
      ]);
      final cli = cliFor(
        fake.call,
        customProviders: registry,
        modelsFetcher: (baseUrl, {required apiKey}) async => const [],
      );
      final run = cli.run();
      await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

      final items = cli.buildModelMenuForTest('');
      final keys = items.map((i) => i.key).toList();
      expect(keys, containsAll(['@work', '@codemie.lab.epam.com']));
      expect(
        keys.where((k) => k.contains('|')),
        isEmpty,
        reason: 'no flat model rows on the provider step',
      );
      // Typing a model id as the filter lands on its provider only.
      final filtered = cli.buildModelMenuForTest('work-model');
      expect(filtered.map((i) => i.key), ['@work']);
      io.sendLine('/exit');
      await run;
    });

    test('a single provider goes straight to its models', () async {
      // The flat behavior is kept when there is nothing to choose between:
      // one provider → its model rows immediately.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

      final items = cli.buildModelMenuForTest('');
      expect(items, isNotEmpty);
      expect(
        items.every((i) => !i.key.startsWith('@')),
        isTrue,
        reason: 'no provider step with a single provider',
      );
      io.sendLine('/exit');
      await run;
    });

    test('selecting a provider row opens its model list', () async {
      // The `@<name>` selection routes into the provider's model list
      // (the generic `modelProvider` picker). Without a TUI controller the
      // step is a safe no-op; the picker handler itself is exercised via
      // the handler table wiring in agent_cli tests.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'work',
          apiType: 'openai',
          baseUrl: 'http://localhost:9000/v1',
          modelId: 'work-model',
        ),
      ]);
      final cli = cliFor(
        fake.call,
        customProviders: registry,
        modelsFetcher: (baseUrl, {required apiKey}) async => const [],
      );
      final run = cli.run();
      await waitForIt(() => !cli.isBusy);

      // No controller in line mode — must not throw.
      await cli.tuiSelectModelForTest('@work');
      io.sendLine('/exit');
      await run;
    });

    test(
      'minimax entry without a key falls back to the bundled catalog',
      () async {
        // Root cause of "только одна m3 захардкожена": the saved
        // MiniMax entry's `/v1/models` fetch returns [] without a
        // stored key (401), so the cache held the single-id
        // last-resort seed — the picker surfaced just that one
        // model. The bundled catalog now seeds the picker with
        // every catalog-known MiniMax model id (deduped against the
        // live cache). With one saved entry and a non-catalog
        // active provider the picker goes two-step; we assert on
        // the provider row count (it counts every deduped candidate)
        // and on the cross-provider candidates list.
        final fake = FakeStreamFunction([textTurn('ok')]);
        final enrichment = RemoteCatalogEnrichment();
        await enrichment.preload(
          client: MockClient((req) async {
            return http.Response(
              '{"providers": {"minimax": {"contextWindows": '
              '{"MiniMax-M3": 1000000, "MiniMax-M2.7": 204800, '
              '"MiniMax-M2": 204800, "MiniMax-M1": 128000}}}}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        setRemoteCatalogEnrichmentForTesting(enrichment);

        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'minimax',
            apiType: 'minimax',
            baseUrl: 'https://api.minimax.io/v1',
            modelId: 'MiniMax-M3',
          ),
        ]);
        final cli = cliFor(
          fake.call,
          customProviders: registry,
          modelsFetcher: (baseUrl, {required apiKey}) async => const [],
        );
        final run = cli.run();
        await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

        // Step 1 of the two-step picker: provider rows. The
        // `@minimax` row's description ends in `N model(s)` — that
        // N is every deduped candidate for the entry (catalog +
        // live + entry.modelId), not just the saved model's id.
        final items = cli.buildModelMenuForTest('');
        final minimaxRow = items.where((i) => i.key == '@minimax').single;
        expect(minimaxRow.description, contains('4 model(s)'));

        // The cross-provider candidates carry every catalog-known
        // MiniMax id (and nothing more) — the union logic from
        // `_registryEntryModels` only ever appends the entry's
        // modelId when it isn't already in the catalog list.
        final candidates = cli.crossProviderCandidatesForTest('');
        final minimaxIds = candidates
            .where((c) => c.$1 == 'minimax')
            .map((c) => c.$2)
            .toList();
        expect(minimaxIds, <String>[
          'MiniMax-M3',
          'MiniMax-M2.7',
          'MiniMax-M2',
          'MiniMax-M1',
        ]);

        io.sendLine('/exit');
        await run;
      },
    );
  });
}
