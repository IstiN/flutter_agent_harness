/// The agents-hub overlay state machine for the dart_tui REPL (issue #277):
/// the full-screen modal behind `/agents` — fleet tree with metrics in tree
/// mode, a read-only live transcript in transcript mode.
///
/// The host (the CLI hub driver) pushes freshly rendered [HubLine] content
/// via `HubStateMsg` whenever subagent events land; between pushes this
/// state owns the interactive bits locally: selection, collapse, and
/// transcript scrolling. Everything here is pure Dart — `fa_tui.dart` only
/// routes keys and paints the frame.
library;

import 'tui_text_width.dart' show tuiTextWidth;

/// `dim`/`inverse` ANSI wrappers (SGR-only, same style family as fa_tui).
String hubDim(String s) => '\x1b[2m$s\x1b[0m';
String hubInverse(String s) => '\x1b[7m$s\x1b[0m';

/// Which surface the overlay shows.
enum FaHubMode { tree, transcript }

/// What a key press asks the host to do (besides local state changes).
enum FaHubAction { none, enter, back, close }

/// One rendered content line of the overlay. Tree rows carry their row key
/// (the agent id); transcript lines are keyless.
final class HubLine {
  const HubLine(this.text, {this.key});
  final String? key;
  final String text;
}

/// The overlay state: mode, content lines, selection/scroll anchors.
final class FaHubState {
  FaHubState({
    required this.mode,
    required this.title,
    required this.lines,
    this.footer = '',
    this.selectedKey,
    this.follow = true,
    this.topOffset = 0,
    this.transcriptId = '',
    this.transcriptRunning = false,
    this.hint = '',
  });

  /// A tree-mode state over pre-rendered [rows] (see `hubAgentRow`).
  factory FaHubState.tree({
    required List<HubLine> rows,
    required String footer,
    String? selectedKey,
    String hint = defaultTreeHint,
  }) {
    return FaHubState(
      mode: FaHubMode.tree,
      title: 'agents hub',
      lines: rows,
      footer: footer,
      selectedKey: selectedKey ?? (rows.isEmpty ? null : rows.first.key),
      hint: hint,
    );
  }

  /// A transcript-mode state for [agentId] over pre-rendered [lines].
  factory FaHubState.transcript({
    required String agentId,
    required List<String> lines,
    required bool running,
  }) {
    return FaHubState(
      mode: FaHubMode.transcript,
      title: 'transcript — $agentId${running ? ' (live)' : ''}',
      lines: [for (final line in lines) HubLine(line)],
      transcriptId: agentId,
      transcriptRunning: running,
      hint: defaultTranscriptHint,
    );
  }

  static const defaultTreeHint =
      '↑↓ move · ←→ collapse · enter transcript · esc close';
  static const defaultTranscriptHint = '↑↓ scroll · end follow · esc back';

  final FaHubMode mode;
  final String title;
  final List<HubLine> lines;

  /// The tree footer aggregate line (empty in transcript mode).
  final String footer;

  /// Tree mode: the selected row's key (survives host re-pushes).
  final String? selectedKey;

  /// Transcript mode: pinned to the live edge (down at the edge re-arms).
  final bool follow;

  /// Transcript mode: top line offset while detached from the live edge.
  final int topOffset;

  /// Transcript mode: whose transcript (the agent id).
  final String transcriptId;

  /// Transcript mode: whether the subject agent is still running (drives
  /// the host's live-follow re-push timer).
  final bool transcriptRunning;

  final String hint;

  /// Collapsed row keys (tree mode). View-local on purpose: collapse is a
  /// TUI-side lens, the host's footer aggregates stay exact, and the set
  /// survives re-pushes because copies share it by reference.
  final Set<String> collapsedKeys = {};

  /// Carries the interactive bits over a host re-push: the tree selection
  /// key re-resolves into the fresh rows (first row when it vanished) and
  /// the collapsed set survives; transcript scroll anchors clamp to the
  /// new length. A mode change (or a first open) starts fresh.
  FaHubState carryingFrom(FaHubState? prev) {
    if (prev == null || prev.mode != mode) return this;
    if (mode == FaHubMode.tree) {
      final keys = [for (final line in lines) line.key];
      final wanted = prev.selectedKey;
      final kept = wanted != null && keys.contains(wanted)
          ? wanted
          : keys.isEmpty
          ? null
          : keys.first;
      final next = copyWith(selectedKey: kept)
        ..collapsedKeys.addAll(prev.collapsedKeys);
      return next;
    }
    // The new state's scroll fields are factory defaults; the user's
    // follow/detach anchor rides over the re-push — taking the fresh
    // follow=true here snapped detached scrolling back to the live edge
    // on every 500ms tick.
    return copyWith(
      follow: prev.follow,
      topOffset: prev.topOffset.clamp(0, lines.length),
    );
  }

