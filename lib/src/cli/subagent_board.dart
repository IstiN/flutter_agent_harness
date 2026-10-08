/// The subagent status line-language (gh-1415): ONE dense terminal line per
/// subagent — state, name, age, cost — replacing the tall multi-line task
/// cards as the TUI's live subagent surface.
///
/// Presentation only: every field is composed from data the task machinery
/// already produces ([SubagentHandle] — P2, zero new data dependencies).
/// Three subjects, three pieces:
///
/// - [SubagentStatusRecord] — what one subagent's status IS right now
///   (display state, spawn time, token usage, task preview).
/// - [subagentStatusLine] — the SubagentLine renderer: fixed column order
///   `glyph state name age cost preview`, fixed widths, ellipsize-never-wrap
///   (the ten deltas' density/state/name/age/cost/alignment/truncation).
/// - [TaskBoardRegion] — the TaskBoardRegion: the SET of rows; rows appear
///   on spawn, occupy the same slot for their lifetime, flash on settle and
///   collapse to a dim one-liner, fold oldest-first under the settled cap;
///   zero rows when no subagent is known (quiet zero).
library;

import '../task/subagent.dart';
import 'tui_repl.dart' show stripAnsi;
import 'tui_text_width.dart';

/// The widest line the renderer targets (AC1's budget); hosts pass the live
/// terminal width, this is the default/golden width.
const int kSubagentLineMaxWidth = 100;

/// Display state of one subagent row (the card's four-state vocabulary:
/// omp-compressed glyphs + short verbs, never prose phrases).
enum SubagentDisplayState { running, waiting, completed, failed }

/// What one subagent's status IS right now — the pure data the renderer
/// consumes. Composed by [subagentRecordOf] from a [SubagentHandle]; every
/// field degrades to null independently (absent columns render `–`).
final class SubagentStatusRecord {
  const SubagentStatusRecord({
    required this.id,
    required this.name,
    required this.state,
    this.spawnedAt,
    this.lastActivityAt,
    this.tokens,
    this.preview,
  });

  /// The agent id (== the `agent://<id>` address). Duplicate-name rows
  /// disambiguate with its last 4 chars (E2).
  final String id;

  /// The human name (delta 3 — never mailbox/uuid noise).
  final String name;

  /// Display state (delta 2 — one glyph + one dim/bright level).
  final SubagentDisplayState state;

  /// When the child spawned (age base — recomputed per render, E3).
  final DateTime? spawnedAt;

  /// Last provider/turn activity (reserved for the liveness column).
  final DateTime? lastActivityAt;

  /// Cumulative tokens (lifetime + live), or null when nothing is known
  /// yet (E5 — `–`, alignment preserved).
  final int? tokens;

  /// One-line task preview (the trailing volatile column — dies first on
  /// narrow terminals, E1).
  final String? preview;
}

/// One rendered board row handed to the TUI: the line's text plus its
/// dim/bright level (delta 2 — live rows and the settle flash render
/// bright, collapsed summaries render dim).
final class SubagentBoardRow {
  const SubagentBoardRow({required this.text, required this.bright});

  /// The fitted one-line text (never wider than the render width).
  final String text;

  /// True = paint undimmed (live row, or inside the settle flash).
  final bool bright;
}

/// Composes a record from the retained-subagent handle the task machinery
/// already maintains (IT-1): no new orchestration calls, no new fields.
///
/// Every lifecycle state maps onto the four display states; usage folds the
/// in-flight `liveTokens` on top of the billed lifetime `tokens`; all
/// timestamps parse tolerantly (a bad stamp degrades that column only).
SubagentStatusRecord subagentRecordOf(
  SubagentHandle handle, {
  String? task,
}) {
  final total = handle.tokens + handle.liveTokens;
  // The preview is pre-rendered host-side: strip ANSI/control sequences so
  // the frame buffer stays plain text (review thread 3 — the source is
  // model-authored `task` text; escapes measure zero-width and would ride
  // the row raw).
  final previewSource = stripAnsi(
    (task ?? handle.task).replaceAll('\n', ' ').trim(),
  );
  return SubagentStatusRecord(
    id: handle.id,
    name: handle.name,
    state: switch (handle.status) {
      SubagentStatus.queued => SubagentDisplayState.waiting,
      SubagentStatus.running => SubagentDisplayState.running,
      SubagentStatus.idle => SubagentDisplayState.waiting,
      SubagentStatus.completed => SubagentDisplayState.completed,
      SubagentStatus.failed => SubagentDisplayState.failed,
      SubagentStatus.aborted => SubagentDisplayState.failed,
    },
    spawnedAt: DateTime.tryParse(handle.createdAt),
    lastActivityAt: handle.lastActivity.isEmpty
        ? null
        : DateTime.tryParse(handle.lastActivity),
    tokens: total > 0 ? total : null,
    preview: previewSource.isEmpty ? null : previewSource,
  );
}

