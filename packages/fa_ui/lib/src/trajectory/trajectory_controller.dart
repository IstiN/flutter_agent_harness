// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show
        ThrottledTrajectorySearchIndex,
        TrajectoryAssistantRecord,
        TrajectoryCellKind,
        TrajectoryCompactedRecord,
        TrajectoryGroupModel,
        TrajectoryRecord,
        TrajectorySnapshot,
        TrajectorySystemRecord,
        TrajectoryTimeRange,
        TrajectoryTimelineMode,
        TrajectoryTimelineModel,
        TrajectoryToolRecord,
        TrajectoryTurnModel,
        deriveTrajectoryLayout,
        deriveTrajectoryTimeline,
        trajectoryTimelineFocusIndexes;

/// View-state owner for the trajectory ledger.
///
/// Hosts push [TrajectorySnapshot]s via [updateSnapshot]; the controller
/// debounces them, folds the derived layout/timeline models once, and owns
/// every session-local interaction state: turn/assistant folds, the
/// duration/time projections with their timeline selection, record
/// selection, and the throttled full-text search. Widgets listen and
/// render; the table, timeline, and details surfaces build on this state.
class TrajectoryController extends ChangeNotifier {
  /// Creates a controller seeded with [initial].
  ///
  /// [snapshotDebounce] coalesces bursts of [updateSnapshot] calls;
  /// [searchThrottle] paces the incremental search index rebuild.
  TrajectoryController({
    TrajectorySnapshot? initial,
    this.snapshotDebounce = const Duration(milliseconds: 50),
    Duration searchThrottle = const Duration(milliseconds: 3000),
  }) : _throttledIndex = ThrottledTrajectorySearchIndex(
         throttle: searchThrottle,
       ) {
    _apply(initial ?? TrajectorySnapshot.empty, notify: false);
  }

  /// Coalescing window applied to [updateSnapshot] bursts.
  final Duration snapshotDebounce;

  final ThrottledTrajectorySearchIndex _throttledIndex;
  final Set<int> _collapsedTurns = {};
  final Set<String> _collapsedAssistants = {};

  TrajectorySnapshot _snapshot = TrajectorySnapshot.empty;
  List<TrajectoryTurnModel> _turns = const [];
  List<TrajectoryRecord> _records = const [];
  Map<String, int> _indexById = const {};
  TrajectoryTimelineModel? _timelineModel;
  Timer? _debounce;
  TrajectorySnapshot? _pendingSnapshot;
  bool _actualDuration = false;
  bool _actualTime = false;
  TrajectoryTimeRange? _timelineSelection;
  String? _selectedRecordId;
  String _searchQuery = '';
  Set<String>? _searchMatches;
  int? _pendingRecordFocus;
  final Set<TrajectoryLedgerFilter> _filters = {
    ...TrajectoryLedgerFilter.values,
  };
  final Set<String> _expandedRows = {};
  TrajectorySessionStats _stats = TrajectorySessionStats.empty;
  List<String> _searchMatchOrder = const [];
  int? _searchMatchIndex;

  /// The latest applied snapshot.
  TrajectorySnapshot get snapshot => _snapshot;

  /// The display turns: the layout fold with the active ledger filters
  /// applied (the table projection's input). Timeline and search always
  /// run over the full layout.
  List<TrajectoryTurnModel> get turns =>
      applyTrajectoryFilters(_turns, _filters);

  /// The layout's cells flattened into display order.
  List<TrajectoryRecord> get records => _records;

  /// The full-domain timeline model for the active mode, or null when no
  /// record is visible.
  TrajectoryTimelineModel? get timelineModel => _timelineModel;

  /// Monotonic version of the applied snapshot.
  int get revision => _snapshot.revision;

  /// Registers [snapshot] as the latest input; applies it (recomputing the
  /// derived state and notifying) after [snapshotDebounce] so bursts of
  /// appends collapse into one rebuild.
  void updateSnapshot(TrajectorySnapshot snapshot) {
    _pendingSnapshot = snapshot;
    _debounce?.cancel();
    _debounce = Timer(snapshotDebounce, () {
      _debounce = null;
      final pending = _pendingSnapshot!;
      _pendingSnapshot = null;
      _apply(pending);
    });
  }

  /// Collapsed turn numbers (the ledger hides their content rows).
  Set<int> get collapsedTurns => UnmodifiableSetView(_collapsedTurns);

  /// Collapsed assistant record ids (their contiguous tool run is hidden).
  Set<String> get collapsedAssistants =>
      UnmodifiableSetView(_collapsedAssistants);

