/// The FinalizeGate contract + TaskLedger (gh-1412): near-miss elimination
/// for unattended runs.
///
/// An unattended agent must stop declaring success on intent and start
/// declaring it on re-verified state. Two named components:
///
/// - **FinalizeGate** — the prompt contract (unattended/bench mode only;
///   `prompts/cli/finalize_gate.md`, rendered by the hosts into the system
///   prompt). Before any final summary the agent re-quotes every explicit
///   requirement as a checklist, verifies each item with a real command
///   against the produced state, and fixes or explicitly reports every
///   unmet item.
/// - **TaskLedger** — the checklist itself as a hidden session record
///   (`task_ledger` custom record, shaped like `model_request_summary`):
///   post-mortems see WHAT was self-checked, the bench summary reports
///   near-miss proximity (items verified / checks passed), and CI can
///   REG-gate the contract's presence.
///
/// The loop parses the `task-ledger` block out of the run's final
/// assistant message ([parseTaskLedger], tolerant to the unfenced
/// near-miss shape models emit — gh-1516), rewrites the answer so the
/// transcript never shows the ledger ([stripTaskLedger]), and emits
/// [TaskLedgerEvent]
/// (declared in `agent_loop.dart` — the event family is sealed there);
/// hosts persist [taskLedgerRecordType] records and the trajectory
/// snapshot builder folds them.
library;

/// The `custom` record type of the TaskLedger session record.
const String taskLedgerRecordType = 'task_ledger';

/// The fenced-block info string the FinalizeGate contract mandates for the
/// final answer's ledger (`​```task-ledger … `​`` `).
const String taskLedgerFence = 'task-ledger';

/// Per-item verification outcome. `fixed` = failed, then fixed and
/// re-verified — counts as verified (the fix loop is the contract's point).
enum TaskLedgerItemStatus {
  pass,
  fail,
  fixed;

  /// The payload spelling.
  String get jsonName => name;

  /// Tolerant parse: a missing or unrecognized status is [fail] — an
  /// unverified item must never silently count as verified.
  static TaskLedgerItemStatus fromName(Object? name) {
    final token = '$name'.trim().toLowerCase().split(RegExp(r'\s')).first;
    if (token.startsWith('pass')) return pass;
    if (token.startsWith('fix')) return fixed;
    return fail;
  }
}

/// One checklist entry: the verbatim requirement quote plus the real
/// verification command and its expected/actual outcome.
final class TaskLedgerItem {
  /// Creates an item. Fields other than [requirement] default to empty;
  /// [status] defaults to [TaskLedgerItemStatus.fail] (unverified).
  const TaskLedgerItem({
    required this.requirement,
    this.command = '',
    this.expected = '',
    this.actual = '',
    this.status = TaskLedgerItemStatus.fail,
  });

  /// The requirement, quoted verbatim from the task text.
  final String requirement;

  /// The command that verified the item against produced state.
  final String command;

  /// What the command should show.
  final String expected;

  /// What it actually showed.
  final String actual;

  /// The outcome.
  final TaskLedgerItemStatus status;

  /// Whether the item counts as verified (`pass` or `fixed`).
  bool get verified => status != TaskLedgerItemStatus.fail;

  /// Serializes for the `task_ledger` session record.
  Map<String, dynamic> toJson() => {
    'requirement': requirement,
    'command': command,
    'expected': expected,
    'actual': actual,
    'status': status.jsonName,
  };

  /// Tolerant parse (forward-versioned payloads): rows without a
  /// requirement are dropped, unknown fields ignored.
  static TaskLedgerItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final requirement = '${json['requirement'] ?? ''}'.trim();
    if (requirement.isEmpty) return null;
    return TaskLedgerItem(
      requirement: requirement,
      command: '${json['command'] ?? ''}',
      expected: '${json['expected'] ?? ''}',
      actual: '${json['actual'] ?? ''}',
      status: TaskLedgerItemStatus.fromName(json['status']),
    );
  }
}

/// The parsed task ledger: the checklist a run finished with.
final class TaskLedger {
  /// Creates a ledger.
  const TaskLedger({required this.items});

  /// One entry per checklist requirement.
  final List<TaskLedgerItem> items;

  /// Items verified against produced state (`pass` + `fixed`).
  int get verifiedCount => items.where((item) => item.verified).length;

  /// Items still unmet.
  int get failedCount => items.length - verifiedCount;

  /// Whether every item verified — the gate's green state.
  bool get allVerified => failedCount == 0 && items.isNotEmpty;

  /// Serializes for the `task_ledger` session record.
  Map<String, dynamic> toJson() => {
    'items': [for (final item in items) item.toJson()],
  };

  /// Tolerant parse: non-map payloads and requirement-less rows never
  /// throw; a payload with no surviving items parses to null.
  static TaskLedger? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['items'];
    if (raw is! List) return null;
    final items = [for (final row in raw) ?TaskLedgerItem.fromJson(row)];
    if (items.isEmpty) return null;
    return TaskLedger(items: items);
  }
}