// ---------------------------------------------------------------------------
// Column geometry — the fixed-width left rail (delta 6).
// ---------------------------------------------------------------------------

/// Glyph zone: the widest glyph is 2 cells (`⏸`, `✓`, `✗`), so the zone
/// pads every glyph to 2 and the state column aligns across rows.
const int _glyphZoneCells = 2;

/// State word field: the longest verb (`wait`) is 4 cells.
const int _stateCells = 4;

/// Name column: ellipsize-inside (delta 8), shrinks below the fixed
/// minimum before anything structural does (E1).
const int _nameCells = 16;

/// Age + cost fields: fixed 4 cells, right-aligned so digit growth never
/// reflows the row (the busy-row fixed-cell rule).
const int _ageCells = 4;
const int _costCells = 4;

/// Cells the rail needs with the name column at its 1-cell floor: glyph
/// zone + state + name(1) + age + cost + the four separators.
const int _railFloorCells =
    _glyphZoneCells +
    1 +
    _stateCells +
    1 +
    1 +
    1 +
    _ageCells +
    1 +
    _costCells;

/// The rendered head's cell count is `_railFloorCells + nameBudget - 1`
/// (the name column grows past its floor cell); the preview plus its one
/// separator must fit in whatever is left.

/// The state's glyph (delta 2): the vocabulary the task list and the tool
/// rows already use — `⠿` running, `⏸` waiting (queued/idle), `✓` done,
/// `✗` failed.
String subagentStateGlyph(SubagentDisplayState state) => switch (state) {
  SubagentDisplayState.running => '⠿',
  SubagentDisplayState.waiting => '⏸',
  SubagentDisplayState.completed => '✓',
  SubagentDisplayState.failed => '✗',
};

/// The state's short verb (delta 2 — never a phrase).
String subagentStateWord(SubagentDisplayState state) => switch (state) {
  SubagentDisplayState.running => 'run',
  SubagentDisplayState.waiting => 'wait',
  SubagentDisplayState.completed => 'done',
  SubagentDisplayState.failed => 'fail',
};

/// Renders ONE record as ONE terminal line (SubagentLine, AC1): fixed
/// column order `glyph state name age cost preview`, fixed widths,
/// ellipsize-never-wrap. Width-aware (E4: a resize re-truncates), and the
/// narrow ladder (E1) sacrifices the preview first, then the name — never
/// the state glyph, never the age/cost fields.
String subagentStatusLine(
  SubagentStatusRecord record, {
  required DateTime now,
  int width = kSubagentLineMaxWidth,
  String? idSuffix,
}) {
  final w = width < 1 ? 1 : width;
  // E1 ladder: below the full rail the NAME shrinks first (floor 1 cell);
  // the preview only exists while head + separator + text fit.
  final nameBudget = (w - (_railFloorCells - 1)).clamp(1, _nameCells);
  final previewBudget = w - _railFloorCells - nameBudget;

  final glyph = tuiPadRight(
    subagentStateGlyph(record.state),
    _glyphZoneCells,
  );
  final state = tuiPadRight(subagentStateWord(record.state), _stateCells);
  final label = idSuffix == null || idSuffix.isEmpty
      ? record.name
      : // The suffix must stay visible: the NAME shrinks around it, the
        // ellipsis never eats the disambiguator (E2).
        '${tuiFitWidth(record.name, (nameBudget - idSuffix.length - 1).clamp(1, nameBudget))}·$idSuffix';
  final name = tuiPadRight(tuiFitWidth(label, nameBudget), nameBudget);
  final age = subagentAgeLabel(record.spawnedAt, now).padLeft(_ageCells);
  final cost = subagentCompactTokens(record.tokens).padLeft(_costCells);
  final head = '$glyph $state $name $age $cost';

  // The preview only exists when the rail + separator fit (E1: it dies
  // first, and a below-minimum terminal drops it entirely).
  if (previewBudget < 1) return head;
  final previewText = record.preview == null || record.preview!.isEmpty
      ? '–'
      : record.preview!;
  return '$head ${tuiFitWidth(previewText, previewBudget)}';
}

