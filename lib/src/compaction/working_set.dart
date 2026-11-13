/// The bounded working set (gh-210): post-compaction continuity re-injected
/// at the context tail.
///
/// After a compact the context is digest/markers + a small protected tail;
/// operative continuity (the current plan/goal, recently touched files)
/// survives only by luck — mid-context information is disproportionately
/// lost (lost-in-the-middle). This library owns the two primitives the
/// card adds, both generalizations of in-tree mechanisms:
///
/// - **The goal recitation slot** — a latest-snapshot-wins `custom` record
///   ledger (`goal_recitation`, the obligations-ledger / judge-health
///   shape) the agent updates through the `recite_goal` tool. The engine
///   renders the LATEST snapshot as a bounded block at the context tail
///   (the level-0 obligations-block position), where every hide path is
///   structurally blind to it: hide passes walk PROJECTING records
///   (`visibleStructuredPath` → the ledger) and a `CustomRecord` never
///   projects — the judge, the deterministic fallback, the LRU re-hide and
///   the agent hide cannot even see the slot, let alone hide it (same
///   spirit as exempt user turns, one level stronger: exemption by
///   absence).
/// - **Recently touched files** — the `write`/`edit` call paths from the
///   branch path, newest-last, rendered as PATH REFERENCES ONLY (content
///   re-read on demand) once a compaction boundary exists on the branch.
///   The derivation walks the FULL post-classic-transform path, hidden and
///   checkpoint-covered records included: the fold removes content, the
///   working set keeps the pointers.
///
/// Operative skills already re-inject post-boundary (gh-1409's pinned
/// carrier at the request build); this card leaves that mechanism
/// untouched.
///
/// Budgets are enforced at RENDER time (the obligations precedent): the
/// goal clips with an explicit marker, the oldest files drop first with an
/// honest counting tail, and the whole block caps at
/// [defaultWorkingSetBudgetChars]. Every write this feature adds is an
/// append-only `custom` record — no migration ever rewrites or replaces
/// session files, and a pre-gh-210 session renders byte-identically (no
/// recitation snapshot + no compaction boundary → no block).
library;

import '../session/session_record.dart';
import '../types.dart' show AssistantMessage, ToolCall;

/// The `custom` record type of the goal recitation snapshot
/// (latest-snapshot-wins; an empty-goal payload is the agent's CLEAR
/// event).
const String goalRecitationRecordType = 'goal_recitation';

/// Default render budget of the whole working-set block in characters
/// (~1.5k tokens at the chars/4 heuristic) — the obligations block's
/// budget scale.
const int defaultWorkingSetBudgetChars = 6000;

/// Char cap of the goal line inside the block: a recited goal is the
/// agent's own summary, not verbatim history — clipping it is safe as long
/// as the clip is explicit (the agent re-recites a shorter goal).
const int goalRecitationBudgetChars = 2048;

/// How many recently-touched file paths the block renders at most (the
/// oldest drop first, counted honestly).
const int defaultWorkingSetMaxPaths = 8;

/// The tools whose `path` argument marks a file as recently touched: the
/// write-tier file mutators. Read-class calls never count — reading a file
/// is not touching it.
const Set<String> workingSetWriteTools = {'write', 'edit'};

/// One goal recitation snapshot: the agent's own recited plan/goal text
/// plus the write time (audit only — the render is position-free).
final class GoalRecitation {
  const GoalRecitation({required this.goal, required this.updatedAt});

  /// The recited goal/plan text, trimmed.
  final String goal;

  /// When the snapshot was recited.
  final DateTime updatedAt;

  /// The snapshot payload for `Session.appendCustomEntry`.
  Map<String, Object?> toPayload() => {
    'goal': goal,
    'updatedAt': updatedAt.toIso8601String(),
  };

  @override
  String toString() => 'GoalRecitation(${goal.length} chars)';
}

/// The snapshot payload for [goalRecitationRecordType] appends. Blank
/// goals normalize to `''` — the CLEAR payload.
Map<String, Object?> goalRecitationPayload(
  String goal, {
  DateTime? updatedAt,
}) => {
  'goal': goal.trim(),
  'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
};

