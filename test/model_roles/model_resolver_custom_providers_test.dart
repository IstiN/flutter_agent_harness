/// Issue #1552 — roles resolve `customProviders:` entries by name: the
/// hand-written `provider: aiai` chain entry works exactly like the
/// equivalent kind+baseUrl+apiKeyName spelling.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

StreamFunction _neverStream(String kind, String apiKey) =>
    (model, context, {cancelToken}) => throw StateError('no stream expected');

/// The user-report fixture shape (bycom.by): a saved entry named `aiai`
/// on an OpenAI-compatible endpoint, key under a dedicated env name.
CustomProviderEntry _bycom({String? keyName = 'AIAI_API_KEY'}) =>
    CustomProviderEntry(
      name: 'aiai',
      apiType: 'openai',
      baseUrl: 'https://api.bycom.by/v1',
      modelId: 'glm-4.6',
      keyName: keyName,
    );

ModelRolesResolver _resolver(
  Map<String, List<ModelRef>> roles, {
  Map<String, String> secrets = const {},
  List<CustomProviderEntry> customProviders = const [],
}) {
  return ModelRolesResolver(
    config: ModelRolesConfig(roles: roles),
    secrets: secrets,
    customProviders: customProviders,
    streamFactory: _neverStream,
  );
}

void main() {
  group('UT-1 — custom-name resolution (AC1)', () {
    test('`provider: aiai` resolves through the registry entry', () {
      final resolver = _resolver(
        {
          'default': [ModelRef(provider: 'aiai', modelId: 'glm-4.6')],
        },
        secrets: const {'AIAI_API_KEY': 'k'},
        customProviders: [_bycom()],
      );
      final entry = resolver.chainFor('default')!.single;
      expect(entry.model.provider, 'openai');
      expect(entry.model.api, 'openai-completions');
      expect(entry.model.baseUrl, 'https://api.bycom.by/v1');
      expect(entry.model.id, 'glm-4.6');
      expect(entry.keyRing.baseName, 'AIAI_API_KEY');
      expect(resolver.skippedEntries['default'] ?? [], isEmpty);
    });

    test('equivalence: the kind+baseUrl+apiKeyName spelling builds the '
        'same chain entry', () {
      final byName = _resolver(
        {
          'default': [ModelRef(provider: 'aiai', modelId: 'glm-4.6')],
        },
        secrets: const {'AIAI_API_KEY': 'k'},
        customProviders: [_bycom()],
      ).chainFor('default')!.single;
      final byKind = _resolver(
        {
          'default': [
            ModelRef(
              provider: 'openai',
              modelId: 'glm-4.6',
              baseUrl: 'https://api.bycom.by/v1',
              apiKeyName: 'AIAI_API_KEY',
            ),
          ],
        },
        secrets: const {'AIAI_API_KEY': 'k'},
      ).chainFor('default')!.single;
      expect(byName.model.provider, byKind.model.provider);
      expect(byName.model.api, byKind.model.api);
      expect(byName.model.baseUrl, byKind.model.baseUrl);
      expect(byName.model.id, byKind.model.id);
      expect(byName.model.contextWindow, byKind.model.contextWindow);
      expect(byName.keyRing.baseName, byKind.keyRing.baseName);
    });

    test('entry defaults: a keyless-looking entry resolves the '
        'endpoint-scoped slot', () {
      final resolver = _resolver(
        {
          'default': [ModelRef(provider: 'aiai', modelId: 'glm-4.6')],
        },
        secrets: const {'FA_KEY_API_BYCOM_BY': 'k'},
        customProviders: [_bycom(keyName: null)],
      );
      final entry = resolver.chainFor('default')!.single;
      expect(entry.model.baseUrl, 'https://api.bycom.by/v1');
      expect(entry.keyRing.baseName, 'FA_KEY_API_BYCOM_BY');
    });

    test('a keyName pinned on the ENTRY defaults the key resolution', () {
      // Bare ref (no apiKeyName): the entry's own pin carries it — the
      // collectRoleSecrets wiring feeds the snapshot (see the boot IT).
      final resolver = _resolver(
        {
          'default': [ModelRef(provider: 'aiai', modelId: 'glm-4.6')],
        },
        secrets: const {'AIAI_API_KEY': 'k'},
        customProviders: [_bycom()],
      );
      expect(
        resolver.chainFor('default')!.single.keyRing.baseName,
        'AIAI_API_KEY',
      );
    });

    test('explicit ref fields win over the entry defaults', () {
      final resolver = _resolver(
        {
          'default': [
            ModelRef(
              provider: 'aiai',
              modelId: 'glm-4.6',
              baseUrl: 'https://mirror.example/v1',
              apiKeyName: 'MIRROR_KEY',
            ),
          ],
        },
        secrets: const {'MIRROR_KEY': 'k'},
        customProviders: [_bycom()],
      );
      final entry = resolver.chainFor('default')!.single;
      expect(entry.model.baseUrl, 'https://mirror.example/v1');
      expect(entry.keyRing.baseName, 'MIRROR_KEY');
    });

    test('the name matches case-insensitively', () {
      final resolver = _resolver(
        {
          'default': [ModelRef(provider: 'AIAI', modelId: 'glm-4.6')],
        },
        secrets: const {'AIAI_API_KEY': 'k'},
        customProviders: [_bycom()],
      );
      expect(resolver.chainFor('default'), hasLength(1));
    });
  });

  group('UT-2 — catalog parity (AC2)', () {
    test('catalog-name and kind entries resolve exactly as before with a '
        'loaded registry', () {
      final roles = {
        'default': [
          ModelRef(provider: 'anthropic', modelId: 'claude-main'),
          ModelRef(provider: 'chatgpt-codex', modelId: 'gpt-5-codex'),
        ],
      };
      final withRegistry = _resolver(
        roles,
        secrets: const {
          'ANTHROPIC_API_KEY': 'a',
          'CHATGPT_OAUTH_CREDENTIALS': 'c',
        },
        customProviders: [_bycom()],
      ).chainFor('default')!;
      final legacy = _resolver(
        roles,
        secrets: const {
          'ANTHROPIC_API_KEY': 'a',
          'CHATGPT_OAUTH_CREDENTIALS': 'c',
        },
      ).chainFor('default')!;
      expect(withRegistry, hasLength(legacy.length));
      for (var i = 0; i < legacy.length; i++) {
        expect(withRegistry[i].model.provider, legacy[i].model.provider);
        expect(withRegistry[i].model.api, legacy[i].model.api);
        expect(withRegistry[i].model.baseUrl, legacy[i].model.baseUrl);
        expect(withRegistry[i].keyRing.baseName, legacy[i].keyRing.baseName);
      }
    });
  });

  group('UT-3 — unknown in both namespaces (AC3)', () {
    test('unknown-name entries keep the gh-760 skip+degrade contract', () {
      final resolver = _resolver(
        {
          'default': [ModelRef(provider: 'from-the-future', modelId: 'x')],
        },
        customProviders: [_bycom()],
      );
      expect(
        () => resolver.chainFor('default'),
        throwsA(isA<UnknownProviderRoleException>()),
      );
      expect(
        resolver.skippedEntries['default']!.join(' '),
        allOf(contains('unknown provider'), contains('from-the-future')),
      );
    });

    test('a known entry still carries the role past an unknown one', () {
      final resolver = _resolver(
        {
          'default': [
            ModelRef(provider: 'from-the-future', modelId: 'x'),
            ModelRef(provider: 'anthropic', modelId: 'claude-smol'),
          ],
        },
        secrets: const {'ANTHROPIC_API_KEY': 'a'},
        customProviders: [_bycom()],
      );
      final entries = resolver.chainFor('default');
      expect(entries, hasLength(1));
      expect(entries!.single.model.provider, 'anthropic');
      expect(
        resolver.skippedEntries['default']!.join(' '),
        contains('unknown provider'),
      );
    });

    test('a matched entry with an unknown apiType names the dialect, not '
        'the provider', () {
      // The registry entry IS known (the name matched) — only its adapter
      // dialect is not (a saved entry written by a newer CLI). "unknown
      // provider" wording would send the user hunting an entry spelling
      // that is actually fine.
      final futureDialect = CustomProviderEntry(
        name: 'quantum',
        apiType: 'quantum-chat',
        baseUrl: 'https://quantum.example/v1',
        modelId: 'q-1',
      );
      final resolver = _resolver(
        {
          'default': [ModelRef(provider: 'quantum', modelId: 'q-1')],
        },
        customProviders: [futureDialect],
      );
      expect(
        () => resolver.chainFor('default'),
        throwsA(isA<UnknownProviderRoleException>()),
      );
      expect(
        resolver.skippedEntries['default']!.join(' '),
        allOf(
          contains('unknown adapter dialect'),
          contains('quantum-chat'),
          isNot(contains('unknown provider')),
        ),
      );
    });
  });

  group('REG-2 — key provenance unchanged (issue #40 invariant)', () {
    test('the custom-name form picks the SAME key slots as the '
        'kind+baseUrl form in every key layout', () {
      // Per-layout shapes: the 'entry pin' layout is only reachable with
      // a KEYED entry (a keyless entry never consults the pin), so that
      // layout pins `keyName` on the entry and — to keep both sides of
      // the comparison meaningful — `apiKeyName` on the kind+baseUrl twin
      // ref. The slot-based layouts stay keyless: the entry then resolves
      // through the endpoint-scoped slot / the adapter's spec env names,
      // exactly like the twin.
      const layouts = [
        ('entry pin', {'AIAI_API_KEY': 'k'}, 'AIAI_API_KEY', 'AIAI_API_KEY'),
        ('endpoint slot', {'FA_KEY_API_BYCOM_BY': 'k'}, null, null),
        ('spec env fallback', {'OPENAI_API_KEY': 'k'}, null, null),
      ];
      for (final (label, secrets, entryKeyName, refApiKeyName) in layouts) {
        final byName = _resolver(
          {
            'default': [ModelRef(provider: 'aiai', modelId: 'glm-4.6')],
          },
          secrets: secrets,
          customProviders: [_bycom(keyName: entryKeyName)],
        ).chainFor('default')!.single.keyRing.baseName;
        final byKind = _resolver({
          'default': [
            ModelRef(
              provider: 'openai',
              modelId: 'glm-4.6',
              baseUrl: 'https://api.bycom.by/v1',
              apiKeyName: refApiKeyName,
            ),
          ],
        }, secrets: secrets).chainFor('default')!.single.keyRing.baseName;
        expect(byName, byKind, reason: 'key layout: $label');
      }
    });

    test('the entry pin wins over the endpoint slot when both exist', () {
      final resolver = _resolver(
        {
          'default': [ModelRef(provider: 'aiai', modelId: 'glm-4.6')],
        },
        secrets: const {'AIAI_API_KEY': 'k', 'FA_KEY_API_BYCOM_BY': 'slot'},
        customProviders: [_bycom()],
      );
      expect(
        resolver.chainFor('default')!.single.keyRing.baseName,
        'AIAI_API_KEY',
      );
    });
  });
}
