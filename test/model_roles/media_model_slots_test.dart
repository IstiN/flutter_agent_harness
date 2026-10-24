// Copyright (c) 2026, the Flutter Agent Harness authors.
// gh-1844: media slot override parsing — useMainConnection opt-in and
// declared input/output modalities ride the per-slot YAML map.

import 'package:flutter_agent_harness/src/model_roles/media_model_slots.dart';
import 'package:flutter_agent_harness/src/model_roles/models_config.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('parseMediaSlotModelOverride (gh-1844)', () {
    MediaSlotModelConfig parse(String yaml) =>
        ModelsConfig.parseMediaSlotModelOverride(
          'imageGeneration',
          loadYaml(yaml),
        );

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

  group('mediaModelSlotNames', () {
    test('covers both media slots', () {
      expect(mediaModelSlotNames, contains('imageGeneration'));
      expect(mediaModelSlotNames, contains('videoGeneration'));
    });
  });
}
