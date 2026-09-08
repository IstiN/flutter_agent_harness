// Issue #40 regression: on a CUSTOM endpoint the catalog env names are
// never in play — `OPENROUTER_API_KEY` exported for OpenRouter must not
// serve api.z.ai (the boot key resolution and the banner/error renderer
// both follow the shared resolveEndpointKey chain).
import 'package:flutter_agent_harness/src/cli/headless_provider_key.dart';
import 'package:flutter_agent_harness/src/cli/key_status.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/secrets/secure_key_store.dart';
import 'package:test/test.dart';
import 'agent_cli_test_support.dart';

void main() {
  const zaiUrl = 'https://api.z.ai/api/coding/paas/v4';
  const openRouterUrl = 'https://openrouter.ai/api/v1';
  const zaiKeyName = 'FA_KEY_API_Z_AI';

  Model modelOf(String baseUrl) => Model(
    id: 'glm-5.3-flash',
    api: 'openai-completions',
    provider: 'openai',
    baseUrl: baseUrl,
    contextWindow: 200000,
    maxTokens: 16384,
  );

  Future<KeyStatusRenderer> rendererOf({
    required Map<String, String> env,
    required FakeSecureKeyStore store,
  }) async {
    final keys = SecureKeyCache(store);
    await keys.preload(store.map.keys.toList());
    return KeyStatusRenderer(
      rolesDriven: false,
      providerKind: 'openai-completions',
      explicitToken: false,
      activeCustomName: null,
      red: (message) => message,
      secureKeys: keys,
      envVarIsSet: (name) => env.containsKey(name),
      envVarValue: (name) => env[name],
    );
  }

  group('keyStatusLine (issue #40: env key must not hijack a custom '
      'endpoint)', () {
    test('a custom endpoint ignores the exported OPENROUTER_API_KEY', () async {
      final renderer = await rendererOf(
        env: const {'OPENROUTER_API_KEY': 'sk-openrouter'},
        store: FakeSecureKeyStore(),
      );

      expect(renderer.keyStatusLine(modelOf(zaiUrl)), isNull);
    });

    test('a custom endpoint names its endpoint-scoped store key', () async {
      final renderer = await rendererOf(
        env: const {'OPENROUTER_API_KEY': 'sk-openrouter'},
        store: FakeSecureKeyStore()..map[zaiKeyName] = 'sk-zai',
      );

      expect(renderer.keyStatusLine(modelOf(zaiUrl)), 'key: $zaiKeyName');
    });

    test('the default endpoint still resolves the catalog env key', () async {
      final renderer = await rendererOf(
        env: const {'OPENROUTER_API_KEY': 'sk-openrouter'},
        store: FakeSecureKeyStore(),
      );

      expect(
        renderer.keyStatusLine(modelOf(openRouterUrl)),
        'key: OPENROUTER_API_KEY',
      );
    });
  });

  group('authHint (issue #40: the 401 diagnostic must not blame the '
      'environment on a custom endpoint)', () {
    test(
      'a custom endpoint with only a foreign env key says no key set',
      () async {
        final renderer = await rendererOf(
          env: const {'OPENROUTER_API_KEY': 'sk-openrouter'},
          store: FakeSecureKeyStore(),
        );

        final hint = renderer.authHint(zaiUrl);

        expect(hint, isNot(contains('came from the environment')));
        expect(hint, contains('/key set $zaiKeyName'));
      },
    );

    test('a custom endpoint names its endpoint-scoped store key', () async {
      final renderer = await rendererOf(
        env: const {'OPENROUTER_API_KEY': 'sk-openrouter'},
        store: FakeSecureKeyStore()..map[zaiKeyName] = 'sk-zai',
      );

      expect(renderer.authHint(zaiUrl), contains('came from the fake store'));
    });

    test('the default endpoint still names the environment source', () async {
      final renderer = await rendererOf(
        env: const {'OPENROUTER_API_KEY': 'sk-openrouter'},
        store: FakeSecureKeyStore(),
      );

      expect(
        renderer.authHint(openRouterUrl),
        contains('came from the environment (OPENROUTER_API_KEY)'),
      );
    });
  });

  group('boot resolution parity (optionalProviderApiKey)', () {
    test('a custom endpoint ignores the exported catalog env key', () async {
      final store = FakeSecureKeyStore()..map[zaiKeyName] = 'sk-zai';
      final keys = SecureKeyCache(store);
      await keys.preload([zaiKeyName]);

      final key = optionalProviderApiKey(
        'openai-completions',
        keys,
        baseUrl: zaiUrl,
        env: const {'OPENROUTER_API_KEY': 'sk-openrouter'},
      );

      expect(key, 'sk-zai');
    });

    test(
      'a custom endpoint ignores legacy env-name store entries too',
      () async {
        final store = FakeSecureKeyStore()
          ..map['OPENROUTER_API_KEY'] = 'sk-stored-openrouter';
        final keys = SecureKeyCache(store);
        await keys.preload(const ['OPENROUTER_API_KEY']);

        final key = optionalProviderApiKey(
          'openai-completions',
          keys,
          baseUrl: zaiUrl,
          env: const {},
        );

        expect(key, isNull);
      },
    );

    test('the default endpoint keeps the env-first order', () {
      final keys = SecureKeyCache(FakeSecureKeyStore());

      final key = optionalProviderApiKey(
        'openai-completions',
        keys,
        baseUrl: openRouterUrl,
        env: const {'OPENROUTER_API_KEY': 'sk-openrouter'},
      );

      expect(key, 'sk-openrouter');
    });

    test('a keyless custom endpoint (local llama.cpp) still resolves null', () {
      final keys = SecureKeyCache(FakeSecureKeyStore());

      final key = optionalProviderApiKey(
        'openai-completions',
        keys,
        baseUrl: 'http://localhost:8080/v1',
        env: const {},
      );

      expect(key, isNull);
    });
  });
}
