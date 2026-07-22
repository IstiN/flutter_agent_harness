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
/// provider runs on iOS/Android (FFI) only: the web on-device Gemma path
/// moved to the transformers.js provider (`lib/transformers_js/`) because
/// the pinned `@litert-lm/core` (0.12.1) crashes creating the GPU executor
/// for the `-web.litertlm` builds; desktop builds hide it — the plugin's
/// desktop path needs extra native packaging that this app does not do (see
/// the flutter_gemma README's macOS section).
const gemmaUnsupportedPlatformMessage =
    'On-device inference (Gemma 4) is not available in this build of the '
    'app. Pick a hosted provider here — or use the web build (Chrome/Edge), '
    'which runs Gemma 4 on-device via transformers.js, or the iOS/Android '
    'app, which runs it via flutter_gemma.';

/// Whether the Gemma provider appears in the settings provider picker.
/// Pure function so widget/unit tests can exercise the mobile and desktop
/// cases without a device; the app reads [gemmaProviderSupported].
///
/// iOS/Android only: on web the provider is replaced by the transformers.js
/// one ([transformersJsProviderVisible] in `lib/transformers_js/`) — the
/// flutter_gemma web engine (`@litert-lm/core`) is abandoned there.
bool gemmaProviderVisible({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  if (isWeb) return false;
  return platform == TargetPlatform.iOS || platform == TargetPlatform.android;
}

/// Whether the Gemma provider is offered on this platform (iOS/Android;
/// hidden on web — replaced by transformers.js — and on desktop).
bool get gemmaProviderSupported =>
    gemmaProviderVisible(isWeb: kIsWeb, platform: defaultTargetPlatform);

/// The storage note shown under the Gemma model picker in the settings
/// form. On web the weights stream into the browser's OPFS storage
/// (flutter_gemma's `WebStorageMode.streaming` — required because Gemma 4
/// E2B/E4B exceed Chrome's ~2 GB single-blob limit); on mobile they live in
/// the app's on-device storage. The token sentence is identical on both so
/// the form's privacy story stays uniform.
///
/// The web variant also says the model is text-only there: the pinned
/// `@litert-lm/core` (0.12.1) drops image/audio inputs, so advertising
/// multimodal would be dishonest UI.
String gemmaStorageNote({
  required bool isWeb,
  required GemmaModelPreset preset,
}) {
  const tokenNote =
      'the token is used for the download only and is never persisted';
  return isWeb
      ? 'Runs fully offline after download · downloads '
            '${preset.sizeLabelFor(isWeb: true)} once, cached by the browser '
            '(OPFS) · text-only on web (the web engine drops image/audio '
            'inputs) · $tokenNote'
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
    this.webUrl,
    required this.filename,
    required this.sizeLabel,
    this.webSizeLabel,
    this.contextWindow = 4096,
    this.temperature = 1,
    this.topK = 64,
    this.topP = 0.95,
  });

  /// Stable id stored in [AgentConfig.modelId] (not the download URL).
  final String id;

  /// Human-readable name shown in the model picker.
  final String displayName;

  /// Download URL of the mobile/desktop `.litertlm` bundle (HuggingFace
  /// `resolve/main`).
  final String url;

  /// Web-specific download URL — the `-web.litertlm` build of the same
  /// model. The mobile build's section layout is rejected by the web engine
  /// ("Streaming kTfLiteEmbedder models is not supported yet" —
  /// `@litert-lm/core`'s legacy EngineImpl), so web must download this
  /// build instead; same HuggingFace repo, different file.
  final String? webUrl;

  /// File name the plugin installs the model under on mobile (its model id
  /// for `FlutterGemma.isModelInstalled` / `uninstallModel`). On web the id
  /// differs — see [filenameFor].
  final String filename;

  /// Approximate download size of the mobile build, e.g. `~2.4 GB`.
  final String sizeLabel;

  /// Approximate download size of the [webUrl] build when it differs
  /// meaningfully from [sizeLabel].
  final String? webSizeLabel;

  /// Context window (`maxTokens` in the plugin's vocabulary — the KV-cache
  /// budget shared by input and output). 4096 matches the plugin's own
  /// example for Gemma 4.
  final int contextWindow;

  /// Sampling defaults, matching the plugin example's Gemma 4 settings
  /// (Google's recommended values for Gemma instruction-tuned models).
  final double temperature;
  final int topK;
  final double topP;

  /// The download URL for the platform: [webUrl] on web when set, [url]
  /// otherwise.
  String urlFor({required bool isWeb}) =>
      isWeb && webUrl != null ? webUrl! : url;

  /// The model id the plugin installs this preset under on the platform.
  /// The plugin derives the id from the download URL's basename, so on web
  /// (downloading the `-web.litertlm` build via [webUrl]) the id is the web
  /// file name, not [filename]. This matters for the installed-check: the
  /// mobile bytes must not satisfy the web build's cache check (they are
  /// the wrong layout and would crash the engine on load).
  String filenameFor({required bool isWeb}) {
    if (isWeb && webUrl != null) {
      return Uri.parse(webUrl!).pathSegments.last;
    }
    return filename;
  }

  /// Approximate download size for the platform (the `-web.litertlm` builds
  /// are smaller than the mobile ones).
  String sizeLabelFor({required bool isWeb}) =>
      isWeb && webSizeLabel != null ? webSizeLabel! : sizeLabel;
}

