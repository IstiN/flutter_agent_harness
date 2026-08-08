import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('faVoicePresetsFor', () {
    test('matches Gemini TTS by model id (gemini + tts)', () {
      final presets = faVoicePresetsFor(
        modelId: 'gemini-2.5-flash-preview-tts',
      );
      expect(presets, hasLength(30));
      expect(presets.first.id, 'Zephyr');
      expect(presets.first.trait, 'Bright');
      expect(
        presets.first.sampleUrl,
        'https://www.gstatic.com/aistudio/voices/samples/Zephyr.wav',
      );
      expect(presets.last.id, 'Sulafat');
      expect(presets.last.trait, 'Warm');
    });

    test('matches Gemini by base URL regardless of the model id', () {
      final presets = faVoicePresetsFor(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        modelId: 'some-model',
      );
      expect(presets, hasLength(30));
    });

    test('matches Kokoro by model id (no sample urls)', () {
      final presets = faVoicePresetsFor(modelId: 'kokoro-82m');
      expect(presets.map((preset) => preset.id), [
        'af_heart',
        'af_bella',
        'af_nicole',
        'af_sarah',
        'af_sky',
        'am_adam',
        'am_michael',
        'am_onyx',
        'bf_emma',
        'bf_isabella',
        'bm_george',
        'bm_lewis',
      ]);
      expect(presets.every((preset) => preset.sampleUrl == null), isTrue);
    });

    test('matches OpenAI-compatible TTS by the tts marker', () {
      final presets = faVoicePresetsFor(modelId: 'tts-1');
      expect(presets.map((preset) => preset.id), [
        'alloy',
        'ash',
        'coral',
        'echo',
        'fable',
        'nova',
        'onyx',
        'sage',
        'shimmer',
      ]);
      expect(presets.every((preset) => preset.sampleUrl == null), isTrue);
    });

    test('matching is case-insensitive', () {
      expect(faVoicePresetsFor(modelId: 'GPT-4o-mini-TTS'), isNotEmpty);
      expect(faVoicePresetsFor(modelId: 'KOKORO'), hasLength(12));
    });

    test('no match returns an empty list', () {
      expect(faVoicePresetsFor(modelId: 'gpt-4o'), isEmpty);
      expect(
        faVoicePresetsFor(
          baseUrl: 'https://openrouter.ai/api/v1',
          modelId: 'gpt-image-1',
        ),
        isEmpty,
      );
    });
  });
}
