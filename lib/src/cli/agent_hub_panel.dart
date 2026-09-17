library;

import 'agent_hub_view.dart' show hubDuration;

/// Deferred-message panels (btw-style) and background-task blocks for the
/// agents hub surface (issue #277).
///
/// Ported (reduced) from oh-my-pi `btw-panel.ts`/`btw-history-panel.ts` and
/// `background-tan-message.ts`: incoming subagent mail, scheduled-message
/// fires, and user steering that land MID-RUN render as distinct bordered
/// panels with a lifecycle state (instead of plain dim text), and
/// background jobs (shell + `task`) render as compact status blocks.
///
/// Pure Dart: bordered-line renderers take a width and return plain lines
/// (no ANSI); [DeferredPanelLog] is the host-side history with state
/// transitions.

/// Where a deferred panel came from.
enum DeferredPanelKind { mail, scheduled, steering }

/// Panel lifecycle.
///
/// Mail/scheduled panels ride the run: `running` while their turn runs,
/// then `complete` / `aborted` / `error` with it.
///
/// Steering panels follow DELIVERY instead (issue #437): `pending`
/// (persisted, waiting for a step boundary) → `delivered` (consumed: the
/// message merged at a step boundary or started a turn), or `dead` (the
/// consumer is gone — the run ended with the message unconsumed, or the
/// loop looks wedged). A late delivery from `dead` is honest recovery.
enum DeferredPanelState {
  pending,
  running,
  delivered,
  complete,
  aborted,
  error,
  dead,
}

/// One state icon for the panel header.
String deferredPanelStateIcon(DeferredPanelState state) => switch (state) {
  DeferredPanelState.pending => '⏳',
  DeferredPanelState.running => '🔄',
  DeferredPanelState.delivered => '✅',
  DeferredPanelState.complete => '✅',
  DeferredPanelState.aborted => '🛑',
  DeferredPanelState.error => '❌',
  DeferredPanelState.dead => '⚠',
};

/// One label for the panel kind.
String deferredPanelKindLabel(DeferredPanelKind kind) => switch (kind) {
  DeferredPanelKind.mail => 'mail',
  DeferredPanelKind.scheduled => 'scheduled',
  DeferredPanelKind.steering => 'steering',
};

/// One label for the panel state (issue #514): `dead` is internal
/// vocabulary — a wedged consumer reads as `queued (agent stalled)` so the
/// panel, the busy row and the banner all name ONE state.
String deferredPanelStateLabel(DeferredPanelState state) =>
    state == DeferredPanelState.dead ? 'queued (agent stalled)' : state.name;

/// One deferred (btw-style) message panel.
final class DeferredPanel {
  DeferredPanel({
    required this.id,
    required this.kind,
    required this.from,
    required this.body,
    required this.createdAt,
    this.state = DeferredPanelState.running,
    this.source,
    this.replyAddress,
  });

  /// Unique panel id (`btw-<n>`).
  final String id;

  final DeferredPanelKind kind;

  /// Sender (mail) / source label (scheduled, steering).
  final String from;

  /// The message body, pre-flattened by the host for one-panel display.
  final String body;

  final DateTime createdAt;

  DeferredPanelState state;

  /// Source link (e.g. the scheduled-records queue path) shown in the panel.
  final String? source;

  /// The mailbox a `reply` action addresses (absolute for cross-instance
  /// mail, the child id for in-session children); null = no reply action.
  final String? replyAddress;

  /// The one-line preview used by `/mail` listings.
  String get preview {
    final flat = body.replaceAll('\n', ' ').trim();
    return flat.length <= 60 ? flat : '${flat.substring(0, 60)}…';
  }
}

