// Issue #1398 — the per-provider timeout keys on the provider registry
// entries (`connectTimeoutMs`/`streamIdleTimeoutMs` on customProviders,
// models.custom, roles chain entries, providersQueue entries) and the boot
// seeding into [providerTuningRegistry].
@Timeout(Duration(seconds: 30))
library;

import 'dart:core';
import 'dart:io';

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

    test('values above the 1 h sanity bound are hard parse errors', () {
      // Review r2: a fat-fingered 30-minute idle timeout would silently
      // defeat the watchdog this config exists to tune.
      for (final pair in const {
        'connectTimeoutMs': 3600001,
        'streamIdleTimeoutMs': 7200000,
      }.entries) {
        final doc =
            loadYaml('''
- name: fat-finger
  apiType: openai
  baseUrl: https://fat.example.com/v1
  modelId: gpt-4o
  ${pair.key}: ${pair.value}
''')
                as YamlList;
        expect(
          () => CustomProviderEntry.fromYaml(doc.first),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf(contains(pair.key), contains('3600000')),
            ),
          ),
          reason: '${pair.key}: ${pair.value} exceeds the 1 h sanity bound',
        );
      }
      // The bound itself parses (boundary stays legal).
      final doc =
          loadYaml('''
- name: bound
  apiType: openai
  baseUrl: https://bound.example.com/v1
  modelId: gpt-4o
  streamIdleTimeoutMs: 3600000
''')
              as YamlList;
      expect(
        CustomProviderEntry.fromYaml(doc.first).streamIdleTimeout,
        const Duration(hours: 1),
      );
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

    test('the /provider edit wizard carries the hand-configured fields', () {
      // Review r2: the wizard rebuilds the entry from its own answers —
      // authMethod, authHeader and the tuning keys must survive the edit.
      final existing = CustomProviderEntry(
        name: 'glm-relay',
        apiType: 'openai',
        baseUrl: 'https://glm.example.com/v1',
        modelId: 'glm-5.3-flash',
        authMethod: CustomProviderAuthMethod.sso,
        authHeader: 'x-api-key',
        connectTimeout: const Duration(seconds: 30),
        streamIdleTimeout: const Duration(milliseconds: 1500),
      );
      final updated = mergeEditedCustomProviderEntry(
        existing: existing,
        updated: CustomProviderEntry(
          name: 'glm-relay',
          apiType: 'openai',
          baseUrl: 'https://glm.example.com/v2',
          modelId: 'glm-5.4-flash',
        ),
      );
      expect(updated.modelId, 'glm-5.4-flash', reason: 'wizard-owned');
      expect(
        updated.baseUrl,
        'https://glm.example.com/v2',
        reason: 'wizard-owned',
      );
      expect(updated.authMethod, CustomProviderAuthMethod.sso);
      expect(updated.authHeader, 'x-api-key');
      expect(updated.connectTimeout, const Duration(seconds: 30));
      expect(updated.streamIdleTimeout, const Duration(milliseconds: 1500));
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

    test('reset: true clears removed entries (host reload semantics)', () {
      providerTuningRegistry.clear();
      addTearDown(providerTuningRegistry.clear);
      seedProviderTuning(
        customProviders: [
          CustomProviderEntry(
            name: 'glm-relay',
            apiType: 'openai',
            baseUrl: 'https://glm.example.com/v1',
            modelId: 'glm-5.3-flash',
            streamIdleTimeout: const Duration(seconds: 2),
          ),
        ],
      );
      // The reload pass names ONLY the surviving entry and resets first:
      // a removed entry's row cannot survive the reload (E4).
      seedProviderTuning(
        reset: true,
        customProviders: [
          CustomProviderEntry(
            name: 'other',
            apiType: 'openai',
            baseUrl: 'https://other.example.com/v1',
            modelId: 'm',
            connectTimeout: const Duration(seconds: 5),
          ),
        ],
      );
      expect(providerTuningRegistry.forName('glm-relay'), isNull);
      expect(providerTuningRegistry.forName('other'), isNotNull);
    });

    test(
      'queue-lane entries render boot notices (never a silent override)',
      () {
        providerTuningRegistry.clear();
        addTearDown(providerTuningRegistry.clear);
        seedProviderTuning(
          queueEntries: [
            ProviderQueueEntry(
              providerType: 'openai-completions',
              model: 'q',
              baseUrl: 'https://queue.example.com/v1',
              streamIdleTimeout: const Duration(milliseconds: 1500),
            ),
          ],
        );
        final notices = providerTuningBootNotices();
        expect(notices, isNotEmpty, reason: 'AC1: every seeded entry prints');
        expect(
          notices.join('\n'),
          contains('queue:'),
          reason:
              'the queue lane replaces main-model resolution — its '
              'tuning entries must be loud like every other lane',
        );
        expect(notices.join('\n'), contains('idle 1.5s'));
      },
    );
  });

  group('boot wiring — runapp prints tuning notices AFTER queue seeding', () {
    // Source-order pin (the bin_boot_restore_pin_test.dart pattern): the
    // review's blocking bug — `providerTuningBootNotices()` captured before
    // `seedProviderTuning(queueEntries:)` — is a boot-ORDER property only a
    // full `fa` boot could exercise; the source order pins it cheaply.
    test('fah_runapp.dart captures the notices after the queue pass', () {
      final source = File('bin/fah_runapp.dart').readAsStringSync();
      final queueSeed = source.indexOf('seedProviderTuning(queueEntries:');
      final noticeCapture = source.indexOf('providerTuningBootNotices()');
      expect(queueSeed, greaterThan(-1));
      expect(noticeCapture, greaterThan(-1));
      expect(
        noticeCapture,
        greaterThan(queueSeed),
        reason:
            'queue-carried tuning entries must be in the table BEFORE '
            'the boot notices are captured, or they never print',
      );
    });
  });
}
