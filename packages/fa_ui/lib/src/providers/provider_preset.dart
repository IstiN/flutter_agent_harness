// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/widgets.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart' as harness;

import 'package:fa_ui/src/host_config.dart';
import 'package:fa_ui/src/stores/keychain_store.dart';
import 'package:fa_ui/src/stores/media_models_store.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/stores/session_keys_store.dart';
import 'package:fa_ui/src/strings/fa_ui_strings.dart';

/// A bring-your-own-key provider preset. Hosted presets talk to an
/// OpenAI-compatible chat-completions endpoint; [webllm] runs a small model
/// on-device in the browser (no key, no endpoint); [gemma] runs Gemma 4
/// on-device via the `flutter_gemma` plugin on iOS/Android;
/// [transformersJs] runs Gemma 4 ONNX on-device in the browser via
/// `@huggingface/transformers`.
///
/// Presets are built-in and cannot be deleted; user-added providers
/// ([CustomProvider], managed by [ProviderRegistry]) appear in the same
/// picker and can be edited and removed. The on-device presets have no
/// endpoint UI of their own here — host apps route them through injected
/// builders (`FaOnDeviceRoute`).
enum ProviderPreset {
  openrouter(
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'z-ai/glm-5.2',
  ),
  ollamaCloud(baseUrl: 'https://ollama.com/v1', defaultModel: 'gpt-oss:120b'),
  gemini(
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    defaultModel: 'gemini-2.5-flash',
  ),
  dial(
    baseUrl: 'https://ai-proxy.lab.epam.com',
    defaultModel: 'anthropic.claude-sonnet-4-5-20250929-v1:0',
  ),
  minimax(baseUrl: 'https://api.minimax.io/v1', defaultModel: 'MiniMax-M3'),
  custom(baseUrl: null, defaultModel: ''),
  webllm(baseUrl: null, defaultModel: ''),
  gemma(baseUrl: null, defaultModel: ''),
  transformersJs(baseUrl: null, defaultModel: '');

  const ProviderPreset({required this.baseUrl, required this.defaultModel});

  /// Fixed endpoint for hosted presets; `null` for [custom] (user-editable)
  /// and the on-device presets (no endpoint at all).
  final String? baseUrl;

  /// Model prefill applied while the user has not typed their own.
  final String defaultModel;

  /// Whether the base-URL field is editable for this preset. Every hosted
  /// preset is editable (the [baseUrl] prefill is just a default — a
  /// self-hosted DIAL/Ollama instance points at its own endpoint); the
  /// on-device presets have no endpoint at all.
  bool get hasEditableBaseUrl => !isOnDevice;

  /// Whether this preset is an on-device provider, which replaces the
  /// key/model/URL fields with a model picker and a download bar.
  bool get isOnDevice =>
      this == ProviderPreset.webllm ||
      this == ProviderPreset.gemma ||
      this == ProviderPreset.transformersJs;

  /// Short label shown in the provider picker.
  String labelFor(BuildContext context) => label(FaUiStrings.of(context));

  /// Short label resolved from [strings] directly.
  String label(FaUiStrings strings) => switch (this) {
    ProviderPreset.openrouter => strings.settingsPresetOpenrouter,
    ProviderPreset.ollamaCloud => strings.settingsPresetOllama,
    ProviderPreset.gemini => strings.settingsPresetGemini,
    ProviderPreset.dial => strings.settingsPresetDial,
    ProviderPreset.minimax => strings.settingsPresetMinimax,
    ProviderPreset.custom => strings.settingsPresetCustom,
    ProviderPreset.webllm => strings.settingsPresetWebllm,
    ProviderPreset.gemma => strings.settingsPresetGemma,
    ProviderPreset.transformersJs => strings.settingsPresetTransformersJs,
  };

  /// Shown under the form for providers that may reject browser (CORS)
  /// calls. OpenRouter and the Gemini API allow cross-origin browser
  /// requests, so they have no note; other endpoints are not guaranteed to.
  String? corsNote(BuildContext context) => cors(FaUiStrings.of(context));