  FaHubState copyWith({String? selectedKey, bool? follow, int? topOffset}) {
    return FaHubState(
      mode: mode,
      title: title,
      lines: lines,
      footer: footer,
      selectedKey: selectedKey ?? this.selectedKey,
      follow: follow ?? this.follow,
      topOffset: topOffset ?? this.topOffset,
      transcriptId: transcriptId,
      transcriptRunning: transcriptRunning,
      hint: hint,
    )..collapsedKeys.addAll(collapsedKeys);
  }

  /// The visible rows: descendants of collapsed keys are hidden (E1
  /// collapse — the footer string the host computed stays exact).
  List<HubLine> get visibleRows {
    if (collapsedKeys.isEmpty) return lines;
    final visible = <HubLine>[];
    var hiddenUntilDepth = -1;
    for (final line in lines) {
      final depth = _rowDepth(line.text);
      if (hiddenUntilDepth >= 0) {
        if (depth > hiddenUntilDepth) continue;
        hiddenUntilDepth = -1;
      }
      visible.add(line);
      if (line.key != null && collapsedKeys.contains(line.key)) {
        hiddenUntilDepth = depth;
      }
    }
    return visible;
  }

  int? _selectedIndex(List<HubLine> rows) {
    final key = selectedKey;
    if (rows.isEmpty) return null;
    if (key == null) return 0;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].key == key) return i;
    }
    return 0;
  }

  /// Toggles collapse for the selected row. A collapsed row toggles
  /// straight back open (its children are hidden, so the has-children
  /// guard below cannot see them); an expanded row collapses only when
  /// the next visible row is deeper (it has children at all).
  FaHubState toggleCollapseSelected() {
    final rows = visibleRows;
    final index = _selectedIndex(rows);
    if (index == null) return this;
    final key = rows[index].key;
    if (key == null) return this;
    if (collapsedKeys.contains(key)) {
      collapsedKeys.remove(key);
      return this;
    }
    if (index + 1 >= rows.length) return this;
    if (_rowDepth(rows[index + 1].text) <= _rowDepth(rows[index].text)) {
      return this;
    }
    collapsedKeys.add(key);
    return this;
  }

  /// Moves the tree selection one visible row (delta -1/+1).
  FaHubState moveSelection(int delta) {
    final rows = visibleRows;
    if (rows.isEmpty) return this;
    final index = (_selectedIndex(rows) ?? 0) + delta;
    final clamped = index.clamp(0, rows.length - 1);
    return copyWith(selectedKey: rows[clamped].key);
  }

  /// Scrolls the transcript (delta <0 up, >0 down). Scrolling down onto the
  /// live edge re-arms follow; scrolling up detaches.
  FaHubState scrollTranscript(int delta, {required int viewport}) {
    if (delta > 0) {
      if (follow) return this;
      final next = (topOffset + delta).clamp(0, lines.length);
      final reachedEdge = next + viewport >= lines.length;
      return copyWith(topOffset: reachedEdge ? 0 : next, follow: reachedEdge);
    }
    if (follow) {
      // Detach with the window showing the current live edge.
      final top = (lines.length - viewport).clamp(0, lines.length);
      return copyWith(follow: false, topOffset: top);
    }
    return copyWith(topOffset: (topOffset + delta).clamp(0, lines.length));
  }

  /// Handles a key; returns the next state and the host action. [viewport]
  /// is the content-row height (transcript scroll math).
  (FaHubState, FaHubAction) handleKey(String key, {int viewport = 20}) {
    return switch (mode) {
      FaHubMode.tree => _handleTreeKey(key),
      FaHubMode.transcript => _handleTranscriptKey(key, viewport: viewport),
    };
  }

  (FaHubState, FaHubAction) _handleTreeKey(String key) {
    switch (key) {
      case 'up':
      case 'k':
        return (moveSelection(-1), FaHubAction.none);
      case 'down':
      case 'j':
        return (moveSelection(1), FaHubAction.none);
      case 'left':
      case 'h':
      case 'right':
      case 'l':
        return (toggleCollapseSelected(), FaHubAction.none);
      case 'enter':
        return (this, FaHubAction.enter);
      case 'esc':
      case 'q':
        return (this, FaHubAction.close);
    }
    return (this, FaHubAction.none);
  }

  (FaHubState, FaHubAction) _handleTranscriptKey(
    String key, {
    required int viewport,
  }) {
    switch (key) {
      case 'up':
        return (scrollTranscript(-1, viewport: viewport), FaHubAction.none);
      case 'down':
        return (scrollTranscript(1, viewport: viewport), FaHubAction.none);
      case 'end':
        return (copyWith(follow: true, topOffset: 0), FaHubAction.none);
      case 'esc':
        return (this, FaHubAction.back);
      case 'q':
        return (this, FaHubAction.close);
    }
    return (this, FaHubAction.none);
  }
}

