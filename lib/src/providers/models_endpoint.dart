/// Parses an OpenAI-compatible `/models` response body into (sorted ids,
/// id → reported context window, id → reported max output tokens). Window
/// fields read: `context_length` (OpenRouter), `context_window`,
/// `max_context_length` (LM Studio and friends); output caps read:
/// `max_completion_tokens` (OpenRouter, then its `top_provider` nested
/// form), `max_output_tokens`. Entries without a field are absent from the
/// maps.
///
/// Shared by the CLI (`/model` picker, auto window/cap correction) and the
/// Flutter app (settings form quick select + connect) so every host applies
/// endpoint-reported limits the same way instead of its own hardcoded
/// defaults.
library;

import 'dart:convert';

/// The parsed `/models` payload: ids, per-id context windows, per-id output
/// caps.
typedef ModelsEndpointInfo = (List<String>, Map<String, int>, Map<String, int>);

/// Fetches and parses the `/models` payload of [baseUrl] (hosts inject fakes
/// in tests; production defaults do the HTTP GET + [parseModelsResponse]).
typedef ModelsEndpointFetcher =
    Future<ModelsEndpointInfo> Function(
      String baseUrl, {
      required String apiKey,
    });

/// Fallback limits when the endpoint reports nothing — the CLI catalog and
/// the app share this floor (pi's smallest modern per-model values; the cap
/// is a ceiling, not a target).
const fallbackContextWindow = 200000;
const fallbackMaxTokens = 16384;

/// Parses [body] (the raw `/models` JSON) into [ModelsEndpointInfo].
ModelsEndpointInfo parseModelsResponse(String body) {
  final decoded = jsonDecode(body);
  final data = decoded is Map ? decoded['data'] : null;
  final ids = <String>[];
  final windows = <String, int>{};
  final maxTokens = <String, int>{};
  if (data is List) {
    for (final entry in data) {
      if (entry is! Map) continue;
      final id = entry['id'];
      if (id is! String || id.isEmpty) continue;
      ids.add(id);
      final window =
          entry['context_length'] ??
          entry['context_window'] ??
          entry['max_context_length'];
      if (window is num && window > 0) windows[id] = window.round();
      final topProvider = entry['top_provider'];
      final cap =
          entry['max_completion_tokens'] ??
          (topProvider is Map ? topProvider['max_completion_tokens'] : null) ??
          entry['max_output_tokens'];
      if (cap is num && cap > 0) maxTokens[id] = cap.round();
    }
  }
  ids.sort();
  return (ids, windows, maxTokens);
}