  /// The CORS note resolved from [strings] directly.
  String? cors(FaUiStrings strings) => switch (this) {
    ProviderPreset.openrouter || ProviderPreset.gemini => null,
    ProviderPreset.ollamaCloud => strings.settingsCorsNoteOllama,
    ProviderPreset.dial => strings.settingsCorsNoteCustom,
    ProviderPreset.minimax => strings.settingsCorsNoteCustom,
    ProviderPreset.custom => strings.settingsCorsNoteCustom,
    ProviderPreset.webllm ||
    ProviderPreset.gemma ||
    ProviderPreset.transformersJs => null,
  };

  /// Infers a preset from a configured base URL (for env-prefilled setups).
  static ProviderPreset fromBaseUrl(String url) {
    if (url.contains('openrouter.ai')) return ProviderPreset.openrouter;
    if (url.contains('ollama.com')) return ProviderPreset.ollamaCloud;
    if (url.contains('generativelanguage.googleapis.com')) {
      return ProviderPreset.gemini;
    }
    if (_isDialBaseUrl(url)) return ProviderPreset.dial;
    if (url.contains('minimax.io')) return ProviderPreset.minimax;
    return ProviderPreset.custom;
  }
}

/// The secure-store key name backing a hosted preset's API key. `null` for
/// presets without an endpoint key (custom, on-device).
/// Whether the hosted [preset] is "connected": SOME key resolves for its
/// default endpoint through the CLI's documented chain — the catalog env
/// name ([hostedProviderKeyName], env/store) or the endpoint-scoped
/// `FA_KEY_<HOST>` entry (what the OAuth/SSO flows write). Keyless presets
/// (no key name) count as connected.
bool hostedProviderConnected(ProviderPreset preset) {
  final envName = hostedProviderKeyName(preset);
  if (envName == null) return true; // keyless
  final baseUrl = preset.baseUrl;
  if (baseUrl == null) return false;
  // The CLI/app shared chain (resolveEndpointKey): the app's host resolver
  // merges env/store per name, so envRead and storeRead are the same lookup.
  return harness.resolveEndpointKey(
        envNames: [envName],
        defaultBaseUrl: baseUrl,
        baseUrl: baseUrl,
        envRead: (name) {
          final value = FaUiHost.resolveKey(name, () => '');
          return value.isEmpty ? null : value;
        },
        storeRead: (name) {
          final value = FaUiHost.resolveKey(name, () => '');
          return value.isEmpty ? null : value;
        },
      ) !=
      null;
}

String? hostedProviderKeyName(ProviderPreset preset) => switch (preset) {
  ProviderPreset.openrouter => 'OPENROUTER_API_KEY',
  ProviderPreset.ollamaCloud => 'OLLAMA_API_KEY',
  ProviderPreset.gemini => 'GEMINI_API_KEY',
  ProviderPreset.dial => 'DIAL_API_KEY',
  ProviderPreset.minimax => 'MINIMAX_API_KEY',
  _ => null,
};

/// Whether [baseUrl] addresses a DIAL Core endpoint (the chat path is
/// `/openai/deployments/...`, not `/chat/completions`).
bool _isDialBaseUrl(String url) => url.contains('ai-proxy.lab.epam.com');

/// DIAL deployments, the bundled ChatGPT Codex catalog, and Copilot (the
/// GitHub→Copilot token exchange) each have a dedicated wire dialect;
/// everything else probes the generic OpenAI `/models` (null hint). The
/// single mapping every model picker passes as the `provider:` argument.
String? modelsDispatchHintFor(String baseUrl) {
  if (_isDialBaseUrl(baseUrl)) return 'dial';
  if (harness.isCopilotBaseUrl(baseUrl)) return 'copilot';
  return null;
}

/// The hosted endpoint presets listed by the Providers section, the
/// default-chat-model picker, and the media slot editor (the ad-hoc
/// `custom` preset is covered by "Add provider"; on-device presets have no
/// endpoint to manage).
const hostedProviderPresets = [
  ProviderPreset.openrouter,
  ProviderPreset.ollamaCloud,
  ProviderPreset.gemini,
  ProviderPreset.dial,
  ProviderPreset.minimax,
];

