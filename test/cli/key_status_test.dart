// Issue #40 regression: on a CUSTOM endpoint the catalog env names are
// never in play — `OPENROUTER_API_KEY` exported for OpenRouter must not
// serve api.z.ai (the boot key resolution and the banner/error renderer
// both follow the shared resolveEndpointKey chain).
import 'package:flutter_agent_harness/src/cli/custom_providers.dart';
import 'package:flutter_agent_harness/src/cli/headless_provider_key.dart';
import 'package:flutter_agent_harness/src/cli/key_status.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/providers/chatgpt_oauth.dart';
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
    String providerKind = 'openai-completions',
    String? activeCustomName,
    CustomProviderRegistry? registry,
  }) async {
    final keys = SecureKeyCache(store);
    await keys.preload(store.map.keys.toList());
    return KeyStatusRenderer(
      rolesDriven: false,
      providerKind: providerKind,
      explicitToken: false,
      activeCustomName: activeCustomName,
      red: (message) => message,
      secureKeys: keys,
      customProviders: registry,
      envVarIsSet: (name) => env.containsKey(name),
      envVarValue: (name) => env[name],
    );
  }

  group('errorLine attempted-provider diagnosis (gh-1226 AC2)', () {
    // The ticket's verbatim failure — what CopilotAuthException's
    // toString() returns from the copilot token exchange (lib/src/
    // providers/copilot_oauth.dart). The old synthetic
    // '(github-copilot api)' marker never occurs in production.
    const copilotExchangeFailure =
        'GitHub token rejected (401) by the Copilot token exchange — '
        're-authorize Copilot (CLI: /provider copilot).';
    const zaiFailure = '401 Unauthorized: invalid key for api.z.ai';
    const doubledZaiKeyName = 'FA_KEY_API_Z_AI_Z_AI';

    // The production wiring (agent_cli_run.dart's _keyStatusView): the
    // renderer holds BOTH the believed binding (a z.ai session) and the
    // custom registry, with the gh-1226-doubled slot actually holding a
    // value — the exact state that produced the fused guidance.
    Future<KeyStatusRenderer> productionWiredZaiRenderer() async {
      return rendererOf(
        env: const {},
        store: FakeSecureKeyStore()..map[doubledZaiKeyName] = 'sk-zai',
        providerKind: 'zai',
        activeCustomName: 'z.ai',
        registry: CustomProviderRegistry([
          CustomProviderEntry(
            name: 'z.ai',
            apiType: 'zai',
            baseUrl: zaiUrl,
            modelId: 'glm-5.3-flash',
            keyName: doubledZaiKeyName,
          ),
        ]),
      );
    }

    test(
      'the ticket’s exact copilot exchange failure on a z.ai-bound '
      'session names only copilot — no z.ai slot, no z.ai endpoint',
      () async {
        final renderer = await productionWiredZaiRenderer();

        // The endpoint the binding believes (z.ai): the diagnosis must
        // follow the ATTEMPTED provider (copilot), not this binding.
        final line = renderer.errorLine(copilotExchangeFailure, zaiUrl);

        expect(line, contains('copilot'));
        expect(
          line,
          isNot(contains(doubledZaiKeyName)),
          reason:
              'the believed entry’s (doubled) z.ai key slot must not '
              'leak into a copilot diagnosis (gh-1226 AC2)',
        );
        expect(line, isNot(contains('api.z.ai')));
      },
    );

    test(
      'the doubled z.ai slot is never consulted even though it holds a '
      'value — the attempted-provider path skips the believed entry',
      () async {
        final renderer = await productionWiredZaiRenderer();

        final hint = renderer.authHintForAttempt(
          copilotExchangeFailure,
          zaiUrl,
        );

        expect(hint, isNot(contains(doubledZaiKeyName)));
        expect(hint, isNot(contains(zaiKeyName)));
      },
    );

    test('a z.ai failure names the z.ai slot even when the binding believes '
        'another provider — the hint follows the attempted provider', () async {
      final renderer = await rendererOf(
        env: const {},
        store: FakeSecureKeyStore()..map[zaiKeyName] = 'sk-zai',
        providerKind: 'copilot',
        activeCustomName: null,
      );

      expect(renderer.errorLine(zaiFailure, zaiUrl), contains(zaiKeyName));
    });
  });

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

    test(
      'a trailing-slash default endpoint keeps the environment source',
      () async {
        // Saved entries and resolved endpoints disagree on the trailing slash
        // routinely — ONE endpoint-equality rule for both helpers (round-3
        // review): this must read as the CATALOG default, not a custom slot.
        final renderer = await rendererOf(
          env: const {'OPENROUTER_API_KEY': 'sk-openrouter'},
          store: FakeSecureKeyStore(),
        );

        expect(
          renderer.authHint('$openRouterUrl/'),
          contains('came from the environment (OPENROUTER_API_KEY)'),
        );
      },
    );
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

  group('keyStatusLine by provider kind (issue #772 identity)', () {
    test('the chatgpt-codex kind resolves the catalog env names', () async {
      final keys = SecureKeyCache(FakeSecureKeyStore());
      final renderer = KeyStatusRenderer(
        rolesDriven: false,
        providerKind: 'chatgpt-codex',
        explicitToken: false,
        activeCustomName: null,
        red: (message) => message,
        secureKeys: keys,
        envVarIsSet: (name) => name == 'CHATGPT_OAUTH_CREDENTIALS',
        envVarValue: (name) =>
            name == 'CHATGPT_OAUTH_CREDENTIALS' ? 'blob' : null,
      );
      final model = Model(
        id: 'gpt-5-codex',
        api: 'responses',
        provider: 'chatgpt',
        baseUrl: chatGptCodexBaseUrl,
        contextWindow: 128000,
        maxTokens: 16384,
      );
      expect(renderer.keyStatusLine(model), isNotNull);
    });
  });

  group('authHint under roles mode (gh-1000 AC2)', () {
    const kimiUrl = 'https://api.kimi.com/coding/v1';
    const kimiMeKey = 'FA_KEY_API_KIMI_COM_KIMI_ME';

    Future<KeyStatusRenderer> rolesRendererOf({
      Map<String, String> env = const {},
      FakeSecureKeyStore? store,
      CustomProviderRegistry? registry,
      String? activeCustomName,
    }) async {
      final keys = SecureKeyCache(store ?? FakeSecureKeyStore());
      await keys.preload(store == null ? const [] : store.map.keys.toList());
      return KeyStatusRenderer(
        rolesDriven: true,
        providerKind: 'openai-completions',
        explicitToken: false,
        activeCustomName: activeCustomName,
        red: (message) => message,
        secureKeys: keys,
        customProviders: registry,
        envVarIsSet: (name) => env.containsKey(name),
        envVarValue: (name) => env[name],
      );
    }

    test('a catalog default endpoint keeps the generic roles hint', () async {
      final renderer = await rolesRendererOf();
      expect(
        renderer.authHint(openRouterUrl),
        contains('roles mode reads keys from the environment only'),
      );
    });

    test(
      'a custom endpoint never shows the generic roles hint (AC2)',
      () async {
        final renderer = await rolesRendererOf();
        expect(
          renderer.authHint(kimiUrl),
          isNot(contains('roles mode reads keys from the environment only')),
        );
      },
    );

    test(
      'a custom endpoint names the saved entry and its key slot (AC2)',
      () async {
        final renderer = await rolesRendererOf(
          registry: CustomProviderRegistry([
            CustomProviderEntry(
              name: 'kimi_me',
              apiType: 'openai',
              baseUrl: kimiUrl,
              modelId: 'k3-256k',
              keyName: kimiMeKey,
            ),
          ]),
          activeCustomName: 'kimi_me',
        );
        final hint = renderer.authHint(kimiUrl);
        expect(hint, contains('kimi_me'));
        expect(hint, contains('/key set $kimiMeKey'));
      },
    );

    test('a stored key names the store as the source to verify', () async {
      final renderer = await rolesRendererOf(
        store: FakeSecureKeyStore()..map[kimiMeKey] = 'sk-stale',
        registry: CustomProviderRegistry([
          CustomProviderEntry(
            name: 'kimi_me',
            apiType: 'openai',
            baseUrl: kimiUrl,
            modelId: 'k3-256k',
            keyName: kimiMeKey,
          ),
        ]),
        activeCustomName: 'kimi_me',
      );
      final hint = renderer.authHint(kimiUrl);
      expect(hint, contains(kimiMeKey));
      expect(hint, isNot(contains('sk-stale')));
    });

    test(
      'a custom endpoint without a saved entry names the scoped slot',
      () async {
        final renderer = await rolesRendererOf();
        final hint = renderer.authHint(kimiUrl);
        expect(hint, contains('/key set FA_KEY_API_KIMI_COM'));
      },
    );
  });

  group('envShadowingNote (E2 — one provenance rule)', () {
    test('non-null only when the env value is non-empty and DIFFERENT', () {
      // No store entry = nothing shadowed (all three original copies agree).
      expect(envShadowingNote('K', 'env-1', null), isNull);
      expect(envShadowingNote('K', 'env-1', 'store-2'), isNotNull);
      expect(envShadowingNote('K', 'env-1', 'env-1'), isNull);
      expect(envShadowingNote('K', null, 'store-2'), isNull);
      expect(envShadowingNote('K', '', 'store-2'), isNull);
    });

    test('the note names the variable and the provenance order', () {
      final note = envShadowingNote('FA_KEY_X', 'env-1', 'store-2')!;
      expect(note, contains('FA_KEY_X'));
      expect(note, contains('DIFFERENT'));
      expect(note, contains('the env value is the one sent'));
    });

    test('an unwired envVarValue degrades conservatively: a store twin still '
        'warns (round-4 follow-up)', () async {
      Future<SecureKeyCache> cacheOf(FakeSecureKeyStore store) async {
        final keys = SecureKeyCache(store);
        await keys.preload(store.map.keys.toList());
        return keys;
      }

      // A store twin + no lookup = a real shadow: the hint only renders
      // when the env value is the one sent, so warn (pre-round-3
      // availability restored).
      final shadowed = KeyStatusRenderer(
        rolesDriven: false,
        providerKind: 'openai-completions',
        explicitToken: false,
        activeCustomName: null,
        red: (message) => message,
        secureKeys: await cacheOf(
          FakeSecureKeyStore()..map['FA_KEY_X'] = 'store-2',
        ),
      ).envKeyHint('FA_KEY_X', openRouterUrl);
      expect(shadowed, contains('shadows a DIFFERENT key'));

      // No store twin = nothing to shadow.
      final noTwin = KeyStatusRenderer(
        rolesDriven: false,
        providerKind: 'openai-completions',
        explicitToken: false,
        activeCustomName: null,
        red: (message) => message,
        secureKeys: await cacheOf(FakeSecureKeyStore()),
      ).envKeyHint('FA_KEY_X', openRouterUrl);
      expect(noTwin, isNot(contains('shadows a DIFFERENT key')));

      // Wired lookup that comes back equal stays precise: no warning.
      // (covered by envShadowingNote('K', 'env-1', 'env-1') above and
      // the wired renderer tests — listed here for the contract.)
    });
  });
}
