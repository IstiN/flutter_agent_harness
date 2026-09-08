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

    test(
      'glm-5 flagships are text-only, only the v/flash lines see images',
      () {
        // Issue #42: switching onto glm-5.3 claimed image input, and the next
        // turn replayed history images as image_url parts — z.ai rejected the
        // request with `messages.content.type is invalid, allowed values:
        // ['text']`. OpenRouter metadata agrees: glm-5/5.1/5.2/5.3 are
        // text-only, glm-5v-turbo and glm-5.3-flash take image input.
        for (final id in [
          'glm-5',
          'glm-5.1',
          'glm-5.2',
          'glm-5.3',
          'glm-5-turbo',
          'glm-4.6',
          'glm-4.7',
        ]) {
          expect(modelIdSuggestsVision(id), isFalse, reason: id);
          expect(inputModalitiesFor(id), ['text'], reason: id);
        }
        for (final id in [
          'glm-4v-9b',
          'zai/glm-4.5v',
          'glm-4.6v',
          'glm-5v-turbo',
          'glm-5.3-flash',
        ]) {
          expect(modelIdSuggestsVision(id), isTrue, reason: id);
        }
      },
    );
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
