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
        'supported providers: openrouter, openai, chatgpt, codemie, anthropic, google',
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

  test('/provider-edit updates the active custom provider', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final registry = CustomProviderRegistry([
      CustomProviderEntry(
        name: 'localhost:11434',
        apiType: 'openai',
        baseUrl: 'http://localhost:11434/v1',
        modelId: 'old-model',
      ),
    ]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      customProviders: registry,
      modelsFetcher: (baseUrl, {required apiKey}) async => [
        'new-model',
        'old-model',
      ],
    );
    final run = cli.run();

    io.sendLine('/provider localhost:11434');
    await waitForIt(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/provider-edit');
    // The new Edit/Delete picker shows first; pick "Edit provider".
    await waitForIt(
      () => io.out.toString().contains('provider localhost:11434'),
    );
    io.sendLine('1');
    await waitForIt(
      () => io.out.toString().contains('editing provider localhost:11434'),
    );
    io.sendLine('1');
    await waitForIt(
      () => io.out.toString().contains(
        'base URL (empty = http://localhost:11434/v1)',
      ),
    );
    io.sendLine('');
    await waitForIt(
      () =>
          io.out.toString().contains('provider name (empty = localhost:11434)'),
    );
    io.sendLine('renamed-ollama');
    await waitForIt(
      () => io.out.toString().contains('API key (empty for none):'),
    );
    io.sendLine('');
    await waitForIt(() => io.out.toString().contains('1) new-model'));
    io.sendLine('1');
    await waitForIt(() => cli.agent.state.model.id == 'new-model');
    io.sendLine('/exit');
    await run;

    expect(registry.find('localhost:11434'), isNull);
    final entry = registry.entries.single;
    expect(entry.name, 'renamed-ollama');
    expect(entry.modelId, 'new-model');
    expect(entry.baseUrl, 'http://localhost:11434/v1');
  });

  test('/provider-edit delete removes the custom provider', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final registry = CustomProviderRegistry([
      CustomProviderEntry(
        name: 'to-delete',
        apiType: 'openai',
        baseUrl: 'http://delete.me/v1',
        modelId: 'm1',
      ),
    ]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      customProviders: registry,
    );
    final run = cli.run();

    io.sendLine('/provider to-delete');
    await waitForIt(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/provider-edit');
    await waitForIt(() => io.out.toString().contains('provider to-delete'));
    io.sendLine('2'); // pick "Delete provider"
    await waitForIt(
      () => io.out.toString().contains('Delete provider to-delete'),
    );
    io.sendLine('1'); // confirm "Yes, delete"
    await waitForIt(
      () => io.out.toString().contains('deleted provider to-delete'),
    );
    io.sendLine('/exit');
    await run;

    expect(registry.entries, isEmpty);
  });

  test('/provider-edit delete cancelled keeps the provider', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final registry = CustomProviderRegistry([
      CustomProviderEntry(
        name: 'to-keep',
        apiType: 'openai',
        baseUrl: 'http://keep.me/v1',
        modelId: 'm1',
      ),
    ]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      customProviders: registry,
    );
    final run = cli.run();

    io.sendLine('/provider to-keep');
    await waitForIt(
      () => io.out.toString().contains('switched provider to openai'),
    );
    io.sendLine('/provider-edit');
    await waitForIt(() => io.out.toString().contains('provider to-keep'));
    io.sendLine('2'); // pick "Delete provider"
    await waitForIt(
      () => io.out.toString().contains('Delete provider to-keep'),
    );
    io.sendLine('2'); // confirm "No, cancel"
    await waitForIt(() => io.out.toString().contains('delete cancelled'));
    io.sendLine('/exit');
    await run;

    expect(registry.entries, hasLength(1));
    expect(registry.find('to-keep'), isNotNull);
  });

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
        expect(store.map['OPENROUTER_API_KEY'], 'sk-or-oauth-123');
        expect(cli.agent.state.model.provider, 'openrouter');
        expect(cli.providerKind, 'openai-completions');
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
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
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
        expect(cli.agent.state.model.provider, 'chatgpt');
        expect(cli.providerKind, 'chatgpt-codex');
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
        await waitForIt(() => io.out.toString().contains('saved provider'));
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(output, contains('CodeMie session expires'));
        final entry = registry.find('codemie.lab.epam.com');
        expect(entry, isNotNull);
        expect(
          entry!.baseUrl,
          'https://codemie.lab.epam.com/code-assistant-api/v1',
        );
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
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      // One entry, last-used model preserved, key refreshed.
      expect(registry.entries, hasLength(1));
      expect(registry.entries.single.modelId, 'codemie-model-1');
      expect(cli.agent.state.model.id, 'codemie-model-1');
    });

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
  });
}