/// Parses the LAST parseable `task-ledger` block out of [text] — the
/// fenced shape the FinalizeGate contract mandates for the final answer,
/// or the near-miss unfenced `task-ledger` heading + bullet shape models
/// actually emit (gh-1516). Returns null when the text carries no
/// requirement-bearing ledger (legacy answers replay unchanged).
///
/// Entries are `- key: value` lines; further `key: value` lines (deeper
/// indented) extend the current entry. Missing statuses parse as
/// [TaskLedgerItemStatus.fail]; unknown keys are ignored.
TaskLedger? parseTaskLedger(String text) => resolveTaskLedger(text)?.ledger;

/// Removes the last parseable ledger (fenced or the unfenced near-miss
/// shape) from [text] — the run's final answer must never SHOW the
/// checklist it self-checked with (gh-1516): the record lives in the
/// hidden `task_ledger` session record, the transcript stays clean.
/// Returns [text] unchanged when no ledger parses out of it.
///
/// Only the blank runs TOUCHING the removed span are collapsed — the
/// rest of the answer stays byte-identical (gh-1516 review): multi-blank
/// formatting elsewhere is user-facing text, not strip fallout.
String stripTaskLedger(String text) =>
    resolveTaskLedger(text)?.strippedText ?? text;

/// Resolves the last parseable ledger of [text] in ONE scan (gh-1516
/// review): the parsed [TaskLedger] plus the answer text with the ledger
/// span removed. Null when no requirement-bearing ledger parses. The
/// `MessageEndEvent` interceptor and the end-of-run fold both derive
/// their payloads from a single call here — pairing the event with the
/// stripped answer never re-parses the text.
({TaskLedger ledger, String strippedText})? resolveTaskLedger(String text) {
  final hit = _lastParseableLedgerSpan(text);
  if (hit == null) return null;
  return (
    ledger: TaskLedger(items: hit.items),
    strippedText: _stripSpan(text, hit.span),
  );
}

final RegExp _fenceLine = RegExp(r'^\s*(`{3,})(.*)$');
final RegExp _entryLine = RegExp(r'^\s*-\s+([A-Za-z_]+)\s*:\s?(.*)$');
final RegExp _fieldLine = RegExp(r'^\s+([A-Za-z_]+)\s*:\s?(.*)$');

/// One candidate ledger span in the answer text: the fenced block (span =
/// opening fence through closing fence) or the unfenced heading + bullets
/// (span = the heading through the last entry line). [body] carries the
/// entry lines only — the parser's exact input shape.
final class _LedgerSpan {
  _LedgerSpan({
    required this.startLine,
    required this.endLine,
    required this.body,
  });

  final int startLine;
  final int endLine;
  final String body;
}

/// The last ledger candidate that parses to a requirement-bearing ledger,
/// or null — carrying the candidate's already-parsed [items] (each
/// candidate is parsed exactly once; the winner's list is reused, never
/// re-parsed). Candidates are tried newest-first so a revised (fenced)
/// ledger still wins over an earlier near-miss — the "last block decides"
/// rule of gh-1412, widened to both shapes (gh-1516).
({_LedgerSpan span, List<TaskLedgerItem> items})? _lastParseableLedgerSpan(
  String text,
) {
  final spans = _ledgerSpans(text);
  for (final span in spans.reversed) {
    final items = _parseLedgerItems(span.body);
    if (items.isNotEmpty) return (span: span, items: items);
  }
  return null;
}

/// Removes the span's lines from [text], collapsing ONLY the blank runs
/// touching the vacated range (gh-1516 review): a mid-answer seam keeps a
/// single blank line of separation; a run the removal pushed to the very
/// start or end of the answer drops entirely (the edge the ledger
/// vacated). Everything away from the seam stays byte-identical.
String _stripSpan(String text, _LedgerSpan span) {
  final lines = text.split('\n');
  final kept = <String>[
    for (var i = 0; i < lines.length; i++)
      if (i < span.startLine || i > span.endLine) lines[i],
  ];
  // Kept coordinates: lines[0, span.startLine) keep their indices; the
  // first line after the span lands at kept index span.startLine.
  _collapseSeamBlank(kept, span.startLine, span.startLine == 0);
  _collapseSeamBlank(
    kept,
    span.startLine - 1,
    span.endLine == lines.length - 1,
  );
  return kept.join('\n');
}

/// Collapses the maximal blank run touching kept-coordinate [index] to a
/// single blank line — or removes it entirely under [dropEntirely] (the
/// run is the answer's leading/trailing edge, blank only because the
/// ledger vacated it). Out-of-range and non-blank indices are no-ops.
void _collapseSeamBlank(List<String> lines, int index, bool dropEntirely) {
  if (index < 0 || index >= lines.length) return;
  if (lines[index].trim().isNotEmpty) return;
  var start = index;
  while (start > 0 && lines[start - 1].trim().isEmpty) {
    start--;
  }
  var end = index;
  while (end + 1 < lines.length && lines[end + 1].trim().isEmpty) {
    end++;
  }
  lines.replaceRange(start, end + 1, dropEntirely ? const [] : const ['']);
}

