// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared, platform-neutral types for the on-device transformers.js provider
/// (Gemma 4 ONNX via `@huggingface/transformers` + onnxruntime-web/WebGPU).
///
/// This file is pure Dart so host tests can use it (and fake the engine)
/// without `dart:js_interop`. The concrete engine lives in
/// `transformers_js_service_web.dart` (web) and
/// `transformers_js_service_stub.dart` (host).
library;

import 'package:flutter/foundation.dart';

/// [AgentConfig.providerKind] value that selects the on-device
/// transformers.js provider. Kept as a constant so the settings form,
/// [AgentService], and tests agree on the spelling.
const transformersJsProviderKind = 'transformers_js';

/// Shown when the transformers.js provider is used off the web (the stub's
/// every operation fails with this; the settings picker hides the provider
/// off the web anyway — see [transformersJsProviderVisible]).
const transformersJsUnavailableMessage =
    'On-device inference (Gemma, transformers.js) is only available in the '
    'web build of this app. Pick a hosted provider here, or open the web '
    'demo in Chrome/Edge.';

/// Whether the transformers.js provider appears in the settings provider
/// picker. Web-only: the ONNX Runtime Web backend needs a browser (WebGPU);
/// on iOS/Android the flutter_gemma provider covers on-device Gemma, and
/// desktop builds offer no on-device provider at all. Pure function so
/// widget/unit tests can exercise the rule; the app reads
/// [transformersJsProviderSupported].
bool transformersJsProviderVisible({required bool isWeb}) => isWeb;

/// Whether the transformers.js provider is offered on this platform
/// (web only).
bool get transformersJsProviderSupported =>
    transformersJsProviderVisible(isWeb: kIsWeb);

/// A chat message in the provider-neutral shape the transformers.js stream
/// function hands to the engine. [content] is plain text; [images] carries
/// attached images as `data:` URIs (base64), which the web engine feeds to
/// the model's vision encoder (see `transformers_js_helpers.js`). Roles are
/// `system` / `user` / `assistant` — the Gemma chat template has no `tool`
/// role, so tool history degrades to text one layer up (see
/// `transformers_js_stream_function.dart`).
typedef TransformersJsChatMessage = ({
  String role,
  String content,
  List<String> images,
});

/// A preset describing an on-device model loadable through
/// `@huggingface/transformers` from a HuggingFace ONNX repo.
///
/// [id] is the HuggingFace repo id (`org/name`); the library downloads the
/// ONNX weights selected by [dtype] straight from huggingface.co into the
/// browser's CacheStorage (`transformers-cache`) on first use. Public repos
/// need no token.
final class TransformersJsModelPreset {
  /// Creates a model preset.
  const TransformersJsModelPreset({
    required this.id,
    required this.displayName,
    required this.sizeLabel,
    required this.dtype,
    required this.downloadSizes,
    this.contextWindow = 4096,
    this.supportsVision = false,
  });

  /// The HuggingFace repo id passed to `from_pretrained`.
  final String id;

  /// Human-readable name shown in the model picker.
  final String displayName;

  /// Approximate download size, e.g. `~3.2 GB`, cached by the browser after
  /// the first load.
  final String sizeLabel;

  /// Per-component dtype selection (the `dtype` option of
  /// `from_pretrained`), e.g. `{embed_tokens: q4f16, decoder_model_merged:
  /// q4f16, vision_encoder: q4f16, audio_encoder: q4f16}`.
  ///
  /// The map MUST cover every component the model class instantiates:
  /// transformers.js resolves a missing component to the device default
  /// (fp32) and downloads that instead — with `audio_encoder` absent this
  /// pulled the 1.18 GB fp32 audio encoder the app never uses. The audio
  /// session itself cannot be excluded: `Gemma4ForConditionalGeneration` is
  /// registered as an image+audio→text model type whose session list always
  /// includes `audio_encoder` (no `from_pretrained` option filters
  /// components, and no other registered class loads this repo's vision
  /// encoder with the right inputs). Pinning `audio_encoder` to q4f16 bounds
  /// the dead weight to 0.17 GB — the smallest audio variant in the repo.
  final Map<String, String> dtype;

  /// Expected download size in bytes per repo-relative file
  /// (`onnx/embed_tokens_q4f16.onnx_data` → 1590689792), taken from the
  /// HuggingFace API for the revision this preset targets.
  ///
  /// Doubles as the download ALLOWLIST: the load helper
  /// (`transformers_js_helpers.js`) wraps `env.fetch` while loading and
  /// rejects any repo URL outside this key set, so no file outside the
  /// requested dtype set (no fp32 variants, no other quantizations) can
  /// download. The smooth aggregate progress bar
  /// ([TransformersJsProgressAggregator]) uses the byte values as per-file
  /// weights. Sizes are informational — a repo-side re-upload shifts bytes,
  /// not correctness (fractions clamp at 100%).
  final Map<String, int> downloadSizes;