/// The host-side panel history: capped, latest last, with state
/// transitions the host applies as runs settle.
final class DeferredPanelLog {
  DeferredPanelLog({this.capacity = 30, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final int capacity;
  final DateTime Function() _now;

  final _panels = <DeferredPanel>[];
  var _nextId = 1;

  /// The panels, oldest first.
  List<DeferredPanel> get panels => List.unmodifiable(_panels);

  /// The panel with [id], or null.
  DeferredPanel? operator [](String id) {
    for (final panel in _panels) {
      if (panel.id == id) return panel;
    }
    return null;
  }

  /// Records a new running panel, evicting the oldest beyond [capacity].
  /// Returns the panel.
  DeferredPanel add({
    required DeferredPanelKind kind,
    required String from,
    required String body,
    String? source,
    String? replyAddress,
    DeferredPanelState state = DeferredPanelState.running,
  }) {
    final panel = DeferredPanel(
      id: 'btw-${_nextId++}',
      kind: kind,
      from: from,
      body: body,
      createdAt: _now(),
      state: state,
      source: source,
      replyAddress: replyAddress,
    );
    _panels.add(panel);
    while (_panels.length > capacity) {
      _panels.removeAt(0);
    }
    return panel;
  }

  /// Moves one panel to [state] (no-op when unknown/already terminal).
  bool transition(String id, DeferredPanelState state) {
    final panel = this[id];
    if (panel == null) return false;
    panel.state = state;
    return true;
  }

  /// Moves every ride-along [DeferredPanelState.running] panel to [state].
  /// Steering panels are skipped: their lifecycle follows delivery
  /// (pending → delivered / dead), never the run's (issue #437). Returns
  /// the transitioned ids (for the host's one-line transition notices).
  List<String> transitionRunning(DeferredPanelState state) {
    final moved = <String>[];
    for (final panel in _panels) {
      if (panel.kind == DeferredPanelKind.steering) continue;
      if (panel.state == DeferredPanelState.running) {
        panel.state = state;
        moved.add(panel.id);
      }
    }
    return moved;
  }
}

/// The composer prefill for a panel's `reply` action: the direct-send
/// slash command addressed to the panel's reply mailbox. Null when the
/// panel carries no reply address.
String? replyPrefillFor(DeferredPanel panel) {
  final address = panel.replyAddress;
  if (address == null || address.isEmpty) return null;
  return '/reply $address ';
}

/// Renders one bordered panel block: header (kind · from · state), the
/// body (hard-clamped to [width]), the optional source line, and the
/// action hint line when the panel has actions. Plain text, one string per
/// line; every line fits [width] visually (border included).
List<String> deferredPanelLines(DeferredPanel panel, {int width = 80}) {
  final w = width < 20 ? 20 : width;
  final inner = w - 2;
  final header =
      'btw · ${deferredPanelKindLabel(panel.kind)} from ${panel.from} · '
      '${deferredPanelStateLabel(panel.state)}';
  final lines = <String>[
    '┌─ ${_clip(header, inner - 3)}',
    for (final bodyLine in _wrapBody(panel.body, inner - 3))
      '│ ${_pad(bodyLine, inner - 3)}',
    if (panel.source != null) '│ ${_pad('source: ${panel.source}', inner - 3)}',
    '└─ ${_pad(_actionHint(panel), inner - 3)}',
  ];
  return lines;
}

/// The action hint trailing a panel (`reply: /reply …`), empty when the
/// panel has no actions.
String _actionHint(DeferredPanel panel) {
  final address = panel.replyAddress;
  if (address == null || address.isEmpty) return '';
  return 'reply: /reply $address';
}

/// One line of the transition notice printed when a panel settles.
String deferredPanelTransitionLine(DeferredPanel panel) =>
    '[btw] ${deferredPanelKindLabel(panel.kind)} from ${panel.from} → '
    '${deferredPanelStateLabel(panel.state)}';

/// Background-task block states — the kimi status table (issue #429).
/// `running` is the only live state; everything else is terminal. A card
/// that froze in `running` is a lie, so settled history never renders it.
enum TaskBlockState { running, done, failed, aborted, timedOut, stopped, lost }

/// Whether [state] is final. Live (`running`) cards belong to the transient
/// board region only — the transcript record never stores them.
bool taskBlockStateIsTerminal(TaskBlockState state) =>
    state != TaskBlockState.running;

/// Why a job landed in [TaskBlockState.lost]: the process vanished without
/// a settle report (host killed, PID gone) — the exit is unknowable.
const String shellJobLostReason = 'process gone, no exit reported';

/// The ONE resume summary row (issue #503): jobs that were live at
/// restart collapse into a single line instead of N four-line cards —
/// the card flood evicted the resumed transcript tail from the first
/// glass. Ids stay visible (a zombie is never hidden); full details
/// remain on the /tasks board and `bash_job` output.
String shellJobResumeLostSummaryLine({
  required List<String> ids,
  required int width,
}) {
  final n = ids.length;
  final head = '✗ $n background task${n == 1 ? '' : 's'} lost on restart'
      ' ($shellJobLostReason)';
  final line = ids.isEmpty ? head : '$head: ${ids.join(' · ')}';
  return line.length <= width ? line : '${line.substring(0, width - 1)}…';
}

/// kimi `MAX_DETAIL_LENGTH`: one dim detail line, capped so it fits any
/// width and never wraps into noise.
const int maxShellJobDetailLength = 240;

/// The human subject of a headline: `bash task` / `agent task`.
String _taskSubject(String kind) => '$kind task';

/// One human headline for a card state (issue #429 AC2): past tense, the
/// outcome first, no ids. The elapsed rides the completed headline; the
/// exit code rides the failed one.
String taskBlockHeadline({
  required String kind,
  required TaskBlockState state,
  double? elapsed,
  int? exitCode,
}) {
  final subject = _taskSubject(kind);
  return switch (state) {
    TaskBlockState.running => '$subject started in background',
    TaskBlockState.done =>
      elapsed == null
          ? '$subject completed in background'
          : '$subject completed in background (${hubDurationLike(elapsed)})',
    TaskBlockState.failed => '$subject failed (exit ${exitCode ?? '?'})',
    TaskBlockState.aborted || TaskBlockState.stopped => '$subject stopped',
    TaskBlockState.timedOut => '$subject timed out',
    TaskBlockState.lost => '$subject lost',
  };
}

/// The last path segment of [cwd] — the cwd tail of a dim detail line.
String shellJobCwdTail(String? cwd) {
  if (cwd == null || cwd.isEmpty) return '';
  final parts = cwd.split('/').where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? cwd : parts.last;
}

/// One dim detail line for a job card: id + cwd tail + reason + log path,
/// capped at [maxShellJobDetailLength] (issue #429 AC2).
String shellJobCardDetail({
  required String id,
  String? cwd,
  String? logPath,
  required TaskBlockState state,
  int? exitCode,
}) {
  final reason = switch (state) {
    TaskBlockState.running => '',
    TaskBlockState.done => 'exit 0',
    TaskBlockState.failed => 'exit ${exitCode ?? '?'}',
    TaskBlockState.aborted || TaskBlockState.stopped => 'stopped by user',
    TaskBlockState.timedOut => 'watchdog timeout',
    TaskBlockState.lost => shellJobLostReason,
  };
  final detail = [
    id,
    shellJobCwdTail(cwd),
    if (reason.isNotEmpty) reason,
    if (logPath != null && logPath.isNotEmpty) 'log: $logPath',
  ].join(' · ');
  return detail.length <= maxShellJobDetailLength
      ? detail
      : '${detail.substring(0, maxShellJobDetailLength - 1)}…';
}

/// One compact background-job block: a shell job or a background `task`.
final class TaskBlock {
  const TaskBlock({
    required this.id,
    required this.kind,
    required this.label,
    required this.state,
    this.elapsed,
    this.detail,
    this.exitCode,
    this.turn = 0,
  });

  /// The job id (`sh-…` for shell jobs, the agent:// id for tasks). Lives
  /// in the dim DETAIL line, never the header (issue #429 AC2).
  final String id;

  /// `bash` or `agent`.
  final String kind;

  /// The command (shell) or `agentType — task preview` (task).
  final String label;

  final TaskBlockState state;

  /// Elapsed seconds when known (settle time or live age).
  final double? elapsed;

  /// The process exit code when known (drives the failed headline).
  final int? exitCode;

  /// Exit code / log path / agent:// ref line (dim, pre-capped).
  final String? detail;

  /// The turn bucket this job belongs to (issue #429 collapse per turn).
  final int turn;

  /// A copy with terminal-state fields filled in (the board's settle).
  TaskBlock settled({
    required TaskBlockState state,
    double? elapsed,
    int? exitCode,
    String? detail,
  }) => TaskBlock(
    id: id,
    kind: kind,
    label: label,
    state: state,
    elapsed: elapsed ?? this.elapsed,
    exitCode: exitCode ?? this.exitCode,
    detail: detail ?? this.detail,
    turn: turn,
  );

  /// The JSONL `shell_job_registry` record shape (issue #429 AC9).
  Map<String, Object?> toRecord() => {
    'id': id,
    'kind': kind,
    'label': label,
    'state': state.name,
    if (elapsed != null) 'elapsed': elapsed,
    if (exitCode != null) 'exitCode': exitCode,
    if (detail != null) 'detail': detail,
    'turn': turn,
  };

  /// Restores a card from its record. Unknown states restore as
  /// [TaskBlockState.lost] — a reload never resurrects a live card.
  factory TaskBlock.fromRecord(Map<Object?, Object?> record) {
    final stateName = record['state'];
    final state = TaskBlockState.values.firstWhere(
      (s) => s.name == stateName,
      orElse: () => TaskBlockState.lost,
    );
    final rest = state == TaskBlockState.running ? TaskBlockState.lost : state;
    return TaskBlock(
      id: '${record['id']}',
      kind: '${record['kind'] ?? 'bash'}',
      label: '${record['label'] ?? ''}',
      state: rest,
      elapsed: (record['elapsed'] as num?)?.toDouble(),
      exitCode: (record['exitCode'] as num?)?.toInt(),
      detail: record['detail'] as String?,
      turn: (record['turn'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Renders one compact task card: the human headline header (no ids), the
/// label line, and the optional dim detail line. Every line fits [width]
/// visually (border included).
List<String> taskBlockLines(TaskBlock block, {required int width}) {
  final w = width < 20 ? 20 : width;
  final inner = w - 2;
  final header = taskBlockHeadline(
    kind: block.kind,
    state: block.state,
    elapsed: block.elapsed,
    exitCode: block.exitCode,
  );
  final lines = <String>['┌─ ${_clip(header, inner - 3)}'];
  void body(String text) =>
      lines.add('│ ${_pad(_clip(text, inner - 3), inner - 3)}');
  body(block.label);
  if (block.detail != null) {
    body(block.detail!);
  } else {
    // The id always lives in the dim detail line (issue #429 AC2) —
    // synthesize one when the card arrived without it.
    body(
      shellJobCardDetail(
        id: block.id,
        state: block.state,
        exitCode: block.exitCode,
      ),
    );
  }
  lines.add('└─${'─' * (inner - 2)}');
  return lines;
}

/// The live (transient) board summary line: `⟳ Background jobs (17) · 2
/// running · 15 done · 0 lost`. The lost segment is ALWAYS present — a
/// zombie is never hidden inside a green count (issue #429 AC3).
String shellJobLiveSummaryLine({
  required int total,
  required int running,
  required int done,
  required int lost,
  bool older = false,
}) =>
    '⟳ Background jobs ($total) · $running running · $done done · '
    '$lost lost${older ? ' · older' : ''}';

/// The settled summary card a collapsed turn leaves in the transcript:
/// terminal counts only (issue #429 AC6).
List<String> shellJobSummaryCardLines({
  required int total,
  required int running,
  required int done,
  required int lost,
  required int width,
}) {
  final w = width < 20 ? 20 : width;
  final inner = w - 2;
  final lines = <String>[
    '┌─ ${_clip('Background jobs ($total) · $running running · $done done · '
    '$lost lost', inner - 3)}',
  ];
  final hint = done + lost > 0
      ? 'bash_job status lists ids · bash_job output <id> tails a log'
      : 'still running — a summary settles when the turn\u2019s jobs finish';
  lines.add('│ ${_pad(_clip(hint, inner - 3), inner - 3)}');
  lines.add('└─${'─' * (inner - 2)}');
  return lines;
}

/// Seconds label in the same style as [hubDuration].
String hubDurationLike(double seconds) =>
    hubDuration(Duration(milliseconds: (seconds * 1000).round()));

/// Clips [text] to [width] visible characters with an ellipsis.
String _clip(String text, int width) {
  final flat = text.replaceAll('\n', ' ');
  if (flat.length <= width) return flat;
  if (width <= 1) return flat.substring(0, width);
  return '${flat.substring(0, width - 1)}…';
}

/// Right-pads [text] with spaces to exactly [width].
String _pad(String text, int width) => text.length >= width
    ? text.substring(0, width)
    : text + ' ' * (width - text.length);

/// Flattens a body into panel body lines: single long lines clamp to the
/// width; embedded newlines split (a panel body is a preview, not a
/// transcript).
Iterable<String> _wrapBody(String body, int width) sync* {
  if (body.isEmpty) {
    yield '';
    return;
  }
  final split = body.split('\n');
  final overflow = split.length - _maxPanelBodyLines;
  for (final line
      in overflow > 0 ? split.sublist(0, _maxPanelBodyLines) : split) {
    yield _clip(line, width);
  }
  if (overflow > 0) yield '… $overflow more';
}

/// Panel bodies render as a bounded preview: at most [_maxPanelBodyLines]
/// lines, a `… N more` tail when truncated.
const int _maxPanelBodyLines = 12;
