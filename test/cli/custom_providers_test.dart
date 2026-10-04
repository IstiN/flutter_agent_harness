import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('CustomProviderEntry yaml', () {
    test('round-trips with and without a key name', () {
      final withKey = CustomProviderEntry(
        name: 'localhost:11434',
        apiType: 'openai',
        baseUrl: 'http://localhost:11434/v1',
        modelId: 'llama3.1:8b',
        keyName: 'FA_KEY_LOCALHOST_11434',
      );
      final parsed = CustomProviderEntry.fromYaml(withKey.toYaml());
      expect(parsed.name, 'localhost:11434');
      expect(parsed.apiType, 'openai');
      expect(parsed.baseUrl, 'http://localhost:11434/v1');
      expect(parsed.modelId, 'llama3.1:8b');
      expect(parsed.keyName, 'FA_KEY_LOCALHOST_11434');

      final keyless = CustomProviderEntry(
        name: 'a',
        apiType: 'anthropic',
        baseUrl: 'https://a.example.com',
        modelId: 'm',
      );
      expect(keyless.toYaml().containsKey('keyName'), isFalse);
      expect(CustomProviderEntry.fromYaml(keyless.toYaml()).keyName, isNull);
    });

    test('rejects bad shapes and unsupported api types loudly', () {
      expect(() => CustomProviderEntry.fromYaml('nope'), throwsConfigException);
      expect(
        () => CustomProviderEntry.fromYaml(const {'apiType': 'openai'}),
        throwsConfigException,
      );
      expect(
        () => CustomProviderEntry.fromYaml(const {
          'name': 'x',
          'apiType': 'gemini',
          'baseUrl': 'https://x',
          'modelId': 'm',
        }),
        throwsConfigException,
      );
    });

    test('round-trips authHeader (issue #964)', () {
      final gateway = CustomProviderEntry(
        name: 'acme-gw',
        apiType: 'openai',
        baseUrl: 'https://gateway.acme.com/v1',
        modelId: 'bedrock-model',
        authHeader: 'x-api-key',
      );
      final parsed = CustomProviderEntry.fromYaml(gateway.toYaml());
      expect(parsed.authHeader, 'x-api-key');
      // Unset keeps the Bearer default and stays out of the yaml.
      final plain = CustomProviderEntry(
        name: 'a',
        apiType: 'openai',
        baseUrl: 'https://a.example.com',
        modelId: 'm',
      );
      expect(plain.authHeader, isNull);
      expect(plain.toYaml().containsKey('authHeader'), isFalse);
    });

    test('rejects invalid authHeader values naming the entry '
        '(issue #964 AC5)', () {
      void expectBadAuth(Object? authHeader) {
        expect(
          () => CustomProviderEntry.fromYaml({
            'name': 'acme-gw',
            'apiType': 'openai',
            'baseUrl': 'https://gateway.acme.com/v1',
            'modelId': 'bedrock-model',
            'authHeader': authHeader,
          }),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('acme-gw'),
                contains('invalid authHeader'),
              ),
            ),
          ),
        );
      }

      expectBadAuth('');
      expectBadAuth('  ');
      expectBadAuth('x-api-key\r\nX-Evil: 1');
      expectBadAuth('x api key');
      expectBadAuth(7);
    });

    test('rejects authHeader on a non-openai-completions api type '
        '(issue #964 review)', () {
      expect(
        () => CustomProviderEntry.fromYaml(const {
          'name': 'acme-gw',
          'apiType': 'anthropic',
          'baseUrl': 'https://gateway.acme.com/v1',
          'modelId': 'claude-x',
          'authHeader': 'x-api-key',
        }),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('customProviders entry "acme-gw"'),
              contains('provider "anthropic"'),
              contains('anthropic adapter'),
            ),
          ),
        ),
      );
    });

    test('rejects authHeader on dial and copilot — openai-completions-'
        'shaped apis whose adapters ignore it (issue #964 round-2)', () {
      for (final apiType in const ['dial', 'copilot']) {
        expect(
          () => CustomProviderEntry.fromYaml({
            'name': 'acme-gw',
            'apiType': apiType,
            'baseUrl': 'https://gateway.acme.com/v1',
            'modelId': 'm',
            'authHeader': 'x-api-key',
          }),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('customProviders entry "acme-gw"'),
                contains('routes to the $apiType adapter, which ignores it'),
              ),
            ),
          ),
          reason: apiType,
        );
      }
    });
  });

  group('CustomProviderRegistry', () {
    test('derives unique names from the endpoint host', () {
      final registry = CustomProviderRegistry(const []);
      expect(
        registry.deriveName('http://localhost:11434/v1'),
        'localhost:11434',
      );
      expect(registry.deriveName('https://api.acme.com/v1'), 'api.acme.com');
      expect(
        registry.deriveName('https://api.acme.com:8443/v1'),
        'api.acme.com:8443',
      );
      registry.add(
        CustomProviderEntry(
          name: 'api.acme.com',
          apiType: 'openai',
          baseUrl: 'https://api.acme.com/v1',
          modelId: 'm',
        ),
      );
      expect(registry.deriveName('https://api.acme.com/v1'), 'api.acme.com-2');
    });

    test('never derives catalog or wizard names', () {
      final registry = CustomProviderRegistry(const []);
      // 'openai' collides with the catalog; the suffix disambiguates.
      registry.add(
        CustomProviderEntry(
          name: 'openai-2',
          apiType: 'openai',
          baseUrl: 'https://openai-2.example.com',
          modelId: 'm',
        ),
      );
      expect(registry.deriveName('https://openai/v1'), isNot('openai'));
      expect(registry.deriveName('https://openai-2/v1'), 'openai-2-2');
    });

    test('find is case-insensitive and updateModel rewrites the entry', () {
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'Box',
          apiType: 'google',
          baseUrl: 'https://box.example.com',
          modelId: 'm1',
        ),
      ]);
      expect(registry.find('box')?.modelId, 'm1');
      expect(registry.find('missing'), isNull);
      registry.updateModel('BOX', 'm2');
      expect(registry.find('box')?.modelId, 'm2');
      registry.updateModel('missing', 'm3');
      expect(registry.entries, hasLength(1));
    });

    test('add replaces an existing same-name entry', () {
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'a',
          apiType: 'openai',
          baseUrl: 'https://a1.example.com',
          modelId: 'm1',
        ),
      ]);
      registry.add(
        CustomProviderEntry(
          name: 'a',
          apiType: 'openai',
          baseUrl: 'https://a2.example.com',
          modelId: 'm2',
        ),
      );
      expect(registry.entries, hasLength(1));
      expect(registry.entries.single.baseUrl, 'https://a2.example.com');
    });

    test('keyNameFor sanitizes host and port', () {
      expect(
        CustomProviderRegistry.keyNameFor('http://localhost:11434/v1'),
        'FA_KEY_LOCALHOST_11434',
      );
      expect(
        CustomProviderRegistry.keyNameFor('https://api.acme.com/v1'),
        'FA_KEY_API_ACME_COM',
      );
      expect(
        CustomProviderRegistry.keyNameFor('http://127.0.0.1:8080'),
        'FA_KEY_127_0_0_1_8080',
      );
      expect(
        CustomProviderRegistry.keyNameFor('not a url at all'),
        startsWith('FA_KEY_'),
      );
    });

    test('copilotEntryKeyName scopes to the entry name', () {
      expect(
        CustomProviderRegistry.copilotEntryKeyName('copilot-octocat'),
        'FA_KEY_COPILOT_COPILOT_OCTOCAT',
      );
      // Non-alphanumerics collapse; edges trim.
      expect(
        CustomProviderRegistry.copilotEntryKeyName('Copilot -- Hub.Org_2'),
        'FA_KEY_COPILOT_COPILOT_HUB_ORG_2',
      );
    });

    test('keyNameFor scopes to the provider name when given', () {      expect(
        CustomProviderRegistry.keyNameFor(
          'https://api.acme.com/v1',
          providerName: 'work',
        ),
        'FA_KEY_API_ACME_COM_WORK',
      );
      expect(
        CustomProviderRegistry.keyNameFor(
          'https://api.acme.com/v1',
          providerName: 'my acc 2',
        ),
        'FA_KEY_API_ACME_COM_MY_ACC_2',
      );
      // Empty/blank names fall back to the host-only slot.
      expect(
        CustomProviderRegistry.keyNameFor(
          'https://api.acme.com/v1',
          providerName: ' - ',
        ),
        'FA_KEY_API_ACME_COM',
      );
      // A provider named after its host (the derived default) must not
      // double the suffix.
      expect(
        CustomProviderRegistry.keyNameFor(
          'https://api.aiin.by/v1',
          providerName: 'api.aiin.by',
        ),
        'FA_KEY_API_AIIN_BY',
      );
    });

    test(
      'an entry name already a suffix of the host slug is not doubled '
      '(gh-1226 AC3)',
      () {
        // An entry named 'z.ai' on host api.z.ai used to generate
        // FA_KEY_API_Z_AI_Z_AI — the slug was appended even though the
        // host slug already ended with it.
        expect(
          CustomProviderRegistry.keyNameFor(
            'https://api.z.ai/api/coding/paas/v4',
            providerName: 'z.ai',
          ),
          'FA_KEY_API_Z_AI',
        );
        // A name that is NOT a suffix still scopes the slot.
        expect(
          CustomProviderRegistry.keyNameFor(
            'https://api.z.ai/api/coding/paas/v4',
            providerName: 'work',
          ),
          'FA_KEY_API_Z_AI_WORK',
        );
      },
    );

    test(
      'a registry loaded from an older doubled slot reports a migration '
      'note (gh-1226 AC3)',
      () {
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'z.ai',
            apiType: 'zai',
            baseUrl: 'https://api.z.ai/api/coding/paas/v4',
            modelId: 'glm-5.3-flash',
            keyName: 'FA_KEY_API_Z_AI_Z_AI',
          ),
        ]);

        expect(registry.keyNameMigrationNotes, isNotEmpty);
        expect(registry.keyNameMigrationNotes.single, contains('z.ai'));
        expect(
          registry.keyNameMigrationNotes.single,
          contains('FA_KEY_API_Z_AI'),
        );
        expect(registry.keyNameMigrationNotes.single, contains('canonical'));
      },
    );

    test('a canonical registry reports no migration notes', () {
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'z.ai',
          apiType: 'zai',
          baseUrl: 'https://api.z.ai/api/coding/paas/v4',
          modelId: 'glm-5.3-flash',
          keyName: 'FA_KEY_API_Z_AI',
        ),
      ]);

      expect(registry.keyNameMigrationNotes, isEmpty);
    });
  });

  group('CliConfig customProviders section', () {
    test('round-trips through toYaml/fromYaml', () {
      final config = CliConfig(
        customProviders: [
          CustomProviderEntry(
            name: 'localhost:11434',
            apiType: 'openai',
            baseUrl: 'http://localhost:11434/v1',
            modelId: 'llama3.1:8b',
            keyName: 'FA_KEY_LOCALHOST_11434',
          ),
          CustomProviderEntry(
            name: 'proxy',
            apiType: 'anthropic',
            baseUrl: 'https://proxy.example.com',
            modelId: 'claude-x',
          ),
        ],
      );
      final doc = loadYaml(config.toYaml());
      expect(doc, isA<YamlMap>());
      final parsed = CliConfig.fromYaml(doc as YamlMap);
      expect(parsed.customProviders, hasLength(2));
      expect(parsed.customProviders[0].name, 'localhost:11434');
      expect(parsed.customProviders[0].keyName, 'FA_KEY_LOCALHOST_11434');
      expect(parsed.customProviders[1].keyName, isNull);
      expect(parsed.customProviders[1].modelId, 'claude-x');
    });

    test('rejects a malformed section loudly', () {
      expect(
        () => CliConfig.fromYaml(
          loadYaml('customProviders: just-a-string') as YamlMap,
        ),
        throwsConfigException,
      );
      expect(
        () => CliConfig.fromYaml(
          loadYaml('customProviders:\n  - {name: x}') as YamlMap,
        ),
        throwsConfigException,
      );
    });
  });
}

/// Matcher helper: the config schema must fail loudly.
Matcher get throwsConfigException =>
    throwsA(const TypeMatcher<ConfigException>());
