@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The provider-key lifecycle: keys of ADDED providers must save to the
/// secure store under the right scoped name and resolve back on restart —
/// in legacy AND roles mode, for same-host siblings, across edits and
/// deletes. Every test drives the real CLI surface (commands/wizards)
/// against a fake secure store; "restart" = a fresh AgentCli over a fresh
/// SecureKeyCache preloaded from the SAME store.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor({
    CustomProviderRegistry? customProviders,
    SecureKeyCache? secureKeys,
    ModelRolesResolver? modelRolesResolver,
    String? Function(String name)? envVarValue,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        customProviders: customProviders,
        secureKeys: secureKeys,
        modelRolesResolver: modelRolesResolver,
        envVarValue: envVarValue ?? (_) => null,
        modelsFetcher: (baseUrl, {required apiKey}) async => const [],
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: FakeStreamFunction([]).call,
    );
  }

  Future<SecureKeyCache> cacheOf(FakeSecureKeyStore store, [String? also]) {
    final names = {...store.map.keys, ?also};
    return SecureKeyCache(store).preload(names).then((_) {
      final cache = SecureKeyCache(store);
      return cache.preload(names).then((_) => cache);
    });
  }

  group('provider key lifecycle', () {
    test('wizard add writes the key under the entry keyName; a restart '
        'resolves it from the store', () async {
      final registry = CustomProviderRegistry([]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final cli = cliFor(customProviders: registry, secureKeys: cache);
      final run = cli.run();

      // The full add wizard: api type → URL → name → key → model.
      io.sendLine('/provider custom');
      await waitForIt(() => io.out.toString().contains('type a number:'));
      io.sendLine('1'); // openai-like
      await waitForIt(() => io.out.toString().contains('base URL (empty ='));
      io.sendLine('https://api.kimi.com/coding/v1');
      await waitForIt(
        () => io.out.toString().contains('provider name (empty ='),
      );
      io.sendLine('kimi_ira1');
      await waitForIt(
        () => io.out.toString().contains('API key (empty for none):'),
        reason: 'key step',
      );
      io.sendLine('sk-ira1-secret');
      await waitForIt(
        () => io.out.toString().contains('model id'),
        reason: 'model step',
      );
      io.sendLine('kimi-for-coding');
      await waitForIt(
        () => io.out.toString().contains('saved provider kimi_ira1'),
        reason: 'saved',
      );
      io.sendLine('/exit');
      await run;

      // The key landed in the store under the entry's scoped name.
      final entry = registry.find('kimi_ira1')!;
      expect(entry.keyName, 'FA_KEY_API_KIMI_COM_KIMI_IRA1');
      expect(store.map['FA_KEY_API_KIMI_COM_KIMI_IRA1'], 'sk-ira1-secret');
      // The token never leaked into the transcript.
      expect(io.out.toString(), isNot(contains('sk-ira1-secret')));

      // "Restart": a fresh CLI over a fresh cache preloaded from the same
      // store resolves the key when switching to the saved provider (a
      // second FakeCliIO: the line stream is single-subscription).
      final io2 = FakeCliIO();
      final cache2 = await cacheOf(store);
      final cli2 = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          customProviders: registry,
          secureKeys: cache2,
          envVarValue: (_) => null,
          modelsFetcher: (baseUrl, {required apiKey}) async => const [],
          providerKind: 'openai-completions',
        ),
        io: io2,
        streamFunction: FakeStreamFunction([]).call,
      );
      final run2 = cli2.run();
      await waitForIt(() => io2.out.toString().contains('[Model]'));
      io2.sendLine('/provider kimi_ira1');
      await waitForIt(
        () => io2.out.toString().contains('switched provider to openai'),
      );
      io2.sendLine('/exit');
      await run2;

      expect(
        io2.out.toString(),
        contains('/key delete FA_KEY_API_KIMI_COM_KIMI_IRA1'),
      );
      await io2.close();
    });

    test('two providers on one host keep distinct scoped keys', () async {
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'kimi_me',
          apiType: 'openai',
          baseUrl: 'https://api.kimi.com/coding/v1',
          modelId: 'kimi-for-coding',
          keyName: 'FA_KEY_API_KIMI_COM_KIMI_ME',
        ),
        CustomProviderEntry(
          name: 'kimi_ira1',
          apiType: 'openai',
          baseUrl: 'https://api.kimi.com/coding/v1',
          modelId: 'kimi-for-coding',
          keyName: 'FA_KEY_API_KIMI_COM_KIMI_IRA1',
        ),
      ]);
      final store = FakeSecureKeyStore()
        ..map['FA_KEY_API_KIMI_COM_KIMI_ME'] = 'sk-me'
        ..map['FA_KEY_API_KIMI_COM_KIMI_IRA1'] = 'sk-ira1';
      final cache = await cacheOf(store);
      final cli = cliFor(customProviders: registry, secureKeys: cache);
      final run = cli.run();

      io.sendLine('/provider kimi_me');
      await waitForIt(
        () => io.out.toString().contains(
          '/key delete FA_KEY_API_KIMI_COM_KIMI_ME',
        ),
      );
      io.sendLine('/provider kimi_ira1');
      await waitForIt(
        () => io.out.toString().contains(
          '/key delete FA_KEY_API_KIMI_COM_KIMI_IRA1',
        ),
      );
      io.sendLine('/exit');
      await run;

      // Both keys still intact after the switches.
      expect(store.map['FA_KEY_API_KIMI_COM_KIMI_ME'], 'sk-me');
      expect(store.map['FA_KEY_API_KIMI_COM_KIMI_IRA1'], 'sk-ira1');
    });

    test('roles mode: a token switch persists to the store AND pins the '
        'chain to that name', () async {
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final resolver = ModelRolesResolver(
        config: ModelRolesConfig(
          roles: const {
            'default': [
              ModelRef(
                provider: 'openai',
                modelId: 'kimi-for-coding',
                baseUrl: 'https://api.kimi.com/coding/v1',
                apiKeyName: 'FA_KEY_API_KIMI_COM_KIMI_IRA1',
              ),
            ],
          },
          retry: const ModelRolesRetryPolicy(retriesPerEntry: 0),
        ),
        secrets: const {'FA_KEY_API_KIMI_COM_KIMI_IRA1': 'old-key'},
        streamFactory: (kind, apiKey) => FakeStreamFunction([]).call,
      );
      final cli = cliFor(secureKeys: cache, modelRolesResolver: resolver);
      final run = cli.run();

      io.sendLine(
        '/provider openai https://api.kimi.com/coding/v1 sk-fresh-token',
      );
      await waitForIt(
        () => io.out.toString().contains('switched provider to openai'),
      );
      io.sendLine('/exit');
      await run;

      // The token is persisted (restart-safe) under the preserved name…
      expect(store.map['FA_KEY_API_KIMI_COM_KIMI_IRA1'], 'sk-fresh-token');
      // …and the chain references it.
      final chain = resolver.config.roles['default']!;
      expect(chain.single.apiKeyName, 'FA_KEY_API_KIMI_COM_KIMI_IRA1');
      // The resolver picked the new secret up live.
      expect(
        resolver.config.roles['default']!.single.baseUrl,
        'https://api.kimi.com/coding/v1',
      );
    });

    test('roles mode: /model switch preserves the scoped key name', () async {
      final resolver = ModelRolesResolver(
        config: ModelRolesConfig(
          roles: const {
            'default': [
              ModelRef(
                provider: 'openai',
                modelId: 'kimi-for-coding',
                baseUrl: 'https://api.kimi.com/coding/v1',
                apiKeyName: 'FA_KEY_API_KIMI_COM_KIMI_IRA1',
              ),
            ],
          },
          retry: const ModelRolesRetryPolicy(retriesPerEntry: 0),
        ),
        secrets: const {'FA_KEY_API_KIMI_COM_KIMI_IRA1': 'kimi-key'},
        streamFactory: (kind, apiKey) => FakeStreamFunction([]).call,
      );
      final cli = cliFor(modelRolesResolver: resolver);
      final run = cli.run();

      io.sendLine('/model other-kimi-model');
      await waitForIt(
        () => io.out.toString().contains('switched model to other-kimi-model'),
      );
      io.sendLine('/exit');
      await run;

      expect(
        resolver.config.roles['default']!.single.apiKeyName,
        'FA_KEY_API_KIMI_COM_KIMI_IRA1',
      );
    });

    test('deleting a provider keeps its key in the store', () async {
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'kimi_ira1',
          apiType: 'openai',
          baseUrl: 'https://api.kimi.com/coding/v1',
          modelId: 'kimi-for-coding',
          keyName: 'FA_KEY_API_KIMI_COM_KIMI_IRA1',
        ),
      ]);
      final store = FakeSecureKeyStore()
        ..map['FA_KEY_API_KIMI_COM_KIMI_IRA1'] = 'sk-ira1';
      final cache = await cacheOf(store);
      final cli = cliFor(customProviders: registry, secureKeys: cache);
      final run = cli.run();

      // The delete picker is TUI; line mode exposes it through the registry
      // removal API the picker calls.
      await waitForIt(() => io.out.toString().contains('[Model]'));
      cli.removeProvider(registry.find('kimi_ira1')!);
      io.sendLine('/exit');
      await run;

      expect(registry.find('kimi_ira1'), isNull);
      expect(store.map['FA_KEY_API_KIMI_COM_KIMI_IRA1'], 'sk-ira1');
    });

    test('/key set writes the store; /key lists it as store-sourced', () async {
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final cli = cliFor(secureKeys: cache);
      final run = cli.run();

      io.sendLine('/key set FA_KEY_API_KIMI_COM_KIMI_IRA1 sk-via-key-set');
      await waitForIt(
        () => io.out.toString().contains('FA_KEY_API_KIMI_COM_KIMI_IRA1'),
      );
      io.sendLine('/key');
      await waitForIt(
        () => io.out.toString().contains('fake store'),
        reason: 'key listing shows the store as the source',
      );
      io.sendLine('/exit');
      await run;

      expect(store.map['FA_KEY_API_KIMI_COM_KIMI_IRA1'], 'sk-via-key-set');
      // The value never appears in the transcript.
      expect(io.out.toString(), isNot(contains('sk-via-key-set')));
    });
  });
}