  /// Context window reported to the agent loop (drives overflow/compaction
  /// heuristics). Kept small: on-device KV-cache memory scales with the
  /// window, and the demo's turns are short.
  final int contextWindow;

  /// Whether the preset loads a vision encoder and accepts image inputs.
  /// Advertised in the model picker; image blocks in user messages are only
  /// forwarded when this is true (otherwise they degrade to an omission
  /// note).
  final bool supportsVision;
}

/// The on-device models offered by the example app through transformers.js.
///
/// Starts with a single preset: the public `onnx-community` ONNX export of
/// Gemma 4 E2B (the model the webml-community/Gemma-4-WebGPU space runs).
/// q4f16 weights: decoder 1.52 GB + embed tokens 1.59 GB + vision encoder
/// 0.10 GB + audio encoder 0.17 GB ≈ 3.4 GB, downloaded from HuggingFace on
/// first use and cached by the browser. The audio encoder is dead weight —
/// the app has no audio input UI — but transformers.js always instantiates
/// it for this model class; q4f16 is the smallest variant (see
/// [TransformersJsModelPreset.dtype]).
const transformersJsModelPresets = <TransformersJsModelPreset>[
  TransformersJsModelPreset(
    id: 'onnx-community/gemma-4-E2B-it-ONNX',
    displayName: 'Gemma 4 E2B (ONNX)',
    sizeLabel: '~3.4 GB',
    dtype: {
      'embed_tokens': 'q4f16',
      'decoder_model_merged': 'q4f16',
      'vision_encoder': 'q4f16',
      'audio_encoder': 'q4f16',
    },
    // Byte sizes from the HuggingFace paths-info API (rev main, 2026-07).
    downloadSizes: {
      'config.json': 5549,
      'generation_config.json': 238,
      'preprocessor_config.json': 43,
      'processor_config.json': 1689,
      'tokenizer_config.json': 18807,
      'tokenizer.json': 19439251,
      'chat_template.jinja': 16317,
      'onnx/embed_tokens_q4f16.onnx': 5621,
      'onnx/embed_tokens_q4f16.onnx_data': 1590689792,
      'onnx/decoder_model_merged_q4f16.onnx': 673231,
      'onnx/decoder_model_merged_q4f16.onnx_data': 1519700992,
      'onnx/vision_encoder_q4f16.onnx': 189124,
      'onnx/vision_encoder_q4f16.onnx_data': 99189440,
      'onnx/audio_encoder_q4f16.onnx': 260446,
      'onnx/audio_encoder_q4f16.onnx_data': 171258112,
    },
    supportsVision: true,
  ),
];

/// Looks up a preset by [id]; `null` when the id is not one of
/// [transformersJsModelPresets].
TransformersJsModelPreset? findTransformersJsPreset(String id) {
  for (final preset in transformersJsModelPresets) {
    if (preset.id == id) return preset;
  }
  return null;
}

/// Cache-storage info for one on-device model's downloaded weights.
///
/// transformers.js stores downloads in the browser's CacheStorage (cache
/// name `transformers-cache`, keys are huggingface.co URLs containing the
/// repo id); off the web there is no cache and
/// [TransformersJsEngineApi.modelCacheInfo] returns `null`.
final class TransformersJsCacheInfo {
  /// Creates a cache report.
  const TransformersJsCacheInfo({required this.cached, this.bytes});

  /// Whether any CacheStorage entries for the model id exist.
  final bool cached;

  /// Total cached bytes when cheaply known (sum of `content-length`
  /// headers), else `null` — the preset's `sizeLabel` is the fallback.
  final int? bytes;
}

/// One download progress report from `@huggingface/transformers` (weights
/// download → CacheStorage), surfaced by the settings form as a progress
/// bar.
final class TransformersJsProgress {
  /// Creates a progress report.
  const TransformersJsProgress({this.fraction, required this.text});

  /// Download fraction in `0..1`, when the engine reports one.
  final double? fraction;

  /// Human-readable status line from the engine.
  final String text;
}

/// One raw per-file progress event forwarded by the JS load helper (see
/// `transformers_js_helpers.js`) — the transformers.js download events
/// (`initiate` / `progress` / `done` / `ready`) reduced to plain values
/// that cross the js_interop boundary as JSON.
typedef TransformersJsDownloadEvent = ({
  String status,
  String? file,
  int? loaded,
  int? total,
});

/// Aggregates raw per-file download events into a SMOOTH overall progress
/// report for the settings form's progress bar.
///
/// The library's own events are per file (fraction resets per file — the
/// "flickering bar" bug), so this aggregator weights each file by its
/// expected byte size ([TransformersJsModelPreset.downloadSizes]) and sums
/// completed + in-flight fractions across files. The reported fraction is
/// monotonic: it never moves backwards, even when events arrive out of
/// order or a file restarts. Pure Dart so host tests can drive it.
final class TransformersJsProgressAggregator {
  /// Creates an aggregator over [expectedFiles] (repo-relative path →
  /// expected bytes, see [TransformersJsModelPreset.downloadSizes]).
  TransformersJsProgressAggregator(Map<String, int> expectedFiles)
    : _expected = Map.unmodifiable(expectedFiles),
      _totalBytes = expectedFiles.values.fold(0, (sum, n) => sum + n);

