// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

/// A secure store over a plain map (the CLI resolves keys from this
/// snapshot exactly as it would from the platform keychain).
final class _FakeSecureKeyStore implements SecureKeyStore {
  _FakeSecureKeyStore([Map<String, String>? values]) : _values = {...?values};

  final Map<String, String> _values;

  @override
  String get label => 'fake store';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String?> read(String name) async => _values[name];

  @override
  Future<void> write(String name, String value) async => _values[name] = value;

  @override
  Future<void> delete(String name) async => _values.remove(name);
}

Future<SecureKeyCache> _cache([Map<String, String>? values]) async {
  final cache = SecureKeyCache(_FakeSecureKeyStore(values));
  await cache.preload(values?.keys ?? const []);
  return cache;
}

const _openrouter = 'https://openrouter.ai/api/v1';

void main() {
  group('resolveEnabledPlugins', () {
    test('defaults to hub with no args and no config', () {
      expect(resolveEnabledPlugins(const [], const {}), {'hub'});
    });

    test('argument plugins join the default-on hub', () {
      expect(resolveEnabledPlugins(const ['inspect_image'], const {}), {
        'hub',
        'inspect_image',
      });
    });

    test('a packages.yaml falsy value opts the plugin OUT', () {
      expect(resolveEnabledPlugins(const [], {'hub': false}), isEmpty);
    });

    test('a packages.yaml null value (empty `hub:`) opts the plugin OUT', () {
      expect(resolveEnabledPlugins(const [], {'hub': null}), isEmpty);
    });

    test('a packages.yaml truthy value keeps the plugin on', () {
      expect(
        resolveEnabledPlugins(const [], {
          'hub': {'url': 'ws://example:8080'},
        }),
        {'hub'},
      );
    });
  });

  group('splitServeA2aArgs', () {
    test('a plain invocation passes through untouched', () {
      final split = splitServeA2aArgs(const ['--model', 'm', 'prompt']);
      expect(split.serveA2a, isFalse);
      expect(split.cliArgs, const ['--model', 'm', 'prompt']);
    });

    test('serve flags and their values are stripped from the parse args', () {
      final split = splitServeA2aArgs(const [
        'serve',
        '--a2a',
        '--model',
        'm1',
        '--port',
        '9999',
        '--token',
        't0',
      ]);
      expect(split.serveA2a, isTrue);
      expect(split.cliArgs, const ['--model', 'm1']);
    });

    test('a value directly after --port/--token drops, the next one stays', () {
      final split = splitServeA2aArgs(const [
        'serve',
        '--a2a',
        '--token',
        'sekret',
        'positional',
      ]);
      expect(split.cliArgs, const ['positional']);
    });

    test('a serve invocation without --a2a still reports for the caller', () {
      final split = splitServeA2aArgs(const ['serve', 'positional']);
      expect(split.serveA2a, isTrue);
      expect(split.cliArgs, const ['positional']);
    });
  });

  group('resolveEffectiveCliArgs', () {
    test('an explicit --provider wins over the saved kind', () {
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(provider: 'anthropic', providerExplicit: true),
        CliConfig(providerKind: 'google'),
      );
      expect(resolved.provider, 'anthropic');
      expect(resolved.args.provider, 'anthropic');
    });

    test('a saved restorable kind is restored', () {
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(providerKind: 'minimax'),
      );
      expect(resolved.provider, 'minimax');
    });

    test('a saved non-restorable kind keeps the parsed default', () {
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(providerKind: 'chatgpt-codex'),
      );
      expect(resolved.provider, 'openai-completions');
    });

    test('model, baseUrl and mode fall back to the saved config', () {
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(
          modelId: 'saved/model',
          baseUrl: 'https://saved.example/api',
          mode: 'architect',
        ),
      );
      expect(resolved.args.model, 'saved/model');
      expect(resolved.args.baseUrl, 'https://saved.example/api');
      expect(resolved.args.mode, 'architect');
    });

    test('explicit flags win over the saved config', () {
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(
          model: 'flag/model',
          baseUrl: 'https://flag.example/api',
          mode: 'review',
        ),
        CliConfig(
          modelId: 'saved/model',
          baseUrl: 'https://saved.example/api',
          mode: 'architect',
        ),
      );
      expect(resolved.args.model, 'flag/model');
      expect(resolved.args.baseUrl, 'https://flag.example/api');
      expect(resolved.args.mode, 'review');
    });

    test('an FA_PROVIDER_* declaration wins over the saved kind and '
        'supplies model and baseUrl', () {
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(providerKind: 'google'),
        env: const {
          'FA_PROVIDER_TYPE': 'openai-completions',
          'FA_PROVIDER_NAME': 'local',
          'FA_PROVIDER_CONFIG':
              '{"baseUrl":"http://localhost:8080/v1","model":"qwen3",'
              '"apiKeyEnvVar":"LOCAL_KEY"}',
          'LOCAL_KEY': 'sk-test',
        },
      );
      expect(resolved.provider, 'openai-completions');
      expect(resolved.args.model, 'qwen3');
      expect(resolved.args.baseUrl, 'http://localhost:8080/v1');
      expect(resolved.faPreconfig?.apiKeyEnvVar, 'LOCAL_KEY');
    });

    test('a saved restorable kind is restored (zai joined the set)', () {
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(providerKind: 'zai'),
        env: const {},
      );
      expect(resolved.provider, 'zai');
    });
  });

  group('roleKeyNames', () {
    test('collects apiKeyName refs from chains and path overrides', () {
      final names = roleKeyNames(
        ModelRolesConfig(
          roles: {
            'default': [
              const ModelRef(
                provider: 'openai',
                modelId: 'm1',
                apiKeyName: 'CHAIN_KEY',
              ),
              const ModelRef(provider: 'openai', modelId: 'm2'),
            ],
          },
          pathOverrides: [
            const PathRoleOverride(
              pattern: 'sub/**',
              roles: {
                'default': [
                  ModelRef(
                    provider: 'openai',
                    modelId: 'm3',
                    apiKeyName: 'OVERRIDE_KEY',
                  ),
                ],
              },
            ),
          ],
        ),
      );
      expect(names, {'CHAIN_KEY', 'OVERRIDE_KEY'});
    });

    test('a config without explicit key names yields nothing', () {
      final names = roleKeyNames(
        ModelRolesConfig(
          roles: {
            'default': const [ModelRef(provider: 'openai', modelId: 'm1')],
          },
        ),
      );
      expect(names, isEmpty);
    });
  });

  group('secureKeyPreloadNames', () {
    test('preloads catalog, endpoint, media-slot and role key names', () {
      final names = secureKeyPreloadNames(
        CliConfig(
          customProviders: [
            CustomProviderEntry(
              name: 'mine',
              apiType: 'openai',
              baseUrl: 'http://lan:8080',
              modelId: 'm1',
              keyName: 'ENTRY_KEY',
            ),
            CustomProviderEntry(
              name: 'keyless',
              apiType: 'openai',
              baseUrl: 'http://other:8080',
              modelId: 'm2',
            ),
          ],
          modelRoles: ModelRolesConfig(
            roles: {
              'default': const [
                ModelRef(
                  provider: 'openai',
                  modelId: 'm1',
                  apiKeyName: 'CHAIN_KEY',
                ),
              ],
            },
          ),
        ),
        baseUrl: 'http://flag:1234',
      );
      expect(
        names,
        containsAll([
          'OPENROUTER_API_KEY',
          'VISION_API_KEY',
          'TRANSCRIBE_API_KEY',
          CustomProviderRegistry.keyNameFor(_openrouter),
          CustomProviderRegistry.keyNameFor('http://flag:1234'),
          CustomProviderRegistry.keyNameFor('http://other:8080'),
          'ENTRY_KEY',
          'CHAIN_KEY',
        ]),
      );
    });

    test('a null baseUrl just skips the endpoint slot', () {
      final names = secureKeyPreloadNames(CliConfig(), baseUrl: null);
      expect(names, contains('OPENROUTER_API_KEY'));
      expect(names, contains('VISION_API_KEY'));
    });
  });

  group('collectRoleSecrets', () {
    final roles = ModelRolesConfig(
      roles: {
        'default': const [
          ModelRef(provider: 'openai', modelId: 'm1', apiKeyName: 'CHAIN_KEY'),
        ],
      },
    );

    test('env wins over the store', () async {
      final secrets = collectRoleSecrets(
        roles,
        await _cache({'CHAIN_KEY': 'storevalue1'}),
        env: const {'CHAIN_KEY': 'envvalue12345'},
      );
      expect(secrets['CHAIN_KEY'], 'envvalue12345');
    });

    test('rotation stack entries come from env only', () {
      final secrets = collectRoleSecrets(
        roles,
        SecureKeyCache(_FakeSecureKeyStore({'CHAIN_KEY_2': 'store2value1'})),
        env: const {'CHAIN_KEY': 'envvalue12345', 'CHAIN_KEY_2': 'env2value12'},
      );
      expect(secrets, {
        'CHAIN_KEY': 'envvalue12345',
        'CHAIN_KEY_2': 'env2value12',
      });
    });

    test('the store backs up a base name the env lacks', () async {
      final secrets = collectRoleSecrets(
        roles,
        await _cache({'CHAIN_KEY': 'storevalue1'}),
        env: const {},
      );
      expect(secrets, {'CHAIN_KEY': 'storevalue1'});
    });

    test('an empty env value is skipped and the store fills in', () async {
      final secrets = collectRoleSecrets(
        roles,
        await _cache({'CHAIN_KEY': 'storevalue1'}),
        env: const {'CHAIN_KEY': ''},
      );
      expect(secrets, {'CHAIN_KEY': 'storevalue1'});
    });
  });

  group('startupApiKey', () {
    final entry = CustomProviderEntry(
      name: 'mine',
      apiType: 'openai',
      baseUrl: 'http://llama.local:8080',
      modelId: 'm1',
      keyName: 'ENTRY_KEY',
    );

    test('an interactive start tolerates a missing key', () {
      final key = startupApiKey(
        'openai-completions',
        SecureKeyCache(null),
        baseUrl: _openrouter,
        customProviders: const [],
        defaultRoleResolved: false,
        interactive: true,
        env: const {},
      );
      expect(key, isEmpty);
    });

    test('a headless hosted start without a key is a hard failure', () {
      expect(
        () => startupApiKey(
          'openai-completions',
          SecureKeyCache(null),
          baseUrl: _openrouter,
          customProviders: const [],
          defaultRoleResolved: false,
          interactive: false,
          env: const {},
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('missing API key: set OPENROUTER_API_KEY'),
          ),
        ),
      );
    });

    test('a headless hosted start with an env key resolves it', () {
      final key = startupApiKey(
        'openai-completions',
        SecureKeyCache(null),
        baseUrl: _openrouter,
        customProviders: const [],
        defaultRoleResolved: false,
        interactive: false,
        env: const {'OPENROUTER_API_KEY': 'envkeyvalue123'},
      );
      expect(key, 'envkeyvalue123');
    });

    test('a custom endpoint keeps the key optional headless', () {
      final key = startupApiKey(
        'openai-completions',
        SecureKeyCache(null),
        baseUrl: 'http://llama.local:8080',
        customProviders: [
          CustomProviderEntry(
            name: 'keyless',
            apiType: 'openai',
            baseUrl: 'http://llama.local:8080',
            modelId: 'm1',
          ),
        ],
        defaultRoleResolved: false,
        interactive: false,
        env: const {},
      );
      expect(key, isEmpty);
    });

    test('a name-scoped custom entry key resolves from the store', () async {
      final key = startupApiKey(
        'openai-completions',
        await _cache({'ENTRY_KEY': 'storekeyvalue'}),
        baseUrl: 'http://llama.local:8080',
        customProviders: [entry],
        defaultRoleResolved: false,
        interactive: false,
        env: const {},
      );
      expect(key, 'storekeyvalue');
    });

    test('roles mode tolerates a missing key', () {
      final key = startupApiKey(
        'openai-completions',
        SecureKeyCache(null),
        baseUrl: _openrouter,
        customProviders: const [],
        defaultRoleResolved: true,
        interactive: false,
        env: const {},
      );
      expect(key, isEmpty);
    });
  });

  group('buildSecretRedactor', () {
    test('registers env values, role secrets and store values', () async {
      final redactor = buildSecretRedactor(
        roleSecrets: const {'CHAIN_KEY': 'rolesecret123'},
        keys: await _cache({'STASHED_KEY': 'stashvalue123'}),
        env: const {'OPENROUTER_API_KEY': 'envsecret12345'},
      );
      expect(redactor.names, containsAll(['CHAIN_KEY', 'STASHED_KEY']));
      expect(
        redactor.redact('envsecret12345 rolesecret123 stashvalue123'),
        '*** *** ***',
      );
    });

    test('short values are never registered', () {
      final redactor = buildSecretRedactor(
        env: const {'OPENROUTER_API_KEY': 'short'},
      );
      expect(redactor.isEmpty, isTrue);
    });

    test('an empty startup yields a detached redactor', () {
      expect(buildSecretRedactor(env: const {}).isEmpty, isTrue);
    });
  });

  group('webSearchSecrets', () {
    test('keyed providers join when their env key is set', () async {
      final store = webSearchSecrets(
        env: const {
          'BRAVE_API_KEY': 'bravekey12345',
          'TAVILY_API_KEY': 'tavilykey123',
          'OPENROUTER_API_KEY': 'notasearch1',
        },
      );
      expect(await store.readAll(), {
        'BRAVE_API_KEY': 'bravekey12345',
        'TAVILY_API_KEY': 'tavilykey123',
      });
    });

    test('an empty key does not join the chain', () async {
      final store = webSearchSecrets(env: const {'BRAVE_API_KEY': ''});
      expect(await store.readAll(), isEmpty);
    });
  });
}
