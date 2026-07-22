import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
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