/// The age field: elapsed since [spawnedAt], recomputed from timestamps on
/// every render (E3 — clock jumps self-correct, nothing accumulates).
/// Fixed ≤ 4 cells — `42s`, `12m`, `1h30` (2 h 15 m → `2h15`), `12h`
/// (hours-only from 10 h: `12h34` would be 5 cells), capped at `99h+`; `–`
/// when the spawn time is unknown (E5).
String subagentAgeLabel(DateTime? spawnedAt, DateTime now) {
  if (spawnedAt == null) return '–';
  final seconds = now.difference(spawnedAt).inSeconds;
  if (seconds < 0) return '0s'; // clock jump backwards clamps (E3)
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  // ponytail: stable cells beat honest digits past 99 h (the busy-row cap
  // precedent) — a multi-day agent freezes the field instead of reflowing.
  if (hours > 99) return '99h+';
  // The 4-cell budget binds (review thread 2): `2h15` keeps the minutes
  // while the hour is one digit; `12h34` would overflow, so from 10 h the
  // field carries hours only.
  if (hours >= 10) return '${hours}h';
  return '${hours}h${(minutes % 60).toString().padLeft(2, '0')}';
}

/// The cost field: compact token count ≤ 4 cells (delta 5 — a number, not
/// a sentence): `999`, `9.9k`, `12k`, `999k`, `9.9m`, `12m`, capped at
/// `999m`; `–` when absent/zero (E5 — a child with no provider requests
/// yet). One decimal only while the unit is single-digit (`4.1k`, `9.9m`);
/// from 10 up the integer form keeps the 4-cell budget (`12.3k` would
/// overflow it — review thread 2).
String subagentCompactTokens(int? tokens) {
  if (tokens == null || tokens <= 0) return '–';
  if (tokens < 1000) return '$tokens';
  // One decimal, `.0`-stripped (`4.1k`, `10k`) — below 10 units only.
  String oneDecimal(double unit) {
    final fixed = unit.toStringAsFixed(1);
    return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
  }

  if (tokens < 1000000) {
    final k = tokens / 1000;
    return k < 10 ? '${oneDecimal(k)}k' : '${tokens ~/ 1000}k';
  }
  if (tokens < 100000000) {
    final m = tokens / 1000000;
    return m < 10 ? '${oneDecimal(m)}m' : '${tokens ~/ 1000000}m';
  }
  final m = tokens ~/ 1000000;
  return m > 999 ? '999m' : '${m}m';
}

// ---------------------------------------------------------------------------
// The region — the SET of rows (TaskBoardRegion).
// ---------------------------------------------------------------------------

/// How long a settled row flashes bright before collapsing to the dim
/// one-line summary (the card's 3 s success/fail flash).
const Duration kSubagentSettleFlash = Duration(seconds: 3);

/// How many settled one-liners persist (open question 1's lean: persist a
/// line, fold on pressure — the oldest summaries fold first).
const int kSubagentMaxSettledRows = 4;

final class _BoardEntry {
  _BoardEntry(this.record);

  SubagentStatusRecord record;

  /// When the row settled (the flash base); null while live.
  DateTime? settledAt;

  bool get isTerminal => _isTerminalState(record.state);
}

