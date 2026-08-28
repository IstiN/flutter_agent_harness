import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
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
    ExecutionEnv? envOverride,
    bool Function(String name)? envVarIsSet,
    String? Function(String name)? envVarValue,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
    http.Client? modelsHttpClient,
    void Function(String providerKind, String apiKey)? onProviderChanged,
    SecureKeyCache? secureKeys,
    CustomProviderRegistry? customProviders,
    void Function(String name, String value)? onSecretStored,
    String? providerKind,
    Future<OpenRouterOAuthKey> Function({
      required String code,
      required String codeVerifier,
      String? label,
    })?
    openRouterOAuthExchangeFn,
    Future<ChatGptOAuthCredentials> Function({
      required String code,
      required String redirectUri,
      required String verifier,
    })?
    chatGptOAuthExchangeFn,
    Future<CodeMieSsoCredentials?> Function(
      String codeMieUrl,
      void Function(String) onStatus,
    )?
    codeMieSsoAuthenticateFn,
    Future<String?> Function(
      String apiBase,
      String token,
      Future<String?> Function(
        String title,
        List<(String, String, String)> options,
      )
      pickOption,
      Future<String?> Function(String question, {bool secret}) askLine,
    )?
    codeMieGuidedSetupFn,
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
        modelsHttpClient: modelsHttpClient,
        onProviderChanged: onProviderChanged,
        secureKeys: secureKeys,
        customProviders: customProviders,
        onSecretStored: onSecretStored,
        providerKind: providerKind ?? 'openai-completions',
        openRouterOAuthExchangeFn: openRouterOAuthExchangeFn,
        chatGptOAuthExchangeFn: chatGptOAuthExchangeFn,
        codeMieSsoAuthenticateFn: codeMieSsoAuthenticateFn,
        codeMieGuidedSetupFn: codeMieGuidedSetupFn,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  test('/provider prints the active provider and the catalog', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/provider');
    await waitForIt(() => io.out.toString().contains('supported providers:'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('provider: test-provider (test-api)'));
    expect(output, contains('endpoint: https://example.test'));
    expect(output, contains('openrouter — https://openrouter.ai/api/v1'));
    expect(output, contains('anthropic — https://api.anthropic.com'));
    expect(output, contains('use /provider <name> [baseUrl] [token]'));
  });

  test('/provider lists saved providers and marks the active one', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final registry = CustomProviderRegistry([
      CustomProviderEntry(
        name: 'my-ollama',
        apiType: 'openai',
        baseUrl: 'http://localhost:11434/v1',
        modelId: 'm2',
      ),
      CustomProviderEntry(
        name: 'other',
        apiType: 'openai',
        baseUrl: 'http://localhost:9999/v1',
        modelId: 'm1',
      ),
    ]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      customProviders: registry,
    );
    final run = cli.run();

    io.sendLine('/provider my-ollama');
    await waitForIt(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/provider');
    await waitForIt(() => io.out.toString().contains('saved providers:'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(
      output,
      contains('  my-ollama — http://localhost:11434/v1 · m2 (current)'),
    );
    expect(output, contains('  other — http://localhost:9999/v1 · m1'));
  });

  test('/provider <name> switches provider, endpoint, and env key', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final changes = <(String, String)>[];
    final cli = cliFor(
      fake.call,
      envVarValue: (name) => name == 'ANTHROPIC_API_KEY' ? 'env-key-123' : null,
      onProviderChanged: (kind, key) => changes.add((kind, key)),
    );
    final run = cli.run();

    io.sendLine('/provider anthropic');
    await waitForIt(
      () => io.out.toString().contains('switched provider to anthropic'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    final model = cli.agent.state.model;
    expect(model.provider, 'anthropic');
    expect(model.api, 'anthropic-messages');
    expect(model.baseUrl, 'https://api.anthropic.com');
    expect(model.id, 'test-model', reason: 'the model id is kept');
    expect(cli.providerKind, 'anthropic');
    expect(output, contains('endpoint: https://api.anthropic.com'));
    expect(output, contains('key: ANTHROPIC_API_KEY'));
    expect(output, isNot(contains('env-key-123')));
    expect(output, contains('model unchanged: test-model'));
    expect(changes, [('anthropic', 'env-key-123')]);
  });

  test('/provider with a custom baseUrl runs keyless', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final changes = <(String, String)>[];
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      onProviderChanged: (kind, key) => changes.add((kind, key)),
    );
    final run = cli.run();

    io.sendLine('/provider openai http://127.0.0.1:1/v1');
    await waitForIt(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    final model = cli.agent.state.model;
    expect(model.provider, 'openai');
    expect(model.api, 'openai-completions');
    expect(model.baseUrl, 'http://127.0.0.1:1/v1');
    expect(cli.providerKind, 'openai-completions');
    expect(output, contains('key: none (keyless endpoint)'));
    expect(changes, [('openai-completions', '')]);
  });

  test('/provider accepts an explicit session token', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final changes = <(String, String)>[];
    final cli = cliFor(
      fake.call,
      onProviderChanged: (kind, key) => changes.add((kind, key)),
    );
    final run = cli.run();

    io.sendLine('/provider openai http://127.0.0.1:1/v1 tok-1234567890');
    await waitForIt(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('key: provided'));
    expect(output, isNot(contains('tok-1234567890')));
    expect(changes, [('openai-completions', 'tok-1234567890')]);
  });

  test('/provider rejects an unknown provider without state changes', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/provider bogus');
    await waitForIt(
      () => io.out.toString().contains('unknown provider: bogus'),
    );
    io.sendLine('/provider a b c d');
    await waitForIt(
      () => io.out.toString().contains('usage: /provider <name>'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(
      output,
      contains(
        'supported providers: openrouter, kimi, openai, chatgpt, codemie, dial, minimax, anthropic, google',
      ),
    );
    expect(cli.agent.state.model.provider, 'test-provider');
    expect(cli.providerKind, 'openai-completions');
  });

  test('/key lists key sources without exposing values', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore()
      ..map['GOOGLE_API_KEY'] = 'google-key-123';
    final cache = SecureKeyCache(store);
    await cache.preload(const ['GOOGLE_API_KEY']);
    final cli = cliFor(
      fake.call,
      secureKeys: cache,
      envVarIsSet: (name) => name == 'OPENROUTER_API_KEY',
    );
    final run = cli.run();

    io.sendLine('/key');
    await waitForIt(
      () => io.out.toString().contains('secure storage: fake store'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('OPENROUTER_API_KEY: env'));
    expect(output, contains('GOOGLE_API_KEY: fake store'));
    expect(output, contains('ANTHROPIC_API_KEY: not set'));
    expect(output, isNot(contains('google-key-123')));
  });

  test(
    '/key set stores, redacts, and updates the active provider key',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final stored = <(String, String)>[];
      final cli = cliFor(
        fake.call,
        secureKeys: cache,
        onSecretStored: (name, value) => stored.add((name, value)),
      );
      final run = cli.run();

      io.sendLine('/key set OPENAI_API_KEY sk-new-key-456');
      await waitForIt(
        () => io.out.toString().contains('saved OPENAI_API_KEY to fake store'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(store.map['OPENAI_API_KEY'], 'sk-new-key-456');
      expect(stored, [('OPENAI_API_KEY', 'sk-new-key-456')]);
      expect(output, isNot(contains('sk-new-key-456')));
      // openai-completions resolves OPENROUTER_API_KEY/OPENAI_API_KEY, so the
      // freshly stored key is picked up without a restart.
      expect(output, contains('active provider key updated'));
    },
  );

  test('/key set reports when secure storage is unavailable', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore(available: false);
    final cache = SecureKeyCache(store);
    await cache.probe();
    final cli = cliFor(fake.call, secureKeys: cache);
    final run = cli.run();

    io.sendLine('/key set OPENAI_API_KEY sk-new-key-456');
    await waitForIt(
      () => io.out.toString().contains('secure storage unavailable'),
    );
    io.sendLine('/exit');
    await run;

    expect(store.map, isEmpty);
  });

  test(
    '/key set reports a failing keychain write instead of crashing',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore()..failWrites = true;
      final cache = SecureKeyCache(store);
      await cache.probe();
      final cli = cliFor(fake.call, secureKeys: cache);
      final run = cli.run();

      io.sendLine('/key set OPENAI_API_KEY sk-new-key-456');
      await waitForIt(
        () => io.out.toString().contains('could not save OPENAI_API_KEY'),
      );
      io.sendLine('/exit');
      await run;

      expect(store.map, isEmpty);
    },
  );

  test(
    '/provider token falls back to session-only when the write fails',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final changes = <(String, String)>[];
      final store = FakeSecureKeyStore()..failWrites = true;
      final cache = SecureKeyCache(store);
      await cache.probe();
      final cli = cliFor(
        fake.call,
        secureKeys: cache,
        onProviderChanged: (kind, key) => changes.add((kind, key)),
      );
      final run = cli.run();

      io.sendLine('/provider openai http://127.0.0.1:1/v1 sk-token-789');
      await waitForIt(
        () => io.out.toString().contains('could not save the key'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(store.map, isEmpty);
      // Session continues keyless-to-store but with the token live.
      expect(output, contains('key: provided'));
      expect(changes, [('openai-completions', 'sk-token-789')]);
    },
  );

  test('/key delete removes the stored key', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    await cache.save('OPENAI_API_KEY', 'sk-stored-key');
    final cli = cliFor(fake.call, secureKeys: cache);
    final run = cli.run();

    io.sendLine('/key delete OPENAI_API_KEY');
    await waitForIt(() => io.out.toString().contains('removed OPENAI_API_KEY'));
    io.sendLine('/exit');
    await run;

    expect(store.map, isEmpty);
    expect(cache.read('OPENAI_API_KEY'), isNull);
  });

  test('/key validates its arguments', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    final cli = cliFor(fake.call, secureKeys: cache);
    final run = cli.run();

    // Line mode: /key set NAME (without value) prompts for the value;
    // an empty value cancels.
    io.sendLine('/key set ONLYNAME');
    await waitForIt(() => io.out.toString().contains('value'));
    io.sendLine('');
    await waitForIt(() => io.out.toString().contains('cancelled'));
    io.sendLine('/key set bad-name! value');
    await waitForIt(
      () => io.out.toString().contains('invalid key name: bad-name!'),
    );
    io.sendLine('/key frobnicate');
    await waitForIt(() => io.out.toString().contains('usage: /key [set'));
    io.sendLine('/exit');
    await run;

    expect(store.map, isEmpty);
  });

  test('/provider persists the explicit token in the secure store', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    final cli = cliFor(fake.call, secureKeys: cache);
    final run = cli.run();

    io.sendLine('/provider openai http://127.0.0.1:1/v1 sk-token-789');
    await waitForIt(() => io.out.toString().contains('saved to fake store'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    // Endpoint-scoped store name (FA_KEY_<HOST>), never the shared env name.
    expect(store.map['FA_KEY_127_0_0_1_1'], 'sk-token-789');
    expect(store.map['OPENAI_API_KEY'], isNull);
    expect(
      output,
      contains(
        'key: provided (saved to fake store; '
        'remove with /key delete FA_KEY_127_0_0_1_1)',
      ),
    );
    expect(output, isNot(contains('sk-token-789')));
  });

  test('/provider resolves the endpoint-scoped store key', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    await cache.save('FA_KEY_127_0_0_1_1', 'scoped-key');
    final changes = <(String, String)>[];
    final cli = cliFor(
      fake.call,
      secureKeys: cache,
      envVarValue: (name) =>
          name == 'FA_KEY_127_0_0_1_1' ? cache.read(name) : null,
      onProviderChanged: (kind, key) => changes.add((kind, key)),
    );
    final run = cli.run();

    io.sendLine('/provider openai http://127.0.0.1:1/v1');
    await waitForIt(() => changes.isNotEmpty);
    io.sendLine('/exit');
    await run;

    expect(changes.single.$2, 'scoped-key');
    expect(io.out.toString(), contains('key: FA_KEY_127_0_0_1_1 (fake store)'));
  });

  test('/provider still resolves a legacy env-name store key', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    await cache.save('OPENAI_API_KEY', 'legacy-key');
    final changes = <(String, String)>[];
    final cli = cliFor(
      fake.call,
      secureKeys: cache,
      envVarValue: (name) => name == 'OPENAI_API_KEY' ? cache.read(name) : null,
      onProviderChanged: (kind, key) => changes.add((kind, key)),
    );
    final run = cli.run();

    io.sendLine('/provider openai');
    await waitForIt(() => changes.isNotEmpty);
    io.sendLine('/exit');
    await run;

    expect(changes.single.$2, 'legacy-key');
    expect(io.out.toString(), contains('key: OPENAI_API_KEY (fake store)'));
  });

  test('/provider key order: env beats scoped on the default endpoint, '
      'scoped wins on custom endpoints', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    await cache.save('OPENAI_API_KEY', 'legacy-key');
    await cache.save('FA_KEY_127_0_0_1_1', 'scoped-key');
    final changes = <(String, String)>[];
    final cli = cliFor(
      fake.call,
      secureKeys: cache,
      envVarValue: (name) {
        if (name == 'OPENAI_API_KEY') return 'env-key';
        if (name == 'FA_KEY_127_0_0_1_1') return cache.read(name);
        return null;
      },
      onProviderChanged: (kind, key) => changes.add((kind, key)),
    );
    final run = cli.run();

    // Default hosted endpoint: env wins over scoped and legacy.
    io.sendLine('/provider openai');
    await waitForIt(() => changes.isNotEmpty);
    expect(changes.removeLast().$2, 'env-key');

    // Custom endpoint, env still set: the env name must NOT hijack it.
    io.sendLine('/provider openai http://127.0.0.1:1/v1');
    await waitForIt(() => changes.isNotEmpty);
    expect(changes.removeLast().$2, 'scoped-key');

    io.sendLine('/provider openai http://127.0.0.1:2/v1');
    await waitForIt(() => changes.isNotEmpty);
    io.sendLine('/exit');
    await run;

    expect(changes.removeLast().$2, '');
  });

  test('/provider custom runs the guided openai-like setup', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final changes = <(String, String)>[];
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      onProviderChanged: (kind, key) => changes.add((kind, key)),
    );
    final run = cli.run();

    io.sendLine('/provider custom');
    await waitForIt(() => io.out.toString().contains('type a number:'));
    io.sendLine('1');
    await waitForIt(() => io.out.toString().contains('base URL (empty ='));
    io.sendLine('http://127.0.0.1:1/v1');
    await waitForIt(() => io.out.toString().contains('provider name (empty ='));
    io.sendLine('');
    await waitForIt(
      () => io.out.toString().contains('API key (empty for none):'),
    );
    io.sendLine('');
    await waitForIt(
      () => io.out.toString().contains('no model list from the endpoint'),
    );
    io.sendLine('my-local-model');
    await waitForIt(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    final model = cli.agent.state.model;
    expect(model.provider, 'openai');
    expect(model.api, 'openai-completions');
    expect(model.id, 'my-local-model');
    expect(model.baseUrl, 'http://127.0.0.1:1/v1');
    expect(output, contains('model: my-local-model'));
    expect(output, contains('key: none (keyless endpoint)'));
    expect(changes, [('openai-completions', '')]);
  });

  test('/provider custom offers the endpoint model list', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      modelsFetcher: (baseUrl, {required apiKey}) async => ['m1', 'm2'],
    );
    final run = cli.run();

    io.sendLine('/provider custom');
    await waitForIt(() => io.out.toString().contains('type a number:'));
    io.sendLine('1');
    await waitForIt(() => io.out.toString().contains('base URL (empty ='));
    io.sendLine('https://proxy.example.com/v1');
    await waitForIt(() => io.out.toString().contains('provider name (empty ='));
    io.sendLine('');
    await waitForIt(
      () => io.out.toString().contains('API key (empty for none):'),
    );
    io.sendLine('');
    await waitForIt(() => io.out.toString().contains('2) m2'));
    io.sendLine('2');
    await waitForIt(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(cli.agent.state.model.id, 'm2');
    expect(output, contains('model: m2'));
  });

  test('/provider custom stores the typed key in the secure store', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    final cli = cliFor(
      fake.call,
      secureKeys: cache,
      modelsFetcher: (baseUrl, {required apiKey}) async => const [],
    );
    final run = cli.run();

    io.sendLine('/provider custom');
    await waitForIt(() => io.out.toString().contains('type a number:'));
    io.sendLine('1');
    await waitForIt(() => io.out.toString().contains('base URL (empty ='));
    io.sendLine('https://proxy.example.com/v1');
    await waitForIt(() => io.out.toString().contains('provider name (empty ='));
    io.sendLine('work');
    await waitForIt(
      () => io.out.toString().contains('API key (empty for none):'),
    );
    io.sendLine('sk-flow-key-1');
    await waitForIt(
      () => io.out.toString().contains('no model list from the endpoint'),
    );
    io.sendLine('proxy-model');
    await waitForIt(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    // Name-scoped slot: the key binds to this entry, not just the host.
    expect(store.map['FA_KEY_PROXY_EXAMPLE_COM_WORK'], 'sk-flow-key-1');
    expect(output, contains('key: provided (saved to fake store'));
    expect(output, isNot(contains('sk-flow-key-1')));
  });

  test('two accounts on one endpoint keep separate keys', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    final cli = cliFor(
      fake.call,
      secureKeys: cache,
      modelsFetcher: (baseUrl, {required apiKey}) async => const [],
      customProviders: CustomProviderRegistry(const []),
    );
    final run = cli.run();

    Future<void> addAccount(String name, String key) async {
      // Match only output produced by THIS wizard run — identical prompts
      // from the previous account would satisfy the waits prematurely and
      // desync the scripted answers.
      final marker = io.out.toString().length;
      String fresh() => io.out.toString().substring(marker);
      io.sendLine('/provider custom');
      await waitForIt(() => fresh().contains('type a number:'));
      io.sendLine('1');
      await waitForIt(() => fresh().contains('base URL (empty ='));
      io.sendLine('https://proxy.example.com/v1');
      await waitForIt(() => fresh().contains('provider name (empty ='));
      io.sendLine(name);
      await waitForIt(() => fresh().contains('API key (empty for none):'));
      io.sendLine(key);
      await waitForIt(
        () => fresh().contains('no model list from the endpoint'),
      );
      io.sendLine('proxy-model');
      await waitForIt(() => fresh().contains('saved provider $name'));
    }

    await addAccount('ira1', 'sk-one');
    await addAccount('ira2', 'sk-two');
    io.sendLine('/exit');
    await run;

    // Distinct name-scoped slots — the second account did not overwrite the
    // first.
    expect(store.map['FA_KEY_PROXY_EXAMPLE_COM_IRA1'], 'sk-one');
    expect(store.map['FA_KEY_PROXY_EXAMPLE_COM_IRA2'], 'sk-two');
    final entries = cli.config.customProviders?.entries ?? const [];
    expect(
      entries.map((e) => e.keyName).toSet().length,
      entries.length,
      reason: 'every entry owns a distinct key slot',
    );
  });

  test('/provider custom supports anthropic-like endpoints', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, envVarValue: (_) => null);
    final run = cli.run();

    io.sendLine('/provider custom');
    await waitForIt(() => io.out.toString().contains('type a number:'));
    io.sendLine('2');
    await waitForIt(() => io.out.toString().contains('base URL (empty ='));
    io.sendLine('https://anthropic-proxy.example.com');
    await waitForIt(() => io.out.toString().contains('provider name (empty ='));
    io.sendLine('');
    await waitForIt(
      () => io.out.toString().contains('API key (empty for none):'),
    );
    io.sendLine('');
    await waitForIt(() => io.out.toString().contains('model id (empty keeps'));
    io.sendLine('claude-proxy-model');
    await waitForIt(
      () => io.out.toString().contains('switched provider to anthropic'),
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, isNot(contains('fetching models from')));
    final model = cli.agent.state.model;
    expect(model.provider, 'anthropic');
    expect(model.api, 'anthropic-messages');
    expect(model.id, 'claude-proxy-model');
    expect(cli.providerKind, 'anthropic');
  });

  test('/provider custom validates the api type and base URL', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, envVarValue: (_) => null);
    final run = cli.run();

    io.sendLine('/provider custom extra');
    await waitForIt(
      () => io.out.toString().contains('usage: /provider custom'),
    );
    io.sendLine('/provider custom');
    await waitForIt(() => io.out.toString().contains('type a number:'));
    io.sendLine('x');
    await waitForIt(() => io.out.toString().contains('invalid selection: x'));
    io.sendLine('1');
    await waitForIt(() => io.out.toString().contains('base URL (empty ='));
    io.sendLine('localhost:8080');
    await waitForIt(() => io.out.toString().contains('invalid base URL'));
    io.sendLine('/exit');
    await run;

    expect(cli.agent.state.model.provider, 'test-provider');
    expect(cli.providerKind, 'openai-completions');
  });

  test('/provider custom cancels on interrupt without state changes', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, envVarValue: (_) => null);
    final run = cli.run();

    io.sendLine('/provider custom');
    await waitForIt(() => io.out.toString().contains('type a number:'));
    io.interrupt();
    await waitForIt(
      () => io.out.toString().contains('custom provider setup cancelled'),
    );
    io.sendLine('/exit');
    await run;

    expect(cli.agent.state.model.provider, 'test-provider');
    expect(cli.providerKind, 'openai-completions');
  });

  test(
    '/provider custom consumes piped answers without leaking into runs',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, envVarValue: (_) => null);
      final run = cli.run();

      // All answers arrive before the flow asks for them (piped stdin):
      // type, url, name (empty = default), key (empty = none), model.
      io
        ..sendLine('/provider custom')
        ..sendLine('1')
        ..sendLine('http://127.0.0.1:1/v1')
        ..sendLine('')
        ..sendLine('')
        ..sendLine('my-local-model');
      await waitForIt(
        () => io.out.toString().contains('switched provider to openai'),
      );
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.id, 'my-local-model');
      expect(fake.calls, 0, reason: 'no answer may leak into a run');
    },
  );

  test(
    '/provider custom applies the spec default URL on an empty answer',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        modelsFetcher: (baseUrl, {required apiKey}) async => const [],
      );
      final run = cli.run();

      io.sendLine('/provider custom');
      await waitForIt(() => io.out.toString().contains('type a number:'));
      io.sendLine('1');
      await waitForIt(
        () => io.out.toString().contains('base URL (empty = https://'),
      );
      io.sendLine('');
      await waitForIt(
        () => io.out.toString().contains('provider name (empty ='),
      );
      io.sendLine('');
      await waitForIt(
        () => io.out.toString().contains('API key (empty for none):'),
      );
      io.sendLine('');
      await waitForIt(
        () => io.out.toString().contains('no model list from the endpoint'),
      );
      io.sendLine('gpt-4o-mini');
      await waitForIt(
        () => io.out.toString().contains('switched provider to openai'),
      );
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.baseUrl, 'https://api.openai.com/v1');
      expect(cli.agent.state.model.id, 'gpt-4o-mini');
    },
  );

  test(
    '/provider custom saves the provider and switching restores its model',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry(const []);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        modelsFetcher: (baseUrl, {required apiKey}) async => ['m1', 'm2'],
      );
      final run = cli.run();

      io.sendLine('/provider custom');
      await waitForIt(() => io.out.toString().contains('type a number:'));
      io.sendLine('1');
      await waitForIt(() => io.out.toString().contains('base URL (empty ='));
      io.sendLine('http://localhost:11434/v1');
      await waitForIt(
        () => io.out.toString().contains('provider name (empty ='),
      );
      io.sendLine('my-ollama');
      await waitForIt(
        () => io.out.toString().contains('API key (empty for none):'),
      );
      io.sendLine('');
      await waitForIt(() => io.out.toString().contains('2) m2'));
      io.sendLine('2');
      await waitForIt(
        () => io.out.toString().contains('saved provider my-ollama'),
      );

      final entry = registry.entries.single;
      expect(entry.name, 'my-ollama');
      expect(entry.modelId, 'm2');
      expect(entry.baseUrl, 'http://localhost:11434/v1');

      // A catalog switch clears it; switching back by name restores m2.
      io.sendLine('/provider anthropic');
      await waitForIt(
        () => io.out.toString().contains('switched provider to anthropic'),
      );
      io.sendLine('/model other-model');
      await waitForIt(
        () => io.out.toString().contains('switched model to other-model'),
      );
      io.sendLine('/provider my-ollama');
      await waitForIt(() => cli.agent.state.model.id == 'm2');

      // Per-provider model memory: /model rewrites the entry.
      io.sendLine('/model llama3.2');
      await waitForIt(
        () => io.out.toString().contains('switched model to llama3.2'),
      );
      expect(registry.find('my-ollama')!.modelId, 'llama3.2');
      io.sendLine('/exit');
      await run;
    },
  );

  // /provider-edit edit/delete tests moved to visual TUI suite — the
  // command was removed; edit/delete is now inline in the /provider picker
  // (select a saved provider → Edit/Delete sub-picker). Line mode no longer
  // has a dedicated edit command.

  test('deleting a saved provider notifies the host so it persists', () async {
    // Regression: _removeProviderFromRegistry mutated the registry but
    // never called onProviderChanged — the host never re-saved the config,
    // so deleted providers reappeared after restart.
    final fake = FakeStreamFunction([textTurn('ok')]);
    final changes = <(String, String)>[];
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
      envVarValue: (_) => null,
      customProviders: registry,
      onProviderChanged: (kind, key) => changes.add((kind, key)),
    );
    final run = cli.run();
    io.sendLine('/exit');
    await run;

    // The picker delete path resolves here; the public regression is the
    // persistence notification, exercised through the same entry object.
    final entry = registry.entries.single;
    cli.removeProvider(entry);

    expect(registry.entries, isEmpty, reason: 'entry removed');
    expect(changes, isNotEmpty, reason: 'host notified to persist config');
  });

  test(
    '/provider-edit line-mode is gone — typed command falls through',
    () async {
      // /provider-edit was removed; its functionality is now inline in the
      // /provider picker (saved provider → Edit/Delete). A typed /provider-edit
      // is an unknown command → filtered menu.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider-edit');
      await waitForIt(
        () => io.out.toString().contains('unknown command: /provider-edit'),
      );
      io.sendLine('/exit');
      await run;
    },
  );

  group('OpenRouter OAuth', () {
    test(
      '/provider openrouter oauth headless exchanges, stores key and switches',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          openRouterOAuthExchangeFn:
              ({
                required String code,
                required String codeVerifier,
                String? label,
              }) async {
                expect(code, 'auth-code-123');
                expect(codeVerifier, isNotEmpty);
                expect(label, 'Fa');
                return const OpenRouterOAuthKey(
                  key: 'sk-or-oauth-123',
                  keyHash: 'abc123',
                  label: 'Fa',
                );
              },
        );
        final run = cli.run();

        io.sendLine('/provider openrouter oauth headless');
        await waitForIt(
          () => io.out.toString().contains('OpenRouter OAuth (headless)'),
        );
        await waitForIt(
          () => io.out.toString().contains('authorization code:'),
        );

        io.sendLine('auth-code-123');
        await waitForIt(
          () => io.out.toString().contains('switched provider to openrouter'),
        );
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(
          output,
          contains('authorization code received, exchanging for API key'),
        );
        expect(output, contains('OpenRouter authorized'));
        expect(
          output,
          contains('key settings: https://openrouter.ai/keys/abc123'),
        );
        // The key persists under the ENDPOINT-SCOPED store name — the slot
        // the saved registry entry references and the first store slot boot
        // resolution reads. The legacy env name would let a stale scoped
        // entry shadow the fresh OAuth key in every new session.
        expect(store.map['FA_KEY_OPENROUTER_AI'], 'sk-or-oauth-123');
        expect(cli.agent.state.model.provider, 'openrouter');
        expect(cli.providerKind, 'openai-completions');
      },
    );

    test(
      'openrouter oauth saves a registry entry so it shows in /provider',
      () async {
        // Regression: the OAuth flow stored only the key — the provider
        // never appeared in the saved list (dial/CodeMie entries did).
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final registry = CustomProviderRegistry([]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
          openRouterOAuthExchangeFn:
              ({
                required String code,
                required String codeVerifier,
                String? label,
              }) async => const OpenRouterOAuthKey(
                key: 'sk-or-9',
                keyHash: 'h',
                label: 'Fa',
              ),
        );
        final run = cli.run();

        io.sendLine('/provider openrouter oauth headless');
        await waitForIt(
          () => io.out.toString().contains('authorization code:'),
        );
        io.sendLine('auth-code-123');
        // First connect offers the provider-name step every add flow has.
        await waitForIt(
          () => io.out.toString().contains('provider name [openrouter.ai]'),
        );
        io.sendLine(''); // keep the host-derived default name
        await waitForIt(
          () => io.out.toString().contains('switched provider to openrouter'),
        );
        io.sendLine('/provider');
        await waitForIt(() => io.out.toString().contains('saved providers:'));
        io.sendLine('/exit');
        await run;

        final entry = registry.find('openrouter.ai');
        expect(entry, isNotNull, reason: 'connected provider saved');
        expect(entry!.apiType, 'openrouter');
        expect(entry.baseUrl, 'https://openrouter.ai/api/v1');
        // The stored key lands under the SAME name the entry references —
        // the mismatch sent new sessions to an empty/stale slot.
        expect(store.map[entry.keyName], 'sk-or-9');
        // /provider status lists it among the saved providers.
        expect(io.out.toString(), contains('openrouter.ai —'));
      },
    );

    test('openrouter oauth lets the user name the saved entry', () async {
      // Every add flow offers a display name; a custom one distinguishes
      // accounts in the /provider picker. The key stays endpoint-scoped.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
        openRouterOAuthExchangeFn:
            ({
              required String code,
              required String codeVerifier,
              String? label,
            }) async => const OpenRouterOAuthKey(key: 'sk-or-9'),
      );
      final run = cli.run();

      io.sendLine('/provider openrouter oauth headless');
      await waitForIt(() => io.out.toString().contains('authorization code:'));
      io.sendLine('auth-code-123');
      await waitForIt(
        () => io.out.toString().contains('provider name [openrouter.ai]'),
      );
      io.sendLine('my-or');
      await waitForIt(
        () => io.out.toString().contains('switched provider to openrouter'),
      );
      io.sendLine('/exit');
      await run;

      final entry = registry.find('my-or');
      expect(entry, isNotNull, reason: 'saved under the typed name');
      expect(entry!.baseUrl, 'https://openrouter.ai/api/v1');
      expect(store.map[entry.keyName], 'sk-or-9');
      expect(registry.find('openrouter.ai'), isNull, reason: 'no duplicate');
    });

    test(
      '/provider openrouter picker offers the already-stored key first',
      () async {
        // Regression: opening a fresh session and running /provider
        // openrouter forced OAuth/key re-entry even when a working key was
        // already in the secure store.
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        await store.write('FA_KEY_OPENROUTER_AI', 'sk-or-stored');
        final cache = SecureKeyCache(store);
        // Boot preload semantics: probe + load the names resolution reads.
        await cache.preload(['FA_KEY_OPENROUTER_AI']);
        var oauthStarted = false;
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          openRouterOAuthExchangeFn:
              ({
                required String code,
                required String codeVerifier,
                String? label,
              }) async {
                oauthStarted = true;
                return const OpenRouterOAuthKey(key: 'x', keyHash: 'h');
              },
        );
        final run = cli.run();

        io.sendLine('/provider openrouter');
        await waitForIt(
          () => io.out.toString().contains('OpenRouter sign-in method'),
        );
        // The stored-key option is offered first in the list.
        expect(io.out.toString(), contains('1) Use stored key'));
        io.sendLine('1'); // accept the stored key
        await waitForIt(
          () => io.out.toString().contains('switched provider to openrouter'),
        );
        io.sendLine('/exit');
        await run;

        expect(oauthStarted, isFalse, reason: 'no re-auth needed');
        expect(cli.agent.state.model.baseUrl, contains('openrouter.ai'));
      },
    );

    test(
      'oauth overwrites a stale endpoint-scoped key so it cannot shadow it',
      () async {
        // Regression: an old manual key under FA_KEY_OPENROUTER_AI (e.g.
        // revoked) used to win startup resolution over the fresh OAuth key
        // stored under OPENROUTER_API_KEY — new sessions came up "logged
        // out". The OAuth flow now writes the scoped slot itself.
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        await store.write('FA_KEY_OPENROUTER_AI', 'sk-or-stale');
        final cache = SecureKeyCache(store);
        await cache.preload(['FA_KEY_OPENROUTER_AI']);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          openRouterOAuthExchangeFn:
              ({
                required String code,
                required String codeVerifier,
                String? label,
              }) async => const OpenRouterOAuthKey(key: 'sk-or-fresh'),
        );
        final run = cli.run();

        io.sendLine('/provider openrouter oauth headless');
        await waitForIt(
          () => io.out.toString().contains('authorization code:'),
        );
        io.sendLine('auth-code-123');
        await waitForIt(
          () => io.out.toString().contains('OpenRouter authorized'),
        );
        io.sendLine('/exit');
        await run;

        expect(
          store.map['FA_KEY_OPENROUTER_AI'],
          'sk-or-fresh',
          reason: 'stale key replaced by the fresh OAuth key',
        );
      },
    );

    test('/provider openrouter oauth rejects invalid usage', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider openrouter oauth too many args');
      await waitForIt(
        () => io.out.toString().contains('usage: /provider openrouter oauth'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('/provider openrouter oauth headless cancels on empty code', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider openrouter oauth headless');
      await waitForIt(() => io.out.toString().contains('authorization code:'));
      io.sendLine('');
      await waitForIt(
        () => io.out.toString().contains('OpenRouter OAuth cancelled'),
      );
      io.sendLine('/exit');
      await run;
    });
  });

  group('ChatGPT OAuth', () {
    test(
      '/provider chatgpt oauth headless exchanges, stores credentials and switches',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final registry = CustomProviderRegistry([]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
          chatGptOAuthExchangeFn:
              ({
                required String code,
                required String redirectUri,
                required String verifier,
              }) async {
                expect(code, 'auth-code-xyz');
                expect(redirectUri, 'http://127.0.0.1:1455/auth/callback');
                expect(verifier, isNotEmpty);
                return const ChatGptOAuthCredentials(
                  accessToken: 'at-123',
                  refreshToken: 'rt-123',
                  idToken: 'it-123',
                  accountId: 'acc-123',
                );
              },
        );
        final run = cli.run();

        io.sendLine('/provider chatgpt oauth headless');
        await waitForIt(
          () => io.out.toString().contains('ChatGPT OAuth (headless)'),
        );
        await waitForIt(() => io.out.toString().contains('redirect URL:'));

        // The printed authorize URL carries the state parameter the
        // callback must echo back.
        final authUrlLine = io.out
            .toString()
            .split('\n')
            .firstWhere((line) => line.contains('auth.openai.com'));
        final state = Uri.parse(authUrlLine.trim()).queryParameters['state'];
        expect(state, isNotNull);

        io.sendLine(
          'http://127.0.0.1:1455/auth/callback?code=auth-code-xyz&state=$state',
        );
        // The connect flow asks for the provider name like every other
        // add flow; a typed name lands the account in the registry.
        await waitForIt(
          () => io.out.toString().contains('provider name [chatgpt.com]'),
        );
        io.sendLine('my-chatgpt');
        await waitForIt(
          () => io.out.toString().contains('switched provider to chatgpt'),
        );
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(output, contains('ChatGPT authorized'));
        final stored = store.map['CHATGPT_OAUTH_CREDENTIALS'];
        expect(stored, isNotNull);
        expect(stored, contains('"access_token":"at-123"'));
        expect(stored, contains('"refresh_token":"rt-123"'));
        expect(stored, contains('"chatgpt_account_id":"acc-123"'));
        // The account shows in /provider as a saved entry.
        final entry = registry.find('my-chatgpt');
        expect(entry, isNotNull);
        expect(entry!.apiType, 'chatgpt');
        expect(entry.keyName, 'CHATGPT_OAUTH_CREDENTIALS');
        expect(cli.agent.state.model.provider, 'chatgpt');
        expect(cli.providerKind, 'chatgpt-codex');
        // Tokens live ONLY in the secure store: the persisted registry
        // (config.yaml shape) and the transcript never carry them.
        final persistedConfig = jsonEncode(
          registry.entries.map((entry) => entry.toYaml()).toList(),
        );
        for (final secret in ['at-123', 'rt-123', 'it-123']) {
          expect(persistedConfig, isNot(contains(secret)));
          expect(output, isNot(contains(secret)));
        }
      },
    );

    test('/provider chatgpt oauth headless rejects a bad-state URL', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider chatgpt oauth headless');
      await waitForIt(() => io.out.toString().contains('redirect URL:'));
      io.sendLine('http://127.0.0.1:1455/auth/callback?code=x&state=wrong');
      await waitForIt(() => io.out.toString().contains('invalid redirect URL'));
      io.sendLine('/exit');
      await run;
    });

    test('/provider chatgpt oauth rejects invalid usage', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider chatgpt oauth too many args');
      await waitForIt(
        () => io.out.toString().contains('usage: /provider chatgpt oauth'),
      );
      io.sendLine('/exit');
      await run;
    });
  });

  group('DIAL setup', () {
    test(
      '/provider dial setup saves a registry entry, stores the key and switches',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final registry = CustomProviderRegistry([]);
        final changes = <(String, String)>[];
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
          onProviderChanged: (kind, key) => changes.add((kind, key)),
        );
        final run = cli.run();

        io.sendLine('/provider dial setup');
        // Line-mode answers: default base URL (empty), the API key, then the
        // deployment id (the models fetch fails against the default host —
        // no fetcher injected here, the network error is swallowed).
        await waitForIt(() => io.out.toString().contains('base URL [https://'));
        io.sendLine('');
        await waitForIt(() => io.out.toString().contains('DIAL API key'));
        io.sendLine('dial-key-1');
        await waitForIt(
          () => io.out.toString().contains('deployment (model id)'),
        );
        io.sendLine('anthropic.claude-sonnet-4-5-v1:0');
        await waitForIt(() => io.out.toString().contains('provider name'));
        io.sendLine('my-dial');
        await waitForIt(
          () => io.out.toString().contains('switched provider to dial'),
        );
        io.sendLine('/exit');
        await run;

        final entry = registry.find('my-dial');
        expect(entry, isNotNull, reason: 'dial org saved as registry entry');
        expect(entry!.apiType, 'dial');
        expect(entry.modelId, 'anthropic.claude-sonnet-4-5-v1:0');
        expect(store.map[entry.keyName], 'dial-key-1');
        expect(cli.providerKind, 'dial');
        expect(cli.agent.state.model.provider, 'dial');
        expect(cli.agent.state.model.baseUrl, 'https://ai-proxy.lab.epam.com');
        // The switch persisted (host notified).
        expect(changes, isNotEmpty);
        expect(changes.last.$1, 'dial');
      },
    );

    test(
      're-running setup reuses the entry name and updates the model',
      () async {
        final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'ai-proxy.lab.epam.com',
            apiType: 'dial',
            baseUrl: 'https://ai-proxy.lab.epam.com',
            modelId: 'old-model',
          ),
        ]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          customProviders: registry,
        );
        final run = cli.run();

        io.sendLine('/provider dial setup');
        await waitForIt(() => io.out.toString().contains('base URL [https://'));
        io.sendLine('');
        await waitForIt(() => io.out.toString().contains('DIAL API key'));
        io.sendLine('');
        await waitForIt(
          () => io.out.toString().contains('deployment (model id)'),
        );
        io.sendLine('new-model');
        await waitForIt(() => io.out.toString().contains('provider name'));
        io.sendLine('');
        await waitForIt(
          () => io.out.toString().contains('switched provider to dial'),
        );
        io.sendLine('/exit');
        await run;

        expect(registry.entries, hasLength(1), reason: 'no duplicate entry');
        expect(registry.find('ai-proxy.lab.epam.com')!.modelId, 'new-model');
      },
    );

    test('a custom dial name scopes the store key (second org)', () async {
      // Regression: two dial orgs on the same host shared one
      // endpoint-scoped key slot — the second setup overwrote the first
      // org's key. A custom (non-host) name now scopes the slot.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
      );
      final run = cli.run();

      io.sendLine('/provider dial setup');
      await waitForIt(() => io.out.toString().contains('base URL [https://'));
      io.sendLine('');
      await waitForIt(() => io.out.toString().contains('DIAL API key'));
      io.sendLine('dial-key-2');
      await waitForIt(
        () => io.out.toString().contains('deployment (model id)'),
      );
      io.sendLine('gpt-4o');
      await waitForIt(() => io.out.toString().contains('provider name'));
      io.sendLine('dial-work');
      await waitForIt(
        () => io.out.toString().contains('switched provider to dial'),
      );
      io.sendLine('/exit');
      await run;

      final entry = registry.find('dial-work');
      expect(entry, isNotNull);
      // Custom name → name-scoped slot, NOT the host-scoped one.
      expect(entry!.keyName, 'FA_KEY_AI_PROXY_LAB_EPAM_COM_DIAL_WORK');
      expect(store.map[entry.keyName], 'dial-key-2');
      expect(store.map['FA_KEY_AI_PROXY_LAB_EPAM_COM'], isNull);
    });

    test('/provider dial setup rejects extra args', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider dial setup extra');
      await waitForIt(
        () => io.out.toString().contains('usage: /provider dial setup'),
      );
      io.sendLine('/exit');
      await run;
    });
  });

  group('CodeMie SSO', () {
    test(
      '/provider codemie sso saves a custom provider, stores the cookie and switches',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final registry = CustomProviderRegistry([]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
          codeMieSsoAuthenticateFn: (url, onStatus) async {
            expect(url, 'https://codemie.lab.epam.com');
            return const CodeMieSsoCredentials(
              cookies: {'_oauth2_proxy': 'proxy-val', 'session': 's-1'},
              apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
              expiresAt: 9999999999999,
            );
          },
          codeMieGuidedSetupFn: (apiBase, cookie, pickOption, askLine) async {
            return 'codemie-model-1';
          },
        );
        final run = cli.run();

        io.sendLine('/provider codemie sso');
        // First login offers the provider-name step every add flow has.
        await waitForIt(
          () => io.out.toString().contains(
            'provider name [codemie.lab.epam.com]',
          ),
        );
        io.sendLine('my-codemie');
        await waitForIt(() => io.out.toString().contains('saved provider'));
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(output, contains('CodeMie session expires'));
        final entry = registry.find('my-codemie');
        expect(entry, isNotNull, reason: 'saved under the typed name');
        expect(
          entry!.baseUrl,
          'https://codemie.lab.epam.com/code-assistant-api/v1',
        );
        // A custom name scopes the store key (name-scoped slot).
        expect(entry.keyName, 'FA_KEY_CODEMIE_LAB_EPAM_COM_MY_CODEMIE');
        // The full cookie string is stored as the key.
        expect(store.map[entry.keyName], '_oauth2_proxy=proxy-val;session=s-1');
        expect(cli.providerKind, 'openai-completions');
        expect(
          cli.agent.state.model.baseUrl,
          'https://codemie.lab.epam.com/code-assistant-api/v1',
        );
        // The model carries cookie-header auth, not Bearer.
        expect(cli.agent.state.model.headers, {
          'cookie': '_oauth2_proxy=proxy-val;session=s-1',
        });
      },
    );

    test('re-login reuses the entry and keeps the last-used model', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'codemie.lab.epam.com',
          apiType: 'openai',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'codemie-model-1',
        ),
      ]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        codeMieSsoAuthenticateFn: (url, onStatus) async {
          return const CodeMieSsoCredentials(
            cookies: {'_oauth2_proxy': 'new-val'},
            apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
            expiresAt: 9999999999999,
          );
        },
      );
      final run = cli.run();

      io.sendLine('/provider codemie sso');
      // Explicit connect always offers the provider-name step — Enter
      // here keeps the existing entry (same-account cookie refresh).
      await waitForIt(
        () =>
            io.out.toString().contains('provider name [codemie.lab.epam.com]'),
      );
      io.sendLine('');
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      // One entry, last-used model preserved, key refreshed.
      expect(registry.entries, hasLength(1));
      expect(registry.entries.single.modelId, 'codemie-model-1');
      expect(cli.agent.state.model.id, 'codemie-model-1');
    });

    test(
      're-login finds a renamed entry by base URL and keeps its name',
      () async {
        // The entry lookup is by base URL, not the derived host name — a
        // user-renamed entry must not duplicate on re-login; the name
        // prompt is offered, Enter keeps it.
        final fake = FakeStreamFunction([textTurn('ok')]);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'work-codemie',
            apiType: 'openai',
            baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
            modelId: 'codemie-model-1',
          ),
        ]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          customProviders: registry,
          codeMieSsoAuthenticateFn: (url, onStatus) async {
            return const CodeMieSsoCredentials(
              cookies: {'_oauth2_proxy': 'new-val'},
              apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
              expiresAt: 9999999999999,
            );
          },
        );
        final run = cli.run();

        io.sendLine('/provider codemie sso');
        await waitForIt(
          () => io.out.toString().contains('provider name [work-codemie]'),
        );
        io.sendLine('');
        await waitForIt(() => io.out.toString().contains('saved provider'));
        io.sendLine('/exit');
        await run;

        expect(registry.entries, hasLength(1), reason: 'no duplicate entry');
        expect(registry.entries.single.name, 'work-codemie');
        expect(registry.entries.single.modelId, 'codemie-model-1');
      },
    );

    test('/provider codemie sso with an existing entry asks for a name '
        'so a second account gets its own entry', () async {
      // User scenario: first codemie account saved, then adding a
      // SECOND one with a different enterprise profile. The explicit
      // connect flow must ask for a name — a typed name becomes a
      // SEPARATE entry, Enter keeps the existing one.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'codemie.lab.epam.com',
          apiType: 'openai',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'codemie-model-1',
        ),
      ]);
      var guidedSetupCalls = 0;
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        codeMieSsoAuthenticateFn: (url, onStatus) async {
          return const CodeMieSsoCredentials(
            cookies: {'_oauth2_proxy': 'profile-2'},
            apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
            expiresAt: 9999999999999,
          );
        },
        codeMieGuidedSetupFn: (apiBase, cookie, pickOption, askLine) async {
          guidedSetupCalls++;
          return 'codemie-model-2';
        },
      );
      final run = cli.run();

      io.sendLine('/provider codemie sso');
      await waitForIt(
        () =>
            io.out.toString().contains('provider name [codemie.lab.epam.com]'),
      );
      io.sendLine('work');
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      // Two entries: the original kept, a new 'work' entry for the
      // second account.
      expect(registry.entries, hasLength(2));
      expect(registry.find('codemie.lab.epam.com'), isNotNull);
      final work = registry.find('work');
      expect(work, isNotNull);
      // A NEW account runs its own project → model pick (the profile
      // selection the CodeMie flow asks for), so its model is the guided
      // setup's choice, not the first account's.
      expect(guidedSetupCalls, 1);
      expect(work!.modelId, 'codemie-model-2');
      expect(registry.find('codemie.lab.epam.com')!.modelId, 'codemie-model-1');
      // The new entry's key is name-scoped — the existing entry's slot
      // is untouched.
      expect(work.keyName, 'FA_KEY_CODEMIE_LAB_EPAM_COM_WORK');
    });

    test(
      'selecting a saved CodeMie provider with an expired cookie re-runs SSO',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'codemie.lab.epam.com',
            apiType: 'openai',
            baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
            modelId: 'codemie-model-1',
            keyName: 'FA_KEY_CODEMIE_LAB_EPAM_COM',
          ),
        ]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final expiredJwtPayload = base64Url.encode(utf8.encode('{"exp":1}'));
        await cache.save(
          'FA_KEY_CODEMIE_LAB_EPAM_COM',
          'codemie_access_token=eyJhbGciOiJIUzI1NiJ9.$expiredJwtPayload.sig',
        );
        var ssoCalled = false;
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
          codeMieSsoAuthenticateFn: (url, onStatus) async {
            ssoCalled = true;
            expect(url, 'https://codemie.lab.epam.com');
            return const CodeMieSsoCredentials(
              cookies: {'_oauth2_proxy': 'refreshed'},
              apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
              expiresAt: 9999999999999,
            );
          },
          codeMieGuidedSetupFn: (apiBase, cookie, pickOption, askLine) async {
            return 'codemie-model-1';
          },
        );
        final run = cli.run();

        io.sendLine('/provider codemie.lab.epam.com');
        await waitForIt(
          () =>
              io.out.toString().contains('CodeMie session expired or missing'),
        );
        await waitForIt(() => io.out.toString().contains('saved provider'));
        io.sendLine('/exit');
        await run;

        expect(ssoCalled, isTrue);
        expect(cli.agent.state.model.id, 'codemie-model-1');
      },
    );

    test('/provider codemie sso rejects a bad org URL', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider codemie sso not-a-url');
      await waitForIt(
        () => io.out.toString().contains('usage: /provider codemie sso'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('/provider codemie jwt rejects a bad org URL', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider codemie jwt not-a-url token');
      await waitForIt(
        () => io.out.toString().contains('usage: /provider codemie jwt'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('/provider codemie jwt rejects an invalid token format', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine(
        '/provider codemie jwt https://codemie.lab.epam.com not-a-jwt',
      );
      await waitForIt(
        () => io.out.toString().contains('Invalid JWT token format'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('/provider codemie jwt rejects an expired token', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      final expiredToken = _makeJwtToken(exp: 1);
      io.sendLine(
        '/provider codemie jwt https://codemie.lab.epam.com $expiredToken',
      );
      await waitForIt(() => io.out.toString().contains('JWT token expired'));
      io.sendLine('/exit');
      await run;
    });

    test('/provider codemie jwt cancels on empty token', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider codemie jwt https://codemie.lab.epam.com');
      await waitForIt(() => io.out.toString().contains('JWT token:'));
      io.sendLine('');
      await waitForIt(
        () => io.out.toString().contains('CodeMie JWT setup cancelled'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('/provider codemie bogus shows usage', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider codemie bogus');
      await waitForIt(
        () => io.out.toString().contains(
          'usage: /provider codemie [sso [orgUrl] | jwt [orgUrl] [token]]',
        ),
      );
      io.sendLine('/exit');
      await run;
    });

    test(
      '/provider codemie jwt saves a custom provider, stores the token and switches',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final registry = CustomProviderRegistry([]);
        final jwtToken = _makeJwtToken(exp: 9999999999);
        final mockClient = _codeMieJwtMockClient(jwtToken);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
          modelsHttpClient: mockClient,
        );
        final run = cli.run();

        io.sendLine(
          '/provider codemie jwt https://codemie.lab.epam.com $jwtToken',
        );
        await waitForIt(() => io.out.toString().contains('CodeMie model'));
        io.sendLine('1'); // pick codemie-model-jwt
        await waitForIt(
          () => io.out.toString().contains(
            'provider name [codemie.lab.epam.com]',
          ),
        );
        io.sendLine(''); // keep the host-derived default name
        await waitForIt(() => io.out.toString().contains('saved provider'));
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(output, contains('JWT token expires in'));
        final entry = registry.find('codemie.lab.epam.com');
        expect(entry, isNotNull);
        expect(entry!.authMethod, CustomProviderAuthMethod.jwt);
        expect(
          entry.baseUrl,
          'https://codemie.lab.epam.com/code-assistant-api/v1',
        );
        expect(store.map[entry.keyName], jwtToken);
        expect(cli.providerKind, 'openai-completions');
        expect(cli.agent.state.model.baseUrl, entry.baseUrl);
        // JWT uses regular Bearer auth, not a cookie header.
        expect(cli.agent.state.model.headers, isNot(contains('cookie')));
      },
    );

    test('/provider codemie shows auth-method picker', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([]);
      final jwtToken = _makeJwtToken(exp: 9999999999);
      final mockClient = _codeMieJwtMockClient(jwtToken);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        modelsHttpClient: mockClient,
      );
      final run = cli.run();

      io.sendLine('/provider codemie');
      await waitForIt(
        () => io.out.toString().contains('CodeMie sign-in method'),
      );
      io.sendLine('2'); // JWT option
      await waitForIt(() => io.out.toString().contains('JWT token:'));
      io.sendLine(jwtToken);
      await waitForIt(() => io.out.toString().contains('CodeMie model'));
      io.sendLine('1'); // pick codemie-model-jwt
      await waitForIt(
        () =>
            io.out.toString().contains('provider name [codemie.lab.epam.com]'),
      );
      io.sendLine(''); // keep the host-derived default name
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('CodeMie sign-in method'));
      expect(output, contains('JWT token:'));
      expect(registry.find('codemie.lab.epam.com'), isNotNull);
    });

    test(
      'selecting a saved CodeMie JWT provider switches with Bearer auth',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final jwtToken = _makeJwtToken(exp: 9999999999);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        await cache.save('FA_KEY_CODEMIE_LAB_EPAM_COM', jwtToken);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'codemie.lab.epam.com',
            apiType: 'openai',
            baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
            modelId: 'codemie-model-jwt',
            keyName: 'FA_KEY_CODEMIE_LAB_EPAM_COM',
            authMethod: CustomProviderAuthMethod.jwt,
          ),
        ]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
        );
        final run = cli.run();

        io.sendLine('/provider codemie.lab.epam.com');
        await waitForIt(
          () => io.out.toString().contains('switched provider to openai'),
        );
        io.sendLine('/exit');
        await run;

        expect(cli.agent.state.model.id, 'codemie-model-jwt');
        expect(cli.agent.state.model.headers, isNot(contains('cookie')));
      },
    );

    test(
      'selecting a saved CodeMie JWT provider with an expired token reports expiry',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final jwtToken = _makeJwtToken(exp: 1);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        await cache.save('FA_KEY_CODEMIE_LAB_EPAM_COM', jwtToken);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'codemie.lab.epam.com',
            apiType: 'openai',
            baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
            modelId: 'codemie-model-jwt',
            keyName: 'FA_KEY_CODEMIE_LAB_EPAM_COM',
            authMethod: CustomProviderAuthMethod.jwt,
          ),
        ]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
        );
        final run = cli.run();

        io.sendLine('/provider codemie.lab.epam.com');
        await waitForIt(() => io.out.toString().contains('JWT token expired'));
        io.sendLine('/exit');
        await run;

        expect(cli.agent.state.model.id, isNot('codemie-model-jwt'));
      },
    );

    test(
      'selecting a saved CodeMie JWT provider with a missing token reports it',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'codemie.lab.epam.com',
            apiType: 'openai',
            baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
            modelId: 'codemie-model-jwt',
            keyName: 'FA_KEY_CODEMIE_LAB_EPAM_COM',
            authMethod: CustomProviderAuthMethod.jwt,
          ),
        ]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          customProviders: registry,
        );
        final run = cli.run();

        io.sendLine('/provider codemie.lab.epam.com');
        await waitForIt(
          () => io.out.toString().contains('CodeMie JWT token missing'),
        );
        io.sendLine('/exit');
        await run;

        expect(cli.agent.state.model.id, isNot('codemie-model-jwt'));
      },
    );
  });

  group('OpenRouter auth method picker', () {
    test('/provider openrouter shows auth-method picker', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, envVarValue: (_) => null);
      final run = cli.run();

      io.sendLine('/provider openrouter');
      await waitForIt(
        () => io.out.toString().contains('OpenRouter sign-in method'),
      );
      io.sendLine('2'); // API key option
      await waitForIt(() => io.out.toString().contains('OpenRouter API key:'));
      io.sendLine('sk-or-test-key');
      await waitForIt(
        () => io.out.toString().contains('switched provider to openrouter'),
      );
      io.sendLine('/exit');
      await run;

      expect(io.out.toString(), contains('OpenRouter sign-in method'));
      expect(io.out.toString(), contains('key: provided'));
    });

    test('/provider openrouter api-key connect saves a named entry', () async {
      // The API-key branch produces the same saved-entry shape as the OAuth
      // connect — provider-name step included.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
      );
      final run = cli.run();

      io.sendLine('/provider openrouter');
      await waitForIt(
        () => io.out.toString().contains('OpenRouter sign-in method'),
      );
      io.sendLine('2'); // API key option
      await waitForIt(() => io.out.toString().contains('OpenRouter API key:'));
      io.sendLine('sk-or-key');
      await waitForIt(
        () => io.out.toString().contains('provider name [openrouter.ai]'),
      );
      io.sendLine(''); // keep the host-derived default name
      await waitForIt(
        () => io.out.toString().contains('saved provider openrouter.ai'),
      );
      io.sendLine('/exit');
      await run;

      final entry = registry.find('openrouter.ai');
      expect(entry, isNotNull, reason: 'connected provider saved');
      expect(entry!.apiType, 'openrouter');
      expect(store.map[entry.keyName], 'sk-or-key');
      expect(cli.agent.state.model.provider, 'openrouter');
    });
  });

  group('Kimi provider', () {
    test('/provider kimi prompts for the API key when none resolves', () async {
      // Regression: the catalog kimi switch never asked for a key — a
      // keyless switch (and the "no key found" warning) was the only
      // outcome from both the preset picker and the typed command.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
      );
      final run = cli.run();

      io.sendLine('/provider kimi');
      await waitForIt(() => io.out.toString().contains('Kimi API key'));
      io.sendLine('sk-kimi-test');
      await waitForIt(
        () => io.out.toString().contains('switched provider to kimi'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('endpoint: https://api.kimi.com/coding/v1'));
      expect(output, contains('key: provided (saved to'));
      expect(cli.agent.state.model.provider, 'kimi');
      expect(cli.agent.state.model.id, 'k3');
      // The key persists under the endpoint-scoped store name, so the next
      // start resolves it without a prompt.
      expect(store.map['FA_KEY_API_KIMI_COM'], 'sk-kimi-test');
    });

    test('/provider kimi saves a typed key as a named entry', () async {
      // With a registry the typed key becomes a saved entry — the same
      // shape the custom wizard produces, provider-name step included.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
      );
      final run = cli.run();

      io.sendLine('/provider kimi');
      await waitForIt(() => io.out.toString().contains('Kimi API key'));
      io.sendLine('sk-kimi-work');
      await waitForIt(
        () => io.out.toString().contains('provider name [api.kimi.com]'),
      );
      io.sendLine('work');
      await waitForIt(() => io.out.toString().contains('saved provider work'));
      io.sendLine('/exit');
      await run;

      final entry = registry.find('work');
      expect(entry, isNotNull);
      expect(entry!.apiType, 'kimi');
      expect(entry.baseUrl, 'https://api.kimi.com/coding/v1');
      expect(entry.modelId, 'k3');
      // A custom name scopes the store key — the host slot stays untouched.
      expect(store.map['FA_KEY_API_KIMI_COM_WORK'], 'sk-kimi-work');
      expect(store.map['FA_KEY_API_KIMI_COM'], isNull);
      expect(cli.agent.state.model.provider, 'kimi');
      expect(cli.agent.state.model.id, 'k3');
    });

    test('the provider-name step rejects a built-in (catalog) name', () async {
      // Regression: a registry entry named after a catalog provider
      // (e.g. "kimi") is unreachable — `/provider kimi` routes to the
      // catalog flow before the registry lookup. The name step now
      // retries with an explanation instead of saving such a name.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
      );
      final run = cli.run();

      io.sendLine('/provider kimi');
      await waitForIt(() => io.out.toString().contains('Kimi API key'));
      io.sendLine('sk-kimi-x');
      await waitForIt(
        () => io.out.toString().contains('provider name [api.kimi.com]'),
      );
      io.sendLine('kimi'); // built-in name — must be rejected
      await waitForIt(
        () => io.out.toString().contains('is a built-in provider name'),
      );
      io.sendLine('personal');
      await waitForIt(
        () => io.out.toString().contains('saved provider personal'),
      );
      io.sendLine('/exit');
      await run;

      expect(registry.find('kimi'), isNull, reason: 'name not saved');
      expect(registry.find('personal'), isNotNull);
    });

    test('a catalog kimi switch stops recording /model into the previous '
        'custom entry', () async {
      // Regression: `_activeCustomName` leaked across catalog switches —
      // after `/provider kimi` (resolved env key), a `/model` switch
      // rewrote the STILL-ACTIVE codemie entry's model memory with the
      // kimi model id.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'codemie.lab.epam.com',
          apiType: 'openai',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'codemie-model-1',
        ),
      ]);
      final cli = cliFor(
        fake.call,
        envVarValue: (name) => name == 'KIMI_API_KEY' ? 'sk-env-kimi' : null,
        customProviders: registry,
      );
      final run = cli.run();

      io.sendLine('/provider kimi');
      await waitForIt(() => io.out.toString().contains('type a number:'));
      io.sendLine('1'); // Use the resolved key → plain catalog switch
      await waitForIt(
        () => io.out.toString().contains('switched provider to kimi'),
      );
      // Simulate the model-memory write path a `/model` switch takes.
      cli.recordCustomModelForTest('k3');
      io.sendLine('/exit');
      await run;

      // The codemie entry's model memory is untouched.
      expect(registry.find('codemie.lab.epam.com')!.modelId, 'codemie-model-1');
    });

    test(
      '/provider kimi resolves a named entry’s key without re-prompting',
      () async {
        // Regression: the default-endpoint resolution read only the
        // host-scoped and legacy slots — a second account's name-scoped key
        // was invisible, so every typed /provider kimi re-asked for the key
        // the named entry already saved.
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        await store.write('FA_KEY_API_KIMI_COM_WORK', 'sk-kimi-work');
        final cache = SecureKeyCache(store);
        await cache.preload(['FA_KEY_API_KIMI_COM_WORK']);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'work',
            apiType: 'kimi',
            baseUrl: 'https://api.kimi.com/coding/v1',
            modelId: 'k3',
            keyName: 'FA_KEY_API_KIMI_COM_WORK',
          ),
        ]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
        );
        final run = cli.run();

        io.sendLine('/provider kimi');
        // The resolved-key picker appears (no key re-prompt), showing the
        // name-scoped slot as the source.
        await waitForIt(
          () => io.out.toString().contains('Use the resolved key'),
        );
        expect(io.out.toString(), contains('FA_KEY_API_KIMI_COM_WORK'));
        expect(
          io.out.toString(),
          isNot(contains('Kimi API key (empty to skip')),
        );
        io.sendLine('1'); // Use the resolved key
        await waitForIt(
          () => io.out.toString().contains('switched provider to kimi'),
        );
        io.sendLine('/exit');
        await run;

        expect(cli.agent.state.model.provider, 'kimi');
      },
    );

    test(
      '/provider kimi offers the resolved key or a second account',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(
          fake.call,
          envVarValue: (name) => name == 'KIMI_API_KEY' ? 'sk-env-kimi' : null,
        );
        final run = cli.run();

        io.sendLine('/provider kimi');
        await waitForIt(() => io.out.toString().contains('type a number:'));
        io.sendLine('1'); // Use the resolved key
        await waitForIt(
          () => io.out.toString().contains('switched provider to kimi'),
        );
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(output, contains('Kimi API key'));
        expect(output, contains('Use the resolved key'));
        expect(output, contains('Use a different API key'));
        expect(output, isNot(contains('Kimi API key (empty to skip')));
        expect(output, contains('key: KIMI_API_KEY'));
        expect(cli.agent.state.model.provider, 'kimi');
      },
    );

    test('/provider kimi with a resolved key can add a second account '
        'as a named entry', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        fake.call,
        envVarValue: (name) => name == 'KIMI_API_KEY' ? 'sk-env-kimi' : null,
        secureKeys: cache,
        customProviders: registry,
        modelsFetcher: (baseUrl, {required apiKey}) async => const [],
      );
      final run = cli.run();

      io.sendLine('/provider kimi');
      await waitForIt(() => io.out.toString().contains('type a number:'));
      io.sendLine('2'); // Use a different API key → the generic wizard
      await waitForIt(() => io.out.toString().contains('api type'));
      io.sendLine('1'); // openai-like
      await waitForIt(() => io.out.toString().contains('base URL'));
      io.sendLine(''); // keep the prefilled kimi endpoint
      await waitForIt(() => io.out.toString().contains('provider name'));
      io.sendLine(''); // accept the derived unique name
      await waitForIt(() => io.out.toString().contains('API key'));
      io.sendLine('sk-kimi-2');
      await waitForIt(() => io.out.toString().contains('model id'));
      io.sendLine(''); // keep k3
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      // The second account is a named entry with its own store key — the
      // KIMI_API_KEY env var can't shadow it on the next start.
      final entries = registry.entries.where(
        (e) => e.baseUrl == 'https://api.kimi.com/coding/v1',
      );
      expect(entries, hasLength(1));
      expect(store.map[entries.single.keyName], 'sk-kimi-2');
      expect(cli.agent.state.model.baseUrl, entries.single.baseUrl);
      expect(cli.agent.state.model.id, 'k3');
    });

    test('/provider kimi with an empty key answer switches keyless', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, envVarValue: (_) => null);
      final run = cli.run();

      io.sendLine('/provider kimi');
      await waitForIt(() => io.out.toString().contains('Kimi API key'));
      io.sendLine('');
      await waitForIt(
        () => io.out.toString().contains('switched provider to kimi'),
      );
      io.sendLine('/exit');
      await run;

      expect(
        io.out.toString(),
        contains('key: no key found (want KIMI_API_KEY)'),
      );
    });

    test('/provider kimi <baseUrl> skips the resolved-key picker', () async {
      // An explicit base URL is a custom endpoint: no stored/default key
      // applies, so the flow goes straight to the key prompt and saves a
      // named entry for that endpoint.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        fake.call,
        envVarValue: (name) => name == 'KIMI_API_KEY' ? 'sk-env-kimi' : null,
        secureKeys: cache,
        customProviders: registry,
      );
      final run = cli.run();

      io.sendLine('/provider kimi https://kimi-proxy.example.com/v1');
      await waitForIt(() => io.out.toString().contains('Kimi API key'));
      io.sendLine('sk-proxy-key');
      await waitForIt(
        () => io.out.toString().contains('provider name [kimi-proxy'),
      );
      io.sendLine('');
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      final entry = registry.find('kimi-proxy.example.com');
      expect(entry, isNotNull);
      expect(entry!.baseUrl, 'https://kimi-proxy.example.com/v1');
      expect(store.map[entry.keyName], 'sk-proxy-key');
      // The env key never hijacks the custom endpoint.
      expect(
        cli.agent.state.model.baseUrl,
        'https://kimi-proxy.example.com/v1',
      );
    });
  });

  group('saved provider switching', () {
    test('switching to a keyless saved entry stays keyless', () async {
      // A local-server entry with no key: the switch must not invent a
      // key source (the "keyless endpoint" line, never the hosted
      // "no key found" warning).
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'my-ollama',
          apiType: 'openai',
          baseUrl: 'http://localhost:11434/v1',
          modelId: 'llama3.2',
        ),
      ]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
      );
      final run = cli.run();

      io.sendLine('/provider my-ollama');
      await waitForIt(
        () => io.out.toString().contains('switched provider to openai'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('endpoint: http://localhost:11434/v1'));
      expect(output, contains('model: llama3.2'));
      expect(output, contains('key: none (keyless endpoint)'));
      expect(output, isNot(contains('no key found')));
    });

    test('/model rewrite goes to the ACTIVE saved entry only', () async {
      // The real `/model` command (not the test seam) while a saved entry
      // is active: its model memory is rewritten; a sibling entry is not.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'alpha',
          apiType: 'openai',
          baseUrl: 'http://localhost:9000/v1',
          modelId: 'old-model',
        ),
        CustomProviderEntry(
          name: 'beta',
          apiType: 'openai',
          baseUrl: 'http://localhost:9001/v1',
          modelId: 'beta-model',
        ),
      ]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
      );
      final run = cli.run();

      io.sendLine('/provider alpha');
      await waitForIt(
        () => io.out.toString().contains('switched provider to openai'),
      );
      io.sendLine('/model new-model');
      await waitForIt(
        () => io.out.toString().contains('switched model to new-model'),
      );
      io.sendLine('/exit');
      await run;

      expect(registry.find('alpha')!.modelId, 'new-model');
      expect(registry.find('beta')!.modelId, 'beta-model');
    });

    test(
      'the edit wizard prefills from the entry, not the active model',
      () async {
        // Regression: editing a non-active entry while kimi is the active
        // model pre-filled Kimi's URL/model into the codemie wizard. The
        // wizard's URL step must default to the ENTRY's endpoint.
        final fake = FakeStreamFunction([textTurn('ok')]);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'codemie.lab.epam.com',
            apiType: 'openai',
            baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
            modelId: 'codemie-model-1',
          ),
        ]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          customProviders: registry,
          modelsFetcher: (baseUrl, {required apiKey}) async => const [],
        );
        final run = cli.run();

        // Switch the active model to kimi first, then open the codemie
        // entry's edit wizard (the TUI picker's Edit action).
        io.sendLine('/provider kimi https://api.kimi.com/coding/v1');
        await waitForIt(() => io.out.toString().contains('Kimi API key'));
        io.sendLine(''); // keyless kimi switch — active model is now kimi
        await waitForIt(
          () => io.out.toString().contains('switched provider to kimi'),
        );
        cli.startProviderEditWizardForTest(
          registry.find('codemie.lab.epam.com'),
        );
        await waitForIt(() => io.out.toString().contains('editing provider'));
        await waitForIt(() => io.out.toString().contains('type a number:'));
        io.sendLine('1'); // openai-like (keep)
        await waitForIt(
          () => io.out.toString().contains(
            'base URL (empty = https://codemie.lab.epam.com/code-assistant-api/v1)',
          ),
        );
        // Cancel the wizard (Ctrl-C) — the prefill was the assertion.
        io.interrupt();
        await waitForIt(
          () => io.out.toString().contains('provider edit cancelled'),
        );
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(
          output,
          isNot(contains('base URL (empty = https://api.kimi.com')),
          reason: 'the wizard defaults to the entry endpoint, not kimi',
        );
      },
    );

    test('renaming in the edit wizard replaces the old entry', () async {
      // The wizard's rename path: the old entry is dropped, the new name
      // replaces it, and the model memory moves to the renamed entry.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'old-name',
          apiType: 'openai',
          baseUrl: 'http://localhost:9000/v1',
          modelId: 'old-model',
          keyName: 'FA_KEY_LOCALHOST_9000',
        ),
      ]);
      await cache.save('FA_KEY_LOCALHOST_9000', 'sk-original');
      final changes = <(String, String)>[];
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
        modelsFetcher: (baseUrl, {required apiKey}) async => const [],
        onProviderChanged: (kind, key) => changes.add((kind, key)),
      );
      final run = cli.run();

      cli.startProviderEditWizardForTest(registry.find('old-name'));
      await waitForIt(
        () => io.out.toString().contains('editing provider old-name'),
      );
      // api type → keep (picker answer via line mode 'type a number').
      await waitForIt(() => io.out.toString().contains('type a number:'));
      io.sendLine('1'); // openai-like
      // base URL → keep.
      await waitForIt(() => io.out.toString().contains('base URL'));
      io.sendLine('');
      // name → the RENAME.
      await waitForIt(() => io.out.toString().contains('provider name'));
      io.sendLine('renamed');
      // key → keep current.
      await waitForIt(() => io.out.toString().contains('API key (empty'));
      io.sendLine('');
      // model → keep.
      await waitForIt(() => io.out.toString().contains('model id'));
      io.sendLine('');
      await waitForIt(() => io.out.toString().contains('renamed provider'));
      io.sendLine('/exit');
      await run;

      expect(registry.find('old-name'), isNull, reason: 'old entry dropped');
      final renamed = registry.find('renamed');
      expect(renamed, isNotNull);
      expect(renamed!.baseUrl, 'http://localhost:9000/v1');
      // Same-name rename keeps the key slot: no new store entry needed.
      expect(renamed.modelId, 'old-model');
      expect(registry.entries, hasLength(1));
    });
  });
}

String _makeJwtToken({required int exp}) {
  final header = base64Url.encode(utf8.encode('{"alg":"none"}'));
  final payload = base64Url.encode(utf8.encode('{"exp":$exp}'));
  return '$header.$payload.signature';
}

http.Client _codeMieJwtMockClient(String jwtToken) {
  return http_testing.MockClient((request) async {
    final auth = request.headers['authorization'];
    if (auth == null || !auth.endsWith(jwtToken)) {
      return http.Response('Unauthorized', 401);
    }
    final url = request.url.toString();
    if (url.contains('/v1/user')) {
      return http.Response(
        jsonEncode({
          'applications': ['demo'],
        }),
        200,
      );
    }
    if (url.contains('/llm_models')) {
      return http.Response(
        jsonEncode([
          {'id': 'codemie-model-jwt'},
        ]),
        200,
      );
    }
    return http.Response('Not found', 404);
  });
}
