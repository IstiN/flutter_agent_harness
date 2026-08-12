@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/model_roles/vision_models.dart';
import 'package:test/test.dart';

void main() {
  group('modelIdSuggestsVision', () {
    test('mainstream hosted vision families', () {
      for (final id in [
        'gpt-4o',
        'openai/gpt-4.1-mini',
        'claude-sonnet-4-20250514',
        'gemini-2.5-pro',
        'qwen2.5-vl-72b',
        'grok-4',
        'gemma-3-27b-it',
      ]) {
        expect(modelIdSuggestsVision(id), isTrue, reason: id);
      }
    });

    test('text-only and empty ids stay blind', () {
      for (final id in ['', 'text-embedding-3-large', 'gemma-3-1b-it']) {
        expect(modelIdSuggestsVision(id), isFalse, reason: id);
      }
    });
  });

  group('visionMarker', () {
    test('marks vision and text-only models explicitly', () {
      expect(visionMarker('gpt-4o'), '✓ vision');
      expect(visionMarker('some-embed-model'), '✗ text-only');
    });
  });

  group('inputModalitiesFor', () {
    test('vision models get image input, text-only stay text', () {
      expect(inputModalitiesFor('gpt-4o'), ['text', 'image']);
      expect(inputModalitiesFor('text-embedding-3-large'), ['text']);
    });
  });
}
