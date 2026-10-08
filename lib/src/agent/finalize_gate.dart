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
/// The loop parses the `task-ledger` fenced block out of the run's final
/// assistant message ([parseTaskLedger]) and emits [TaskLedgerEvent]
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
    final items = [
      for (final row in raw)
        if (TaskLedgerItem.fromJson(row) case final item?) item,
    ];
    if (items.isEmpty) return null;
    return TaskLedger(items: items);
  }
}

final RegExp _fenceLine = RegExp(r'^\s*(`{3,})(.*)$');

/// Parses the LAST `task-ledger` fenced block out of [text] — the shape the
/// FinalizeGate contract mandates for the final answer. Returns null when
/// the text carries no block (legacy answers replay unchanged) or the block
/// holds no requirement-bearing entries.
///
/// Entries are `- key: value` lines; further `key: value` lines (deeper
/// indented) extend the current entry. Missing statuses parse as
/// [TaskLedgerItemStatus.fail]; unknown keys are ignored.
TaskLedger? parseTaskLedger(String text) {
  final block = _lastLedgerBlock(text);
  if (block == null) return null;
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

  for (final line in block.split('\n')) {
    final entry = RegExp(r'^\s*-\s+([A-Za-z_]+)\s*:\s?(.*)$').firstMatch(line);
    final field = RegExp(r'^\s+([A-Za-z_]+)\s*:\s?(.*)$').firstMatch(line);
    if (entry != null) {
      flush();
      current[entry.group(1)!] = entry.group(2) ?? '';
    } else if (field != null && current.isNotEmpty) {
      current[field.group(1)!] = field.group(2) ?? '';
    }
  }
  flush();
  if (items.isEmpty) return null;
  return TaskLedger(items: items);
}

/// The body of the last ` ```task-ledger ` fenced block in [text], or null.
String? _lastLedgerBlock(String text) {
  String? last;
  var inside = false;
  for (final line in text.split('\n')) {
    final match = _fenceLine.firstMatch(line);
    if (match == null) {
      if (inside) last = '${last ?? ''}$line\n';
      continue;
    }
    final info = match.group(2)!.trim();
    if (inside) {
      inside = false; // Closing fence — the block is complete.
    } else if (info == taskLedgerFence) {
      inside = true;
      last = null;
    }
  }
  return last == null ? null : last.trimRight();
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