  final Map<String, int> _expected;
  final int _totalBytes;
  final Map<String, int> _loaded = {};
  double _maxFraction = 0;
  String? _currentFile;

  /// Total expected bytes across all tracked files.
  int get totalBytes => _totalBytes;

  /// Feeds one raw [event]; returns the aggregate report. Events for files
  /// outside the expected set (none should pass the fetch allowlist) update
  /// the status line only, never the fraction.
  TransformersJsProgress update(TransformersJsDownloadEvent event) {
    final file = event.file;
    if (file != null) {
      final expected = _expected[file];
      if (expected != null) {
        switch (event.status) {
          case 'initiate':
            _loaded.putIfAbsent(file, () => 0);
          case 'progress':
            _loaded[file] = (event.loaded ?? _loaded[file] ?? 0).clamp(
              0,
              expected,
            );
          case 'done':
            _loaded[file] = expected;
        }
      }
      _currentFile = file.split('/').last;
    }

    var fraction = switch (event.status) {
      'ready' => 1.0,
      _ => _overallFraction(),
    };
    // Monotonic: the bar never moves backwards.
    if (fraction < _maxFraction) {
      fraction = _maxFraction;
    } else {
      _maxFraction = fraction;
    }

    final percent = (fraction * 100).floor();
    final text = switch (event.status) {
      'ready' => 'Model ready',
      'prepare' => 'Preparing model download…',
      _ when _currentFile != null => 'Downloading $_currentFile — $percent%',
      _ => 'Downloading model weights — $percent%',
    };
    return TransformersJsProgress(fraction: fraction, text: text);
  }

  double _overallFraction() {
    if (_totalBytes <= 0) return 0;
    var loaded = 0;
    for (final entry in _expected.entries) {
      loaded += (_loaded[entry.key] ?? 0).clamp(0, entry.value);
    }
    return loaded / _totalBytes;
  }
}

/// The engine surface the transformers.js stream function and the settings
/// form talk to. The web build implements it over `@huggingface/transformers`
/// (loaded from CDN by `web/index.html`); host platforms get a stub that
/// reports unavailable, and tests inject fakes.
abstract interface class TransformersJsEngineApi {
  /// Whether on-device inference can run on this platform (web only).
  bool get isAvailable;

  /// The model id currently loaded in the engine, if any.
  String? get loadedModelId;

  /// Download progress reports (weights download → CacheStorage).
  Stream<TransformersJsProgress> get progressEvents;

  /// Loads (downloads + compiles) [preset]; a no-op when already loaded.
  ///
  /// Throws [StateError] with a user-readable message on failure (no WebGPU,
  /// CDN unreachable, download aborted).
  Future<void> loadModel(TransformersJsModelPreset preset);

  /// Starts a streaming chat completion over [messages].
  ///
  /// Text chunks arrive via [onChunk]; exactly one of [onDone] / [onError]
  /// fires at the end; [onDone] receives the finish reason (`stop` or
  /// `length` — derived from the generated token count by the JS helper).
  ///
  /// Plain chat only — tool calling lives one layer up, in the prompt-tools
  /// wrapper (see `transformers_js_stream_function.dart`); Gemma's native
  /// function-calling tokens are deliberately not used.
  ///
  /// Returns a cancel function that interrupts the JS-side generation.
  Future<void Function()> chatStream({
    required List<TransformersJsChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function(String finishReason)? onDone,
    void Function(String message)? onError,
    int? maxTokens,
  });

  /// Interrupts any in-flight generation (maps to
  /// `InterruptableStoppingCriteria.interrupt`).
  Future<void> interrupt();

  /// Drops the loaded model so the next [loadModel] re-initializes from
  /// the cached weights.
  ///
  /// Called after a generation failure: ONNX Runtime errors (e.g. the
  /// WebGPU `mapAsync ... invalid Buffer` OrtRun failure an undecodable
  /// image input causes) can poison the session, and retrying against the
  /// same instance inherits the broken state. Weights stay in CacheStorage,
  /// so recovery pays shader compilation, not the multi-GB download.
  Future<void> unloadModel();

  /// CacheStorage report for [modelId]'s downloaded weights, or `null` when
  /// the cache cannot be queried (non-web platforms, blocked storage).
  Future<TransformersJsCacheInfo?> modelCacheInfo(String modelId);

  /// Deletes [modelId]'s weights from CacheStorage. When [modelId] is the
  /// currently loaded model, the engine state is reset so the next
  /// [loadModel] re-downloads instead of running against dropped weights.
  Future<void> deleteCachedModel(String modelId);
}