/// Tolerant parse (the obligations E6 rule): anything that does not carry
/// a non-blank `goal` string parses to `null` — a junk or cleared snapshot
/// renders nothing, it never throws.
GoalRecitation? goalRecitationFromPayload(Object? data) {
  if (data is! Map) return null;
  final goal = data['goal'];
  if (goal is! String) return null;
  final trimmed = goal.trim();
  if (trimmed.isEmpty) return null;
  return GoalRecitation(
    goal: trimmed,
    updatedAt:
        DateTime.tryParse(data['updatedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// The latest recitation snapshot in file order over [entries], or `null`
/// when none — or when the LATEST snapshot cleared the slot (an empty-goal
/// payload). RESIDENT VIEW ONLY: on a windowed session the latest snapshot
/// can lie below the resident tail; the projection's fallback is the raw
/// scan (the obligations #488 lesson — see `Session.customRecordScan`).
GoalRecitation? latestGoalRecitationIn(List<SessionRecord> entries) {
  GoalRecitation? latest;
  for (final entry in entries) {
    if (entry is CustomRecord && entry.customType == goalRecitationRecordType) {
      latest = goalRecitationFromPayload(entry.data);
    }
  }
  return latest;
}

/// The recently touched file paths over a branch path, NEWEST-LAST,
/// distinct — a path's recency is its LAST mention, so a re-touched file
/// moves to the newest position. Pure: hidden and checkpoint-covered
/// records count (the fold removes content, not pointers).
List<String> recentlyTouchedPaths(List<SessionRecord> path) {
  final lastMention = <String, int>{};
  var i = 0;
  for (final record in path) {
    if (record is! MessageRecord) continue;
    final message = record.message;
    if (message is! AssistantMessage) continue;
    for (final block in message.content) {
      if (block is! ToolCall || !workingSetWriteTools.contains(block.name)) {
        continue;
      }
      final argument = block.arguments['path'];
      if (argument is! String) continue;
      final trimmed = argument.trim();
      if (trimmed.isEmpty) continue;
      lastMention[trimmed] = i++;
    }
  }
  final paths = lastMention.keys.toList()
    ..sort((a, b) => lastMention[a]!.compareTo(lastMention[b]!));
  return paths;
}

/// Whether [path] carries a compaction boundary — a structured hide, a
/// structured checkpoint, or a classic compaction record. The files
/// section of the working set renders only past one (post-compact
/// re-injection; pre-compaction the content is still in context).
bool hasCompactionBoundary(List<SessionRecord> path) => path.any(
  (record) =>
      record is HiddenRangeRecord ||
      record is CompactCheckpointRecord ||
      record is CompactionRecord,
);

const _blockOpen = '<system-notice>';
const _blockClose = '</system-notice>';
const _blockHeading = 'working set (bounded re-injection, gh-210):';
const _filesHeading =
    'recently touched files (paths only — re-read on '
    'demand):';

/// One flat goal line for the block, or `null` when there is no goal.
/// Whitespace collapses (the block is one line per fact) and the text
/// clips at [maxChars] with an explicit marker — never a silent cut.
String? _goalLine(GoalRecitation? recitation, int maxChars) {
  if (recitation == null) return null;
  final flat = recitation.goal.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return null;
  if (maxChars < 1) return null;
  if (flat.length <= maxChars) return 'goal: $flat';
  return 'goal: ${flat.substring(0, maxChars)}… '
      '[clipped at $maxChars chars — re-recite a shorter goal]';
}

/// Clips [goal] to the slot budget with the explicit marker — the single
/// clip both the `recite_goal` tool and the CLI persist path use, so
/// every write lands within the render budget (the render then never
/// clips again).
String reciteGoalForStorage(String goal) {
  final flat = goal.trim();
  if (flat.length <= goalRecitationBudgetChars) return flat;
  const marker = '… [clipped — recite a shorter goal]';
  final room = goalRecitationBudgetChars - marker.length;
  return '${flat.substring(0, room < 0 ? 0 : room)}$marker';
}

/// Renders the working-set block for a branch [path]: the goal section
/// (from [recitation], whenever a snapshot exists — the standing tail
/// slot) plus the recently-touched-files section (only past a compaction
/// boundary — the post-compact re-injection). Empty string when neither
/// section has content, so pre-gh-210 sessions render byte-identically.
///
/// Budgets (never silent): [maxPaths] caps the file lines (the oldest
/// counted away), [budgetChars] caps the whole block (the oldest files
/// drop first, then the goal clips), and every drop renders as an explicit
/// `… and N more` counting line. `budgetChars <= 0` disables the block.
String renderWorkingSetBlock(
  List<SessionRecord> path, {
  GoalRecitation? recitation,
  List<SessionRecord> dropped = const [],
  int maxPaths = defaultWorkingSetMaxPaths,
  int budgetChars = defaultWorkingSetBudgetChars,
}) {
  if (budgetChars <= 0) return '';
  final goalClip = budgetChars - 128 > 0
      ? (goalRecitationBudgetChars < budgetChars - 128
            ? goalRecitationBudgetChars
            : budgetChars - 128)
      : 0;
  final goalLine = _goalLine(recitation, goalClip);
  // The classic engine folds records OFF the path ([dropped] — older than
  // `firstKeptEntryId`); their writes are exactly the pointers a compacted
  // session must keep, so they join the scan ahead of the kept tail.
  final allPaths = hasCompactionBoundary(path)
      ? recentlyTouchedPaths([...dropped, ...path])
      : const <String>[];
  if (goalLine == null && allPaths.isEmpty) return '';

  String tail(int dropped) =>
      dropped > 0 ? '\n… and $dropped more touched files' : '';

  String assemble(List<String> kept) {
    final dropped = allPaths.length - kept.length;
    final lines = <String>[
      _blockOpen,
      _blockHeading,
      ?goalLine,
      if (kept.isNotEmpty) ...[_filesHeading, ...kept.map((p) => '- $p')],
      if (dropped > 0) tail(dropped).substring(1),
      _blockClose,
    ];
    return lines.join('\n');
  }

  // The newest [maxPaths] are the candidates; the budget then drops the
  // OLDEST kept file (never the newest) until the block fits.
  var kept = maxPaths > 0 && allPaths.length > maxPaths
      ? allPaths.sublist(allPaths.length - maxPaths)
      : allPaths;
  var block = assemble(kept);
  while (kept.isNotEmpty && block.length > budgetChars) {
    kept = kept.sublist(1); // drop the oldest kept file
    block = assemble(kept);
  }
  return block;
}
