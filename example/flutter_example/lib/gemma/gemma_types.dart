// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared, platform-neutral types for the on-device Gemma 4 provider.
///
/// This file is pure Dart (plus `flutter/foundation`) so host tests can use
/// it (and fake the engine) without the `flutter_gemma` plugin. The concrete
/// engine lives in `gemma_service_plugin.dart` (web + iOS/Android) and
/// `gemma_service_stub.dart` (desktop) — see `gemma_service.dart`.
library;

import 'package:flutter/foundation.dart';

/// [AgentConfig.providerKind] value that selects the on-device Gemma
/// provider. Kept as a constant so the settings form, [AgentService], and
/// tests agree on the spelling.
const gemmaProviderKind = 'gemma';

/// Shown when the Gemma provider is used on an unsupported platform. The
/// provider runs on web (`@litert-lm/core`) and on iOS/Android (FFI);
/// desktop builds hide it — the plugin's desktop path needs extra native
/// packaging that this app does not do (see the flutter_gemma README's
/// macOS section).
const gemmaUnsupportedPlatformMessage =
    'On-device inference (Gemma 4) is not available in the desktop builds '
    'of this app. Pick a hosted provider here — or use the web build '
    '(Chrome/Edge) or the iOS/Android app, which run Gemma 4 on-device.';

