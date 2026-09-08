import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('modelIdSuggestsVision', () {
    test('mainstream hosted vision families', () {
      for (final id in [
        'gpt-4o',
        'openai/gpt-4.1-mini',
        'claude-sonnet-4-20250514',
        'anthropic/claude-3-haiku',
        'gemini-2.5-pro',
        'qwen2.5-vl-72b',
        'grok-4',
        'gemma-3-27b-it',
      ]) {
        expect(modelIdSuggestsVision(id), isTrue, reason: id);
      }
    });

    test('Moonshot Kimi lines (declared supports_image_in on /models)', () {
      for (final id in [
        'kimi-for-coding',
        'kimi-for-coding-highspeed',
        'k3',
        'k3-256k',
        'k2-thinking',
        'moonshot-v1-128k-vision-preview',
      ]) {
        expect(modelIdSuggestsVision(id), isTrue, reason: id);
      }
    });

    test('text-only and empty ids stay blind', () {
      for (final id in [
        '',
        'text-embedding-3-large',
        'gemma-3-1b-it',
        'some-random-model',
      ]) {
        expect(modelIdSuggestsVision(id), isFalse, reason: id);
      }
    });

    test('glm-5 flagships are text-only, the v/flash lines see images', () {
      // Issue #42: glm-5.3 is text-only on z.ai (400 `messages.content.type
      // is invalid, allowed values: ['text']`); OpenRouter metadata agrees.
      for (final id in ['glm-5', 'glm-5.2', 'glm-5.3', 'glm-4.6']) {
        expect(modelIdSuggestsVision(id), isFalse, reason: id);
      }
      for (final id in [
        'glm-4.5v',
        'glm-4.6v',
        'glm-5v-turbo',
        'glm-5.3-flash',
      ]) {
        expect(modelIdSuggestsVision(id), isTrue, reason: id);
      }
    });
  });
}
