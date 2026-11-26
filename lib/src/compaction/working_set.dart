/// The bounded working set tail block (gh-210, reshaped by issue #2423):
/// the recently-touched-files references re-injected at the context tail.
///
/// After a compact the context is digest/markers + a small protected tail;
/// operative continuity (the current plan, recently touched files)
/// survives only by luck — mid-context information is disproportionately
/// lost (lost-in-the-middle). This library owns the tail primitive:
///
/// - **Recently touched files** — the `write`/`edit` call paths from the
///   branch path, newest-last, rendered as PATH REFERENCES ONLY (content
///   re-read on demand) once a compaction boundary exists on the branch.
///   The derivation walks the FULL post-classic-transform path, hidden and
///   checkpoint-covered records included: the fold removes content, the
///   working set keeps the pointers. The section changes on every
///   `write`/`edit`, so it rides the tail (never the cached prompt
///   prefix) as an additive projection message — never a session record —
///   so every hide path walks records it cannot see.
/// - **The agent's working-set TEXT** — retired from this block (issue
///   #2423, C1). The newest snapshot now rides the SYSTEM channel of every
///   request (`working_set_snapshot.dart`), written through the
///   `working_set` tool (`working_set_tool.dart`) into a latest-wins
///   `custom` record; a legacy gh-210 `goal_recitation` record renders
///   there until a `working_set` record exists on the branch.
///
/// Operative skills already re-inject post-boundary (gh-1409's pinned
/// carrier at the request build); this card leaves that mechanism
/// untouched.
///
/// Budgets are enforced at RENDER time (the obligations precedent): the
/// oldest files drop first with an honest counting tail, and the whole
/// block caps at [defaultWorkingSetBudgetChars]. A pre-gh-210 session (no
/// compaction boundary) renders byte-identically — no block.
library;

import '../session/session_record.dart';
import '../types.dart' show AssistantMessage, ToolCall;

/// Default render budget of the whole tail block in characters — the
/// obligations block's budget scale.
const int defaultWorkingSetBudgetChars = 6000;

/// How many recently-touched file paths the block renders at most (the
/// oldest drop first, counted honestly).
const int defaultWorkingSetMaxPaths = 8;

/// The tools whose `path` argument marks a file as recently touched: the
/// write-tier file mutators. Read-class calls never count — reading a file
/// is not touching it.
const Set<String> workingSetWriteTools = {'write', 'edit'};

/// The recently touched file paths over a branch path, NEWEST-LAST,
/// distinct — a path's recency is its LAST mention, so a re-touched file
/// moves to the newest position. Paths are one-line strings (whitespace
/// collapses — a `\n` inside a tool argument must never become block
/// structure). Pure: hidden and checkpoint-covered records count (the
/// fold removes content, not pointers).
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
      // One line per fact: a `\n` is legal in POSIX filenames and
      // model-emittable into tool arguments — verbatim rendering would
      // inject block structure (fake entries, fake counting tails) into
      // the system-tagged block. Whitespace collapses here so the render
      // and the budgets measure the final strings, and spelling dedupe
      // stays consistent.
      final flattened = argument.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (flattened.isEmpty) continue;
      lastMention[flattened] = i++;
    }
  }
  final paths = lastMention.keys.toList()
    ..sort((a, b) => lastMention[a]!.compareTo(lastMention[b]!));
  return paths;
}

/// Whether [path] carries a compaction boundary — a structured hide, a
/// structured checkpoint, or a classic compaction record. The files
/// section renders only past one (post-compact re-injection; before a
/// compaction the content is still in context).
bool hasCompactionBoundary(List<SessionRecord> path) => path.any(
  (record) =>
      record is HiddenRangeRecord ||
      record is CompactCheckpointRecord ||
      record is CompactionRecord,
);

const _blockOpen = '<system-notice>';
const _blockClose = '</system-notice>';
const _filesHeading =
    'recently touched files (paths only — re-read on demand):';

/// Renders the working-set tail block for a branch [path]: the
/// recently-touched-files section (only past a compaction boundary — the
/// post-compact re-injection). Empty string when there is no section
/// content, so pre-gh-210 sessions render byte-identically.
///
/// Budgets (never silent): [maxPaths] caps the file lines (the oldest
/// counted away), [budgetChars] caps the whole block (the oldest files
/// drop first), and every drop renders as an explicit `… and N more`
/// counting line. `budgetChars <= 0` disables the block.
String renderWorkingSetBlock(
  List<SessionRecord> path, {
  List<SessionRecord> dropped = const [],
  int maxPaths = defaultWorkingSetMaxPaths,
  int budgetChars = defaultWorkingSetBudgetChars,
}) {
  if (budgetChars <= 0) return '';
  // The classic engine folds records OFF the path ([dropped] — older than
  // `firstKeptEntryId`); their writes are exactly the pointers a compacted
  // session must keep, so they join the scan ahead of the kept tail.
  final allPaths = hasCompactionBoundary(path)
      ? recentlyTouchedPaths([...dropped, ...path])
      : const <String>[];
  if (allPaths.isEmpty) return '';

  String assemble(List<String> kept) {
    final droppedCount = allPaths.length - kept.length;
    return <String>[
      _blockOpen,
      _filesHeading,
      ...kept.map((p) => '- $p'),
      if (droppedCount > 0) '… and $droppedCount more touched files',
      _blockClose,
    ].join('\n');
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

/// The gh-210 goal-recitation record type: RETIRED as a write target
/// (issue #2423 — `recite_goal` is gone), kept as the legacy READ shape —
/// the newest `goal_recitation` snapshot renders as the working set until
/// a `working_set` record exists on the branch (`working_set_snapshot.dart`).
const String goalRecitationRecordType = 'goal_recitation';

/// One legacy goal recitation snapshot (gh-210): the agent's recited
/// plan/goal text plus the write time. Read-only history.
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

/// The legacy snapshot payload shape (`{goal, updatedAt}`) — kept so
/// fixtures can write pre-#2423 session files.
Map<String, Object?> goalRecitationPayload(
  String goal, {
  DateTime? updatedAt,
}) => {
  'goal': goal.trim(),
  'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
};

/// Tolerant parse of a legacy payload (the obligations E6 rule): anything
/// that does not carry a non-blank `goal` string parses to `null` — a junk
/// or cleared snapshot renders nothing, it never throws.
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