/// Every ledger-shaped span in [text], in document order: fenced
/// ```task-ledger blocks and unfenced `task-ledger` headings followed by
/// ledger bullets.
List<_LedgerSpan> _ledgerSpans(String text) {
  final lines = text.split('\n');
  final spans = <_LedgerSpan>[];
  var i = 0;
  while (i < lines.length) {
    final fenced = _fencedLedgerSpanAt(lines, i);
    if (fenced != null) {
      spans.add(fenced.span);
      i = fenced.nextLine;
      continue;
    }
    final unfenced = _unfencedLedgerSpanAt(lines, i);
    if (unfenced != null) {
      spans.add(unfenced.span);
      i = unfenced.nextLine;
      continue;
    }
    i++;
  }
  return spans;
}

/// A ledger span found at a line plus the line index to continue the
/// document scan from (past the span).
typedef _SpanScan = ({_LedgerSpan span, int nextLine});

/// Scans a fenced ```task-ledger block opening at [i], or null when the
/// line is not the opening fence. An unclosed fence swallows the rest of
/// [lines].
_SpanScan? _fencedLedgerSpanAt(List<String> lines, int i) {
  final fence = _fenceLine.firstMatch(lines[i]);
  if (fence == null || fence.group(2)!.trim() != taskLedgerFence) {
    return null;
  }
  final body = <String>[];
  var j = i + 1;
  var closed = false;
  while (j < lines.length) {
    if (_fenceLine.hasMatch(lines[j])) {
      closed = true;
      break;
    }
    body.add(lines[j]);
    j++;
  }
  return (
    span: _LedgerSpan(
      startLine: i,
      endLine: closed ? j : lines.length - 1,
      body: body.join('\n'),
    ),
    nextLine: closed ? j + 1 : lines.length,
  );
}

/// Scans an unfenced `task-ledger` heading at [i] plus its ledger bullets,
/// or null when the line is not the bare heading. A heading with no
/// entries spans itself only; blanks may separate entries and the span
/// ends at the last entry line.
_SpanScan? _unfencedLedgerSpanAt(List<String> lines, int i) {
  if (!_isLedgerHeading(lines[i])) return null;
  final body = <String>[];
  var j = i + 1;
  var lastEntry = i;
  while (j < lines.length) {
    final next = lines[j];
    if (_entryLine.hasMatch(next) || _fieldLine.hasMatch(next)) {
      body.add(next);
      lastEntry = j;
    } else if (next.trim().isEmpty) {
      // Blanks may separate entries; the span ends at the last entry.
    } else {
      break;
    }
    j++;
  }
  return (
    span: _LedgerSpan(startLine: i, endLine: lastEntry, body: body.join('\n')),
    nextLine: j,
  );
}

/// Whether [line] is a bare `task-ledger` heading — `#`-prefixed, bold, or
/// bare — and not a prose mention (the token alone on its line).
bool _isLedgerHeading(String line) {
  var token = line.trim();
  if (token.startsWith('#')) {
    token = token.replaceFirst(RegExp(r'^#{1,6}\s*'), '').trim();
  }
  if (token.startsWith('**') && token.endsWith('**') && token.length > 4) {
    token = token.substring(2, token.length - 2).trim();
  }
  return token.toLowerCase() == 'task-ledger';
}

/// Parses the entry grammar out of a span [body]: `- key: value` opens an
/// entry, deeper-indented `key: value` lines extend it. Rows without a
/// requirement are dropped; unknown keys ignored.
List<TaskLedgerItem> _parseLedgerItems(String body) {
  final items = <TaskLedgerItem>[];
  Map<String, String> current = {};
  void flush() {
    final requirement = (current['requirement'] ?? '').trim();
    if (requirement.isNotEmpty) {
      items.add(
        TaskLedgerItem(
          requirement: requirement,
          command: current['command'] ?? '',
          expected: current['expected'] ?? '',
          actual: current['actual'] ?? '',
          status: TaskLedgerItemStatus.fromName(current['status']),
        ),
      );
    }
    current = {};
  }

  for (final line in body.split('\n')) {
    final entry = _entryLine.firstMatch(line);
    final field = _fieldLine.firstMatch(line);
    if (entry != null) {
      flush();
      current[entry.group(1)!] = entry.group(2) ?? '';
    } else if (field != null && current.isNotEmpty) {
      current[field.group(1)!] = field.group(2) ?? '';
    }
  }
  flush();
  return items;
}

/// Renders [ledger] back into the fenced `task-ledger` block the contract
/// mandates (the parser's exact input shape) — the IT harness and tests
/// build final answers with it.
String formatTaskLedgerBlock(TaskLedger ledger) {
  final buffer = StringBuffer('```task-ledger\n');
  for (final item in ledger.items) {
    buffer
      ..writeln('- requirement: ${item.requirement}')
      ..writeln('  command: ${item.command}')
      ..writeln('  expected: ${item.expected}')
      ..writeln('  actual: ${item.actual}')
      ..writeln('  status: ${item.status.jsonName}');
  }
  buffer.write('```');
  return buffer.toString();
}
