// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Session state for the background-job board (issue #429): one source of
/// truth that turns raw job lifecycles into truthful, bounded transcript
/// material.
///
/// The board is pure Dart with no clock: elapsed values arrive as data, so
/// unit tests inject them. Hosts feed it with [start]/[settle]/[newTurn]
/// and drain it after every mutation:
///
/// - [liveLines] feed the TUI's transient job-board region (never written
///   to history — the record never stores a live card).
/// - [takeTranscriptLines] drains terminal cards and per-turn summary
///   cards into the scrolling history, exactly once each.
///
/// Collapse rule: a turn with more than 3 jobs renders no individual
/// walls — one settled summary card when the whole turn finishes, with
/// `lost` cards still emitted individually (a zombie is never hidden
/// inside a green count). EXCEPTION (issue #503): jobs that were live at
/// RESTART collapse into one summary row — the individual-card flood
/// evicted the resumed transcript tail from the first glass.
library;

import 'agent_hub_panel.dart';
import '../session/session_record.dart';

/// AC1 mapping (issue #429): a job's observable lifecycle → card state.
/// Everything lands terminal except a still-running process; unknown
/// causes resolve to [TaskBlockState.lost] — never a fake "running".
TaskBlockState shellJobPhaseOf({
  required bool isRunning,
  int? exitCode,
  String? stopReason,
}) {
  if (isRunning) return TaskBlockState.running;
  if (stopReason != null) {
    return switch (stopReason) {
      'timeout' => TaskBlockState.timedOut,
      'cancelled' || 'stopped' => TaskBlockState.stopped,
      _ => TaskBlockState.lost,
    };
  }
  if (exitCode != null) {
    return exitCode == 0 ? TaskBlockState.done : TaskBlockState.failed;
  }
  return TaskBlockState.lost;
}

/// How many turns' worth of cards the board remembers for records.
const int _maxBoardHistory = 200;

/// How many live rows the transient region shows below the summary.
const int _maxLiveRows = 3;

/// The per-session background-job board. See the library doc.
final class ShellJobBoard {
  ShellJobBoard() : turn = 1;

  /// The latest `shell_job_registry` records in a resumed session's entry
  /// list (issue #429 AC9): later entries win wholesale - the board
  /// snapshot is rewritten per mutation, never merged.
  static List<Map<String, dynamic>> latestRecords(List<Object> entries) {
    var latest = const <Map<String, dynamic>>[];
    for (final entry in entries) {
      final records = _boardRecordsOf(entry);
      if (records != null) latest = records;
    }
    return latest;
  }

  /// The registry payload of one session entry, or null when the entry is
  /// not a `shell_job_registry` custom record carrying a list.
  static List<Map<String, dynamic>>? _boardRecordsOf(Object entry) {
    if (entry is! CustomRecord) return null;
    if (entry.customType != 'shell_job_registry') return null;
    if (entry.data is! List) return null;
    return [
      for (final item in entry.data as List)
        if (item is Map<String, dynamic>) item,
    ];
  }

  /// Rebuilds a board from its `shell_job_registry` records (issue #429
  /// AC9). Cards recorded as live are demoted to [TaskBlockState.lost] — a
  /// reload never shows "running" — and those cards announce themselves on
  /// the next [takeTranscriptLines]. Terminal history stays silent (it was
  /// already printed truthfully before the restart).
  factory ShellJobBoard.rehydrated(List<Object?> records) {
    final board = ShellJobBoard._();
    for (final record in records) {
      if (record is! Map) continue;
      final wasLive = record['state'] == TaskBlockState.running.name;
      final card = TaskBlock.fromRecord(record);
      board._cards.add(card);
      board.turn = card.turn > board.turn ? card.turn : board.turn;
      if (wasLive) board._pendingResumeLost.add(card.id);
    }
    // History buckets never re-print their summaries after a restart.
    for (final card in board._cards) {
      if (taskBlockStateIsTerminal(card.state) &&
          !board._pendingResumeLost.contains(card.id)) {
        board._emittedCardIds.add(card.id);
      }
      board._emittedSummaryTurns.add(card.turn);
    }
    return board;
  }

  ShellJobBoard._() : turn = 1;

  /// All cards ever, in start order (capped at [_maxBoardHistory]).
  final List<TaskBlock> _cards = [];

  /// Card ids already drained into the transcript.
  final Set<String> _emittedCardIds = {};

  /// Turn buckets whose summary card has been drained.
  final Set<int> _emittedSummaryTurns = {};

  /// Cards that reload demoted from live to lost — they still owe the
  /// transcript a terminal card.
  final Set<String> _pendingResumeLost = {};

  /// The current turn bucket. Starts at 1; [newTurn] advances it at each
  /// agent-run boundary.
  int turn;

  /// Advance to the next turn bucket (age-out: old buckets stop emitting).
  void newTurn() => turn++;

  /// Register a started job. The card's state must be live; [turn] is
  /// stamped by the board.
  void start(TaskBlock card) {
    _cards.add(
      TaskBlock(
        id: card.id,
        kind: card.kind,
        label: card.label,
        state: card.state == TaskBlockState.running
            ? TaskBlockState.running
            : TaskBlockState.lost,
        elapsed: card.elapsed,
        exitCode: card.exitCode,
        detail: card.detail,
        turn: turn,
      ),
    );
  }