/// Whether the Gemma provider appears in the settings provider picker.
/// Pure function so widget/unit tests can exercise the web and desktop
/// cases without a device; the app reads [gemmaProviderSupported].
bool gemmaProviderVisible({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  if (isWeb) return true;
  return platform == TargetPlatform.iOS || platform == TargetPlatform.android;
}

/// Whether the Gemma provider is offered on this platform (web and
/// iOS/Android; hidden on desktop).
bool get gemmaProviderSupported =>
    gemmaProviderVisible(isWeb: kIsWeb, platform: defaultTargetPlatform);

/// The storage note shown under the Gemma model picker in the settings
/// form. On web the weights stream into the browser's OPFS storage
/// (flutter_gemma's `WebStorageMode.streaming` — required because Gemma 4
/// E2B/E4B exceed Chrome's ~2 GB single-blob limit); on mobile they live in
/// the app's on-device storage. The token sentence is identical on both so
/// the form's privacy story stays uniform.
String gemmaStorageNote({
  required bool isWeb,
  required GemmaModelPreset preset,
}) {
  const tokenNote =
      'the token is used for the download only and is never persisted';
  return isWeb
      ? 'Runs fully offline after download · downloads ${preset.sizeLabel} '
            'once, cached by the browser (OPFS) · $tokenNote'
      : 'Runs fully offline after download · weights stay on the device · '
            '$tokenNote';
}

/// A chat message in the provider-neutral shape the Gemma stream function
/// hands to the engine. Roles:
/// - `user` / `assistant`: plain text turns.
/// - `tool_call`: an assistant function-call turn; [content] is the
///   OpenAI-style assistant JSON (`{"role":"assistant","tool_calls":[...]}`)
///   — the same shape the plugin's own history replay stores.
/// - `tool_result`: a tool execution result; [toolName] is set and
///   [content] is the result text.
typedef GemmaChatMessage = ({String role, String content, String? toolName});

/// A preset describing an on-device Gemma 4 model installable through the
/// `flutter_gemma` plugin (LiteRT-LM `.litertlm` builds from the
/// `litert-community` HuggingFace repos; FFI on iOS/Android,
/// `@litert-lm/core` on web).
final class GemmaModelPreset {
  /// Creates a model preset.
  const GemmaModelPreset({
    required this.id,
    required this.displayName,
    required this.url,
    required this.filename,
    required this.sizeLabel,
    this.contextWindow = 4096,
    this.temperature = 1,
    this.topK = 64,
    this.topP = 0.95,
  });

  /// Stable id stored in [AgentConfig.modelId] (not the download URL).
  final String id;

  /// Human-readable name shown in the model picker.
  final String displayName;

  /// Download URL of the `.litertlm` bundle (HuggingFace `resolve/main`).
  final String url;

  /// File name the plugin installs the model under (its model id for
  /// `FlutterGemma.isModelInstalled` / `uninstallModel`).
  final String filename;

  /// Approximate download size, e.g. `~2.4 GB`.
  final String sizeLabel;

  /// Context window (`maxTokens` in the plugin's vocabulary — the KV-cache
  /// budget shared by input and output). 4096 matches the plugin's own
  /// example for Gemma 4.
  final int contextWindow;

  /// Sampling defaults, matching the plugin example's Gemma 4 settings
  /// (Google's recommended values for Gemma instruction-tuned models).
  final double temperature;
  final int topK;
  final double topP;
}

/// The on-device Gemma 4 models offered by the example app.
///
/// Both are `ModelType.gemma4` (native function-call tokens) LiteRT-LM
/// builds; E2B is the default (fits in 4 GB phones with the
/// increased-memory entitlement).
const gemmaModelPresets = <GemmaModelPreset>[
  GemmaModelPreset(
    id: 'gemma-4-E2B-it',
    displayName: 'Gemma 4 E2B',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it.litertlm',
    filename: 'gemma-4-E2B-it.litertlm',
    sizeLabel: '~2.4 GB',
  ),
  GemmaModelPreset(
    id: 'gemma-4-E4B-it',
    displayName: 'Gemma 4 E4B',
    url:
        'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/'
        'resolve/main/gemma-4-E4B-it.litertlm',
    filename: 'gemma-4-E4B-it.litertlm',
    sizeLabel: '~4.3 GB',
  ),
];

/// Looks up a preset by [id]; `null` when the id is not one of
/// [gemmaModelPresets].
GemmaModelPreset? findGemmaPreset(String id) {
  for (final preset in gemmaModelPresets) {
    if (preset.id == id) return preset;
  }
  return null;
}

/// One install/load progress report, surfaced by the settings form as a
/// progress bar (mirrors [WebLlmProgress]).
final class GemmaProgress {
  /// Creates a progress report.
  const GemmaProgress({this.fraction, required this.text});

  /// Download fraction in `0..1` when known (`null` → indeterminate bar).
  final double? fraction;

  /// Human-readable status line.
  final String text;
}

/// The engine surface the Gemma stream function and the settings form talk
/// to. The web and iOS/Android builds implement it over the `flutter_gemma`
/// plugin; desktop gets a stub that reports unavailable, and tests inject
/// fakes.
abstract interface class GemmaEngineApi {
  /// Whether on-device inference can run on this platform (web and
  /// iOS/Android; desktop reports unavailable).
  bool get isAvailable;

  /// The preset id currently loaded in the engine, if any.
  String? get loadedModelId;

  /// Install/load progress reports (model download → on-device load).
  Stream<GemmaProgress> get progressEvents;

  /// Whether [preset]'s weights are already downloaded on device.
  Future<bool> isModelInstalled(GemmaModelPreset preset);

  /// Downloads [preset]'s weights (skipping what is already installed) and
  /// marks the model active. Progress is reported via [progressEvents].
  ///
  /// [huggingFaceToken] authorizes gated HuggingFace repos; the
  /// litert-community Gemma 4 repos currently accept unauthenticated
  /// downloads, but pass it when given — gating is the repo owner's call.
  ///
  /// Throws [StateError] with a user-readable message on failure (gated
  /// repo without token, network down, unsupported platform).
  Future<void> installModel(
    GemmaModelPreset preset, {
    String? huggingFaceToken,
  });

  /// Loads [preset] into the engine; a no-op when already loaded. The model
  /// must be installed first (the settings form's connect flow does both).
  Future<void> loadModel(GemmaModelPreset preset);

  /// Starts one streaming chat turn over [messages].
  ///
  /// Text chunks arrive via [onChunk]. When the model emits function calls
  /// they are delivered complete (the plugin surfaces Gemma 4's SDK-parsed
  /// `tool_calls` at end-of-stream) as a single [onToolCalls] payload: a
  /// JSON-encoded array in the OpenAI streaming shape (`[{index, type:
  /// 'function', function: {name, arguments}}]`, `arguments` a JSON
  /// string) — the same shape the WebLLM engine adapter emits, so the
  /// stream function maps both identically.
  ///
  /// Exactly one of [onDone] / [onError] fires at the end. The plugin
  /// reports no finish reason, so [onDone] carries none; the stream
  /// function infers `toolUse` from emitted calls.
  ///
  /// [systemInstruction] maps to the chat's native system instruction;
  /// [tools] is the OpenAI tools array (`[{type: 'function', function:
  /// {name, description, parameters}}]`); [maxOutputTokens] caps the
  /// generated reply length (distinct from the context window).
  Future<void> chatStream({
    required List<GemmaChatMessage> messages,
    required void Function(String chunk) onChunk,
    String? systemInstruction,
    void Function()? onDone,
    void Function(String message)? onError,
    void Function(String toolCallsJson)? onToolCalls,
    List<Map<String, dynamic>>? tools,
    int? maxOutputTokens,
  });

  /// Interrupts any in-flight generation (maps to the chat's
  /// `stopGeneration`).
  Future<void> interrupt();

  /// Unloads the current model from memory (weights stay on disk).
  Future<void> unload();
}
