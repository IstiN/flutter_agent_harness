// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The per-modality model slots [MediaModelsStore] manages.
///
/// Each slot may carry an override pointing at a dedicated endpoint; a slot
/// without an override falls back to the app's main connection (see
/// [MediaModelsStore.resolve]).
final class MediaSlot {
  MediaSlot._();

  /// Image generation (`generate_image`, `jsr.fa.media.generateImage`).
  static const imageGeneration = 'imageGeneration';

  /// Text-to-speech (`speak`, `jsr.fa.media.speak`).
  static const audioTts = 'audioTts';

  /// Music generation (`generate_music`, `jsr.fa.media.generateMusic`).
  static const musicGeneration = 'musicGeneration';

  /// Video generation (`generate_video`, `jsr.fa.media.generateVideo` —
  /// async job endpoint, no main-connection fallback).
  static const videoGeneration = 'videoGeneration';

  /// Image reading / vision (`read_video`, `jsr.fa.media.readVideo` — the
  /// main connection's model is the default when it accepts images; an
  /// override steers frame analysis to a dedicated model).
  static const vision = 'vision';

  /// Audio transcription (`transcribe_audio`, mic voice input,
  /// `jsr.fa.asr.transcribe` — defaults to Whisper on the main connection).
  static const transcription = 'transcription';

  /// Every known slot name, in declaration order.
  ///
  /// Derived from the harness's `mediaModelSlotIds` (the shared schema the
  /// CLI's `models:` config section also uses) — the constants above must
  /// stay string-identical to that list.
  static const all = mediaModelSlotIds;
}

/// A per-slot endpoint override: where ONE media modality is served when the
/// main connection should not handle it.
///
/// Non-secret by design: [apiKeyName] is the NAME of an environment/keychain
/// entry (e.g. `OPENAI_API_KEY`), never the key itself — values live in the
/// secrets/session-keys stores and are resolved at call time.
final class MediaSlotOverride {
  /// Creates an override. [providerKind], [baseUrl], and [modelId] should
  /// all be non-empty for the override to be usable.
  const MediaSlotOverride({
    required this.providerKind,
    required this.baseUrl,
    required this.modelId,
    this.apiKeyName,
    this.voice,
    this.providerId,
  });

  /// Restores an override from its JSON form (see [toJson]).
  factory MediaSlotOverride.fromJson(Map<String, dynamic> json) =>
      MediaSlotOverride(
        providerKind: (json['providerKind'] ?? '').toString(),
        baseUrl: (json['baseUrl'] ?? '').toString(),
        modelId: (json['modelId'] ?? '').toString(),
        apiKeyName: json['apiKeyName']?.toString(),
        voice: json['voice']?.toString(),
        providerId: json['providerId']?.toString(),
      );

  /// Provider adapter kind; the media tools speak the OpenAI-compatible
  /// wire format, so usable overrides carry `openai-completions`.
  final String providerKind;

  /// OpenAI-compatible base URL (e.g. `https://api.openai.com/v1`); the
  /// per-modality path (`/images/generations`, …) is appended.
  final String baseUrl;

  /// Model id passed to the endpoint (e.g. `gpt-image-1`, `tts-1`).
  final String modelId;

  /// Name of the env/keychain entry holding the API key for this endpoint.
  /// When null the main connection's session key is reused (the common
  /// "same provider, different model" case).
  final String? apiKeyName;

  /// Default voice for the [MediaSlot.audioTts] endpoint (e.g. `alloy`,
  /// `af_heart`); null or empty lets the caller pick its own default.
  /// Meaningless for the other slots.
  final String? voice;

  /// The picked provider's stable id (custom id or preset name) — the
  /// default-chat flow keeps the provider's identity through the apply.
  final String? providerId;

  /// JSON form persisted in the store file; absent fields stay absent.
  Map<String, dynamic> toJson() => {
    'providerKind': providerKind,
    'baseUrl': baseUrl,
    'modelId': modelId,
    if (apiKeyName != null) 'apiKeyName': apiKeyName,
    if (voice != null && voice!.isNotEmpty) 'voice': voice,
        'providerId': providerId,
  };

  @override
  String toString() => 'MediaSlotOverride($providerKind, $baseUrl, $modelId)';
}

/// The effective endpoint one media call should use — the resolved merge of
/// a slot override (if any) and the main connection.
final class MediaEndpoint {
  /// Creates an endpoint descriptor.
  const MediaEndpoint({
    required this.providerKind,
    required this.baseUrl,
    required this.modelId,
    required this.apiKey,
    required this.fromOverride,
    this.voice,
  });

