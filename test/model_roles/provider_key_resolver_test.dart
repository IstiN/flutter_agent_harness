// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  const envNames = ['OPENROUTER_API_KEY'];
  const defaultUrl = 'https://openrouter.ai/api/v1';

  String? Function(String) envOf(Map<String, String> env) =>
      (name) => env[name];
  String? Function(String) storeOf(Map<String, String> store) =>
      (name) => store[name];

  group('resolveEndpointKey (the CLI/app shared chain)', () {
    test('a genuine environment value wins over the store', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: defaultUrl,
        envRead: envOf({'OPENROUTER_API_KEY': 'sk-env'}),
        storeRead: storeOf({'OPENROUTER_API_KEY': 'sk-stored'}),
      );
      expect(key, 'sk-env');
    });

    test('an env-looking value that merely mirrors the store does not count '
        'as a genuine environment value', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: defaultUrl,
        envRead: envOf({'OPENROUTER_API_KEY': 'sk-same'}),
        storeRead: storeOf({'OPENROUTER_API_KEY': 'sk-same'}),
      );
      expect(key, 'sk-same'); // via the legacy env-name store entry
    });

    test('the host-scoped FA_KEY_<HOST> entry beats the legacy env-name '
        'store entry', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: defaultUrl,
        envRead: envOf(const {}),
        storeRead: storeOf({
          'OPENROUTER_API_KEY': 'sk-legacy',
          'FA_KEY_OPENROUTER_AI': 'sk-scoped',
        }),
      );
      expect(key, 'sk-scoped');
    });

    test('custom endpoints resolve ONLY scoped store keys — catalog env '
        'names never hijack another endpoint', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: 'https://api.acme.example/v1',
        envRead: envOf({'OPENROUTER_API_KEY': 'sk-env'}),
        storeRead: storeOf({'OPENROUTER_API_KEY': 'sk-stored'}),
      );
      expect(key, isNull);
    });

    test('a custom endpoint resolves its host-scoped store key', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: 'https://api.acme.example/v1',
        envRead: envOf(const {}),
        storeRead: storeOf({'FA_KEY_API_ACME_EXAMPLE': 'sk-acme'}),
      );
      expect(key, 'sk-acme');
    });

    test('the active custom entry key name wins over the host-scoped one', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: 'https://api.acme.example/v1',
        envRead: envOf(const {}),
        storeRead: storeOf({
          'FA_KEY_API_ACME_EXAMPLE': 'sk-host',
          'FA_KEY_API_ACME_EXAMPLE_WORK': 'sk-named',
        }),
        activeCustomKeyName: 'FA_KEY_API_ACME_EXAMPLE_WORK',
      );
      expect(key, 'sk-named');
    });

    test('a null store resolves env-only (web/tests)', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: defaultUrl,
        envRead: envOf({'OPENROUTER_API_KEY': 'sk-env'}),
        storeRead: null,
      );
      expect(key, 'sk-env');
    });
  });

  group('resolveEndpointKeyName (the host-facing slot chain, #1322 Gap 2)', () {
    test('a genuine environment value names the env var', () {
      final name = resolveEndpointKeyName(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: defaultUrl,
        envRead: envOf({'OPENROUTER_API_KEY': 'sk-env'}),
        storeRead: storeOf({'OPENROUTER_API_KEY': 'sk-stored'}),
      );
      expect(name, 'OPENROUTER_API_KEY');
    });

    test('the canonical FA_KEY_<HOST> slot when only the store holds it', () {
      final name = resolveEndpointKeyName(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: defaultUrl,
        envRead: envOf(const {}),
        storeRead: storeOf({'FA_KEY_OPENROUTER_AI': 'sk-scoped'}),
      );
      expect(name, 'FA_KEY_OPENROUTER_AI');
    });

    test('a legacy env-name store entry names the env var', () {
      final name = resolveEndpointKeyName(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: defaultUrl,
        envRead: envOf(const {}),
        storeRead: storeOf({'OPENROUTER_API_KEY': 'sk-legacy'}),
      );
      expect(name, 'OPENROUTER_API_KEY');
    });

    test('the active custom entry slot wins on a custom endpoint', () {
      final name = resolveEndpointKeyName(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: 'https://api.acme.example/v1',
        envRead: envOf(const {}),
        storeRead: storeOf({
          'FA_KEY_API_ACME_EXAMPLE': 'sk-host',
          'FA_KEY_API_ACME_EXAMPLE_WORK': 'sk-named',
        }),
        activeCustomKeyName: 'FA_KEY_API_ACME_EXAMPLE_WORK',
      );
      expect(name, 'FA_KEY_API_ACME_EXAMPLE_WORK');
    });

    test('null when nothing resolves', () {
      final name = resolveEndpointKeyName(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: 'https://api.acme.example/v1',
        envRead: envOf(const {}),
        storeRead: storeOf(const {}),
      );
      expect(name, isNull);
    });
  });

  group('HostKeyResolver (#1322 Gap 2 — the kimi/z.ai slot scenarios)', () {
    // The issue's exact trap: a host bound the CANONICAL slot (absent)
    // while the Keychain held a by-design pinned twin. The resolver must
    // name the pinned slot the request path actually uses — and warn.
    test('canonical empty + pinned twin held: the pinned slot wins, with '
        'a drift hint', () {
      final resolution = kimiResolver.resolveKey(
        provider: 'kimi',
        baseUrl: 'https://api.kimi.com',
        activeCustomKeyName: 'FA_KEY_API_KIMI_COM_IRA_1',
      );
      expect(resolution.slotName, 'FA_KEY_API_KIMI_COM_IRA_1');
      expect(resolution.canonicalName, 'FA_KEY_API_KIMI_COM');
      expect(resolution.fromEnv, isFalse);
      expect(
        resolution.driftHint,
        allOf(
          contains('FA_KEY_API_KIMI_COM_IRA_1'),
          contains('/key set FA_KEY_API_KIMI_COM <value>'),
          contains('/key delete FA_KEY_API_KIMI_COM_IRA_1'),
        ),
      );
      expect(resolution.missingKeyHint, isNull);
    });

    test('the pre-gh-1226 doubled z.ai slot drifts the same way', () {
      final resolution = kimiResolver
          .rebind(store: {'FA_KEY_API_Z_AI_Z_AI': 'sk-zai'})
          .resolveKey(
            baseUrl: 'https://api.z.ai',
            activeCustomKeyName: 'FA_KEY_API_Z_AI_Z_AI',
          );
      expect(resolution.slotName, 'FA_KEY_API_Z_AI_Z_AI');
      expect(resolution.canonicalName, 'FA_KEY_API_Z_AI');
      expect(resolution.driftHint, isNotNull);
    });

    test('a twin-present drift names the same-endpoint entry', () {
      final resolution = kimiResolver
          .rebind(
            store: {
              'FA_KEY_API_KIMI_COM': 'sk-canonical',
              'FA_KEY_API_KIMI_COM_IRA_1': 'sk-ira',
            },
          )
          .resolveKey(
            baseUrl: 'https://api.kimi.com',
            activeCustomKeyName: 'FA_KEY_API_KIMI_COM_IRA_1',
          );
      expect(resolution.slotName, 'FA_KEY_API_KIMI_COM_IRA_1');
      expect(
        resolution.driftHint,
        contains('a same-endpoint entry already uses "FA_KEY_API_KIMI_COM"'),
      );
    });

    test('a clean canonical slot produces no drift hint', () {
      final resolution = kimiResolver
          .rebind(store: {'FA_KEY_API_KIMI_COM': 'sk-canonical'})
          .resolveKey(baseUrl: 'https://api.kimi.com');
      expect(resolution.slotName, 'FA_KEY_API_KIMI_COM');
      expect(resolution.driftHint, isNull);
    });

    test('a known pinned twin wins over an empty canonical (the wiring-time '
        'registry leg)', () {
      final resolution = kimiResolver
          .rebind(
            store: const {
              'FA_KEY_API_KIMI_COM_IRA_1': 'sk-ira',
              'FA_KEY_API_KIMI_ME': 'sk-me',
            },
            knownSlots: const [
              'FA_KEY_API_KIMI_COM_IRA_1',
              'FA_KEY_API_KIMI_ME',
            ],
          )
          .resolveKey(provider: 'kimi', baseUrl: 'https://api.kimi.com');
      expect(resolution.slotName, 'FA_KEY_API_KIMI_COM_IRA_1');
      expect(
        resolution.driftHint,
        allOf(
          contains('/key set FA_KEY_API_KIMI_COM <value>'),
          contains('/key delete FA_KEY_API_KIMI_COM_IRA_1'),
        ),
      );
      expect(resolution.missingKeyHint, isNull);
    });

    test('nothing resolved produces the missing-key hint naming the '
        'canonical slot', () {
      final resolution = kimiResolver.resolveKey(
        provider: 'kimi',
        baseUrl: 'https://api.kimi.com',
      );
      expect(resolution.slotName, isNull);
      expect(
        resolution.missingKeyHint,
        allOf(
          contains('provider "kimi"'),
          contains('/key set FA_KEY_API_KIMI_COM <value>'),
        ),
      );
    });

    test('without catalog facts the env-name leg can never hijack a custom '
        'endpoint (store-only resolution)', () {
      final resolution = kimiResolver
          .rebind(env: {'OPENROUTER_API_KEY': 'sk-env'})
          .resolveKey(
            baseUrl: 'https://api.z.ai',
            // envNames supplied, but no defaultBaseUrl: the host did not
            // declare the catalog, so env names must be ignored here.
            envNames: const ['OPENROUTER_API_KEY'],
          );
      expect(resolution.slotName, isNull);
    });

    test('with catalog facts the default endpoint resolves the env leg', () {
      final resolution = kimiResolver
          .rebind(env: {'OPENROUTER_API_KEY': 'sk-env'})
          .resolveKey(
            baseUrl: defaultUrl,
            envNames: envNames,
            defaultBaseUrl: defaultUrl,
          );
      expect(resolution.slotName, 'OPENROUTER_API_KEY');
      expect(resolution.fromEnv, isTrue);
    });
  });

  group('AgentCoreServices.resolveKey (the one-line host ask)', () {
    test('delegates to the injected resolver', () {
      final services = AgentCoreServices(
        baseEnv: MemoryExecutionEnv(cwd: '/w'),
        keyResolver: HostKeyResolver(envRead: _nullRead, storeRead: _nullRead),
      );
      final resolution = services.resolveKey(
        provider: 'kimi',
        baseUrl: 'https://api.kimi.com',
        model: 'kimi-k2',
      );
      expect(resolution, isNotNull);
      expect(resolution!.canonicalName, 'FA_KEY_API_KIMI_COM');
    });

    test('null without a resolver (the host resolves its own way)', () {
      final services = AgentCoreServices(
        baseEnv: MemoryExecutionEnv(cwd: '/w'),
      );
      expect(services.resolveKey(baseUrl: 'https://api.kimi.com'), isNull);
    });
  });
}

String? _nullRead(String name) => null;

// The issue's macOS-Keychain shape: canonical slot absent, two pinned
// per-account twins held.
final kimiResolver = HostKeyResolver(
  envRead: _nullRead,
  storeRead: (name) => switch (name) {
    'FA_KEY_API_KIMI_COM_IRA_1' => 'sk-ira',
    'FA_KEY_API_KIMI_ME' => 'sk-me',
    _ => null,
  },
);

extension _HostKeyResolverRebind on HostKeyResolver {
  HostKeyResolver rebind({
    Map<String, String> store = const {},
    Map<String, String> env = const {},
    Iterable<String> knownSlots = const [],
  }) => HostKeyResolver(
    envRead: (n) => env[n],
    storeRead: (n) => store[n],
    knownSlotNames: knownSlots,
  );
}