  /// Flips one turn's collapsed state.
  void toggleTurn(int turn) {
    if (!_collapsedTurns.remove(turn)) _collapsedTurns.add(turn);
    notifyListeners();
  }

  /// Flips one assistant run's collapsed state.
  void toggleAssistant(String recordId) {
    if (!_collapsedAssistants.remove(recordId)) {
      _collapsedAssistants.add(recordId);
    }
    notifyListeners();
  }

  /// Collapses every collapsible turn.
  void collapseAllTurns() {
    _collapsedTurns
      ..clear()
      ..addAll(_collapsibleTurnNumbers());
    notifyListeners();
  }

  /// Expands every turn.
  void expandAllTurns() {
    _collapsedTurns.clear();
    notifyListeners();
  }

  /// Collapses every collapsible assistant run.
  void collapseAllAssistants() {
    _collapsedAssistants
      ..clear()
      ..addAll(_collapsibleAssistantIds());
    notifyListeners();
  }

  /// Expands every assistant run.
  void expandAllAssistants() {
    _collapsedAssistants.clear();
    notifyListeners();
  }

  /// The active ledger filter chips; all on by default.
  Set<TrajectoryLedgerFilter> get filters => UnmodifiableSetView(_filters);

  /// Flips one filter chip.
  void toggleFilter(TrajectoryLedgerFilter filter) {
    if (!_filters.remove(filter)) _filters.add(filter);
    notifyListeners();
  }

  /// The cached session roll-ups (turns, duration, tokens, start time).
  TrajectorySessionStats get stats => _stats;

  /// Record ids the ledger expands inline; later waves decide which rows
  /// consult this set (collapsed by default).
  Set<String> get expandedRecordIds => UnmodifiableSetView(_expandedRows);

  /// Flips one row's expanded state.
  void toggleExpandedRow(String recordId) {
    if (!_expandedRows.remove(recordId)) _expandedRows.add(recordId);
    notifyListeners();
  }

  /// Whether spans project onto their real recorded durations (default:
  /// equal-width sequence slots).
  bool get actualDuration => _actualDuration;
  set actualDuration(bool value) {
    if (_actualDuration == value) return;
    _actualDuration = value;
    _timelineSelection = null;
    _recomputeTimeline();
    notifyListeners();
  }

  /// Whether spans sit on the real wall clock (zero-width start markers).
  bool get actualTime => _actualTime;
  set actualTime(bool value) {
    if (_actualTime == value) return;
    _actualTime = value;
    _timelineSelection = null;
    _recomputeTimeline();
    notifyListeners();
  }

  /// The active horizontal projection.
  TrajectoryTimelineMode get timelineMode => _actualDuration
      ? (_actualTime
            ? TrajectoryTimelineMode.actual
            : TrajectoryTimelineMode.duration)
      : (_actualTime
            ? TrajectoryTimelineMode.time
            : TrajectoryTimelineMode.sequence);

  /// The inclusive selected interval in the active domain, null when clear.
  TrajectoryTimeRange? get timelineSelection => _timelineSelection;

  /// Replaces the timeline selection; null clears it.
  void setTimelineSelection(TrajectoryTimeRange? range) {
    if (range == _timelineSelection) return;
    _timelineSelection = range;
    notifyListeners();
  }

  /// Ledger record indexes active anywhere inside the selection, empty
  /// without one.
  Set<int> get timelineFocusIndexes {
    final range = _timelineSelection;
    if (range == null) return const {};
    return trajectoryTimelineFocusIndexes(_turns, range, timelineMode);
  }

  /// The selected ledger record id, null when nothing is selected.
  String? get selectedRecordId => _selectedRecordId;

  /// Selects a record; when a timeline focus set is active and the record
  /// sits outside it, the timeline selection clears.
  void selectRecord(String? id) {
    if (id != null && _timelineSelection != null) {
      final index = _indexById[id];
      if (index != null && !timelineFocusIndexes.contains(index)) {
        _timelineSelection = null;
      }
    }
    _selectedRecordId = id;
    notifyListeners();
  }

  /// The live search query; blank queries match nothing.
  String get searchQuery => _searchQuery;
  set searchQuery(String query) {
    if (_searchQuery == query) return;
    _searchQuery = query;
    _refreshSearch();
    notifyListeners();
  }

  /// Matching stable record ids, or null without a query.
  Set<String>? get searchMatchRecordIds => _searchMatches;