  /// Provider adapter kind (usable media endpoints are
  /// `openai-completions`).
  final String providerKind;

  /// Base URL the per-modality path is appended to (never empty — an empty
  /// configured URL resolves to OpenAI's default).
  final String baseUrl;

  /// Model id sent in the request body.
  final String modelId;

  /// The resolved API key: the override's named key when it resolved, the
  /// main connection's session key otherwise. Empty means "no usable
  /// credential" — the endpoint is not usable.
  final String apiKey;

  /// True when the endpoint came from a slot override rather than the main
  /// connection.
  final bool fromOverride;

  /// The slot override's default voice (TTS only); null when the override
  /// sets none or the endpoint came from the main connection.
  final String? voice;
}

/// The main connection's endpoint details, supplied by the caller (built
/// from the active `AgentConfig`) as the fallback for slots without an
/// override.
final class MediaFallback {
  /// Creates a fallback descriptor.
  const MediaFallback({
    required this.providerKind,
    required this.baseUrl,
    required this.modelId,
    required this.apiKey,
  });

  /// [AgentConfig.providerKind] of the main connection.
  final String providerKind;

  /// [AgentConfig.baseUrl] of the main connection (empty for on-device).
  final String baseUrl;

  /// [AgentConfig.modelId] of the main connection.
  final String modelId;

  /// [AgentConfig.apiKey] of the main connection (session-only).
  final String apiKey;
}

/// Resolves a named secret (see [MediaSlotOverride.apiKeyName]) to its
/// value; returns null when the name is unknown.
typedef MediaKeyResolver = Future<String?> Function(String name);

/// Per-modality media model overrides, persisted as `media_models.json` in
/// the root of the sandbox filesystem ([ExecutionEnv.cwd]) — same
/// JSON-envelope pattern as [ProviderRegistry] / [LastConnectionStore].
///
/// **File shape** (shared contract — the future settings UI and the CLI's
/// models-config read and write this exact schema, so keep it stable):
///
/// ```json
/// {
///   "version": 1,
///   "slots": {
///     "imageGeneration": {
///       "providerKind": "openai-completions",
///       "baseUrl": "https://api.openai.com/v1",
///       "modelId": "gpt-image-1",
///       "apiKeyName": "OPENAI_API_KEY"
///     },
///     "audioTts": { "...": "same shape" },
///     "musicGeneration": { "...": "same shape" },
///     "videoGeneration": { "...": "same shape" },
///     "vision": { "...": "same shape" },
///     "transcription": { "...": "same shape" }
///   }
/// }
/// ```
///
/// Every slot is optional; a missing slot means "use the main connection"
/// (see [resolve]). `apiKeyName` references an env/keychain entry BY NAME —
/// key values are never written to this file. A missing, unreadable, or
/// corrupt file yields an empty store (never crashes boot).
class MediaModelsStore extends ChangeNotifier {
  MediaModelsStore._(this._env);

  /// A store without persistence (tests, widget fallbacks): mutations
  /// notify listeners but nothing is written anywhere.
  MediaModelsStore.inMemory() : _env = null;

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'media_models.json';

  /// Schema version of the JSON envelope; other versions load as empty.
  static const _version = 1;

  /// OpenAI's default base URL, used when a usable endpoint leaves the URL
  /// empty (mirrors the `transcribe_audio` default).
  static const defaultBaseUrl = 'https://api.openai.com/v1';

  /// Default model ids per slot when falling back to the main connection:
  /// the chat model id is wrong for the media APIs, so the OpenAI defaults
  /// apply. Slots absent here (music/video — no OpenAI standard) have no
  /// fallback model and stay unusable without an override.
  static const _fallbackModelIds = {
    MediaSlot.imageGeneration: 'gpt-image-1',
    MediaSlot.audioTts: 'tts-1',
    MediaSlot.transcription: 'whisper-1',
  };

  final ExecutionEnv? _env;
  final Map<String, MediaSlotOverride> _slots = {};

  /// Loads the store persisted in [env]; a missing, unreadable, or corrupt
  /// file yields an empty store.
  static Future<MediaModelsStore> load(ExecutionEnv env) async {
    final store = MediaModelsStore._(env);
    await store._load();
    return store;
  }

  /// The override for [slot], if any.
  MediaSlotOverride? overrideFor(String slot) => _slots[slot];