/// The tree-row nesting depth, from the leading two-space indent units the
/// view renderer emits (see `hubAgentRow`: depth N renders 2·(N+1) leading
/// spaces, so the unit count is depth+1 — only relative comparisons of this
/// value are meaningful).
int _rowDepth(String row) {
  var units = 0;
  while (row.startsWith('  ', units * 2)) {
    units++;
  }
  return units;
}

/// Host push: opens or refreshes the overlay with a whole new state. The
/// message type itself lives in fa_tui.dart (it extends dart_tui's Msg;
/// this file stays pure Dart).

/// Renders the full-overlay frame: title, windowed content, footer, hint.
/// The selected tree row paints inverse; transcript follow pins to the
/// live edge. Every line is padded/clamped to [width].
String renderHubFrame(
  FaHubState state, {
  required int width,
  required int height,
}) {
  final bodyHeight = (height - 3).clamp(1, 1000); // title + footer + hint
  final b = StringBuffer();
  void row(String text) {
    b.writeln(_fitPlain(text, width));
  }

  row(hubInverse(' ${_fitPlain(state.title, width - 2)}'));
  if (state.mode == FaHubMode.tree) {
    _hubTreeBody(state, bodyHeight, width, row);
  } else {
    _hubTranscriptBody(state, bodyHeight, width, row);
  }
  row(hubDim(state.hint));
  return b.toString();
}

/// The tree body: collapsed-aware visible rows in a selected-tracking
/// window, with the host-owned footer line underneath.
void _hubTreeBody(
  FaHubState state,
  int bodyHeight,
  int width,
  void Function(String) row,
) {
  final rows = state.visibleRows;
  if (rows.isEmpty) {
    row(hubDim('  (no agents)'));
  } else {
    final index = state._selectedIndex(rows) ?? 0;
    final window = _hubWindow(rows.length, index, bodyHeight);
    if (window.start > 0) row(hubDim('  … ${window.start} above'));
    for (var i = window.start; i < window.end; i++) {
      final text = ' ${rows[i].text}';
      row(i == index ? hubInverse(_fitPlain(text, width)) : text);
    }
    final below = rows.length - window.end;
    if (below > 0) row(hubDim('  … $below below'));
  }
  if (state.footer.isNotEmpty) row(hubDim(state.footer));
}

/// The transcript body: a window over [FaHubState.lines] pinned to the
/// live edge while following, or scrolled to [FaHubState.topOffset].
void _hubTranscriptBody(
  FaHubState state,
  int bodyHeight,
  int width,
  void Function(String) row,
) {
  final total = state.lines.length;
  final top = state.follow
      ? (total - bodyHeight).clamp(0, total)
      : state.topOffset.clamp(0, total);
  final end = (top + bodyHeight).clamp(0, total);
  if (total == 0) {
    row(hubDim('  (empty transcript)'));
  } else {
    if (!state.follow && top > 0) row(hubDim('  … $top above'));
    for (var i = top; i < end; i++) {
      row(' ${state.lines[i].text}');
    }
    final below = total - end;
    if (below > 0) row(hubDim('  … $below below'));
  }
  if (state.transcriptRunning && state.follow) {
    row(hubDim('  ● following live — esc to go back'));
  }
}

/// The visible window of [count] items for a [viewport] keeping [selected]
/// in view. Clamps to bounds.
({int start, int end}) _hubWindow(int count, int selected, int viewport) {
  if (viewport >= count) return (start: 0, end: count);
  final clamped = selected.clamp(0, count - 1);
  var start = clamped - viewport ~/ 2;
  if (start < 0) start = 0;
  if (start + viewport > count) start = count - viewport;
  return (start: start, end: start + viewport);
}

/// Pads or clips [text] to exactly [width] visible columns.
String _fitPlain(String text, int width) {
  final visible = tuiTextWidth(text);
  if (visible >= width) {
    // Clip by characters (rows are pre-wrapped by the host; this only
    // guards the title row).
    var out = '';
    var used = 0;
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final w = tuiTextWidth(ch);
      if (used + w > width) break;
      out += ch;
      used += w;
    }
    return out;
  }
  return text + ' ' * (width - visible);
}