  /// Ledger indexes of the matching records, empty without matches.
  Set<int> get searchMatchIndexes => switch (_searchMatches) {
    null => const {},
    final matches => {for (final id in matches) ?_indexById[id]},
  };

  /// Matching record ids in display order (empty without a query).
  List<String> get searchMatchOrder => _searchMatchOrder;

  /// 0-based position in [searchMatchOrder], null without matches.
  int? get currentMatchIndex => _searchMatchIndex;

  /// Steps to the next match and selects it (wraps around).
  void nextSearchMatch() => _stepSearchMatch(1);

  /// Steps to the previous match and selects it (wraps around).
  void previousSearchMatch() => _stepSearchMatch(-1);

  void _stepSearchMatch(int delta) {
    final count = _searchMatchOrder.length;
    if (count == 0) return;
    final current = _searchMatchIndex ?? 0;
    _searchMatchIndex = (current + delta + count) % count;
    selectRecord(_searchMatchOrder[_searchMatchIndex!]);
  }

  void _refreshSearch() {
    _throttledIndex.update([_turns]);
    _searchMatches = _throttledIndex.search(_searchQuery);
    _searchMatchOrder = [
      for (final record in _records)
        if (_searchMatches?.contains(record.recordId) ?? false) record.recordId,
    ];
    final count = _searchMatchOrder.length;
    if (count == 0) {
      _searchMatchIndex = null;
      return;
    }
    final index = _searchMatchIndex;
    _searchMatchIndex = index == null
        ? 0
        : (index >= count ? count - 1 : index);
  }

  /// Requests a one-shot scroll-to-record from the timeline; the table
  /// consumes it with [takeRecordFocus].
  void focusRecord(int index) => _pendingRecordFocus = index;

  /// Consumes the pending record focus, or null when none is pending.
  int? takeRecordFocus() {
    final index = _pendingRecordFocus;
    _pendingRecordFocus = null;
    return index;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _throttledIndex.dispose();
    super.dispose();
  }

  void _apply(TrajectorySnapshot snapshot, {bool notify = true}) {
    _snapshot = snapshot;
    _turns = deriveTrajectoryLayout(snapshot);
    _records = [
      for (final turn in _turns)
        for (final group in turn.groups) ...group.cells,
    ];
    _indexById = {for (final record in _records) record.recordId: record.index};
    _recomputeTimeline();
    _stats = computeTrajectoryStats(snapshot, _turns);
    _refreshSearch();
    if (notify) notifyListeners();
  }

  void _recomputeTimeline() {
    _timelineModel = deriveTrajectoryTimeline(_turns, timelineMode);
  }

  /// Turn numbers with more than one content cell (request-only separators
  /// and system rows don't count).
  Set<int> _collapsibleTurnNumbers() => {
    for (final turn in _turns)
      if (turn.turn case final number? when _contentCells(turn).length > 1)
        number,
  };

  List<TrajectoryRecord> _contentCells(TrajectoryTurnModel turn) => [
    for (final group in turn.groups)
      for (final cell in group.cells)
        if (!_isRequestOnly(cell) && cell.kind != TrajectoryCellKind.system)
          cell,
  ];

  bool _isRequestOnly(TrajectoryRecord record) =>
      record is TrajectoryAssistantRecord && record.requestOnly;

  /// Message record ids whose next cell is a tool or subtool row.
  Set<String> _collapsibleAssistantIds() => {
    for (var i = 0; i < _records.length - 1; i++)
      if (_records[i].kind == TrajectoryCellKind.message &&
          (_records[i + 1].kind == TrajectoryCellKind.tool ||
              _records[i + 1].kind == TrajectoryCellKind.subtool))
        _records[i].recordId,
  };
}

/// Which ledger categories stay visible (the header filter chips).
enum TrajectoryLedgerFilter {
  /// User/context/assistant message rows.
  messages,

  /// Tool and subtool call rows.
  tools,

  /// Failed rows of any kind (additive: errors stay visible even when
  /// their category chip is off).
  errors,

  /// System-state and compaction rows.
  system,
}

