// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared, platform-neutral types for the on-device WebLLM provider.
///
/// This file is pure Dart so host tests can use it (and fake the engine)
/// without `dart:js_interop`. The concrete engine lives in
/// `webllm_service_web.dart` (web) and `webllm_service_stub.dart` (host).
library;

/// [AgentConfig.providerKind] value that selects the on-device WebLLM
/// provider. Kept as a constant so the settings form, [AgentService], and
/// tests agree on the spelling.
const webLlmProviderKind = 'webllm';

/// A chat message in the OpenAI-style shape WebLLM's `chatCompletion`
/// expects (`{role, content}`, plain-text only).
typedef WebLlmChatMessage = ({String role, String content});

/// A preset describing an on-device model available through
/// `@mlc-ai/web-llm`'s prebuilt app config.
///
/// Preset ids come from the MLC prebuilt model list (weights on HuggingFace
/// under `mlc-ai/`, model libraries from the `binary-mlc-llm-libs` repo);
/// [sizeLabel] is the approximate download size, cached by the browser after
/// the first load.
final class WebLlmModelPreset {
  /// Creates a model preset.
  const WebLlmModelPreset({
    required this.id,
    required this.displayName,
    required this.sizeLabel,
    this.contextWindow = 2048,
    this.temperature = 0.7,
    this.topP = 0.9,
  });

  /// The prebuilt model id passed to `MLCEngine.reload`.
  final String id;

  /// Human-readable name shown in the model picker.
  final String displayName;

  /// Approximate download size, e.g. `~750 MB`.
  final String sizeLabel;

  /// Context window requested in the reload chat config. Kept small: on-device
  /// KV-cache memory scales with the window, and the demo's turns are short.
  final int contextWindow;

  /// Sampling temperature sent in the reload chat config.
  final double temperature;

  /// Top-p sampling sent in the reload chat config.
  final double topP;
}

/// The on-device models offered by the example app, smallest download first.
///
/// Deliberately capped at ~2 GB downloads: larger weights make the first-run
/// experience in a browser miserable. All ids are `q4f16_1` quantizations
/// from the WebLLM prebuilt list.
const webLlmModelPresets = <WebLlmModelPreset>[
  WebLlmModelPreset(
    id: 'Qwen3-0.6B-q4f16_1-MLC',
    displayName: 'Qwen3 0.6B',
    sizeLabel: '~750 MB',
    temperature: 0.7,
    topP: 0.8,
  ),
  WebLlmModelPreset(
    id: 'Llama-3.2-1B-Instruct-q4f16_1-MLC',
    displayName: 'Llama 3.2 1B',
    sizeLabel: '~770 MB',
    temperature: 0.6,
  ),
  WebLlmModelPreset(
    id: 'gemma-2-2b-it-q4f16_1-MLC',
    displayName: 'Gemma 2 2B',
    sizeLabel: '~1.6 GB',
    temperature: 0.7,
    topP: 0.95,
  ),
  WebLlmModelPreset(
    id: 'SmolLM2-1.7B-Instruct-q4f16_1-MLC',
    displayName: 'SmolLM2 1.7B',
    sizeLabel: '~1.8 GB',
    temperature: 1,
    topP: 1,
  ),
  WebLlmModelPreset(
    id: 'Llama-3.2-3B-Instruct-q4f16_1-MLC',
    displayName: 'Llama 3.2 3B',
    sizeLabel: '~1.9 GB',
    temperature: 0.6,
  ),
  WebLlmModelPreset(
    id: 'Phi-4-mini-instruct-q4f16_1-MLC',
    displayName: 'Phi-4 mini',
    sizeLabel: '~2.1 GB',
    temperature: 1,
    topP: 1,
  ),
];

/// Looks up a preset by [id]; `null` when the id is not one of
/// [webLlmModelPresets].
WebLlmModelPreset? findWebLlmPreset(String id) {
  for (final preset in webLlmModelPresets) {
    if (preset.id == id) return preset;
  }
  return null;
}

/// One engine-init progress report from `@mlc-ai/web-llm` (weights download
/// and shader compilation), surfaced by the settings form as a progress bar.
final class WebLlmProgress {
  /// Creates a progress report.
  const WebLlmProgress({this.fraction, required this.text});

  /// Download/init fraction in `0..1`, when the engine reports one.
  final double? fraction;

  /// Human-readable status line from the engine.
  final String text;
}

/// The engine surface the WebLLM stream function and the settings form talk
/// to. The web build implements it over `@mlc-ai/web-llm`; host platforms get
/// a stub that reports unavailable, and tests inject fakes.
abstract interface class WebLlmEngineApi {
  /// Whether on-device inference can run on this platform (web only).
  bool get isAvailable;

  /// The model id currently loaded in the engine, if any.
  String? get loadedModelId;

  /// Engine-init progress reports (weights download → CacheStorage).
  Stream<WebLlmProgress> get progressEvents;

  /// Loads (downloads + compiles) [preset]; a no-op when already loaded.
  ///
  /// Throws [StateError] with a user-readable message on failure (no WebGPU,
  /// CDN unreachable, download aborted).
  Future<void> loadModel(WebLlmModelPreset preset);

  /// Starts a streaming chat completion over [messages].
  ///
  /// Chunks arrive via [onChunk]; exactly one of [onDone] / [onError] fires
  /// at the end. Returns a cancel function that stops the JS-side iterator.
  Future<void Function()> chatStream({
    required List<WebLlmChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function()? onDone,
    void Function(String message)? onError,
    int? maxTokens,
  });

  /// Interrupts any in-flight generation (maps to
  /// `MLCEngine.interruptGenerate`).
  Future<void> interrupt();
}