/// The display name of a provider entry (a [ProviderPreset] or a
/// [CustomProvider]) for list rows and summaries.
String providerDisplayName(BuildContext context, Object provider) =>
    switch (provider) {
      ProviderPreset preset => preset.labelFor(context),
      CustomProvider custom => custom.name,
      _ => provider.toString(),
    };

/// The hosted preset or saved custom provider serving [baseUrl], if any
/// (presets win over custom providers on an exact match).
Object? providerForBaseUrl(String baseUrl, ProviderRegistry? registry) {
  for (final preset in hostedProviderPresets) {
    if (preset.baseUrl == baseUrl) return preset;
  }
  for (final provider in registry?.providers ?? const <CustomProvider>[]) {
    if (provider.baseUrl == baseUrl) return provider;
  }
  return null;
}

/// The API key a connection through [provider] resolves to: custom
/// providers use the remembered session key (Keychain-backed where
/// supported), hosted presets resolve their named key through the host's
/// key chain ([FaUiHost.keyResolver]) and the saved-keys store. Empty means
/// "no credential" — fine for keyless local endpoints.
String resolveProviderKey(
  Object provider, {
  ProviderRegistry? registry,
  SessionKeysStore? keysStore,
}) {
  return switch (provider) {
    CustomProvider custom => () {
      final remembered = registry?.keyFor(custom.id) ?? '';
      if (remembered.isNotEmpty || !harness.isCopilotBaseUrl(custom.baseUrl)) {
        return remembered;
      }
      // Copilot tokens persist entry-scoped (`FA_KEY_COPILOT_<NAME>`, the
      // CLI contract) rather than host-scoped — fall back to that slot when
      // the registry session key is gone (e.g. after a restart on a
      // platform without a Keychain backend).
      final keyName = harness.CustomProviderRegistry.copilotEntryKeyName(
        custom.name,
      );
      return FaUiHost.resolveKey(
        keyName,
        () => keysStore?.valueOf(keyName) ?? '',
      );
    }(),
    ProviderPreset preset => () {
      final name = hostedProviderKeyName(preset);
      if (name == null) return '';
      return FaUiHost.resolveKey(name, () => keysStore?.valueOf(name) ?? '');
    }(),
    _ => '',
  };
}

/// The host part of [baseUrl] for row summaries (the raw string when it
/// does not parse as a URI with a host).
String providerHostOf(String baseUrl) {
  final host = Uri.tryParse(baseUrl)?.host ?? '';
  return host.isEmpty ? baseUrl : host;
}

/// The key-storage notes match the platform: on iOS/macOS saved keys land
/// in the Keychain (see [KeychainStore]); elsewhere the session/app-sandbox
/// wording applies.
String faKeyNoteHosted(FaUiStrings strings) => KeychainStore.isSupported
    ? strings.settingsKeyNoteHostedSecure
    : strings.settingsKeyNoteHosted;

/// Provider-editor variant of [faKeyNoteHosted].
String faEditorKeyNote(FaUiStrings strings) => KeychainStore.isSupported
    ? strings.settingsEditorKeyNoteSecure
    : strings.settingsEditorKeyNote;

/// The localized label for a media slot (the raw name for unknown slots).
String faMediaSlotLabel(FaUiStrings strings, String slot) => switch (slot) {
  MediaSlot.imageGeneration => strings.mediaModelsSlotImageGeneration,
  MediaSlot.audioTts => strings.mediaModelsSlotAudioTts,
  MediaSlot.musicGeneration => strings.mediaModelsSlotMusicGeneration,
  MediaSlot.videoGeneration => strings.mediaModelsSlotVideoGeneration,
  MediaSlot.vision => strings.mediaModelsSlotVision,
  MediaSlot.transcription => strings.mediaModelsSlotTranscription,
  _ => slot,
};
