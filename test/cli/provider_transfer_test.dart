// `/provider export` + `/provider import` (issue #2090): the CURRENT
// provider only — UC1 cicd JSON/auth-value export and the UC2
// passphrase container round-trip over the `.fahx` machinery, plus the
// loud-failure/no-leak/conflict contracts.
@Timeout(Duration(seconds: 30))
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/paste_image.dart';
import 'package:flutter_agent_harness/src/cli/provider_transfer_payload.dart';
import 'package:flutter_agent_harness/src/providers/fahx_codec.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The shared clipboard box: machine A's export writes it, machine B's
/// import reads it. Declared here so the group-scoped helper closures can
/// capture it.
String? clipboardBox;

/// Builds an active custom-entry model, the way a real `/provider <name>`
/// switch rebuilds it (provider = the spec name, baseUrl = the entry's).
Model _entryModel(CustomProviderEntry entry) => Model(
  id: entry.modelId,
  api: entry.spec.api,
  provider: entry.spec.name,
  baseUrl: entry.baseUrl,
  contextWindow: entry.spec.contextWindow,
  maxTokens: entry.spec.maxTokens,
);

const _anthropicModel = Model(
  id: 'claude-sonnet-4-5',
  api: 'anthropic-messages',
  provider: 'anthropic',
  baseUrl: 'https://api.anthropic.com',
  contextWindow: 200000,
  maxTokens: 16384,
);

CustomProviderEntry _acmeEntry() => CustomProviderEntry(
  name: 'acme',
  apiType: 'openai',
  baseUrl: 'https://api.acme.io/v1',
  modelId: 'glm-4.6',
  keyName: 'FA_KEY_API_ACME_IO',
);

const _acmeKey = 'sk-acme-raw';

