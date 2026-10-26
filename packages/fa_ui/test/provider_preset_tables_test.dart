// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// The preset lookup tables ([ProviderPreset.label] and
/// [ProviderPreset.cors]) resolve every preset — no arm falls through to a
/// crash or a missing note (issue #1848 tier 2 branch coverage).
void main() {
  const strings = FaUiStringsEn();

  test('every preset resolves a non-empty label', () {
    for (final preset in ProviderPreset.values) {
      expect(preset.label(strings), isNotEmpty, reason: '$preset');
    }
    expect(ProviderPreset.aiin.label(strings), strings.settingsPresetAiin);
    expect(ProviderPreset.gemma.label(strings), strings.settingsPresetGemma);
    expect(
      ProviderPreset.transformersJs.label(strings),
      strings.settingsPresetTransformersJs,
    );
  });

  test(
    'faMediaSlotLabel maps every media slot and passes unknowns through',
    () {
      expect(
        faMediaSlotLabel(strings, MediaSlot.imageGeneration),
        strings.mediaModelsSlotImageGeneration,
      );
      expect(
        faMediaSlotLabel(strings, MediaSlot.audioTts),
        strings.mediaModelsSlotAudioTts,
      );
      expect(
        faMediaSlotLabel(strings, MediaSlot.musicGeneration),
        strings.mediaModelsSlotMusicGeneration,
      );
      expect(
        faMediaSlotLabel(strings, MediaSlot.videoGeneration),
        strings.mediaModelsSlotVideoGeneration,
      );
      expect(
        faMediaSlotLabel(strings, MediaSlot.vision),
        strings.mediaModelsSlotVision,
      );
      expect(
        faMediaSlotLabel(strings, MediaSlot.transcription),
        strings.mediaModelsSlotTranscription,
      );
      // Unknown slot kinds render verbatim (forward-compat passthrough).
      expect(faMediaSlotLabel(strings, 'whatever-next'), 'whatever-next');
    },
  );

  test('browser-friendly and on-device presets have no CORS note', () {
    expect(ProviderPreset.aiin.cors(strings), isNull);
    expect(ProviderPreset.openrouter.cors(strings), isNull);
    expect(ProviderPreset.gemini.cors(strings), isNull);
    expect(ProviderPreset.webllm.cors(strings), isNull);
    expect(ProviderPreset.gemma.cors(strings), isNull);
    expect(ProviderPreset.transformersJs.cors(strings), isNull);
  });

  test('Ollama Cloud names its CORS proxy; the rest get the generic note', () {
    expect(
      ProviderPreset.ollamaCloud.cors(strings),
      strings.settingsCorsNoteOllama,
    );
    expect(ProviderPreset.dial.cors(strings), strings.settingsCorsNoteCustom);
    expect(
      ProviderPreset.minimax.cors(strings),
      strings.settingsCorsNoteCustom,
    );
    expect(ProviderPreset.custom.cors(strings), strings.settingsCorsNoteCustom);
  });

  test('the on-device presets are on-device and lose the endpoint field', () {
    expect(ProviderPreset.webllm.isOnDevice, isTrue);
    expect(ProviderPreset.gemma.isOnDevice, isTrue);
    expect(ProviderPreset.transformersJs.isOnDevice, isTrue);
    expect(ProviderPreset.openrouter.isOnDevice, isFalse);
    expect(ProviderPreset.webllm.hasEditableBaseUrl, isFalse);
    expect(ProviderPreset.openrouter.hasEditableBaseUrl, isTrue);
  });
}
