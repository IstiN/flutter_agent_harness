// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'package:fa_ui/src/strings/fa_ui_strings.dart';

/// A named TTS voice offered by a media model: the [id] sent to the
/// endpoint, a human [label] (defaults to the id), an optional one-word
/// [trait] shown next to the label, and an optional [sampleUrl] the
/// [FaVoicePresetPicker] previews inline.
final class FaVoicePreset {
  /// Creates a preset; [label] defaults to [id].
  const FaVoicePreset({
    required this.id,
    String? label,
    this.trait,
    this.sampleUrl,
  }) : label = label ?? id;

  /// The voice identifier sent to the endpoint.
  final String id;

  /// The display name (defaults to [id]).
  final String label;

  /// A short voice character hint (`Bright`, `Firm`), shown after the label.
  final String? trait;

  /// A publicly accessible sample clip URL, or null when the provider
  /// publishes none (no preview button then).
  final String? sampleUrl;
}

/// The Gemini TTS voices (id → trait), as listed by the AI Studio docs; the
/// sample clips are Google's public CDN (no API key needed).
final List<FaVoicePreset> _geminiTtsVoices = [
  for (final entry in const <String, String>{
    'Zephyr': 'Bright',
    'Puck': 'Upbeat',
    'Charon': 'Informative',
    'Kore': 'Firm',
    'Fenrir': 'Excitable',
    'Leda': 'Youthful',
    'Orus': 'Firm',
    'Aoede': 'Breezy',
    'Callirrhoe': 'Easy-going',
    'Autonoe': 'Bright',
    'Enceladus': 'Breathy',
    'Iapetus': 'Clear',
    'Umbriel': 'Easy-going',
    'Algieba': 'Smooth',
    'Despina': 'Smooth',
    'Erinome': 'Clear',
    'Algenib': 'Gravelly',
    'Rasalgethi': 'Informative',
    'Laomedeia': 'Upbeat',
    'Achernar': 'Soft',
    'Alnilam': 'Firm',
    'Schedar': 'Even',
    'Gacrux': 'Mature',
    'Pulcherrima': 'Forward',
    'Achird': 'Friendly',
    'Zubenelgenubi': 'Casual',
    'Vindemiatrix': 'Gentle',
    'Sadachbia': 'Lively',
    'Sadaltager': 'Knowledgeable',
    'Sulafat': 'Warm',
  }.entries)
    FaVoicePreset(
      id: entry.key,
      trait: entry.value,
      sampleUrl:
          'https://www.gstatic.com/aistudio/voices/samples/'
          '${entry.key.toLowerCase()}.wav',
    ),
];

/// The stock Kokoro voices (no published sample clips).
const List<FaVoicePreset> _kokoroVoices = [
  FaVoicePreset(id: 'af_heart'),
  FaVoicePreset(id: 'af_bella'),
  FaVoicePreset(id: 'af_nicole'),
  FaVoicePreset(id: 'af_sarah'),
  FaVoicePreset(id: 'af_sky'),
  FaVoicePreset(id: 'am_adam'),
  FaVoicePreset(id: 'am_michael'),
  FaVoicePreset(id: 'am_onyx'),
  FaVoicePreset(id: 'bf_emma'),
  FaVoicePreset(id: 'bf_isabella'),
  FaVoicePreset(id: 'bm_george'),
  FaVoicePreset(id: 'bm_lewis'),
];

/// The OpenAI TTS voices (no published sample clips).
const List<FaVoicePreset> _openAiTtsVoices = [
  FaVoicePreset(id: 'alloy'),
  FaVoicePreset(id: 'ash'),
  FaVoicePreset(id: 'coral'),
  FaVoicePreset(id: 'echo'),
  FaVoicePreset(id: 'fable'),
  FaVoicePreset(id: 'nova'),
  FaVoicePreset(id: 'onyx'),
  FaVoicePreset(id: 'sage'),
  FaVoicePreset(id: 'shimmer'),
];

/// The known voice presets for a media model, matched by its provider
/// [baseUrl] (may be null — e.g. "same as main connection") and [modelId],
/// both case-insensitively:
///
/// - Gemini TTS: [baseUrl] contains `generativelanguage`, or [modelId]
///   contains both `gemini` and `tts` → the 30 Gemini voices, each with a
///   sample clip on Google's public CDN.
/// - Kokoro: [modelId] contains `kokoro` → the 12 stock Kokoro voices.
/// - OpenAI-compatible TTS: [modelId] contains `tts` → the 9 OpenAI voices.
///
/// Anything else returns an empty list — callers fall back to free-text
/// voice entry.
List<FaVoicePreset> faVoicePresetsFor({
  String? baseUrl,
  required String modelId,
}) {
  final url = (baseUrl ?? '').toLowerCase();
  final id = modelId.toLowerCase();
  if (url.contains('generativelanguage') ||
      (id.contains('gemini') && id.contains('tts'))) {
    return _geminiTtsVoices;
  }
  if (id.contains('kokoro')) return _kokoroVoices;
  if (id.contains('tts')) return _openAiTtsVoices;
  return const [];
}