  /// Settle a job in place: truthful terminal state, elapsed, exit code and
  /// the composed dim detail. Unknown ids are ignored.
  void settle(
    String id, {
    required TaskBlockState state,
    double? elapsed,
    int? exitCode,
    String? detail,
  }) {
    for (var i = _cards.length - 1; i >= 0; i--) {
      if (_cards[i].id != id) continue;
      _cards[i] = _cards[i].settled(
        state: state,
        elapsed: elapsed,
        exitCode: exitCode,
        detail: detail,
      );
      return;
    }
  }

  List<TaskBlock> cardsOfTurn(int t) =>
      _cards.where((c) => c.turn == t).toList();

  int _countOfTurn(int t, bool Function(TaskBlock) test) =>
      cardsOfTurn(t).where(test).length;

  /// Live cards, newest first.
  List<TaskBlock> get liveCards => _cards
      .where((c) => !taskBlockStateIsTerminal(c.state))
      .toList()
      .reversed
      .toList();

  /// Whether the current turn's bucket exceeds the collapse threshold
  /// (more than 3 jobs in one turn).
  bool get collapsed => cardsOfTurn(turn).length > 3;

  /// The transient job-board region: one summary line per collapsed bucket
  /// that still has live cards (current turn first), plus up to
  /// [_maxLiveRows] live rows. Buckets with 3 or fewer jobs show rows only.
  List<String> liveLines() {
    final lines = <String>[];
    final turnsWithLive =
        _cards
            .where((c) => !taskBlockStateIsTerminal(c.state))
            .map((c) => c.turn)
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));
    for (final t in turnsWithLive) {
      if (cardsOfTurn(t).length <= 3) continue;
      lines.add(
        shellJobLiveSummaryLine(
          total: _countOfTurn(t, (_) => true),
          running: _countOfTurn(t, (c) => c.state == TaskBlockState.running),
          done: _countOfTurn(t, (c) => c.state == TaskBlockState.done),
          lost: _countOfTurn(t, (c) => c.state == TaskBlockState.lost),
          older: t != turn,
        ),
      );
    }
    for (final card in liveCards.take(_maxLiveRows)) {
      lines.add('↳ ${card.id} · ${_clipLabel(card.label)}');
    }
    return lines;
  }

  /// All cards (any state), newest last.
  List<TaskBlock> get allCards => List.unmodifiable(_cards);

  /// Terminal material for the scrolling transcript, draining exactly once:
  /// individual cards for non-collapsed turns, one summary card (plus
  /// prominent lost cards) per collapsed turn once ALL its jobs settled.
  List<String> takeTranscriptLines({required int width}) {
    final lines = <String>[];
    // Issue #503: resume-lost cards never print individually — N four-line
    // cards flood the first glass and evict the resumed transcript tail.
    // They collapse into ONE summary row (ids included, details on
    // /tasks); the per-card loop below then skips them as emitted.
    if (_pendingResumeLost.isNotEmpty) {
      _emittedCardIds.addAll(_pendingResumeLost);
      lines.add(
        shellJobResumeLostSummaryLine(
          ids: _pendingResumeLost.toList(growable: false),
          width: width,
        ),
      );
      _pendingResumeLost.clear();
    }
    for (final card in _cards) {
      if (!taskBlockStateIsTerminal(card.state)) continue;
      if (_emittedCardIds.contains(card.id)) continue;
      final bucket = cardsOfTurn(card.turn);
      final collapsed = bucket.length > 3;
      final bucketDone = bucket.every((c) => taskBlockStateIsTerminal(c.state));
      if (collapsed) {
        if (!bucketDone) continue;
        // Collapsed turns emit only the summary — except non-done
        // terminal cards (lost/failed/timed out/stopped), which print
        // individually: a failure is never summarized away (issue #429).
        if (card.state == TaskBlockState.done) continue;
        _emittedCardIds.add(card.id);
        lines.addAll(taskBlockLines(card, width: width));
        continue;
      }
      _emittedCardIds.add(card.id);
      lines.addAll(taskBlockLines(card, width: width));
    }
    final turns = _cards.map((c) => c.turn).toSet().toList()..sort();
    for (final t in turns) {
      if (_emittedSummaryTurns.contains(t)) continue;
      final bucket = cardsOfTurn(t);
      if (bucket.length <= 3) continue;
      if (!bucket.every((c) => taskBlockStateIsTerminal(c.state))) continue;
      _emittedSummaryTurns.add(t);
      lines.addAll(
        shellJobSummaryCardLines(
          total: bucket.length,
          running: 0,
          done: bucket.where((c) => c.state == TaskBlockState.done).length,
          lost: bucket.where((c) => c.state == TaskBlockState.lost).length,
          width: width,
        ),
      );
    }
    return lines;
  }

  /// The `shell_job_registry` records (issue #429 AC9): the capped card
  /// history with truthful terminal states.
  List<Map<String, Object?>> toRecords() => _cards
      .skip(
        _cards.length > _maxBoardHistory ? _cards.length - _maxBoardHistory : 0,
      )
      .map((c) => c.toRecord())
      .toList();

  static String _clipLabel(String label) =>
      label.length <= 48 ? label : '${label.substring(0, 47)}…';
}
