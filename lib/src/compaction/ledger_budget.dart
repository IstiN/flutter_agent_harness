/// gh-2492 C4 — the hidden-ids ledger budget.
///
/// The hidden-record MARKERS a request carries are the compaction
/// ledger's render cost: one marker per hidden record (~19 tokens with
/// the preview) adds up — after several hide passes the ledger alone can
/// cost more than the checkpoint it replaced. This component pins the
/// budget (`hiddenLedgerBudgetTokens`), detects the contiguous marker
/// runs of a request, and collapses OLDEST-FIRST: each merge turns the
/// two oldest adjacent markers into one collapsed pointer
/// (`N records hidden · <label> [expand a-b]`) until the total is under
/// budget — the newest run keeps its per-record detail, the oldest
/// ranges fold into working `compact_expand` doors.
///
/// Enforcement is RENDER-TIME only (no file rewrite): the session file
/// keeps every bare range, so a rebuild derives the same collapsed view
/// from the same records — deterministic by construction (the labels are
/// computed from the covered records, never from model text).
///
/// The C5 label rides the same component: [toolHistogramLabel] builds
/// the per-range label (tool-name histogram + time span) the hide-only
/// path renders, so a compacted view is not content-blind.
library;

import 'structured/markers.dart';
import 'token_estimation.dart';
import '../context.dart';
import '../session/session_record.dart';
import '../types.dart';

/// The budget over ALL hidden markers of ONE request, in harness
/// estimate tokens (gh-2492 C4; #2423 §C4 pinned the figure).
const int hiddenLedgerBudgetTokens = 1000;

/// The top tool names a histogram label renders (the rest fold into the
/// span; C5's shape keeps the label inside the marker budget).
const int toolHistogramMaxEntries = 3;

/// One hidden-marker message the request carries, with its request
/// position and parsed span.
final class LedgerMarkerRef {
  const LedgerMarkerRef({
    required this.index,
    required this.message,
    required this.firstSeq,
    required this.lastSeq,
    required this.hiddenCount,
    required this.tokens,
  });

  /// The marker's position in the request's message list.
  final int index;

  /// The marker message itself.
  final Message message;

  /// The first hidden seq the marker names (0 when unparsable — such a
  /// marker never merges; it keeps its original text).
  final int firstSeq;

  /// The last hidden seq the marker names (equals [firstSeq] for a
  /// single-record marker).
  final int lastSeq;

  /// How many hidden records the marker stands for.
  final int hiddenCount;

  /// The harness token estimate of the marker message.
  final int tokens;

  /// Whether the marker can take part in a merge (a parsable span).
  bool get mergeable => firstSeq > 0;
}

/// The ledger-budget collapse plan over one request's markers.
final class LedgerCollapsePlan {
  const LedgerCollapsePlan({required this.replace, required this.remove});

  /// index → the collapsed marker message that replaces it (the pair's
  /// first marker's position; the tag epoch keeps the first hidden
  /// record's seq).
  final Map<int, Message> replace;

  /// The marker positions folded away by [replace].
  final Set<int> remove;

  /// Whether anything collapsed at all.
  bool get isEmpty => replace.isEmpty && remove.isEmpty;
}

/// Parses one ledger-marker message into a [LedgerMarkerRef]; null when
/// the message is not a collapsible ledger marker (visible content,
/// checkpoint markers, tool_result pair markers).
LedgerMarkerRef? ledgerMarkerRef(int index, Message message) {
  if (message is! UserMessage) return null;
  final text = messageText(message);
  if (!isCompactionMarkerText(text)) return null;
  if (text.contains('·ckpt·') || text.contains(':ckpt·')) return null;
  final tokens = estimateTokens(message);
  // A consolidated range pointer: `<label> [expand a-b]` — the whole
  // span is the marker's unit.
  final expand = RegExp(r'\[expand (\d+)(?:-(\d+))?\]').firstMatch(text);
  if (expand != null) {
    final from = int.parse(expand.group(1)!);
    final to = expand.group(2) == null ? from : int.parse(expand.group(2)!);
    return LedgerMarkerRef(
      index: index,
      message: message,
      firstSeq: from,
      lastSeq: to,
      hiddenCount: to - from + 1,
      tokens: tokens,
    );
  }
  // A per-record hidden marker: `[seq:hidden·kind·…]` (record tag
  // prefix tolerated).
  final hidden = RegExp(
    r'(?:^m\d+ )\[(\d+):hidden·|^\[(\d+):hidden·',
  ).firstMatch(text);
  final seq = hidden == null
      ? null
      : int.parse(hidden.group(1) ?? hidden.group(2)!);
  if (seq == null) return null;
  return LedgerMarkerRef(
    index: index,
    message: message,
    firstSeq: seq,
    lastSeq: seq,
    hiddenCount: 1,
    tokens: tokens,
  );
}

