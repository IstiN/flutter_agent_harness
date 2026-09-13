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

/// Panel lifecycle: delivered panels run while their turn runs, then
/// complete / abort / error with it.
enum DeferredPanelState { running, complete, aborted, error }

/// One state icon for the panel header.
String deferredPanelStateIcon(DeferredPanelState state) => switch (state) {
  DeferredPanelState.running => '🔄',
  DeferredPanelState.complete => '✅',
  DeferredPanelState.aborted => '🛑',
  DeferredPanelState.error => '❌',
};

/// One label for the panel kind.
String deferredPanelKindLabel(DeferredPanelKind kind) => switch (kind) {
  DeferredPanelKind.mail => 'mail',
  DeferredPanelKind.scheduled => 'scheduled',
  DeferredPanelKind.steering => 'steering',
};

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
  }) {
    final panel = DeferredPanel(
      id: 'btw-${_nextId++}',
      kind: kind,
      from: from,
      body: body,
      createdAt: _now(),
      source: source,
      replyAddress: replyAddress,
    );
    _panels.add(panel);
    while (_panels.length > capacity) {
      _panels.removeAt(0);
    }
    return panel;
  }

  /// Moves every [DeferredPanelState.running] panel to [state]. Returns the
  /// transitioned ids (for the host's one-line transition notices).
  List<String> transitionRunning(DeferredPanelState state) {
    final moved = <String>[];
    for (final panel in _panels) {
      if (panel.state == DeferredPanelState.running) {
        panel.state = state;
        moved.add(panel.id);
      }
    }
    return moved;
  }

  /// Moves one panel to [state] (no-op when unknown/already terminal).
  bool transition(String id, DeferredPanelState state) {
    final panel = this[id];
    if (panel == null) return false;
    panel.state = state;
    return true;
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
      '${panel.state.name}';
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
    '${panel.state.name}';

/// Background-task block states (omp's async job rendering).
enum TaskBlockState { running, done, failed, aborted }

/// One compact background-job block: a shell job or a background `task`.
final class TaskBlock {
  const TaskBlock({
    required this.id,
    required this.kind,
    required this.label,
    required this.state,
    this.elapsed,
    this.detail,
  });

  /// The job id (`sh-…` for shell jobs, the agent:// id for tasks).
  final String id;

  /// `bash` or `agent`.
  final String kind;

  /// The command (shell) or `agentType — task preview` (task).
  final String label;

  final TaskBlockState state;

  /// Elapsed seconds when known (settle time or live age).
  final double? elapsed;

  /// Exit code / log path / agent:// ref line.
  final String? detail;
}

/// Renders one compact task block: a header with id/state/elapsed, the
/// label line, and the optional detail line.
List<String> taskBlockLines(TaskBlock block, {int width = 80}) {
  final w = width < 20 ? 20 : width;
  final inner = w - 2;
  final elapsed = block.elapsed == null
      ? ''
      : ' · ${hubDurationLike(block.elapsed!)}';
  final header = '${block.kind} ${block.id} · ${block.state.name}$elapsed';
  final lines = <String>['┌─ ${_clip(header, inner - 3)}'];
  void body(String text) =>
      lines.add('│ ${_pad(_clip(text, inner - 3), inner - 3)}');
  body(block.label);
  if (block.detail != null) body(block.detail!);
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
