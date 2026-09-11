library;

import 'dart:convert';

import '../../agent/agent_loop.dart'
    show StreamCacheRouting, StreamFunction;
import '../../context.dart';
import '../../model.dart' show Model;
import '../../session/uuid.dart' show uuidv7;
import '../../types.dart';
import 'ledger.dart';

/// answer (null = failed call — caller treats as no-op).
typedef HideJudgeFn = Future<String?> Function(String ledgerText);

/// Parses judge output into numeric ids.
///
/// Accepts a bare JSON array of numbers or strings, optionally wrapped in
/// a markdown fence. Range strings (`"7-8"`) expand. Returns `null` when
/// the output contains no JSON array (the no-op signal); an empty array
/// parses to an empty set.
Set<int>? parseHidePicks(String output) {
  final start = output.indexOf('[');
  final end = output.lastIndexOf(']');
  if (start < 0 || end <= start) return null;
  final String arrayText;
  try {
    arrayText = output.substring(start, end + 1);
    final decoded = jsonDecode(arrayText);
    if (decoded is! List) return null;
    final ids = <int>{};
    for (final item in decoded) {
      int? single;
      if (item is int) {
        single = item;
      } else if (item is String) {
        final trimmed = item.trim();
        final range = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(trimmed);
        if (range != null) {
          final lo = int.parse(range.group(1)!);
          final hi = int.parse(range.group(2)!);
          if (lo <= hi && hi - lo < 10000) {
            ids.addAll([for (var i = lo; i <= hi; i++) i]);
          }
          continue;
        }
        single = int.tryParse(trimmed);
      }
      if (single != null && single > 0) ids.add(single);
    }
    return ids;
  } catch (_) {
    return null;
  }
}

/// Narrows judge picks to ids that are safe to hide.
///
/// - ids the ledger does not know (hallucinated) are dropped;
/// - `·exempt` real user turns are dropped (F8);
/// - the last [protectLastN] ledger entries are dropped (live edge — the
///   working set the model is actively reasoning over);
/// - every surviving pick snaps OUTWARD to its whole pair group (D6), and
///   a group touching the protected tail is dropped entirely (a hidden
///   call with a live result orphans the wire).
Set<String> validateHidePicks(
  Set<int> picks,
  ContextLedger ledger, {
  int protectLastN = 8,
}) {
  final protected = <String>{
    for (final entry in ledger.entries.skip(
      ledger.entries.length - protectLastN < 0
          ? 0
          : ledger.entries.length - protectLastN,
    ))
      entry.recordId,
  };
  final result = <String>{};
  for (final pick in picks) {
    final entry = ledger.entryAtSeq(pick);
    if (entry == null || entry.exempt) continue;
    final group = ledger.groupOf(entry.recordId);
    if (group.any(protected.contains)) continue;
    result.addAll(group);
  }
  return result;
}

/// Adapts a provider [StreamFunction] into a [HideJudgeFn].
///
/// Mirrors [streamFunctionSummarizer]: a standalone request with the
/// judge system prompt plus the ledger as a single user message,
/// `cacheRetention: 'none'`, fresh routing session id; returns the joined
/// text blocks or `null` on error/abort/empty (F1). Temperature 0 and
/// `max_tokens` ≥ 1500 (F2) are the model-role/adapter's responsibility —
/// the same place the summarizer's pi clamp divergence lives.
HideJudgeFn streamFunctionHideJudge(
  StreamFunction streamFunction,
  Model model, {
  required String system,
  void Function(String delta)? onDelta,
}) {
  return (String ledgerText) async {
    try {
      final stream = StreamCacheRouting.runWith(
        () => streamFunction(
          model,
          Context(
            systemPrompt: system,
            messages: [UserMessage.text(ledgerText)],
          ),
        ),
        sessionId: uuidv7(),
        cacheRetention: 'none',
      );
      if (onDelta != null) {
        stream.listen((event) {
          final delta = switch (event) {
            TextDeltaEvent(:final delta) => delta,
            ThinkingDeltaEvent(:final delta) => delta,
            _ => null,
          };
          if (delta != null && delta.isNotEmpty) onDelta(delta);
        });
      }
      final response = await stream.result;
      switch (response.stopReason) {
        case StopReason.aborted:
        case StopReason.error:
          return null;
        default:
          final text = response.content
              .whereType<TextContent>()
              .map((block) => block.text)
              .join('\n')
              .trim();
          return text.isEmpty ? null : text;
      }
    } catch (_) {
      return null;
    }
  };
}