/// Plans the oldest-first collapse of [markers] (the request's ledger
/// markers in request order) until the total marker tokens are under
/// [budget]. Each merge replaces the oldest ADJACENT pair with one
/// collapsed pointer at the first marker's position; repeat until under
/// budget or no adjacent pair remains (a request whose markers all sit
/// alone keeps its detail — the budget is best-effort bounded).
LedgerCollapsePlan planLedgerBudget(
  List<LedgerMarkerRef> markers, {
  int budget = hiddenLedgerBudgetTokens,
  String Function(int fromSeq, int toSeq)? labelFor,
}) {
  final replace = <int, Message>{};
  final remove = <int>{};
  // Working copy: the plan mutates spans locally before committing.
  final spans = [
    for (final marker in markers)
      _Span(
        firstSeq: marker.firstSeq,
        lastSeq: marker.lastSeq,
        hiddenCount: marker.hiddenCount,
        tokens: marker.tokens,
        index: marker.index,
        message: marker.message,
      ),
  ];
  int total() => spans.fold(0, (sum, span) => sum + span.tokens);
  while (total() > budget) {
    // The oldest adjacent pair: first two spans that sit next to each
    // other in the request (their original positions are consecutive
    // among the SURVIVING markers — no visible record between).
    final merged = spans.isEmpty;
    if (merged) break;
    var pairStart = -1;
    for (var i = 0; i + 1 < spans.length; i++) {
      if (spans[i].mergeable && spans[i + 1].mergeable) {
        pairStart = i;
        break;
      }
    }
    if (pairStart < 0) break;
    final first = spans[pairStart];
    final second = spans[pairStart + 1];
    final label = labelFor?.call(first.firstSeq, second.lastSeq) ?? '';
    replace[first.index] = UserMessage.text(
      collapsedLedgerMarkerText(
        hiddenCount: first.hiddenCount + second.hiddenCount,
        fromSeq: first.firstSeq,
        toSeq: second.lastSeq,
        label: label,
      ),
      timestamp: _timestampOf(first.message),
    );
    remove.add(second.index);
    spans
      ..[pairStart] = _Span(
        firstSeq: first.firstSeq,
        lastSeq: second.lastSeq,
        hiddenCount: first.hiddenCount + second.hiddenCount,
        tokens: estimateTokens(replace[first.index]!),
        index: first.index,
        message: replace[first.index],
      )
      ..removeAt(pairStart + 1);
  }
  return LedgerCollapsePlan(replace: replace, remove: remove);
}

final class _Span {
  _Span({
    required this.firstSeq,
    required this.lastSeq,
    required this.hiddenCount,
    required this.tokens,
    required this.index,
    this.message,
  });

  final int firstSeq;
  final int lastSeq;
  final int hiddenCount;
  final int tokens;
  final int index;
  final Message? message;

  bool get mergeable => firstSeq > 0;
}

DateTime? _timestampOf(Message? message) => message?.timestamp;

/// The collapsed ledger marker: `N records hidden · <label>
/// [expand a-b]` — the count is honest, the door works
/// (`compact_expand`), and the label is the engine-generated histogram
/// (C5), never model text. Without a parsable span the door is omitted
/// and the marker never renders (the caller keeps the originals).
String collapsedLedgerMarkerText({
  required int hiddenCount,
  required int fromSeq,
  int? toSeq,
  String? label,
}) {
  if (fromSeq <= 0) return '';
  final pointer = expandMarker(from: fromSeq, to: toSeq);
  final cleanLabel = label?.trim() ?? '';
  final head = cleanLabel.isEmpty
      ? '$hiddenCount records hidden'
      : '$hiddenCount records hidden · $cleanLabel';
  return '$head $pointer';
}