/// Decrypts a clipboard container into its bundle (test-side verification).
ProviderTransferBundle _decodeContainer(String container, String passphrase) =>
    ProviderTransferBundle.parse(
      jsonDecode(
        decryptFahxEnvelope(
          jsonDecode(container) as Map<String, dynamic>,
          passphrase,
          version: 1,
        ),
      ),
    );

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  // Second-REPL IOs ("machine B"): FakeCliIO.lines is single-subscription,
  // so every additional cli.run() needs its own stream.
  var extraIos = <FakeCliIO>[];

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    clipboardBox = null;
    extraIos = [];
  });

  tearDown(() async {
    await io.close();
    for (final extra in extraIos) {
      await extra.close();
    }
  });

  /// A fresh IO for a second REPL in the same test.
  FakeCliIO machineB() {
    final ioB = FakeCliIO();
    extraIos.add(ioB);
    return ioB;
  }

  AgentCli cliFor(
    StreamFunction streamFunction, {
    Model? model,
    SecureKeyCache? secureKeys,
    CustomProviderRegistry? customProviders,
    String? activeCustomName,
    String? Function(String name)? envVarValue,
    Future<String?> Function(String text)? clipboardWrite,
    Future<PasteboardRead> Function()? clipboardRead,
    void Function(String name, String value)? onSecretStored,
    Future<void> Function(String kind, String apiKey)? onProviderChanged,
    FakeCliIO? ioOverride,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model ?? testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        envVarValue: envVarValue,
        modelsFetcher: (_, {required apiKey}) async => const ['m-1'],
        secureKeys: secureKeys,
        customProviders: customProviders,
        onSecretStored: onSecretStored,
        onProviderChanged: onProviderChanged,
        clipboardWrite:
            clipboardWrite ??
            (text) async {
              clipboardBox = text;
              return null;
            },
        clipboardRead:
            clipboardRead ??
            () async => (clipboardBox == null || clipboardBox!.isEmpty)
                ? const PasteboardUnavailable('clipboard empty')
                : PasteboardText(clipboardBox!),
        activeCustomName: activeCustomName,
      ),
      io: ioOverride ?? io,
      streamFunction: streamFunction,
    );
  }

  /// A store-backed cache preloaded with [seed] (awaited — reads need the
  /// snapshot warm).
  Future<SecureKeyCache> freshCache([
    Map<String, String> seed = const {},
  ]) async {
    final store = FakeSecureKeyStore()..map.addAll(seed);
    final cache = SecureKeyCache(store);
    await cache.probe();
    await cache.preload(store.map.keys.toList());
    return cache;
  }

  /// Sends one REPL line on [target] and waits for the flow to reach a NEW
  /// occurrence of [marker] in its transcript before the next answer.
  /// Counts occurrences (the buffer is cumulative across a session), so a
  /// step never "completes" on a marker a previous step already produced —
  /// that would send the next line mid-flow, where the flow gate buffers
  /// it forever.
  Future<void> stepOn(FakeCliIO target, String line, String marker) async {
    final before = target.out.toString().split(marker).length - 1;
    target.sendLine(line);
    await waitForIt(
      () => target.out.toString().split(marker).length - 1 > before,
      reason: 'after "$line" expected "$marker"',
    );
  }

  /// Sends one REPL line on the primary test IO and waits for [marker].
  Future<void> step(String line, String marker) => stepOn(io, line, marker);

  /// Drives a full UC2 export on machine A (passphrase prompts answered)
  /// and returns the container text from the clipboard box.
  Future<String> exportContainer(
    AgentCli cli, {
    String passphrase = 'pass-phrase-1',
  }) async {
    final run = cli.run();
    await step('/provider export --yes', 'export passphrase');
    await step(passphrase, 'confirm passphrase');
    await step(passphrase, 'container copied to clipboard');
    io.sendLine('/exit');
    await run;
    return clipboardBox!;
  }

  group('payload codec (pure)', () {
    test('round-trips an entry bundle through the yaml shape', () {
      final entry = CustomProviderEntry(
        name: 'acme',
        apiType: 'openai',
        baseUrl: 'https://api.acme.io/v1',
        modelId: 'glm-4.6',
        keyName: 'FA_KEY_API_ACME_IO',
        authHeader: 'x-api-key',
        authMethod: CustomProviderAuthMethod.jwt,
        project: 'p-1',
        connectTimeout: const Duration(milliseconds: 9000),
        streamIdleTimeout: const Duration(milliseconds: 12000),
      );
      const key = ProviderTransferKey(
        name: 'FA_KEY_API_ACME_IO',
        kind: ProviderTransferKeyKind.apiKey,
        value: 'v',
      );
      final bundle = ProviderTransferBundle(
        entry: entry,
        modelId: entry.modelId,
        key: key,
        exportedAt: '2026-11-10T00:00:00Z',
      );
      final decoded = ProviderTransferBundle.parse(
        jsonDecode(jsonEncode(bundle.toJson())),
      );
      final round = decoded.entry!;
      expect(round.name, 'acme');
      expect(round.apiType, 'openai');
      expect(round.baseUrl, 'https://api.acme.io/v1');
      expect(round.modelId, 'glm-4.6');
      expect(round.keyName, 'FA_KEY_API_ACME_IO');
      expect(round.authHeader, 'x-api-key');
      expect(round.authMethod, CustomProviderAuthMethod.jwt);
      expect(round.project, 'p-1');
      expect(round.connectTimeout, const Duration(milliseconds: 9000));
      expect(round.streamIdleTimeout, const Duration(milliseconds: 12000));
      expect(decoded.key!.kind, ProviderTransferKeyKind.apiKey);
      expect(decoded.key!.value, 'v');
    });

    test('round-trips a catalog preset bundle', () {
      const bundle = ProviderTransferBundle(
        catalog: 'anthropic',
        baseUrl: 'https://proxy.example.com',
        modelId: 'claude-sonnet-4-5',
      );
      final decoded = ProviderTransferBundle.parse(
        jsonDecode(jsonEncode(bundle.toJson())),
      );
      expect(decoded.entry, isNull);
      expect(decoded.catalog, 'anthropic');
      expect(decoded.baseUrl, 'https://proxy.example.com');
      expect(decoded.modelId, 'claude-sonnet-4-5');
      expect(decoded.key, isNull);
    });

    test('refuses the legacy all-providers payload by name', () {
      final legacy = encryptFahxEnvelope(
        jsonEncode({
          'version': 1,
          'exportedAt': 'x',
          'providers': [
            {
              'name': 'z',
              'apiType': 'openai',
              'baseUrl': 'https://z.example',
              'modelId': 'm',
            },
          ],
        }),
        'p',
      );
      final payload = jsonDecode(decryptFahxEnvelope(legacy, 'p', version: 1));
      expect(
        () => ProviderTransferBundle.parse(payload),
        throwsA(
          isA<FahxException>().having(
            (e) => e.message,
            'message',
            contains('legacy all-providers'),
          ),
        ),
      );
    });

    test('refuses a wrong payload kind and a bad key kind', () {
      expect(
        () => ProviderTransferBundle.parse({'payloadKind': 'other'}),
        throwsA(isA<FahxException>()),
      );
      expect(
        () => ProviderTransferBundle.parse({
          'payloadKind': 'provider-transfer',
          'version': 1,
          'provider': {'catalog': 'anthropic', 'modelId': 'm'},
          'key': {'name': 'K', 'kind': 'rot13', 'value': 'v'},
        }),
        throwsA(isA<FahxException>()),
      );
    });

    test('refuses a non-map payload', () {
      expect(
        () => ProviderTransferBundle.parse(42),
        throwsA(
          isA<FahxException>().having(
            (e) => e.message,
            'message',
            'not a provider-transfer container',
          ),
        ),
      );
      expect(
        () => ProviderTransferBundle.parse(['x']),
        throwsA(isA<FahxException>()),
      );
    });

    test('refuses an unsupported payload version by number', () {
      expect(
        () => ProviderTransferBundle.parse({
          'payloadKind': 'provider-transfer',
          'version': 99,
          'provider': {'catalog': 'anthropic', 'modelId': 'm'},
        }),
        throwsA(
          isA<FahxException>().having(
            (e) => e.message,
            'message',
            contains('unsupported provider-transfer payload version: 99'),
          ),
        ),
      );
    });

    test('refuses a provider section that is not a map', () {
      expect(
        () => ProviderTransferBundle.parse({
          'payloadKind': 'provider-transfer',
          'version': 1,
          'provider': 'anthropic',
        }),
        throwsA(
          isA<FahxException>().having(
            (e) => e.message,
            'message',
            'provider-transfer payload is malformed',
          ),
        ),
      );
    });

    test('refuses a catalog subject without catalog or model', () {
      for (final provider in [
        {'catalog': '', 'modelId': 'm'},
        {'catalog': 'anthropic'},
      ]) {
        expect(
          () => ProviderTransferBundle.parse({
            'payloadKind': 'provider-transfer',
            'version': 1,
            'provider': provider,
          }),
          throwsA(
            isA<FahxException>().having(
              (e) => e.message,
              'message',
              'provider-transfer payload is malformed',
            ),
          ),
        );
      }
    });

    test('wraps a malformed entry subject with the config reason', () {
      expect(
        () => ProviderTransferBundle.parse({
          'payloadKind': 'provider-transfer',
          'version': 1,
          // apiType present (so the entry shape is chosen) but no name.
          'provider': {'apiType': 'openai'},
        }),
        throwsA(
          isA<FahxException>().having(
            (e) => e.message,
            'message',
            contains('provider-transfer payload entry is malformed'),
          ),
        ),
      );
    });
  });

  group('UC1 /provider export cicd', () {
    test('current api-key provider: exact JSON schema with embedded key, '
        'no transcript leak', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore()..map['FA_KEY_API_ACME_IO'] = _acmeKey;
      final cache = SecureKeyCache(store);
      await cache.preload(const ['FA_KEY_API_ACME_IO']);
      final entry = _acmeEntry();
      final cli = cliFor(
        fake.call,
        model: _entryModel(entry),
        secureKeys: cache,
        customProviders: CustomProviderRegistry([entry]),
        activeCustomName: 'acme',
      );
      final run = cli.run();

      await step('/provider export cicd --yes', 'copied to the clipboard');
      io.sendLine('/exit');
      await run;

      final json = jsonDecode(clipboardBox!) as Map<String, dynamic>;
      expect(json['v'], 1);
      expect(json['provider'], 'openai');
      expect(json['baseUrl'], 'https://api.acme.io/v1');
      expect(json['model'], 'glm-4.6');
      expect(json['kind'], 'openai-completions');
      expect(json['api'], 'openai-completions');
      expect(json['contextWindow'], 200000);
      expect(json['maxTokens'], 16384);
      final auth = json['auth'] as Map;
      expect(auth['type'], 'api-key');
      expect(auth['env'], 'FA_KEY_API_ACME_IO');
      expect(auth['value'], _acmeKey);
      expect(io.out.toString(), isNot(contains(_acmeKey)));
    });

    test('gate decline writes nothing', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore()..map['FA_KEY_API_ACME_IO'] = _acmeKey;
      final cache = SecureKeyCache(store);
      await cache.preload(const ['FA_KEY_API_ACME_IO']);
      final entry = _acmeEntry();
      final cli = cliFor(
        fake.call,
        model: _entryModel(entry),
        secureKeys: cache,
        customProviders: CustomProviderRegistry([entry]),
        activeCustomName: 'acme',
      );
      final run = cli.run();

      await step('/provider export cicd', 'to the clipboard? [y/N]');
      io.sendLine('n');
      await io.out.waitUntilContains('export cancelled — nothing written');
      expect(clipboardBox, isNull);
      io.sendLine('/exit');
      await run;
    });

    test('cicd usage: unknown flags and extra operands print usage', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore()..map['FA_KEY_API_ACME_IO'] = _acmeKey;
      final cache = SecureKeyCache(store);
      await cache.preload(const ['FA_KEY_API_ACME_IO']);
      final entry = _acmeEntry();
      final cli = cliFor(
        fake.call,
        model: _entryModel(entry),
        secureKeys: cache,
        customProviders: CustomProviderRegistry([entry]),
        activeCustomName: 'acme',
      );
      final run = cli.run();

      await step(
        '/provider export cicd --wat a b',
        'usage: /provider export cicd [path] [--yes]',
      );
      await step(
        '/provider export cicd auth --wat x y',
        'usage: /provider export cicd auth',
      );
      expect(clipboardBox, isNull);
      io.sendLine('/exit');
      await run;
    });

    test('AC3: a CI job consumes a cicd auth export end-to-end', () async {
      // Machine A: the current provider is the anthropic catalog preset,
      // its key resolved from the environment; export the auth value.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        model: _anthropicModel,
        envVarValue: (name) =>
            name == 'ANTHROPIC_API_KEY' ? 'sk-ant-raw' : null,
      );
      final run = cli.run();
      await step(
        '/provider export cicd auth --stdout --yes',
        'ANTHROPIC_API_KEY=',
      );
      io.sendLine('/exit');
      await run;

      // A CI step pastes the emitted line into its secret store — parse
      // it exactly as emitted (the idle prompt may share the line).
      final match = RegExp(
        'ANTHROPIC_API_KEY=(\\S+)',
      ).firstMatch(io.out.toString());
      expect(match, isNotNull);
      final emitted = match!.group(1)!;
      expect(emitted, 'sk-ant-raw');

      // Machine B: a fresh CI box — the exported value rides an env
      // var, the catalog provider resolves with no secure store, and
      // the value never prints.
      final ioB = machineB();
      final cliB = cliFor(
        FakeStreamFunction([textTurn('ok')]).call,
        model: _anthropicModel,
        envVarValue: (name) => name == 'ANTHROPIC_API_KEY' ? emitted : null,
        ioOverride: ioB,
      );
      final runB = cliB.run();
      await stepOn(ioB, '/provider anthropic', 'key: ANTHROPIC_API_KEY');
      ioB.sendLine('/exit');
      await runB;
      // Env-resolved keys show only the slot name — never the value.
      expect(ioB.out.toString(), isNot(contains(emitted)));
    });

    test('a non-exportable current provider is refused', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      await step(
        '/provider export cicd --yes',
        'is not an exportable provider',
      );
      io.sendLine('/exit');
      await run;
    });

    test(
      'no stored credential is refused with the auth-flow suggestion',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cache = SecureKeyCache(FakeSecureKeyStore());
        await cache.probe();
        final entry = _acmeEntry();
        final cli = cliFor(
          fake.call,
          model: _entryModel(entry),
          secureKeys: cache,
          customProviders: CustomProviderRegistry([entry]),
          activeCustomName: 'acme',
        );
        final run = cli.run();

        await step(
          '/provider export cicd --yes',
          'no credential stored for openai',
        );
        io.sendLine('/exit');
        await run;
      },
    );

    test('cicd auth: ENV_NAME=<value>, stdout only via --stdout', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore()..map['FA_KEY_API_ACME_IO'] = _acmeKey;
      final cache = SecureKeyCache(store);
      await cache.preload(const ['FA_KEY_API_ACME_IO']);
      final entry = _acmeEntry();
      final cli = cliFor(
        fake.call,
        model: _entryModel(entry),
        secureKeys: cache,
        customProviders: CustomProviderRegistry([entry]),
        activeCustomName: 'acme',
      );
      final run = cli.run();

      // Default destination is the clipboard; the value never prints.
      await step('/provider export cicd auth --yes', 'copied to the clipboard');
      expect(clipboardBox, 'FA_KEY_API_ACME_IO=$_acmeKey');
      expect(io.out.toString(), isNot(contains(_acmeKey)));

      // --stdout is the explicit secret-printing surface.
      await step(
        '/provider export cicd auth --stdout --yes',
        'FA_KEY_API_ACME_IO=$_acmeKey',
      );
      io.sendLine('/exit');
      await run;
    });

    test(
      'cicd auth: a ChatGPT current provider exports the OAuth blob',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        const blob =
            '{"access_token":"at-x","refresh_token":"rt-x",'
            '"id_token":"id-x"}';
        final spec = providerCatalog['chatgpt']!;
        final entry = CustomProviderEntry(
          name: 'chatgpt.com',
          apiType: 'chatgpt',
          baseUrl: spec.defaultBaseUrl,
          modelId: 'gpt-5.1-codex',
          keyName: 'FA_KEY_CHATGPT_COM',
        );
        final store = FakeSecureKeyStore()..map['FA_KEY_CHATGPT_COM'] = blob;
        final cache = SecureKeyCache(store);
        await cache.preload(const ['FA_KEY_CHATGPT_COM']);
        final cli = cliFor(
          fake.call,
          model: _entryModel(entry),
          secureKeys: cache,
          customProviders: CustomProviderRegistry([entry]),
          activeCustomName: 'chatgpt.com',
        );
        final run = cli.run();

        await step(
          '/provider export cicd auth --yes',
          'copied to the clipboard',
        );
        io.sendLine('/exit');
        await run;

        expect(clipboardBox, blob);
        expect(io.out.toString(), contains('FA_KEY_CHATGPT_COM'));
        expect(io.out.toString(), isNot(contains('at-x')));
      },
    );

    test('path operand writes the cicd JSON to a file', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore()..map['FA_KEY_API_ACME_IO'] = _acmeKey;
      final cache = SecureKeyCache(store);
      await cache.preload(const ['FA_KEY_API_ACME_IO']);
      final entry = _acmeEntry();
      final cli = cliFor(
        fake.call,
        model: _entryModel(entry),
        secureKeys: cache,
        customProviders: CustomProviderRegistry([entry]),
        activeCustomName: 'acme',
      );
      final run = cli.run();

      await step(
        '/provider export cicd /work/cicd.json --yes',
        'wrote /work/cicd.json',
      );
      io.sendLine('/exit');
      await run;

      switch (await env.readTextFile('/work/cicd.json')) {
        case Ok(:final value):
          final json = jsonDecode(value) as Map<String, dynamic>;
          expect((json['auth'] as Map)['value'], _acmeKey);
        case Err(:final error):
          fail('cicd file not written: $error');
      }
    });
  });

  group('UC2 /provider export + /provider import', () {
    /// Drives machine B's import REPL (its own IO — FakeCliIO.lines is
    /// single-subscription, so a second cli.run() needs its own stream):
    /// reads the clipboard box, feeds [answers] each waiting for its
    /// step marker, exits. Returns B's transcript.
    Future<String> runImport({
      required SecureKeyCache secureKeys,
      required CustomProviderRegistry registry,
      void Function(String name, String value)? onSecretStored,
      Future<void> Function(String kind, String apiKey)? onProviderChanged,
      required List<(String, String)> answers,
      Future<PasteboardRead> Function()? clipboardRead,
    }) async {
      final ioB = machineB();
      final cli = cliFor(
        FakeStreamFunction([textTurn('ok')]).call,
        secureKeys: secureKeys,
        customProviders: registry,
        clipboardRead:
            clipboardRead ?? () async => PasteboardText(clipboardBox!),
        onSecretStored: onSecretStored,
        onProviderChanged: onProviderChanged,
        ioOverride: ioB,
      );
      final run = cli.run();
      for (final (line, marker) in answers) {
        await stepOn(ioB, line, marker);
      }
      ioB.sendLine('/exit');
      await run;
      return ioB.out.toString();
    }

    test(
      'api-key entry round-trip: import lands entry + key + switch',
      () async {
        final entry = _acmeEntry();
        final cacheA = await freshCache({'FA_KEY_API_ACME_IO': _acmeKey});
        await exportContainer(
          cliFor(
            FakeStreamFunction([textTurn('ok')]).call,
            model: _entryModel(entry),
            secureKeys: cacheA,
            customProviders: CustomProviderRegistry([entry]),
            activeCustomName: 'acme',
          ),
        );

        // Machine B: clean registry + store, same clipboard.
        final registryB = CustomProviderRegistry([]);
        final storeB = FakeSecureKeyStore();
        final cacheB = SecureKeyCache(storeB);
        await cacheB.probe();
        final imported = <String, String>{};
        final outB = await runImport(
          secureKeys: cacheB,
          registry: registryB,
          onSecretStored: (name, value) => imported[name] = value,
          answers: const [
            ('/provider import', 'container passphrase'),
            ('pass-phrase-1', 'imported provider acme (api-key)'),
            ('', 'switched provider to openai'),
          ],
        );

        final landed = registryB.find('acme');
        expect(landed, isNotNull);
        expect(landed!.keyName, 'FA_KEY_API_ACME_IO');
        expect(storeB.map['FA_KEY_API_ACME_IO'], _acmeKey);
        expect(imported['FA_KEY_API_ACME_IO'], _acmeKey);
        expect(outB, isNot(contains(_acmeKey)));
      },
    );

    test('catalog preset round-trip: key lands in the env-name slot', () async {
      await exportContainer(
        cliFor(
          FakeStreamFunction([textTurn('ok')]).call,
          model: _anthropicModel,
          secureKeys: await freshCache(),
          customProviders: CustomProviderRegistry([]),
          envVarValue: (name) =>
              name == 'ANTHROPIC_API_KEY' ? 'sk-ant-raw' : null,
        ),
      );

      final registryB = CustomProviderRegistry([]);
      final storeB = FakeSecureKeyStore();
      final cacheB = SecureKeyCache(storeB);
      await cacheB.probe();
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        answers: const [
          ('/provider import', 'container passphrase'),
          ('pass-phrase-1', 'imported catalog provider anthropic'),
          ('', 'switched provider to anthropic'),
        ],
      );

      expect(registryB.entries, isEmpty);
      expect(storeB.map['ANTHROPIC_API_KEY'], 'sk-ant-raw');
    });

    test(
      'ChatGPT OAuth round-trip: the blob lands in the entry slot',
      () async {
        const blob =
            '{"access_token":"at-x","refresh_token":"rt-x",'
            '"id_token":"id-x"}';
        final spec = providerCatalog['chatgpt']!;
        final entry = CustomProviderEntry(
          name: 'chatgpt.com',
          apiType: 'chatgpt',
          baseUrl: spec.defaultBaseUrl,
          modelId: 'gpt-5.1-codex',
          keyName: 'FA_KEY_CHATGPT_COM',
        );
        await exportContainer(
          cliFor(
            FakeStreamFunction([textTurn('ok')]).call,
            model: _entryModel(entry),
            secureKeys: await freshCache({'FA_KEY_CHATGPT_COM': blob}),
            customProviders: CustomProviderRegistry([entry]),
            activeCustomName: 'chatgpt.com',
          ),
        );

        final registryB = CustomProviderRegistry([]);
        final storeB = FakeSecureKeyStore();
        final cacheB = SecureKeyCache(storeB);
        await cacheB.probe();
        await runImport(
          secureKeys: cacheB,
          registry: registryB,
          answers: const [
            ('/provider import', 'container passphrase'),
            ('pass-phrase-1', 'imported provider chatgpt.com (oauth)'),
            ('n', 'keeping the current provider'),
          ],
        );

        final landed = registryB.find('chatgpt.com');
        expect(landed, isNotNull);
        expect(landed!.apiType, 'chatgpt');
        expect(storeB.map[landed.keyName], blob);
      },
    );

    test(
      'Copilot OAuth round-trip lands the token in its entry slot',
      () async {
        final entry = CustomProviderEntry(
          name: 'copilot-b',
          apiType: 'copilot',
          baseUrl: 'https://api.business.githubcopilot.com',
          modelId: 'gpt-4.1',
          keyName: 'FA_KEY_COPILOT_COPILOT_B',
        );
        await exportContainer(
          cliFor(
            FakeStreamFunction([textTurn('ok')]).call,
            model: _entryModel(entry),
            secureKeys: await freshCache({
              'FA_KEY_COPILOT_COPILOT_B': 'github_tok_raw',
            }),
            customProviders: CustomProviderRegistry([entry]),
            activeCustomName: 'copilot-b',
          ),
        );

        final registryB = CustomProviderRegistry([]);
        final storeB = FakeSecureKeyStore();
        final cacheB = SecureKeyCache(storeB);
        await cacheB.probe();
        await runImport(
          secureKeys: cacheB,
          registry: registryB,
          answers: const [
            ('/provider import', 'container passphrase'),
            ('pass-phrase-1', 'imported provider copilot-b (oauth)'),
            ('n', 'keeping the current provider'),
          ],
        );

        final landed = registryB.find('copilot-b');
        expect(landed, isNotNull);
        expect(landed!.apiType, 'copilot');
        expect(storeB.map['FA_KEY_COPILOT_COPILOT_B'], 'github_tok_raw');
      },
    );

    test('CodeMie SSO round-trip keeps the sso auth method', () async {
      const cookie = 'RFC=cookie-value; JSESSIONID=abc';
      final entry = CustomProviderEntry(
        name: 'codmie',
        apiType: 'openai',
        baseUrl: 'https://codmie.example.com/code-assistant-api/v1',
        modelId: 'gpt-4o',
        keyName: 'FA_KEY_CODMIE_EXAMPLE_COM',
        authMethod: CustomProviderAuthMethod.sso,
      );
      await exportContainer(
        cliFor(
          FakeStreamFunction([textTurn('ok')]).call,
          model: _entryModel(entry),
          secureKeys: await freshCache({'FA_KEY_CODMIE_EXAMPLE_COM': cookie}),
          customProviders: CustomProviderRegistry([entry]),
          activeCustomName: 'codmie',
        ),
      );

      final registryB = CustomProviderRegistry([]);
      final storeB = FakeSecureKeyStore();
      final cacheB = SecureKeyCache(storeB);
      await cacheB.probe();
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        answers: const [
          ('/provider import', 'container passphrase'),
          ('pass-phrase-1', 'imported provider codmie (sso)'),
          ('n', 'keeping the current provider'),
        ],
      );

      final landed = registryB.find('codmie');
      expect(landed, isNotNull);
      expect(landed!.authMethod, CustomProviderAuthMethod.sso);
      expect(storeB.map['FA_KEY_CODMIE_EXAMPLE_COM'], cookie);
    });

    test('wrong passphrase fails loudly with zero writes', () async {
      final entry = _acmeEntry();
      await exportContainer(
        cliFor(
          FakeStreamFunction([textTurn('ok')]).call,
          model: _entryModel(entry),
          secureKeys: await freshCache({'FA_KEY_API_ACME_IO': _acmeKey}),
          customProviders: CustomProviderRegistry([entry]),
          activeCustomName: 'acme',
        ),
      );

      final registryB = CustomProviderRegistry([]);
      final storeB = FakeSecureKeyStore();
      final cacheB = SecureKeyCache(storeB);
      await cacheB.probe();
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        answers: const [
          ('/provider import', 'container passphrase'),
          ('wrong-passphrase', 'wrong passphrase or corrupted'),
        ],
      );

      expect(registryB.entries, isEmpty);
      expect(storeB.map, isEmpty);
    });

    test('a tampered container fails loudly with zero writes', () async {
      final entry = _acmeEntry();
      final container = await exportContainer(
        cliFor(
          FakeStreamFunction([textTurn('ok')]).call,
          model: _entryModel(entry),
          secureKeys: await freshCache({'FA_KEY_API_ACME_IO': _acmeKey}),
          customProviders: CustomProviderRegistry([entry]),
          activeCustomName: 'acme',
        ),
      );
      final envelope = jsonDecode(container) as Map<String, dynamic>;
      final ct = base64Decode(envelope['ct'] as String);
      ct[0] ^= 0x01;
      envelope['ct'] = base64Encode(ct);
      clipboardBox = jsonEncode(envelope);

      final registryB = CustomProviderRegistry([]);
      final storeB = FakeSecureKeyStore();
      final cacheB = SecureKeyCache(storeB);
      await cacheB.probe();
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        answers: const [
          ('/provider import', 'container passphrase'),
          ('pass-phrase-1', 'wrong passphrase or corrupted'),
        ],
      );

      expect(registryB.entries, isEmpty);
      expect(storeB.map, isEmpty);
    });

    test('a truncated container is not a container: zero writes', () async {
      final entry = _acmeEntry();
      final container = await exportContainer(
        cliFor(
          FakeStreamFunction([textTurn('ok')]).call,
          model: _entryModel(entry),
          secureKeys: await freshCache({'FA_KEY_API_ACME_IO': _acmeKey}),
          customProviders: CustomProviderRegistry([entry]),
          activeCustomName: 'acme',
        ),
      );
      clipboardBox = container.substring(0, container.length ~/ 2);

      final registryB = CustomProviderRegistry([]);
      final storeB = FakeSecureKeyStore();
      final cacheB = SecureKeyCache(storeB);
      await cacheB.probe();
      // Fails at the envelope JSON before any passphrase prompt.
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        answers: const [
          ('/provider import', 'not a provider export container'),
        ],
      );

      expect(registryB.entries, isEmpty);
      expect(storeB.map, isEmpty);
    });

    test('a wrong key-kind tag inside the container fails loudly with zero '
        'writes', () async {
      final entry = _acmeEntry();
      final container = await exportContainer(
        cliFor(
          FakeStreamFunction([textTurn('ok')]).call,
          model: _entryModel(entry),
          secureKeys: await freshCache({'FA_KEY_API_ACME_IO': _acmeKey}),
          customProviders: CustomProviderRegistry([entry]),
          activeCustomName: 'acme',
        ),
      );
      // Rewrite the decrypted payload's key kind and re-encrypt: the
      // envelope opens fine, the payload parse refuses.
      final envelope = jsonDecode(container) as Map<String, dynamic>;
      final payload =
          jsonDecode(decryptFahxEnvelope(envelope, 'pass-phrase-1', version: 1))
              as Map<String, dynamic>;
      payload['key'] = {'name': 'K', 'kind': 'rot13', 'value': 'v'};
      final resealed = encryptFahxEnvelope(
        jsonEncode(payload),
        'pass-phrase-1',
      );
      clipboardBox = jsonEncode(resealed);

      final registryB = CustomProviderRegistry([]);
      final storeB = FakeSecureKeyStore();
      final cacheB = SecureKeyCache(storeB);
      await cacheB.probe();
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        answers: const [
          ('/provider import', 'container passphrase'),
          ('pass-phrase-1', 'is not one of'),
        ],
      );

      expect(registryB.entries, isEmpty);
      expect(storeB.map, isEmpty);
    });

    test('a path operand imports from the file, not the clipboard', () async {
      final entry = _acmeEntry();
      final container = await exportContainer(
        cliFor(
          FakeStreamFunction([textTurn('ok')]).call,
          model: _entryModel(entry),
          secureKeys: await freshCache({'FA_KEY_API_ACME_IO': _acmeKey}),
          customProviders: CustomProviderRegistry([entry]),
          activeCustomName: 'acme',
        ),
      );
      await env.writeFile('/work/c.fahx', container);
      clipboardBox = null; // Proves the read came from the file.

      final registryB = CustomProviderRegistry([]);
      final storeB = FakeSecureKeyStore();
      final cacheB = SecureKeyCache(storeB);
      await cacheB.probe();
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        answers: const [
          ('/provider import /work/c.fahx', 'container passphrase'),
          ('pass-phrase-1', 'imported provider acme (api-key)'),
          ('', 'switched provider to openai'),
        ],
      );

      final landed = registryB.find('acme');
      expect(landed, isNotNull);
      expect(storeB.map['FA_KEY_API_ACME_IO'], _acmeKey);
    });

    test('a missing container file is refused with zero writes', () async {
      final registryB = CustomProviderRegistry([]);
      final storeB = FakeSecureKeyStore();
      final cacheB = SecureKeyCache(storeB);
      await cacheB.probe();
      // Fails before any passphrase prompt.
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        answers: const [
          ('/provider import /work/none.fahx', 'container file not found'),
        ],
      );

      expect(registryB.entries, isEmpty);
      expect(storeB.map, isEmpty);
    });

    test('a directory operand is refused as unreadable, zero writes', () async {
      // writeFile auto-creates parent directories: /work/d becomes one.
      await env.writeFile('/work/d/inner.txt', 'x');

      final registryB = CustomProviderRegistry([]);
      final storeB = FakeSecureKeyStore();
      final cacheB = SecureKeyCache(storeB);
      await cacheB.probe();
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        answers: const [('/provider import /work/d', 'cannot read /work/d')],
      );

      expect(registryB.entries, isEmpty);
      expect(storeB.map, isEmpty);
    });

    test('an unavailable pasteboard points at the path operand', () async {
      final registryB = CustomProviderRegistry([]);
      final storeB = FakeSecureKeyStore();
      final cacheB = SecureKeyCache(storeB);
      await cacheB.probe();
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        clipboardRead: () async => const PasteboardUnavailable('no pasteboard'),
        answers: const [
          ('/provider import', 'clipboard holds no container (no pasteboard)'),
        ],
      );

      expect(registryB.entries, isEmpty);
      expect(storeB.map, isEmpty);
    });

    test(
      'an image clipboard is refused with a path hint, zero writes',
      () async {
        final registryB = CustomProviderRegistry([]);
        final storeB = FakeSecureKeyStore();
        final cacheB = SecureKeyCache(storeB);
        await cacheB.probe();
        await runImport(
          secureKeys: cacheB,
          registry: registryB,
          clipboardRead: () async => const PasteboardImage(<int>[]),
          answers: const [
            ('/provider import', 'clipboard holds an image, not a container'),
          ],
        );

        expect(registryB.entries, isEmpty);
        expect(storeB.map, isEmpty);
      },
    );

    test('a legacy all-providers .fahx export is refused by name', () async {
      clipboardBox = jsonEncode(
        encryptFahxEnvelope(
          jsonEncode({'version': 1, 'exportedAt': 'x', 'providers': []}),
          'pass-phrase-1',
        ),
      );

      final registryB = CustomProviderRegistry([]);
      await runImport(
        secureKeys: await freshCache(),
        registry: registryB,
        answers: const [
          ('/provider import', 'container passphrase'),
          ('pass-phrase-1', 'legacy all-providers'),
        ],
      );
      expect(registryB.entries, isEmpty);
    });

    test(
      'clipboard write failure falls back to --path, never stdout',
      () async {
        final entry = _acmeEntry();
        final cli = cliFor(
          FakeStreamFunction([textTurn('ok')]).call,
          model: _entryModel(entry),
          secureKeys: await freshCache({'FA_KEY_API_ACME_IO': _acmeKey}),
          customProviders: CustomProviderRegistry([entry]),
          activeCustomName: 'acme',
          clipboardWrite: (text) async => 'pbcopy: not found',
        );
        final run = cli.run();

        await step(
          '/provider export --yes --path /work/ct.fahx',
          'export passphrase',
        );
        await step('pass-phrase-1', 'confirm passphrase');
        await step('pass-phrase-1', 'wrote /work/ct.fahx');
        io.sendLine('/exit');
        await run;

        final String file;
        switch (await env.readTextFile('/work/ct.fahx')) {
          case Ok(:final value):
            file = value;
          case Err(:final error):
            fail('fallback file not written: $error');
        }
        // The container never reaches the transcript.
        expect(io.out.toString(), isNot(contains(file.trim())));
        // And the fallback file decrypts to the acme bundle.
        expect(_decodeContainer(file, 'pass-phrase-1').entry!.name, 'acme');
      },
    );

    test('declining the switch offer leaves the current provider active and '
        'the entry untouched', () async {
      final entry = _acmeEntry();
      final container = await exportContainer(
        cliFor(
          FakeStreamFunction([textTurn('ok')]).call,
          model: _entryModel(entry),
          secureKeys: await freshCache({'FA_KEY_API_ACME_IO': _acmeKey}),
          customProviders: CustomProviderRegistry([entry]),
          activeCustomName: 'acme',
        ),
      );
      clipboardBox = container;

      final registryB = CustomProviderRegistry([]);
      final storeB = FakeSecureKeyStore();
      final cacheB = SecureKeyCache(storeB);
      await cacheB.probe();
      var providerChanged = 0;
      final persistedNames = <List<String>>[];
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        onProviderChanged: (kind, apiKey) async {
          providerChanged++;
          // Simulate the executable's reload: what it would persist.
          persistedNames.add(registryB.entries.map((e) => e.name).toList());
        },
        answers: const [
          ('/provider import', 'container passphrase'),
          ('pass-phrase-1', 'imported provider acme (api-key)'),
          // Decline: the imported entry must stay INACTIVE.
          ('n', 'keeping the current provider'),
          // A later /model switch must NOT rewrite the inactive entry's
          // model (the old bug: import pinned the entry active, so this
          // switch corrupted its modelId).
          ('/model m-9', 'm-9'),
        ],
      );

      // The decline itself never fires further callbacks: the import
      // persisted the entry ONCE (at registry add — a declined import
      // survives reload), and no switch-time persist ran.
      expect(providerChanged, 1);
      // The simulated reload sees the imported entry.
      expect(persistedNames.single, contains('acme'));
      // The entry is present, with its bundled model intact.
      final landed = registryB.find('acme');
      expect(landed, isNotNull);
      expect(landed!.modelId, 'glm-4.6');
      expect(storeB.map['FA_KEY_API_ACME_IO'], _acmeKey);
    });

    test('mismatched passphrase confirmation cancels', () async {
      final entry = _acmeEntry();
      final cli = cliFor(
        FakeStreamFunction([textTurn('ok')]).call,
        model: _entryModel(entry),
        secureKeys: await freshCache({'FA_KEY_API_ACME_IO': _acmeKey}),
        customProviders: CustomProviderRegistry([entry]),
        activeCustomName: 'acme',
      );
      final run = cli.run();

      await step('/provider export', 'export passphrase');
      await step('pass-phrase-1', 'confirm passphrase');
      await step('other', 'passphrases do not match');
      io.sendLine('/exit');
      await run;
      expect(clipboardBox, isNull);
    });

    test(
      'AC8: switching providers between exports changes the subject',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore()
          ..map['FA_KEY_API_ACME_IO'] = _acmeKey
          ..map['FA_KEY_API_BETA_IO'] = 'sk-beta-raw';
        final cache = SecureKeyCache(store);
        await cache.preload(const ['FA_KEY_API_ACME_IO', 'FA_KEY_API_BETA_IO']);
        final acme = _acmeEntry();
        final beta = CustomProviderEntry(
          name: 'beta',
          apiType: 'openai',
          baseUrl: 'https://api.beta.io/v1',
          modelId: 'm-1',
          keyName: 'FA_KEY_API_BETA_IO',
        );
        final cli = cliFor(
          fake.call,
          model: _entryModel(acme),
          secureKeys: cache,
          customProviders: CustomProviderRegistry([acme, beta]),
          activeCustomName: 'acme',
        );
        final run = cli.run();

        await step('/provider export --yes', 'export passphrase');
        await step('pass-phrase-1', 'confirm passphrase');
        await step('pass-phrase-1', 'container copied to clipboard');
        expect(
          _decodeContainer(clipboardBox!, 'pass-phrase-1').entry!.name,
          'acme',
        );

        // A real provider switch re-points the export subject.
        await step('/provider beta', 'switched provider to openai');
        await step('/provider export --yes', 'export passphrase');
        await step('pass-phrase-1', 'confirm passphrase');
        await step('pass-phrase-1', 'container copied to clipboard');
        io.sendLine('/exit');
        await run;

        final bundle = _decodeContainer(clipboardBox!, 'pass-phrase-1');
        expect(bundle.entry!.name, 'beta');
        expect(bundle.entry!.baseUrl, 'https://api.beta.io/v1');
      },
    );

    test('AC9: import over an existing name resolves per-prompt', () async {
      final entry = _acmeEntry();
      await exportContainer(
        cliFor(
          FakeStreamFunction([textTurn('ok')]).call,
          model: _entryModel(entry),
          secureKeys: await freshCache({'FA_KEY_API_ACME_IO': _acmeKey}),
          customProviders: CustomProviderRegistry([entry]),
          activeCustomName: 'acme',
        ),
      );

      final local = CustomProviderEntry(
        name: 'acme',
        apiType: 'openai',
        baseUrl: 'https://api.acme.io/v1',
        modelId: 'glm-4.6',
        keyName: 'FA_KEY_API_ACME_IO',
      );
      final storeB = FakeSecureKeyStore()
        ..map['FA_KEY_API_ACME_IO'] = 'sk-local-raw';
      final cacheB = SecureKeyCache(storeB);
      await cacheB.preload(const ['FA_KEY_API_ACME_IO']);
      final registryB = CustomProviderRegistry([local]);

      // Keep local: nothing written.
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        answers: const [
          ('/provider import', 'container passphrase'),
          ('pass-phrase-1', 'already exists'),
          ('1', 'kept the local provider'),
        ],
      );
      expect(storeB.map['FA_KEY_API_ACME_IO'], 'sk-local-raw');

      // Take bundle: the key slot is overwritten.
      await runImport(
        secureKeys: cacheB,
        registry: registryB,
        answers: const [
          ('/provider import', 'container passphrase'),
          ('pass-phrase-1', 'already exists'),
          ('2', 'imported provider acme (api-key)'),
          ('n', 'keeping the current provider'),
        ],
      );
      expect(storeB.map['FA_KEY_API_ACME_IO'], _acmeKey);

      // --force: no prompt, bundle wins.
      storeB.map['FA_KEY_API_ACME_IO'] = 'sk-local-raw';
      final outForce = await runImport(
        secureKeys: cacheB,
        registry: registryB,
        answers: const [
          ('/provider import --force', 'container passphrase'),
          ('pass-phrase-1', 'imported provider acme'),
          ('n', 'keeping the current provider'),
        ],
      );
      expect(storeB.map['FA_KEY_API_ACME_IO'], _acmeKey);
      expect(outForce, isNot(contains('already exists')));
    });

    test('AC7: no secure-store value substring in any transcript', () async {
      final store = FakeSecureKeyStore()
        ..map['FA_KEY_API_ACME_IO'] = _acmeKey
        ..map['FA_KEY_CHATGPT_COM'] =
            '{"access_token":"at-7",'
            '"refresh_token":"rt-7","id_token":"id-7"}';
      final cache = SecureKeyCache(store);
      await cache.preload(const ['FA_KEY_API_ACME_IO', 'FA_KEY_CHATGPT_COM']);
      final spec = providerCatalog['chatgpt']!;
      final chatgpt = CustomProviderEntry(
        name: 'chatgpt.com',
        apiType: 'chatgpt',
        baseUrl: spec.defaultBaseUrl,
        modelId: 'gpt-5.1-codex',
        keyName: 'FA_KEY_CHATGPT_COM',
      );
      final cli = cliFor(
        FakeStreamFunction([textTurn('ok')]).call,
        model: _entryModel(_acmeEntry()),
        secureKeys: cache,
        customProviders: CustomProviderRegistry([_acmeEntry(), chatgpt]),
        activeCustomName: 'acme',
      );
      final run = cli.run();

      await step('/provider export cicd --yes', 'copied to the clipboard');
      await step('/provider export --yes', 'export passphrase');
      await step('pass-phrase-1', 'confirm passphrase');
      await step('pass-phrase-1', 'container copied to clipboard');
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(out, isNot(contains(_acmeKey)));
      expect(out, isNot(contains('at-7')));
      expect(out, isNot(contains('rt-7')));
      expect(out, isNot(contains('id-7')));
      expect(clipboardBox, isNotNull);
    });
  });
}
