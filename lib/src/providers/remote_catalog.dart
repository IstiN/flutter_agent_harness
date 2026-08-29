/// A remote, versioned catalog of provider models served from
/// `https://fa1.dev/models-catalog.json`. Replaces per-provider hardcoded
/// defaults (e.g. `MiniMax-M3`) with a single source of truth for
/// metadata the chat endpoint doesn't publish: per-model `contextWindow`
/// defaults, plus per-slot media-model lists (`imageGeneration`,
/// `videoGeneration`, `speech`, `transcription`) for providers whose
/// chat endpoint never returns them.
///
/// The catalog NEVER seeds the chat model id list — providers expose
/// their own chat models via `GET /v1/models` (MiniMax, OpenAI,
/// OpenRouter, …) and that's the picker source of truth. The catalog
/// only enriches metadata.
///
/// Merged at fetch time with the live endpoint report via
/// `RemoteCatalogEnrichment` (re-exported below). The endpoint's
/// reported values always win; the catalog only fills gaps.
/// The host never blocks on the fetch: failures and slow responses
/// leave the existing per-endpoint fetch + manual entry fallbacks
/// untouched. The result is a strict superset — only enriches /
/// extends, never shrinks. Cache TTL is one process lifetime.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models_endpoint.dart';

// Re-export the live-enrichment seam so consumers can `import
// flutter_agent_harness/.../remote_catalog.dart` and get both halves
// of the catalog plumbing without a second import.
export 'models_for_endpoint.dart' show RemoteCatalogEnrichment;

/// The remote catalog payload. All fields optional — a partial update
/// can ship just a new chat provider without touching media lists.
final class RemoteModelsCatalog {
  const RemoteModelsCatalog({this.providers = const {}});

  /// `providerKind` → per-provider catalog entry.
  final Map<String, RemoteProviderEntry> providers;

  /// Decodes a catalog body, returning a successful empty catalog on
  /// any shape error (the host keeps working with whatever the endpoint
  /// reported).
  factory RemoteModelsCatalog.fromJson(Object? json) {
    if (json is! Map) return const RemoteModelsCatalog();
    final rawProviders = json['providers'];
    if (rawProviders is! Map) return const RemoteModelsCatalog();
    final providers = <String, RemoteProviderEntry>{};
    for (final entry in rawProviders.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final value = entry.value;
      if (value is! Map) continue;
      final parsed = RemoteProviderEntry.fromJson(
        Map<String, Object?>.from(value),
      );
      providers[key] = parsed;
    }
    return RemoteModelsCatalog(providers: providers);
  }
}

/// The catalog entry for one provider (matched by `providerKind` like
/// `minimax`). The endpoint's own `/v1/models` is always the source of
/// truth for chat ids; the catalog only fills the metadata the endpoint
/// doesn't publish (context windows for models it lists) and the media
/// lists the endpoint never returns (image/video/tts/asr).
final class RemoteProviderEntry {
  const RemoteProviderEntry({
    this.contextWindows = const {},
    this.media = const {},
  });

  /// `modelId` → reported context window (used when the endpoint's
  /// `/v1/models` payload doesn't carry one).
  final Map<String, int> contextWindows;

  /// `slotName` → list of model ids (`imageGeneration`,
  /// `videoGeneration`, `speech`, `transcription`).
  final Map<String, List<String>> media;

  factory RemoteProviderEntry.fromJson(Map<String, Object?> json) {
    final windowsRaw = json['contextWindows'];
    final mediaRaw = json['media'];
    final windows = <String, int>{};
    if (windowsRaw is Map) {
      for (final entry in windowsRaw.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is num && value > 0) {
          windows[key] = value.round();
        }
      }
    }
    final media = <String, List<String>>{};
    if (mediaRaw is Map) {
      for (final entry in mediaRaw.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! List) continue;
        final ids = <String>[];
        for (final item in value) {
          if (item is String && item.isNotEmpty) ids.add(item);
        }
        if (ids.isNotEmpty) media[key] = ids;
      }
    }
    return RemoteProviderEntry(contextWindows: windows, media: media);
  }
}

/// The catalog endpoint — overridable via `fa1.dev/models-catalog-url`
/// (the `models:` yaml section keys ride the same resolver) for staging
/// or self-hosted mirrors.
const String defaultRemoteCatalogUrl = 'https://fa1.dev/models-catalog.json';

/// Fetches the remote catalog. Honours a 10-second connect/idle budget
/// (matches the other lightweight endpoint reads in [models_endpoint])
/// and never throws — every error returns `null`, the host falls back to
/// its local defaults + the endpoint's own `/v1/models`.
Future<RemoteModelsCatalog?> fetchRemoteModelsCatalog({
  Uri? url,
  http.Client? client,
}) async {
  final target = url ?? Uri.parse(defaultRemoteCatalogUrl);
  final httpClient = client ?? http.Client();
  final ownsClient = client == null;
  try {
    final response = await httpClient
        .get(target, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;

    final decoded = jsonDecode(response.body);
    return RemoteModelsCatalog.fromJson(decoded);
  } on Object {
    return null;
  } finally {
    if (ownsClient) httpClient.close();
  }
}

/// The host-injected accessor. The CLI passes its yaml override; the
/// app passes its in-memory config.
typedef RemoteCatalogUrlResolver = Uri? Function();

/// Folds a remote catalog into the per-endpoint fetch result: the
/// catalog's context-windows fill gaps the endpoint didn't report, and
/// (only for media slots) its per-slot model ids appear when the
/// endpoint didn't return any. The CHAT id list is NEVER seeded from
/// the catalog — providers expose their own chat models via
/// `GET /v1/models` (MiniMax, OpenAI, OpenRouter, …) and that's the
/// source of truth for the picker; the catalog only enriches metadata.
ModelsEndpointInfo mergeWithRemoteCatalog({
  required ModelsEndpointInfo endpointInfo,
  required String? providerKind,
  required RemoteModelsCatalog? catalog,
  List<String> mediaSlot = const [],
}) {
  if (catalog == null) return endpointInfo;
  final entry = catalog.providers[providerKind ?? ''];
  if (entry == null) return endpointInfo;
  final (ids, windows, maxTokens) = endpointInfo;
  // Chat ids: endpoint list, untouched by the catalog.
  final mergedIds = <String>[...ids];
  // Media ids (image/video/tts/asr) only get catalog-seeded when the
  // endpoint report is empty — most providers have a separate endpoint
  // for media that doesn't go through this fetch at all, so an empty
  // endpoint result is the normal case and the catalog is the only
  // source. The picker still dedupes against manual override / saved
  // custom list.
  for (final slot in mediaSlot) {
    final seed = entry.media[slot];
    if (seed == null) continue;
    for (final id in seed) {
      if (!mergedIds.contains(id)) mergedIds.add(id);
    }
  }
  final mergedWindows = <String, int>{
    ...entry.contextWindows,
    ...windows, // endpoint reported limits override catalog defaults
  };
  final mergedMaxTokens = <String, int>{...maxTokens};
  return (mergedIds, mergedWindows, mergedMaxTokens);
}

/// The media-model list the picker shows for the slot when no override
/// is configured. Empty when the catalog doesn't list the slot — the
/// picker falls through to manual entry, the existing behaviour.
List<String> remoteMediaModelsFor({
  required String? providerKind,
  required String slot,
  required RemoteModelsCatalog? catalog,
}) {
  if (catalog == null) return const [];
  final entry = catalog.providers[providerKind ?? ''];
  if (entry == null) return const [];
  return entry.media[slot] ?? const [];
}
