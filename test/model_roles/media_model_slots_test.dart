// Copyright (c) 2026, the Flutter Agent Harness authors.
// gh-1844: media slot override parsing — useMainConnection opt-in and
// declared input/output modalities ride the per-slot YAML map.

import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:flutter_agent_harness/src/model_roles/media_model_slots.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('parseMediaSlotModelOverride (gh-1844)', () {
    MediaSlotModelConfig parse(String yaml) =>
        MediaSlotModelConfig.fromYaml(loadYaml(yaml), slot: 'imageGeneration');

    test('parses the full override form with modalities', () {
      final config = parse('''
providerKind: openrouter
baseUrl: https://openrouter.ai/api/v1
modelId: google/gemini-3-pro-image-preview
apiKeyName: OR_KEY
input: [image, text]
output: [image]
''');
      expect(config.providerKind, 'openrouter');
      expect(config.baseUrl, 'https://openrouter.ai/api/v1');
      expect(config.modelId, 'google/gemini-3-pro-image-preview');
      expect(config.apiKeyName, 'OR_KEY');
      expect(config.useMainConnection, isFalse);
      expect(config.inputModalities, ['image', 'text']);
      expect(config.outputModalities, ['image']);
    });

    test('parses the useMainConnection opt-in without endpoint fields', () {
      final config = parse('''
useMainConnection: true
''');
      expect(config.useMainConnection, isTrue);
      expect(config.providerKind, isEmpty);
      expect(config.baseUrl, isEmpty);
      expect(config.modelId, isEmpty);
      expect(config.apiKeyName, isNull);
    });

    test('parses the unsupported opt-out without endpoint fields (#2085)', () {
      final config = parse('''
unsupported: true
''');
      expect(config.unsupported, isTrue);
      expect(config.useMainConnection, isFalse);
      expect(config.providerKind, isEmpty);
      expect(config.baseUrl, isEmpty);
      expect(config.modelId, isEmpty);
    });

    test(
      'useMainConnection and unsupported are mutually exclusive (#2085)',
      () {
        expect(
          () => parse('''
useMainConnection: true
unsupported: true
'''),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('cannot set both useMainConnection and unsupported'),
            ),
          ),
        );
      },
    );

    test('non-boolean unsupported is rejected (#2085)', () {
      expect(
        () => parse('unsupported: yes-please'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            'models.slots.imageGeneration.unsupported must be a boolean',
          ),
        ),
      );
    });

    test('unsupported round-trips through writeYaml (#2085)', () {
      final buffer = StringBuffer()..writeln('slots:');
      const MediaSlotModelConfig(unsupported: true).writeYaml(buffer, '  ');
      expect(buffer.toString(), 'slots:\n  unsupported: true\n');
      final reparsed = MediaSlotModelConfig.fromYaml(
        loadYaml('unsupported: true'),
        slot: 'imageGeneration',
      );
      expect(reparsed.unsupported, isTrue);
    });

    test('non-boolean useMainConnection is rejected', () {
      expect(
        () => parse('''
useMainConnection: "yes"
'''),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.toString(),
            'message',
            contains('useMainConnection must be a boolean'),
          ),
        ),
      );
    });

    test('endpoint fields are required without the opt-in', () {
      expect(
        () => parse('''
providerKind: openrouter
modelId: some-model
'''),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.toString(),
            'message',
            contains('models.slots.imageGeneration.baseUrl'),
          ),
        ),
      );
    });

    test('unknown fields are rejected', () {
      expect(
        () => parse('''
providerKind: openrouter
baseUrl: https://openrouter.ai/api/v1
modelId: m
fallbackToMain: true
'''),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.toString(),
            'message',
            contains('unknown field "fallbackToMain"'),
          ),
        ),
      );
    });

    test('non-string list entries in input are rejected', () {
      expect(
        () => parse('''
providerKind: openrouter
baseUrl: https://openrouter.ai/api/v1
modelId: m
input: [image, 7]
'''),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.toString(),
            'message',
            contains('input'),
          ),
        ),
      );
    });
  });

  group('mediaModelSlotIds', () {
    test('covers both media slots', () {
      expect(mediaModelSlotIds, contains('imageGeneration'));
      expect(mediaModelSlotIds, contains('videoGeneration'));
    });
  });
}