  /// The slot names carrying an override, in [MediaSlot.all] order.
  List<String> get configuredSlots =>
      List.unmodifiable(MediaSlot.all.where(_slots.containsKey));

  /// Sets (or clears, with null) the override for [slot]. Unknown slot
  /// names are ignored — the schema above is the contract. Persistence is
  /// best effort: a failed write must not break the caller.
  Future<void> setOverride(String slot, MediaSlotOverride? override) async {
    if (!MediaSlot.all.contains(slot)) return;
    if (override == null) {
      if (_slots.remove(slot) == null) return;
    } else {
      _slots[slot] = override;
    }
    notifyListeners();
    await _save();
  }

  /// Removes every override.
  Future<void> clear() async {
    if (_slots.isEmpty) return;
    _slots.clear();
    notifyListeners();
    await _save();
  }

  /// Resolves the effective endpoint for [slot]: the slot's override when
  /// one is configured, otherwise the main connection [fallback] (with the
  /// slot's default model id — the chat model id does not belong on the
  /// media APIs). Returns null when the result is not a usable
  /// OpenAI-compatible endpoint (wrong provider kind, or no API key after
  /// [resolveKey] ran) — callers surface an actionable "configure the slot"
  /// error.
  Future<MediaEndpoint?> resolve(
    String slot,
    MediaFallback fallback, {
    MediaKeyResolver? resolveKey,
  }) async {
    final override = _slots[slot];
    if (override == null) {
      final modelId = slot == MediaSlot.vision
          ? fallback.modelId
          : _fallbackModelIds[slot];
      if (modelId == null) return null; // no standard fallback for this slot
      return _usable(
        MediaEndpoint(
          providerKind: fallback.providerKind,
          baseUrl: fallback.baseUrl,
          modelId: modelId,
          apiKey: fallback.apiKey,
          fromOverride: false,
        ),
      );
    }
    var apiKey = fallback.apiKey;
    final keyName = override.apiKeyName;
    if (keyName != null && keyName.isNotEmpty) {
      apiKey = (await resolveKey?.call(keyName)) ?? '';
    }
    return _usable(
      MediaEndpoint(
        providerKind: override.providerKind,
        baseUrl: override.baseUrl,
        modelId: override.modelId,
        apiKey: apiKey,
        fromOverride: true,
        voice: override.voice,
      ),
    );
  }

  /// The usability gate every media call shares: an OpenAI-compatible
  /// endpoint with a model id and a credential.
  static MediaEndpoint? _usable(MediaEndpoint endpoint) {
    if (endpoint.providerKind != 'openai-completions') return null;
    if (endpoint.modelId.isEmpty || endpoint.apiKey.isEmpty) return null;
    return MediaEndpoint(
      providerKind: endpoint.providerKind,
      baseUrl: endpoint.baseUrl.isEmpty ? defaultBaseUrl : endpoint.baseUrl,
      modelId: endpoint.modelId,
      apiKey: endpoint.apiKey,
      fromOverride: endpoint.fromOverride,
      voice: endpoint.voice,
    );
  }

  Future<void> _load() async {
    final env = _env;
    if (env == null) return;
    try {
      final text = (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text == null) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['version'] != _version) return;
      final slots = decoded['slots'];
      if (slots is! Map) return;
      _slots.clear();
      for (final slot in MediaSlot.all) {
        final entry = slots[slot];
        if (entry is Map) {
          _slots[slot] = MediaSlotOverride.fromJson(
            entry.cast<String, dynamic>(),
          );
        }
      }
    } on Object {
      // Corrupt or incompatible file → empty store, never crash boot.
    }
  }

  Future<void> _save() async {
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({
          'version': _version,
          'slots': {
            for (final entry in _slots.entries) entry.key: entry.value.toJson(),
          },
        }),
      );
    } on Object {
      // Best effort: a failed write must not break the settings UI.
    }
  }
}

/// Provides the app's [MediaModelsStore] to the widget tree (the settings
/// Media models section) without threading it through every intermediate
/// widget — the [SessionKeysScope] pattern.
class MediaModelsScope extends InheritedNotifier<MediaModelsStore> {
  /// Creates a scope exposing [store].
  const MediaModelsScope({
    super.key,
    required MediaModelsStore store,
    required super.child,
  }) : super(notifier: store);

  /// The nearest store, or `null` outside the app shell (tests).
  static MediaModelsStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaModelsScope>()?.notifier;
}