/// A dropdown picking one of [presets] (`label — trait` items), with a
/// compact play/stop button next to it previewing the selected voice's
/// [FaVoicePreset.sampleUrl] (hidden when the preset publishes no sample).
///
/// A [value] that is not among [presets] (a saved free-form voice, a model
/// switch) is kept as an extra raw item — the selection is never silently
/// dropped. Preview playback shares one `AudioPlayer`: starting a preview
/// stops the previous one, network errors reset the state silently.
class FaVoicePresetPicker extends StatefulWidget {
  /// Creates the picker for [presets]; [value] is the current voice id.
  const FaVoicePresetPicker({
    super.key,
    required this.presets,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  /// The voices to choose from ([faVoicePresetsFor]).
  final List<FaVoicePreset> presets;

  /// The current voice id, or null when none is set.
  final String? value;

  /// Called with the picked voice id.
  final ValueChanged<String> onChanged;

  /// Whether the dropdown is interactive (the preview stays enabled).
  final bool enabled;

  @override
  State<FaVoicePresetPicker> createState() => _FaVoicePresetPickerState();
}

enum _PreviewState { idle, loading, playing }

class _FaVoicePresetPickerState extends State<FaVoicePresetPicker> {
  /// The one shared player; created lazily so tests and non-preview picks
  /// never touch the audio backend.
  AudioPlayer? _player;
  StreamSubscription<void>? _completeSubscription;
  _PreviewState _previewState = _PreviewState.idle;

  @override
  void dispose() {
    unawaited(_completeSubscription?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _togglePreview(String url) async {
    if (_previewState != _PreviewState.idle) {
      await _stopPreview();
      return;
    }
    setState(() => _previewState = _PreviewState.loading);
    try {
      final player = _player ??= AudioPlayer();
      _completeSubscription ??= player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _previewState = _PreviewState.idle);
      });
      // play() on the shared player stops any previous preview.
      await player.play(UrlSource(url));
      if (!mounted) return;
      setState(() => _previewState = _PreviewState.playing);
    } on Object {
      // No network, bad URL, missing plugin in tests — silently reset.
      if (mounted) setState(() => _previewState = _PreviewState.idle);
    }
  }

  Future<void> _stopPreview() async {
    try {
      await _player?.stop();
    } on Object {
      // Ignored — the state resets either way.
    }
    if (mounted) setState(() => _previewState = _PreviewState.idle);
  }

  @override
  Widget build(BuildContext context) {
    final strings = FaUiStrings.of(context);
    final theme = Theme.of(context);
    final value = widget.value;
    final selected = value == null
        ? null
        : widget.presets.where((preset) => preset.id == value).firstOrNull;
    final items = [
      for (final preset in widget.presets)
        DropdownMenuItem(
          value: preset.id,
          child: Text(
            preset.trait == null
                ? preset.label
                : '${preset.label} — ${preset.trait}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
      // A saved voice unknown to the presets stays selectable as-is.
      if (value != null && value.isNotEmpty && selected == null)
        DropdownMenuItem(
          value: value,
          child: Text(value, overflow: TextOverflow.ellipsis),
        ),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            // The key re-seeds the FormField when the value changes
            // programmatically (a model switch replacing the presets).
            key: ValueKey<String?>(value),
            initialValue: value == null || value.isEmpty ? null : value,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: strings.mediaModelsVoiceLabel,
            ),
            items: items,
            onChanged: !widget.enabled
                ? null
                : (picked) {
                    if (picked != null) widget.onChanged(picked);
                  },
          ),
        ),
        if (selected?.sampleUrl != null) ...[
          const SizedBox(width: 4),
          IconButton(
            onPressed: () => unawaited(_togglePreview(selected!.sampleUrl!)),
            visualDensity: VisualDensity.compact,
            color: theme.colorScheme.primary,
            icon: switch (_previewState) {
              _PreviewState.loading => const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              _PreviewState.playing => const Icon(Icons.stop, size: 20),
              _PreviewState.idle => const Icon(Icons.play_arrow, size: 20),
            },
          ),
        ],
      ],
    );
  }
}
