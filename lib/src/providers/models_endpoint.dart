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
///
/// Dialects accepted: OpenAI/OpenRouter `{"data": [{"id": ...}]}` and the
/// `{"models": [{"alias": ...}]}` shape some gateways use (id falls back to
/// `alias`, then `name`).
ModelsEndpointInfo parseModelsResponse(String body) {
  final decoded = jsonDecode(body);
  final data = decoded is Map ? (decoded['data'] ?? decoded['models']) : null;
  final ids = <String>[];
  final windows = <String, int>{};
  final maxTokens = <String, int>{};
  if (data is List) {
    for (final entry in data) {
      _collectModelEntry(entry, ids, windows, maxTokens);
    }
  }
  ids.sort();
  return (ids, windows, maxTokens);
}

/// Collects one `/models` entry into [ids], [windows], and [maxTokens];
/// entries without a usable id (or not a map at all) are skipped.
void _collectModelEntry(
  Object? entry,
  List<String> ids,
  Map<String, int> windows,
  Map<String, int> maxTokens,
) {
  if (entry is! Map) return;
  final idValue = entry['id'] ?? entry['alias'] ?? entry['name'];
  if (idValue is! String || idValue.isEmpty) return;
  final id = idValue;
  ids.add(id);
  final window = _reportedWindow(entry);
  if (window != null) windows[id] = window;
  final cap = _reportedMaxTokens(entry);
  if (cap != null) maxTokens[id] = cap;
}

/// The reported context window (`context_length` for OpenRouter,
/// `context_window`, `max_context_length` for LM Studio and friends, or the
/// max of `limits.max_total_tokens`/`limits.max_prompt_tokens` for DIAL),
/// or null when the entry reports none.
int? _reportedWindow(Map<dynamic, dynamic> entry) {
  final window =
      entry['context_length'] ??
      entry['context_window'] ??
      entry['max_context_length'];
  if (window is num && window > 0) return window.round();
  // DIAL: `limits` carries the endpoint's ceilings; the usable context is
  // the larger of the total and the prompt-only cap.
  final limits = entry['limits'];
  if (limits is Map) {
    final total = limits['max_total_tokens'];
    final prompt = limits['max_prompt_tokens'];
    final candidates = [
      if (total is num && total > 0) total,
      if (prompt is num && prompt > 0) prompt,
    ];
    if (candidates.isNotEmpty) {
      return candidates.reduce((a, b) => a > b ? a : b).round();
    }
  }
  return null;
}

/// The reported max output tokens (`max_completion_tokens` for OpenRouter,
/// then its `top_provider` nested form, `max_output_tokens`, or DIAL's
/// `limits.max_completion_tokens`), or null when the entry reports none.
int? _reportedMaxTokens(Map<dynamic, dynamic> entry) {
  final topProvider = entry['top_provider'];
  final cap =
      entry['max_completion_tokens'] ??
      (topProvider is Map ? topProvider['max_completion_tokens'] : null) ??
      entry['max_output_tokens'];
  if (cap is num && cap > 0) return cap.round();
  final limits = entry['limits'];
  if (limits is Map) {
    final dialCap = limits['max_completion_tokens'];
    if (dialCap is num && dialCap > 0) return dialCap.round();
  }
  return null;
}