/// The on-device Gemma 4 models offered by the example app.
///
/// Both are `ModelType.gemma4` (native function-call tokens) LiteRT-LM
/// builds; E2B is the default (fits in 4 GB phones with the
/// increased-memory entitlement). Web downloads the `-web.litertlm` build
/// (see [GemmaModelPreset.webUrl]); the web sizes below were HEAD-checked
/// against HuggingFace (E2B ≈ 1.87 GiB, E4B ≈ 2.77 GiB).
const gemmaModelPresets = <GemmaModelPreset>[
  GemmaModelPreset(
    id: 'gemma-4-E2B-it',
    displayName: 'Gemma 4 E2B',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it.litertlm',
    webUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it-web.litertlm',
    filename: 'gemma-4-E2B-it.litertlm',
    sizeLabel: '~2.4 GB',
    webSizeLabel: '~1.9 GB',
  ),
  GemmaModelPreset(
    id: 'gemma-4-E4B-it',
    displayName: 'Gemma 4 E4B',
    url:
        'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/'
        'resolve/main/gemma-4-E4B-it.litertlm',
    webUrl:
        'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/'
        'resolve/main/gemma-4-E4B-it-web.litertlm',
    filename: 'gemma-4-E4B-it.litertlm',
    sizeLabel: '~4.3 GB',
    webSizeLabel: '~2.8 GB',
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

/// One model file present in the plugin's model repository (web: OPFS;
/// mobile: app storage), as reported by the settings cache section's scan.
final class GemmaInstalledModel {
  /// Creates an installed-model entry.
  const GemmaInstalledModel({required this.filename, this.sizeBytes});

  /// The repository id — the download URL's basename (see
  /// [GemmaModelPreset.filenameFor]).
  final String filename;

  /// Recorded byte size, when the repository stored one.
  final int? sizeBytes;
}

/// The engine surface the Gemma stream function and the settings form talk
/// to. The iOS/Android builds implement it over the `flutter_gemma` plugin
/// (the web build compiles the same implementation but reports unavailable —
/// the web on-device Gemma path is `lib/transformers_js/`); desktop gets a
/// stub that reports unavailable, and tests inject fakes.
abstract interface class GemmaEngineApi {
  /// Whether on-device inference can run on this platform (iOS/Android;
  /// web and desktop report unavailable).
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

  /// Every model file in the plugin's repository, with recorded sizes.
  /// Includes stale entries installed under another platform's file name
  /// (e.g. a mobile-named build left in the browser's OPFS), which the
  /// settings cache section surfaces as deletable orphans.
  Future<List<GemmaInstalledModel>> installedModels();

  /// Deletes the model installed under [filename] — repository metadata and
  /// files. When [filename] is the active model, the in-memory model is
  /// closed and the plugin's persisted active identity cleared first, so a
  /// later load cannot resurrect a spec whose files are gone.
  Future<void> uninstall(String filename);
}
