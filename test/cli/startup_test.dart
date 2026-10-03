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

  group('splitWireServeArgs', () {
    test('a plain invocation passes through untouched', () {
      final split = splitWireServeArgs(const ['--model', 'm', 'prompt']);
      expect(split.wireServe, isFalse);
      expect(split.cliArgs, const ['--model', 'm', 'prompt']);
    });

    test('stdio mode is detected and flags are stripped', () {
      final split = splitWireServeArgs(const [
        'wire-serve',
        '--stdio',
        '--model',
        'm1',
      ]);
      expect(split.wireServe, isTrue);
      expect(split.stdio, isTrue);
      expect(split.port, isNull);
      expect(split.token, isNull);
      expect(split.cliArgs, const ['--model', 'm1']);
    });

    test('ws mode keeps port and token, strips flags and their values', () {
      final split = splitWireServeArgs(const [
        'wire-serve',
        '--port',
        '9999',
        '--token',
        'sekret',
        '--model',
        'm1',
      ]);
      expect(split.wireServe, isTrue);
      expect(split.stdio, isFalse);
      expect(split.port, 9999);
      expect(split.token, 'sekret');
      expect(split.cliArgs, const ['--model', 'm1']);
    });

    test('a value directly after --port/--token drops, the next one stays', () {
      final split = splitWireServeArgs(const [
        'wire-serve',
        '--token',
        'sekret',
        'positional',
      ]);
      expect(split.token, 'sekret');
      expect(split.cliArgs, const ['positional']);
    });

    test(
      'the word as any non-subcommand argument never intercepts (r2 #6)',
      () {
        final split = splitWireServeArgs(const ['-p', 'wire-serve']);
        expect(split.wireServe, isFalse);
        expect(split.cliArgs, const ['-p', 'wire-serve']);
      },
    );

    test('repeated flags: last occurrence wins for --port and --token (r2 #7)',
        () {
      final split = splitWireServeArgs(const [
        'wire-serve',
        '--port',
        '1111',
        '--port',
        '2222',
        '--token',
        'a',
        '--token',
        'b',
      ]);
      expect(split.port, 2222);
      expect(split.token, 'b');
    });

    test('a value-flag value is consumed verbatim (r2 #7): --token --stdio',
        () {
      final split = splitWireServeArgs(const ['wire-serve', '--token', '--stdio']);
      expect(split.stdio, isFalse, reason: 'the word is the token VALUE');
      expect(split.token, '--stdio');
    });

    test('--stdio and --port together are a loud usage error', () {
      expect(
        () =>
            splitWireServeArgs(const ['wire-serve', '--stdio', '--port', '1']),
        throwsFormatException,
      );
    });

    test('a missing or non-numeric --port value is a usage error', () {
      expect(
        () => splitWireServeArgs(const ['wire-serve', '--port']),
        throwsFormatException,
      );
      expect(
        () => splitWireServeArgs(const ['wire-serve', '--port', 'main']),
        throwsFormatException,
      );
    });

    test('a --token without a value is a usage error', () {
      expect(
        () => splitWireServeArgs(const ['wire-serve', '--token']),
        throwsFormatException,
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

    test('a serve invocation without a serve marker reports neither form', () {
      final split = splitServeA2aArgs(const ['serve', 'positional']);
      expect(split.serveA2a, isFalse);
      expect(split.serveBridge, isFalse);
      expect(split.cliArgs, const ['positional']);
    });

    test('the bridge form is detected and its flags stripped', () {
      final split = splitServeA2aArgs(const [
        'serve',
        '--bridge',
        '--port',
        '9999',
      ]);
      expect(split.serveBridge, isTrue);
      expect(split.serveA2a, isFalse);
      expect(split.cliArgs, const []);
    });

    test('both serve markers never select a form', () {
      final split = splitServeA2aArgs(const ['serve', '--a2a', '--bridge']);
      expect(split.serveA2a, isTrue);
      expect(split.serveBridge, isTrue);
    });
  });

  group('resolveEffectiveCliArgs', () {
    test('an explicit --provider wins over the saved kind', () {
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(provider: 'anthropic', providerExplicit: true),
        CliConfig(providerKind: 'google'),
        env: const {},
      );
      expect(resolved.provider, 'anthropic');
      expect(resolved.args.provider, 'anthropic');
    });

    test('a saved restorable kind is restored', () {
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(providerKind: 'minimax'),
        env: const {},
      );
      expect(resolved.provider, 'minimax');
    });

    test('a saved chatgpt-codex kind is restored (gh-760 AC1)', () {
      // The app writes `provider: chatgpt-codex` into the shared config;
      // the boot path must resolve it to the codex catalog entry. The
      // servable shape carries the codex endpoint (CliConfig defaults an
      // absent baseUrl to the openrouter one — that PAIR degrades, see the
      // endpoint-lock tests below).
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(
          providerKind: 'chatgpt-codex',
          modelId: 'gpt-5-codex',
          baseUrl: 'https://chatgpt.com/backend-api/codex',
        ),
        env: const {},
      );
      expect(resolved.provider, 'chatgpt-codex');
      expect(resolved.unknownSavedProvider, isNull);
      expect(resolved.incompatibleSavedEndpoint, isNull);
    });

    test('a saved catalog NAME restores as its adapter KIND (gh-760 '
        'review)', () {
      // `openai` is a catalog name whose adapter kind differs; restoring
      // the raw string bricks the boot at providerStreamFunction.
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(providerKind: 'openai', modelId: 'gpt-5'),
        env: const {},
      );
      expect(resolved.provider, resolveCliProviderSpec('openai')!.kind);
      expect(resolved.unknownSavedProvider, isNull);
    });

    test('app-written and CLI-written configs restore identically '
        '(issue #772 AC1)', () {
      // The app persists the kind (`chatgpt-codex`); old CLI versions
      // persisted the name (`chatgpt`). Both must land on ONE identity —
      // on the servable pair shape (codex kind + its own endpoint; a
      // defaulted foreign baseUrl degrades, see the endpoint-lock tests).
      final fromName = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(
          providerKind: 'chatgpt',
          modelId: 'gpt-5-codex',
          baseUrl: 'https://chatgpt.com/backend-api/codex',
        ),
        env: const {},
      );
      final fromKind = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(
          providerKind: 'chatgpt-codex',
          modelId: 'gpt-5-codex',
          baseUrl: 'https://chatgpt.com/backend-api/codex',
        ),
        env: const {},
      );
      expect(fromName.provider, 'chatgpt-codex');
      expect(fromName.provider, fromKind.provider);
      expect(fromName.unknownSavedProvider, isNull);
      expect(fromKind.unknownSavedProvider, isNull);
      expect(fromName.incompatibleSavedEndpoint, isNull);
      expect(fromKind.incompatibleSavedEndpoint, isNull);
    });

    test('a saved kind no version knows degrades to the parsed default '
        'and is reported (gh-760 AC2)', () {
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(providerKind: 'from-the-future'),
        env: const {},
      );
      expect(resolved.provider, 'openai-completions');
      expect(resolved.unknownSavedProvider, 'from-the-future');
    });

    test('a BLANK saved provider is unset, not unknown (gh-760 review)', () {
      // `provider: ""` is a hand-edit artifact — pre-#760 it silently took
      // the default; it must not wear the version-skew warning.
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(providerKind: '  '),
        env: const {},
      );
      expect(resolved.provider, 'openai-completions');
      expect(resolved.unknownSavedProvider, isNull);
    });

    test('an endpoint-locked kind over a foreign saved baseUrl degrades '
        'as a PAIR (gh-760 review)', () {
      // The realistic partial write: provider overwritten on an existing
      // config, stale baseUrl kept. Codex speaks the OAuth wire on
      // chatgpt.com only — restoring it over the mock/openrouter endpoint
      // would die at the key gate with self-contradictory guidance.
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(
          providerKind: 'chatgpt-codex',
          modelId: 'gpt-5-codex',
          baseUrl: 'https://openrouter.ai/api/v1',
        ),
        env: const {},
      );
      expect(resolved.provider, 'openai-completions');
      expect(resolved.unknownSavedProvider, isNull);
      expect(resolved.incompatibleSavedEndpoint, 'chatgpt-codex');
      // The same for the catalog NAME form.
      final byName = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(
          providerKind: 'chatgpt',
          modelId: 'gpt-5-codex',
          baseUrl: 'http://127.0.0.1:9/v1',
        ),
        env: const {},
      );
      expect(byName.provider, 'openai-completions');
      expect(byName.incompatibleSavedEndpoint, 'chatgpt');
    });

    test('an endpoint-locked kind on its OWN endpoint restores (gh-760 '
        'review)', () {
      final ownBase = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(
          providerKind: 'chatgpt-codex',
          modelId: 'gpt-5-codex',
          baseUrl: resolveCliProviderSpec('chatgpt-codex')!.defaultBaseUrl,
        ),
        env: const {},
      );
      expect(ownBase.provider, 'chatgpt-codex');
      expect(ownBase.incompatibleSavedEndpoint, isNull);
      // An explicit --provider is full manual control: no pair judgement.
      final explicit = resolveEffectiveCliArgs(
        const CliArgs(
          provider: 'chatgpt-codex',
          providerExplicit: true,
          baseUrl: 'http://127.0.0.1:9/v1',
        ),
        CliConfig(),
        env: const {},
      );
      expect(explicit.provider, 'chatgpt-codex');
      expect(explicit.incompatibleSavedEndpoint, isNull);
    });

    test('an unknown saved kind is not reported when a declaration '
        'overrides it', () {
      final explicit = resolveEffectiveCliArgs(
        const CliArgs(provider: 'anthropic', providerExplicit: true),
        CliConfig(providerKind: 'from-the-future'),
        env: const {},
      );
      expect(explicit.provider, 'anthropic');
      expect(explicit.unknownSavedProvider, isNull);
      final preconfig = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(providerKind: 'from-the-future'),
        env: const {
          'FA_PROVIDER_TYPE': 'openai-completions',
          'FA_PROVIDER_NAME': 'local',
          'FA_PROVIDER_CONFIG':
              '{"baseUrl":"http://localhost:8080/v1","model":"qwen3",'
              '"apiKeyEnvVar":"LOCAL_KEY"}',
          'LOCAL_KEY': 'sk-test',
        },
      );
      expect(preconfig.provider, 'openai-completions');
      expect(preconfig.unknownSavedProvider, isNull);
    });

    test('model, baseUrl and mode fall back to the saved config', () {
      final resolved = resolveEffectiveCliArgs(
        const CliArgs(),
        CliConfig(
          modelId: 'saved/model',
          baseUrl: 'https://saved.example/api',
          mode: 'architect',
        ),
        env: const {},
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
        env: const {},
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

    test('collects the endpoint-scoped slots of custom-endpoint refs '
        '(gh-1000 AC5)', () {
      final names = roleKeyNames(
        ModelRolesConfig(
          roles: {
            'smol': const [
              ModelRef(
                provider: 'openai',
                modelId: 'k3-256k',
                baseUrl: 'https://api.kimi.com/coding/v1',
              ),
            ],
          },
        ),
      );
      expect(names, {
        CustomProviderRegistry.keyNameFor('https://api.kimi.com/coding/v1'),
      });
    });

    test('a catalog-default ref adds no endpoint slot', () {
      final names = roleKeyNames(
        ModelRolesConfig(
          roles: {
            'default': const [
              ModelRef(
                provider: 'openrouter',
                modelId: 'm1',
                baseUrl: _openrouter,
              ),
            ],
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

    test('the endpoint-scoped slot of a custom-endpoint ref is collected '
        '(gh-1000 AC6)', () async {
      final config = ModelRolesConfig(
        roles: {
          'smol': const [
            ModelRef(
              provider: 'openai',
              modelId: 'k3-256k',
              baseUrl: 'https://api.kimi.com/coding/v1',
            ),
          ],
        },
      );
      final scoped = CustomProviderRegistry.keyNameFor(
        'https://api.kimi.com/coding/v1',
      );
      final secrets = collectRoleSecrets(
        config,
        await _cache({scoped: 'sk-store'}),
        env: const {},
      );
      expect(secrets[scoped], 'sk-store');
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

    test(
      'a headless RESTORE names the pinned key slot, not the catalog env',
      () {
        expect(
          () => startupApiKey(
            'openai-completions',
            SecureKeyCache(null),
            baseUrl: _openrouter,
            customProviders: const [],
            defaultRoleResolved: false,
            interactive: false,
            env: const {},
            pinnedKeyName: 'FA_KEY_API_KIMI_COM_KIMI_ME',
          ),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('restored provider'),
                contains('/key set FA_KEY_API_KIMI_COM_KIMI_ME'),
                isNot(contains('OPENROUTER_API_KEY')),
              ),
            ),
          ),
        );
      },
    );

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

    test('gh-1059 AC3: a seeded snapshot resolves every saved entry key BY '
        'keyName (H2 seam guard, multi-entry)', () async {
      // Owner-shaped: several saved custom providers, each with its own
      // name-scoped key, all values persisted in the store snapshot —
      // the boot key for the ACTIVE endpoint must resolve from the
      // entry's keyName (not the host-scoped slot, which is empty here).
      const active = 'https://api.chatgpt.com/v1';
      const other = 'https://api.z.ai/api/paas/v4';
      final customProviders = [
        CustomProviderEntry(
          name: 'chatgpt.com',
          apiType: 'openai',
          baseUrl: active,
          modelId: 'gpt-5',
          keyName: 'FA_KEY_CHATGPT_COM',
        ),
        CustomProviderEntry(
          name: 'z.ai',
          apiType: 'openai',
          baseUrl: other,
          modelId: 'glm-4.7',
          keyName: 'FA_KEY_Z_AI',
        ),
      ];
      final cache = await _cache({
        'FA_KEY_CHATGPT_COM': 'active-entry-key',
        'FA_KEY_Z_AI': 'other-entry-key',
      });

      final key = startupApiKey(
        'openai-completions',
        cache,
        baseUrl: active,
        customProviders: customProviders,
        defaultRoleResolved: false,
        interactive: false,
        env: const {},
      );

      expect(key, 'active-entry-key');

      // Interactive boot (the owner's REPL case) resolves the same way.
      expect(
        startupApiKey(
          'openai-completions',
          cache,
          baseUrl: active,
          customProviders: customProviders,
          defaultRoleResolved: false,
          interactive: true,
          env: const {},
        ),
        'active-entry-key',
      );
    });

    test('gh-1059 AC3: an empty snapshot reads as keyless (the reported '
        'symptom, H1 discriminator)', () async {
      const active = 'https://api.chatgpt.com/v1';
      final cache = await _cache({});

      final key = startupApiKey(
        'openai-completions',
        cache,
        baseUrl: active,
        customProviders: [
          CustomProviderEntry(
            name: 'chatgpt.com',
            apiType: 'openai',
            baseUrl: active,
            modelId: 'gpt-5',
            keyName: 'FA_KEY_CHATGPT_COM',
          ),
        ],
        defaultRoleResolved: false,
        interactive: true,
        env: const {},
      );

      // The resolution seam consults the snapshot correctly — an EMPTY
      // snapshot is the only way providers boot keyless, which pins the
      // bug to the preload/read path (H1), not this seam (H2).
      expect(key, isEmpty);
    });
  });

  group('referencedSecureKeyNames + secureKeyBootDiagnostics (gh-1059)', () {
    final savedWithKeys = CliConfig(
      customProviders: [
        CustomProviderEntry(
          name: 'chatgpt.com',
          apiType: 'openai',
          baseUrl: 'https://api.chatgpt.com/v1',
          modelId: 'gpt-5',
          keyName: 'FA_KEY_CHATGPT_COM',
        ),
        CustomProviderEntry(
          name: 'z.ai',
          apiType: 'openai',
          baseUrl: 'https://api.z.ai/api/paas/v4',
          modelId: 'glm-4.7',
          keyName: 'FA_KEY_Z_AI',
        ),
        CustomProviderEntry(
          name: 'keyless-local',
          apiType: 'openai',
          baseUrl: 'http://llama.local:8080',
          modelId: 'm1',
        ),
      ],
    );

    test('referenced names are exactly the saved entries keyNames', () {
      expect(referencedSecureKeyNames(savedWithKeys), {
        'FA_KEY_CHATGPT_COM',
        'FA_KEY_Z_AI',
      });
    });

    test('an env-only config references nothing', () {
      expect(referencedSecureKeyNames(CliConfig()), isEmpty);
    });

    test('debug: one line per outcome plus the summary', () {
      final report = SecureKeyPreloadReport(
        storeAvailable: true,
        outcomes: const [
          SecureKeyReadOutcome(
            'FA_KEY_CHATGPT_COM',
            SecureKeyReadStatus.found,
            value: 'x',
          ),
          SecureKeyReadOutcome('FA_KEY_Z_AI', SecureKeyReadStatus.absent),
          SecureKeyReadOutcome(
            'OPENAI_API_KEY',
            SecureKeyReadStatus.error,
            error: 'exit 45: Interaction is not allowed.',
          ),
        ],
      );

      final lines = secureKeyBootDiagnostics(
        report: report,
        referencedKeyNames: referencedSecureKeyNames(savedWithKeys),
        debug: true,
        storeLabel: 'macOS Keychain',
      );

      expect(lines, contains('[keys] FA_KEY_CHATGPT_COM: found'));
      expect(lines, contains('[keys] FA_KEY_Z_AI: absent'));
      expect(
        lines,
        contains(
          '[keys] OPENAI_API_KEY: error: exit 45: Interaction is '
          'not allowed.',
        ),
      );
      expect(
        lines.lastWhere((l) => l.startsWith('[keys] ')),
        contains('2 config-referenced, 1 found, 1 absent, 1 errors'),
      );
      // Some referenced keys resolved → no zero-resolved warning.
      expect(lines.where((l) => l.startsWith('warning:')), isEmpty);
    });

    test('zero referenced keys resolved → the NOTHING warning plus a '
        'per-name list of the errored reads', () {
      SecureKeyPreloadReport reportOf(List<SecureKeyReadOutcome> outcomes) =>
          SecureKeyPreloadReport(storeAvailable: true, outcomes: outcomes);
      final referenced = referencedSecureKeyNames(savedWithKeys);

      for (final debug in [false, true]) {
        final lines = secureKeyBootDiagnostics(
          report: reportOf(const [
            SecureKeyReadOutcome(
              'FA_KEY_CHATGPT_COM',
              SecureKeyReadStatus.error,
              error: 'timed out after 15s',
            ),
            SecureKeyReadOutcome('FA_KEY_Z_AI', SecureKeyReadStatus.absent),
          ]),
          referencedKeyNames: referenced,
          debug: debug,
        );
        final warnings = lines.where((l) => l.startsWith('warning:'));
        expect(warnings, hasLength(2), reason: 'debug=$debug');
        expect(warnings.first, contains('2 provider key(s)'));
        expect(warnings.first, contains('resolved NOTHING'));
        // gh-1059 review: `error` means the store ANSWERED and failed —
        // worth naming even though the NOTHING line already fired.
        expect(warnings.last, contains('1 provider key(s)'));
        expect(warnings.last, contains('failed to read'));
        expect(warnings.last, contains('FA_KEY_CHATGPT_COM'));
      }
    });

    test('a partial read failure warns per-name even though other '
        'referenced keys resolve (debug off)', () {
      final lines = secureKeyBootDiagnostics(
        report: const SecureKeyPreloadReport(
          storeAvailable: true,
          outcomes: [
            SecureKeyReadOutcome(
              'FA_KEY_CHATGPT_COM',
              SecureKeyReadStatus.found,
              value: 'x',
            ),
            SecureKeyReadOutcome(
              'FA_KEY_Z_AI',
              SecureKeyReadStatus.error,
              error: 'exit 45: interaction not allowed',
            ),
          ],
        ),
        referencedKeyNames: referencedSecureKeyNames(savedWithKeys),
        debug: false,
      );
      final warnings = lines.where((l) => l.startsWith('warning:'));
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('1 provider key(s)'));
      expect(warnings.single, contains('failed to read'));
      expect(warnings.single, contains('FA_KEY_Z_AI'));
      expect(warnings.single, contains('--debug-secrets'));
    });

    test('an env-only boot (nothing referenced) never warns', () {
      final lines = secureKeyBootDiagnostics(
        report: const SecureKeyPreloadReport(
          storeAvailable: true,
          outcomes: [],
        ),
        referencedKeyNames: referencedSecureKeyNames(CliConfig()),
        debug: false,
      );
      expect(lines, isEmpty);
    });

    test('an unavailable store stays quiet for env-only configs but warns '
        'when the config references store keys', () {
      final base = {
        'report': const SecureKeyPreloadReport(
          storeAvailable: false,
          outcomes: [],
        ),
        'debug': false,
      };
      // Env-only: nothing referenced, nothing to warn about.
      expect(
        secureKeyBootDiagnostics(
          report: base['report'] as SecureKeyPreloadReport,
          referencedKeyNames: const {},
          debug: base['debug'] as bool,
        ),
        isEmpty,
      );
      // Referenced keys + no backend: the boot is keyless for them — loud.
      final lines = secureKeyBootDiagnostics(
        report: base['report'] as SecureKeyPreloadReport,
        referencedKeyNames: {'FA_KEY_CHATGPT_COM', 'FA_KEY_Z_AI'},
        debug: false,
      );
      expect(lines, hasLength(1));
      expect(lines.single, contains('2 provider key(s)'));
      expect(lines.single, contains('store unavailable'));
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