/// Folds [turns] down to the records matching the active [filters].
///
/// Pure: rebuilds the turn/group models minus hidden cells and drops the
/// groups and turns that end up empty. With every chip selected the input
/// list returns unchanged.
List<TrajectoryTurnModel> applyTrajectoryFilters(
  List<TrajectoryTurnModel> turns,
  Set<TrajectoryLedgerFilter> filters,
) {
  if (filters.length == TrajectoryLedgerFilter.values.length) return turns;
  List<TrajectoryRecord> visible(List<TrajectoryRecord> cells) => [
    for (final record in cells)
      if (_recordMatchesFilters(record, filters)) record,
  ];
  return [
    for (final turn in turns)
      if ([
            for (final group in turn.groups)
              if (visible(group.cells) case final cells when cells.isNotEmpty)
                TrajectoryGroupModel(
                  kind: group.kind,
                  stepNumber: group.stepNumber,
                  description: group.description,
                  cells: cells,
                ),
          ]
          case final groups when groups.isNotEmpty)
        TrajectoryTurnModel(turn: turn.turn, groups: groups),
  ];
}

bool _recordMatchesFilters(
  TrajectoryRecord record,
  Set<TrajectoryLedgerFilter> filters,
) {
  if (filters.contains(TrajectoryLedgerFilter.errors) &&
      _recordIsError(record)) {
    return true;
  }
  return switch (record.kind) {
    TrajectoryCellKind.user ||
    TrajectoryCellKind.context ||
    TrajectoryCellKind.message => filters.contains(
      TrajectoryLedgerFilter.messages,
    ),
    TrajectoryCellKind.tool || TrajectoryCellKind.subtool => filters.contains(
      TrajectoryLedgerFilter.tools,
    ),
    TrajectoryCellKind.system || TrajectoryCellKind.compacted =>
      filters.contains(TrajectoryLedgerFilter.system),
  };
}

bool _recordIsError(TrajectoryRecord record) => switch (record) {
  TrajectoryAssistantRecord(:final isError) => isError ?? false,
  TrajectoryToolRecord(:final isError) => isError,
  TrajectoryCompactedRecord(:final interrupted) => interrupted,
  TrajectorySystemRecord(:final errorCode, :final errorMessage) =>
    errorCode != null || errorMessage != null,
  _ => false,
};

/// Session roll-ups for the header stats cluster. Cached on the
/// controller per applied snapshot (see [computeTrajectoryStats]).
final class TrajectorySessionStats {
  /// Creates the stats.
  const TrajectorySessionStats({
    required this.turnCount,
    required this.totalDuration,
    required this.inputTokens,
    required this.outputTokens,
    required this.startedAt,
  });

  /// Stats for an empty snapshot.
  static const empty = TrajectorySessionStats(
    turnCount: 0,
    totalDuration: Duration.zero,
    inputTokens: 0,
    outputTokens: 0,
    startedAt: null,
  );

  /// Model turns in the session.
  final int turnCount;

  /// Sum of every recorded step/tool duration.
  final Duration totalDuration;

  /// Prompt tokens across all assistant steps (input + cache read/write).
  final int inputTokens;

  /// Completion tokens across all assistant steps.
  final int outputTokens;

  /// Earliest recorded step start, null without timing data.
  final DateTime? startedAt;
}

/// Pure session roll-up over the snapshot's records: turns, total
/// duration, and the token in/out sums.
TrajectorySessionStats computeTrajectoryStats(
  TrajectorySnapshot snapshot,
  List<TrajectoryTurnModel> turns,
) {
  var duration = Duration.zero;
  var input = 0;
  var output = 0;
  for (final record in snapshot.records) {
    switch (record) {
      case TrajectoryAssistantRecord(
        :final timeSeconds,
        :final inputTokens,
        :final cacheReadTokens,
        :final cacheWriteTokens,
        :final outputTokens,
        :final usage,
      ):
        duration += timeSeconds ?? Duration.zero;
        input +=
            (inputTokens ?? usage?.input ?? 0) +
            (cacheReadTokens ?? usage?.cacheRead ?? 0) +
            (cacheWriteTokens ?? usage?.cacheWrite ?? 0);
        output += outputTokens ?? usage?.output ?? 0;
      case TrajectoryToolRecord(:final timeSeconds):
      case TrajectoryCompactedRecord(:final timeSeconds):
        duration += timeSeconds ?? Duration.zero;
      default:
        break;
    }
  }
  DateTime? startedAt;
  for (final request in snapshot.requests) {
    final start = request.startedAt;
    if (start != null && (startedAt == null || start.isBefore(startedAt))) {
      startedAt = start;
    }
  }
  return TrajectorySessionStats(
    turnCount: [
      for (final turn in turns)
        if (turn.turn != null) turn.turn!,
    ].length,
    totalDuration: duration,
    inputTokens: input,
    outputTokens: output,
    startedAt: startedAt,
  );
}