/// The live subagent board (TaskBoardRegion): owns one row per subagent for
/// its lifetime — rows appear on spawn, keep their slot (a settled row is
/// reused by no one, AC3), flash on settle then collapse to the dim
/// one-liner, and fold oldest-first past the settled cap. An empty region
/// renders nothing (quiet zero, AC4).
final class TaskBoardRegion {
  TaskBoardRegion({
    DateTime Function()? now,
    this.settleFlash = kSubagentSettleFlash,
    this.maxSettledRows = kSubagentMaxSettledRows,
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration settleFlash;
  final int maxSettledRows;

  /// Insertion-ordered rows: spawn order IS the render order (AC2 — rows
  /// never interleave).
  final _rows = <String, _BoardEntry>{};

  /// Whether any row is live (drives the host's repaint ticker).
  bool get hasLive => _rows.values.any((e) => !e.isTerminal);

  /// Whether any settled row is inside its settle flash — a dim collapse
  /// is pending, so the host's ticker must stay armed to ship it (review
  /// thread 1: without this probe the ticker disarmed on settle and a
  /// lone settled row stayed bright forever).
  bool get hasFlashing {
    final now = _now();
    return _rows.values.any(
      (e) =>
          e.isTerminal &&
          e.settledAt != null &&
          now.difference(e.settledAt!) < settleFlash,
    );
  }

  /// Quiet zero (AC4): no subagent the board ever saw live → no rows.
  bool get isEmpty => _rows.isEmpty;

  /// Upserts one record. Terminal-first-sight children are ignored: a child
  /// that settled before the board ever saw it (rehydrated history, a
  /// digest race) is history, not news — the board stays quiet.
  void upsert(SubagentStatusRecord record, {DateTime? at}) {
    final existing = _rows[record.id];
    final terminal = _isTerminalState(record.state);
    if (existing == null) {
      if (terminal) return;
      _rows[record.id] = _BoardEntry(record);
      return;
    }
    existing.record = record;
    if (terminal) {
      // Stamp once: a second terminal event must not restart the flash.
      existing.settledAt ??= at ?? _now();
    } else {
      // A resume revives the row (the settle stamp clears).
      existing.settledAt = null;
    }
    _pruneSettled();
  }

  /// Drops all rows (session switch / teardown).
  void clear() => _rows.clear();

  /// Renders the visible rows at [width] (AC2): spawn order, one line each,
  /// never wider than [width]. Bright = live row or inside the settle
  /// flash; dim = the collapsed summary. Duplicate names disambiguate with
  /// a 4-char id suffix (E2).
  List<SubagentBoardRow> rows({required DateTime now, required int width}) {
    // Duplicate names across the VISIBLE set only (a folded row cannot
    // force a suffix on a visible one).
    final nameCounts = <String, int>{};
    for (final entry in _rows.values) {
      nameCounts[entry.record.name] = (nameCounts[entry.record.name] ?? 0) + 1;
    }
    return [
      for (final entry in _rows.values)
        SubagentBoardRow(
          text: subagentStatusLine(
            entry.record,
            now: now,
            width: width,
            idSuffix: (nameCounts[entry.record.name] ?? 0) > 1
                ? _idSuffix(entry.record.id)
                : null,
          ),
          bright: !entry.isTerminal ||
              entry.settledAt == null ||
              now.difference(entry.settledAt!) < settleFlash,
        ),
    ];
  }

  /// The E2 disambiguator: the id's last 4 chars.
  String _idSuffix(String id) => id.length <= 4 ? id : id.substring(id.length - 4);

  /// Folds the OLDEST settled one-liners past the cap (open question 1's
  /// lean — persist a line, fold on pressure). Live rows never fold.
  void _pruneSettled() {
    final settledIds = [
      for (final entry in _rows.entries)
        if (entry.value.isTerminal) entry.key,
    ];
    final overflow = settledIds.length - maxSettledRows;
    if (overflow <= 0) return;
    for (final id in settledIds.take(overflow)) {
      _rows.remove(id);
    }
  }
}

bool _isTerminalState(SubagentDisplayState state) =>
    state == SubagentDisplayState.completed ||
    state == SubagentDisplayState.failed;