/// The C5 per-range label over [records] (the covered session records):
/// the tool-name histogram (`bash ×61 · read ×40`) capped at
/// [toolHistogramMaxEntries], then the time span (`12:41–13:44`).
/// Engine-generated only — no model text, no injection surface. Empty
/// when there is nothing to name (the caller renders the bare pointer).
String toolHistogramLabel(List<SessionRecord?> records) {
  final counts = <String, int>{};
  DateTime? first;
  DateTime? last;
  for (final record in records) {
    if (record == null) continue;
    final at = record.timestamp;
    if (at.millisecondsSinceEpoch > 0) {
      first ??= at;
      last = at;
    }
    if (record is MessageRecord) {
      final message = record.message;
      if (message is AssistantMessage) {
        for (final block in message.content) {
          if (block is ToolCall) {
            counts[block.name] = (counts[block.name] ?? 0) + 1;
          }
        }
      } else if (message is ToolResultMessage) {
        counts[message.toolName] = (counts[message.toolName] ?? 0) + 1;
      }
    }
  }
  final parts = <String>[];
  final names = counts.keys.toList()
    ..sort((a, b) {
      final byCount = (counts[b] ?? 0).compareTo(counts[a] ?? 0);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  for (final name in names.take(toolHistogramMaxEntries)) {
    parts.add('$name ×${counts[name]}');
  }
  if (first != null && last != null) {
    parts.add('${_hhmm(first)}–${_hhmm(last)}');
  }
  return parts.join(' · ');
}

String _hhmm(DateTime at) {
  final h = at.hour.toString().padLeft(2, '0');
  final m = at.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// The outcome of [collapseLedgerMarkers]: the collapsed marker list in
/// order and how many merges ran.
final class LedgerCollapseOutcome {
  const LedgerCollapseOutcome({
    required this.messages,
    required this.replacementCount,
  });

  final List<Message> messages;
  final int replacementCount;
}

/// Convenience: applies [planLedgerBudget] to a plain marker-message
/// list and returns the collapsed markers in order (unit-test shape;
/// the projection uses the plan form to splice in place).
LedgerCollapseOutcome collapseLedgerMarkers(
  List<Message> markers, {
  int budget = hiddenLedgerBudgetTokens,
  String Function(int fromSeq, int toSeq)? labelFor,
}) {
  final refs = <LedgerMarkerRef>[];
  for (var i = 0; i < markers.length; i++) {
    final ref = ledgerMarkerRef(i, markers[i]);
    if (ref != null) refs.add(ref);
  }
  final plan = planLedgerBudget(refs, budget: budget, labelFor: labelFor);
  if (plan.isEmpty) {
    return LedgerCollapseOutcome(messages: markers, replacementCount: 0);
  }
  final result = <Message>[];
  for (var i = 0; i < markers.length; i++) {
    if (plan.remove.contains(i)) continue;
    result.add(plan.replace[i] ?? markers[i]);
  }
  return LedgerCollapseOutcome(
    messages: result,
    replacementCount: plan.replace.length,
  );
}

/// The joined text of a user message's content.
String messageText(Message message) {
  final content = message is UserMessage ? message.content : null;
  if (content is String) return content;
  if (content is List<ContentBlock>) {
    return content.whereType<TextContent>().map((b) => b.text).join('\n');
  }
  return '';
}

/// gh-2492 C5: the consolidated-hide write shape for ONE batch — the
/// engine-generated histogram label keyed to EVERY member (any member
/// the path still renders becomes the carrier) so the projection renders
/// `<label> [expand a-b]` instead of a per-record marker run. Labels
/// derive from the covered records at WRITE time — deterministic,
/// engine-only, no model text, no injection surface.
Map<String, String> hideBatchLabels(
  Iterable<String> recordIds, {
  required SessionRecord? Function(String id) recordAt,
}) {
  final ids = recordIds.toList();
  if (ids.isEmpty) return const {};
  final label = toolHistogramLabel([for (final id in ids) recordAt(id)]);
  if (label.isEmpty) return const {};
  return {for (final id in ids) id: label};
}
