/// Parses an OpenAI-compatible `/models` response body into (sorted ids,
/// id → reported context window, id → reported max output tokens, id →
/// reported input modalities). Window fields read: `context_length`
/// (OpenRouter), `context_window`, `max_context_length` (LM Studio and
/// friends); output caps read: `max_completion_tokens` (OpenRouter, then its
/// `top_provider` nested form), `max_output_tokens`; input modalities read:
/// `input_modalities` (the AIIN gateway's list form) with the `modality`
/// string's input side ("text+image->text") as the fallback. Entries without
/// a field are absent from the maps.
///
/// Shared by the CLI (`/model` picker, auto window/cap correction) and the
/// Flutter app (settings form quick select + connect) so every host applies
/// endpoint-reported limits the same way instead of its own hardcoded
/// defaults.
library;

import 'dart:convert';

/// The parsed `/models` payload: ids, per-id context windows, per-id output
/// caps, per-id reported input modalities.
typedef ModelsEndpointInfo =
    (
      List<String>,
      Map<String, int>,
      Map<String, int>,
      Map<String, List<String>>,
    );

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
  final inputModalities = <String, List<String>>{};
  if (data is List) {
    for (final entry in data) {
      _collectModelEntry(entry, ids, windows, maxTokens, inputModalities);
    }
  }
  ids.sort();
  return (ids, windows, maxTokens, inputModalities);
}

/// Collects one `/models` entry into [ids], [windows], [maxTokens], and
/// [inputModalities]; entries without a usable id (or not a map at all) are
/// skipped.
void _collectModelEntry(
  Object? entry,
  List<String> ids,
  Map<String, int> windows,
  Map<String, int> maxTokens,
  Map<String, List<String>> inputModalities,
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
  final modalities = _reportedInputModalities(entry);
  if (modalities != null) inputModalities[id] = modalities;
}

/// The reported input modalities: `input_modalities` (the AIIN gateway's
/// list form — string entries kept, everything else dropped) with the
/// `modality` string's input side as the fallback ("text+image->text" →
/// the text before `->` split on `+`). Null when neither field is usable —
/// endpoints without modality metadata stay absent (the heuristic owns
/// those ids).
List<String>? _reportedInputModalities(Map<dynamic, dynamic> entry) {
  final list = entry['input_modalities'];
  if (list is List) {
    final modalities = [
      for (final item in list)
        if (item is String && item.isNotEmpty) item,
    ];
    if (modalities.isNotEmpty) return modalities;
  }
  final modality = entry['modality'];
  if (modality is String) {
    final inputSide = modality.split('->').first.trim();
    final modalities = [
      for (final part in inputSide.split('+'))
        if ((part).trim().isNotEmpty) part.trim(),
    ];
    if (modalities.isNotEmpty) return modalities;
  }
  return null;
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

// ── AIIN per-family context windows (gh-2466) ────────────────────────────

/// The AIN gateway's blanket context-window stamps (gh-2466): the ≈1M
/// values it puts on every entry whose window it has not verified —
/// 1048576 exact (2²⁰) and the round 1000000. A stamp is NOT per-model
/// evidence: the live answer (fetched 2026-11) reports it for
/// claude-sonnet-5/5.5, claude-opus-4.6…5.5 and haiku-5.5 whose real
/// window is 200k, while verified entries carry precise values
/// (claude-opus-4.5 → 200000, deepseek → 163840, gpt-5 → 400000). Some
/// entries report 0 — treated as absent by the parser already.
const ainBlanketWindowStamps = <int>{1048576, 1000000};

/// The curated per-family context windows for AIN-served models
/// (gh-2466): the families whose real window the gateway's blanket
/// default misreports. `claude` is 200k; `gemini` legitimately serves a
/// 1M window (its curated value equals the stamp, so the endpoint's
/// report and the curated map agree). Families outside the map have no
/// curated knowledge — the endpoint's per-model report stands (gh-1742:
/// ONE window per model identity everywhere; normalization happens at
/// parse time so the picker, the ctx meter, the window registry and the
/// compaction trigger all inherit the same number).
const ainFamilyContextWindows = <String, int>{
  'claude': 200000,
  'gemini': 1048576,
};

/// The curated window for [modelId]'s family, or null when the family is
/// unknown. Family tokens match case-insensitively anywhere in the id
/// (provider-prefixed ids included — `anthropic/claude-…`,
/// `google/gemini-…`).
int? ainCuratedContextWindow(String modelId) {
  final id = modelId.toLowerCase();
  for (final entry in ainFamilyContextWindows.entries) {
    if (id.contains(entry.key)) return entry.value;
  }
  return null;
}

/// Normalizes an AIN gateway `/models` answer into per-model windows
/// (gh-2466): the gateway applies ONE blanket ≈1M default to every
/// unverified id, so the per-model list it serves cannot be trusted for
/// the curated families. For each id: a blanket stamp (or a missing/zero
/// window) is replaced by the curated per-family value; a precise
/// non-stamp endpoint value ALWAYS wins (claude-opus-4.5 keeps its
/// reported 200000); a family outside the curated map keeps the
/// endpoint's word — the 1M survives only where per-model or per-family
/// evidence says 1M, never as a global fallback. Modalities and output
/// caps ride through untouched.
ModelsEndpointInfo normalizeAiinModelInfo(ModelsEndpointInfo info) {
  final (ids, windows, maxTokens, inputModalities) = info;
  final normalized = <String, int>{};
  for (final id in ids) {
    final reported = windows[id];
    final curated = ainCuratedContextWindow(id);
    // Curated family: a stamp (or nothing) is not per-model evidence — the
    // curated value stands; a precise endpoint report wins.
    final window =
        (curated != null &&
            (reported == null || ainBlanketWindowStamps.contains(reported)))
        ? curated
        : reported;
    if (window != null) normalized[id] = window;
  }
  return (ids, normalized, maxTokens, inputModalities);
}
