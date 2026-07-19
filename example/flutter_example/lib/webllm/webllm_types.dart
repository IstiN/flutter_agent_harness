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
    this.isCoder = false,
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

  /// Whether the model is code-specialized (the Qwen2.5-Coder family); the
  /// settings picker shows a "coder" badge next to these presets.
  final bool isCoder;
}

/// The on-device models offered by the example app, grouped by family.
///
/// The 22 flutter_agent_memory demo presets (relative order preserved,
/// ids from the WebLLM prebuilt list), plus the Qwen2.5-Coder and Qwen3.5
/// families added later from the same list (ids and wasm libs verified
/// against `@mlc-ai/web-llm@0.2.84`). Sizes are approximate download
/// weights, cached by the browser after the first load.
const webLlmModelPresets = <WebLlmModelPreset>[
  // === SmolLM2 ===
  WebLlmModelPreset(
    id: 'SmolLM2-135M-Instruct-q0f16-MLC',
    displayName: 'SmolLM2 135M',
    sizeLabel: '~270 MB',
    temperature: 1,
    topP: 1,
  ),
  WebLlmModelPreset(
    id: 'SmolLM2-360M-Instruct-q0f16-MLC',
    displayName: 'SmolLM2 360M',
    sizeLabel: '~720 MB',
    temperature: 1,
    topP: 1,
  ),
  WebLlmModelPreset(
    id: 'SmolLM2-1.7B-Instruct-q4f16_1-MLC',
    displayName: 'SmolLM2 1.7B',
    sizeLabel: '~1.8 GB',
    temperature: 1,
    topP: 1,
  ),

  // === Qwen 2.5 ===
  WebLlmModelPreset(
    id: 'Qwen2.5-0.5B-Instruct-q0f16-MLC',
    displayName: 'Qwen2.5 0.5B',
    sizeLabel: '~1 GB',
    temperature: 0.7,
    topP: 0.8,
  ),
  WebLlmModelPreset(
    id: 'Qwen2.5-1.5B-Instruct-q4f16_1-MLC',
    displayName: 'Qwen2.5 1.5B',
    sizeLabel: '~1 GB',
    temperature: 0.7,
    topP: 0.8,
  ),
  WebLlmModelPreset(
    id: 'Qwen2.5-3B-Instruct-q4f16_1-MLC',
    displayName: 'Qwen2.5 3B',
    sizeLabel: '~1.9 GB',
    temperature: 0.7,
    topP: 0.8,
  ),
  WebLlmModelPreset(
    id: 'Qwen2.5-7B-Instruct-q4f16_1-MLC',
    displayName: 'Qwen2.5 7B',
    sizeLabel: '~4.2 GB',
    temperature: 0.7,
    topP: 0.8,
  ),

  // === Qwen 2.5 Coder ===
  WebLlmModelPreset(
    id: 'Qwen2.5-Coder-1.5B-Instruct-q4f16_1-MLC',
    displayName: 'Qwen2.5-Coder 1.5B',
    sizeLabel: '~900 MB',
    temperature: 0.7,
    topP: 0.8,
    isCoder: true,
  ),
  WebLlmModelPreset(
    id: 'Qwen2.5-Coder-3B-Instruct-q4f16_1-MLC',
    displayName: 'Qwen2.5-Coder 3B',
    sizeLabel: '~1.8 GB',
    temperature: 0.7,
    topP: 0.8,
    isCoder: true,
  ),

  // === Qwen 3 ===
  WebLlmModelPreset(
    id: 'Qwen3-0.6B-q4f16_1-MLC',
    displayName: 'Qwen3 0.6B',
    sizeLabel: '~750 MB',
    temperature: 0.7,
    topP: 0.8,
  ),
  WebLlmModelPreset(
    id: 'Qwen3-1.7B-q4f16_1-MLC',
    displayName: 'Qwen3 1.7B',
    sizeLabel: '~1.4 GB',
    temperature: 0.7,
    topP: 0.8,
  ),
  WebLlmModelPreset(
    id: 'Qwen3-4B-q4f16_1-MLC',
    displayName: 'Qwen3 4B',
    sizeLabel: '~2.8 GB',
    temperature: 0.7,
    topP: 0.8,
  ),

  // === Qwen 3.5 ===
  WebLlmModelPreset(
    id: 'Qwen3.5-0.8B-q4f16_1-MLC',
    displayName: 'Qwen3.5 0.8B',
    sizeLabel: '~450 MB',
    temperature: 0.7,
    topP: 0.8,
  ),
  WebLlmModelPreset(
    id: 'Qwen3.5-2B-q4f16_1-MLC',
    displayName: 'Qwen3.5 2B',
    sizeLabel: '~1.1 GB',
    temperature: 0.7,
    topP: 0.8,
  ),
  WebLlmModelPreset(
    id: 'Qwen3.5-4B-q4f16_1-MLC',
    displayName: 'Qwen3.5 4B',
    sizeLabel: '~2.4 GB',
    temperature: 0.7,
    topP: 0.8,
  ),

  // === Phi ===
  WebLlmModelPreset(
    id: 'Phi-3.5-mini-instruct-q4f16_1-MLC',
    displayName: 'Phi-3.5 mini',
    sizeLabel: '~2.3 GB',
    temperature: 1,
    topP: 1,
  ),
  WebLlmModelPreset(
    id: 'Phi-3.5-mini-instruct-q4f16_1-MLC-1k',
    displayName: 'Phi-3.5 mini (1k)',
    sizeLabel: '~1.6 GB',
    contextWindow: 1024,
    temperature: 1,
    topP: 1,
  ),
  WebLlmModelPreset(
    id: 'Phi-4-mini-instruct-q4f16_1-MLC',
    displayName: 'Phi-4 mini',
    sizeLabel: '~2.1 GB',
    temperature: 1,
    topP: 1,
  ),

  // === Gemma 2 ===
  WebLlmModelPreset(
    id: 'gemma-2-2b-it-q4f16_1-MLC',
    displayName: 'Gemma 2 2B',
    sizeLabel: '~1.6 GB',
    temperature: 0.7,
    topP: 0.95,
  ),
  WebLlmModelPreset(
    id: 'gemma-2-2b-it-q4f16_1-MLC-1k',
    displayName: 'Gemma 2 2B (1k)',
    sizeLabel: '~1.2 GB',
    contextWindow: 1024,
    temperature: 0.7,
    topP: 0.95,
  ),

  // === Llama 3.2 ===
  WebLlmModelPreset(
    id: 'Llama-3.2-1B-Instruct-q4f16_1-MLC',
    displayName: 'Llama 3.2 1B',
    sizeLabel: '~770 MB',
    temperature: 0.6,
  ),
  WebLlmModelPreset(
    id: 'Llama-3.2-1B-Instruct-q4f32_1-MLC',
    displayName: 'Llama 3.2 1B (f32)',
    sizeLabel: '~1.4 GB',
    temperature: 0.6,
  ),
  WebLlmModelPreset(
    id: 'Llama-3.2-3B-Instruct-q4f16_1-MLC',
    displayName: 'Llama 3.2 3B',
    sizeLabel: '~1.9 GB',
    temperature: 0.6,
  ),

  // === Llama 3.1 ===
  WebLlmModelPreset(
    id: 'Llama-3.1-8B-Instruct-q4f16_1-MLC-1k',
    displayName: 'Llama 3.1 8B (1k)',
    sizeLabel: '~4.3 GB',
    contextWindow: 1024,
    temperature: 0.6,
  ),
  WebLlmModelPreset(
    id: 'Llama-3.1-8B-Instruct-q4f16_1-MLC',
    displayName: 'Llama 3.1 8B',
    sizeLabel: '~4.6 GB',
    temperature: 0.6,
  ),

  // === Hermes ===
  WebLlmModelPreset(
    id: 'Hermes-3-Llama-3.2-3B-q4f16_1-MLC',
    displayName: 'Hermes 3 Llama 3.2 3B',
    sizeLabel: '~1.9 GB',
    temperature: 0.6,
  ),
  WebLlmModelPreset(
    id: 'Hermes-3-Llama-3.1-8B-q4f16_1-MLC',
    displayName: 'Hermes 3 Llama 3.1 8B',
    sizeLabel: '~4.5 GB',
    temperature: 0.6,
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

/// Cache-storage info for one on-device model's downloaded weights.
///
/// WebLLM stores weights in the browser's CacheStorage (keyed by download
/// URL, which contains the model id); off the web there is no cache and
/// [WebLlmEngineApi.modelCacheInfo] returns `null`.
final class WebLlmCacheInfo {
  /// Creates a cache report.
  const WebLlmCacheInfo({required this.cached, this.bytes});

  /// Whether any CacheStorage entries for the model id exist.
  final bool cached;

  /// Total cached bytes when cheaply known (sum of `content-length`
  /// headers), else `null` — the preset's `sizeLabel` is the fallback.
  final int? bytes;
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
  /// Text chunks arrive via [onChunk]; exactly one of [onDone] / [onError]
  /// fires at the end; [onDone] receives the completion's finish reason
  /// (`stop`, `length`, or `''` when the engine reports none).
  ///
  /// Plain chat only — tool calling lives one layer up, in the prompt-tools
  /// wrapper (see `webllm_stream_function.dart`); the engine's native
  /// function-calling mode is deliberately not used.
  ///
  /// Returns a cancel function that stops the JS-side iterator.
  Future<void Function()> chatStream({
    required List<WebLlmChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function(String finishReason)? onDone,
    void Function(String message)? onError,
    int? maxTokens,
  });

  /// Interrupts any in-flight generation (maps to
  /// `MLCEngine.interruptGenerate`).
  Future<void> interrupt();

  /// CacheStorage report for [modelId]'s downloaded weights, or `null` when
  /// the cache cannot be queried (non-web platforms, blocked storage).
  Future<WebLlmCacheInfo?> modelCacheInfo(String modelId);

  /// Deletes [modelId]'s weights from CacheStorage. When [modelId] is the
  /// currently loaded model, the engine state is reset so the next
  /// [loadModel] re-downloads instead of running against dropped weights.
  Future<void> deleteCachedModel(String modelId);
}
