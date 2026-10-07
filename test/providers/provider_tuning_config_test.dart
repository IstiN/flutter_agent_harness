// Issue #1398 — the per-provider timeout keys on the provider registry
// entries (`connectTimeoutMs`/`streamIdleTimeoutMs` on customProviders,
// models.custom, roles chain entries, providersQueue entries) and the boot
// seeding into [providerTuningRegistry].
@Timeout(Duration(seconds: 30))
library;

import 'dart:core';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('config — customProviders entries carry the tuning keys', () {
    test('both keys parse to durations', () {
      final doc =
          loadYaml('''
- name: glm-relay
  apiType: openai
  baseUrl: https://glm.example.com/v1
  modelId: glm-5.3-flash
  connectTimeoutMs: 30000
  streamIdleTimeoutMs: 1500
''')
              as YamlList;
      final entry = CustomProviderEntry.fromYaml(doc.first);
      expect(entry.connectTimeout, const Duration(seconds: 30));
      expect(entry.streamIdleTimeout, const Duration(milliseconds: 1500));
    });

    test('absent keys stay null', () {
      final doc =
          loadYaml('''
- name: plain
  apiType: openai
  baseUrl: https://plain.example.com/v1
  modelId: gpt-4o
''')
              as YamlList;
      final entry = CustomProviderEntry.fromYaml(doc.first);
      expect(entry.connectTimeout, isNull);
      expect(entry.streamIdleTimeout, isNull);
    });

    test('zero / negative / non-int values are hard parse errors', () {
      for (final bad in ['0', '-5', '"soon"', '1.5']) {
        final doc =
            loadYaml('''
- name: bad
  apiType: openai
  baseUrl: https://bad.example.com/v1
  modelId: gpt-4o
  streamIdleTimeoutMs: $bad
''')
                as YamlList;
        expect(
          () => CustomProviderEntry.fromYaml(doc.first),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('streamIdleTimeoutMs'),
            ),
          ),
          reason: 'streamIdleTimeoutMs: $bad must be rejected',
        );
      }
    });

    test('the yaml writer round-trips the keys', () {
      final doc =
          loadYaml('''
- name: glm-relay
  apiType: openai
  baseUrl: https://glm.example.com/v1
  modelId: glm-5.3-flash
  connectTimeoutMs: 30000
  streamIdleTimeoutMs: 1500
''')
              as YamlList;
      final entry = CustomProviderEntry.fromYaml(doc.first);
      final yaml = entry.toYaml();
      expect(yaml['connectTimeoutMs'], 30000);
      expect(yaml['streamIdleTimeoutMs'], 1500);
    });
  });

  group('config — models.custom entries carry the tuning keys', () {
    test('both keys parse; unknown fields stay strict', () {
      final doc =
          loadYaml('''
fast:
  provider: openai
  baseUrl: https://glm.example.com/v1
  model: glm-5.3-flash
  connectTimeoutMs: 45000
  streamIdleTimeoutMs: 240000
''')
              as YamlMap;
      final def = CustomModelDefinition.fromYaml('fast', doc['fast']);
      expect(def.connectTimeout, const Duration(seconds: 45));
      expect(def.streamIdleTimeout, const Duration(minutes: 4));
      expect(
        () => CustomModelDefinition.fromYaml(
          'fast',
          loadYaml('''
  provider: openai
  baseUrl: https://x.example/v1
  model: m
  notAField: 1
'''),
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('config — roles chain entries carry the tuning keys', () {
    test('map-form chain entries parse the keys', () {
      final doc =
          loadYaml('''
provider: openai
model: glm-5.3-flash
baseUrl: https://glm.example.com/v1
streamIdleTimeoutMs: 240000
''')
              as YamlMap;
      final ref = ModelRef.fromYaml(doc, role: 'default');
      expect(ref.streamIdleTimeout, const Duration(minutes: 4));
      expect(ref.connectTimeout, isNull);
    });
  });

  group('config — providersQueue entries carry the tuning keys', () {
    test('provider_config keys parse to durations', () {
      final entry = ProviderQueueEntry.fromJsonMap({
        'provider_type': 'openai-completions',
        'model': 'glm-5.3-flash',
        'provider_config': {
          'model': 'glm-5.3-flash',
          'baseUrl': 'https://glm.example.com/v1',
          'connectTimeoutMs': 30000,
          'streamIdleTimeoutMs': 1500,
        },
      }, position: 1);
      expect(entry.connectTimeout, const Duration(seconds: 30));
      expect(entry.streamIdleTimeout, const Duration(milliseconds: 1500));
    });
  });

  group('boot seeding — registry entries reach the tuning table', () {
    test('seedProviderTuning registers every entry with overrides', () {
      providerTuningRegistry.clear();
      addTearDown(providerTuningRegistry.clear);
      seedProviderTuning(
        customProviders: [
          CustomProviderEntry(
            name: 'glm-relay',
            apiType: 'openai',
            baseUrl: 'https://glm.example.com/v1',
            modelId: 'glm-5.3-flash',
            streamIdleTimeout: const Duration(milliseconds: 1500),
          ),
        ],
        customModels: {
          'slow': CustomModelDefinition(
            provider: 'openai',
            baseUrl: 'https://slow.example.com/v1',
            model: 'thinker',
            connectTimeout: const Duration(seconds: 45),
          ),
        },
        roleRefs: [
          ModelRef(
            provider: 'openai',
            modelId: 'm',
            baseUrl: 'https://role.example.com/v1',
            streamIdleTimeout: const Duration(seconds: 77),
          ),
        ],
        queueEntries: [
          ProviderQueueEntry(
            providerType: 'openai-completions',
            model: 'q',
            baseUrl: 'https://queue.example.com/v1',
            connectTimeout: const Duration(seconds: 11),
            streamIdleTimeout: const Duration(seconds: 22),
          ),
        ],
      );
      expect(providerTuningRegistry.forName('glm-relay'), isNotNull);
      expect(
        providerTuningRegistry.forUrl(
          Uri.parse('https://glm.example.com/v1/chat/completions'),
        ),
        isNotNull,
      );
      expect(
        providerTuningRegistry
            .forUrl(Uri.parse('https://slow.example.com/v1/chat/completions'))
            ?.name,
        'models.custom.slow',
      );
      expect(
        providerTuningRegistry
            .forUrl(Uri.parse('https://role.example.com/v1/x'))
            ?.streamIdle,
        const Duration(seconds: 77),
      );
      expect(
        providerTuningRegistry
            .forUrl(Uri.parse('https://queue.example.com/v1/x'))
            ?.connect,
        const Duration(seconds: 11),
      );
      // Entries without overrides never reach the table.
      seedProviderTuning(
        customProviders: [
          CustomProviderEntry(
            name: 'plain',
            apiType: 'openai',
            baseUrl: 'https://plain.example.com/v1',
            modelId: 'gpt-4o',
          ),
        ],
      );
      expect(
        providerTuningRegistry.forUrl(
          Uri.parse('https://plain.example.com/v1/x'),
        ),
        isNull,
      );
    });

    test('re-seeding replaces a changed entry (E4: next request wins)', () {
      providerTuningRegistry.clear();
      addTearDown(providerTuningRegistry.clear);
      final entry = CustomProviderEntry(
        name: 'glm-relay',
        apiType: 'openai',
        baseUrl: 'https://glm.example.com/v1',
        modelId: 'glm-5.3-flash',
        streamIdleTimeout: const Duration(seconds: 2),
      );
      seedProviderTuning(customProviders: [entry]);
      seedProviderTuning(
        customProviders: [
          CustomProviderEntry(
            name: 'glm-relay',
            apiType: 'openai',
            baseUrl: 'https://glm.example.com/v1',
            modelId: 'glm-5.3-flash',
            streamIdleTimeout: const Duration(seconds: 9),
          ),
        ],
      );
      expect(
        providerTuningRegistry.forName('glm-relay')?.streamIdle,
        const Duration(seconds: 9),
      );
    });
  });
}
