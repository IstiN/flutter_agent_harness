// The subagent status board coordinator (gh-1415): one compact live row
// per subagent in the CLI TUI. Composition + region lifecycle + the TUI
// push — presentation only, the task machinery's data and contracts are
// read, never changed.
//
// Part of agent_cli.dart (the _WaitingCoordinator pattern): the state
// lives on this coordinator, not on [AgentCli], to keep the host class
// under the line gate.
part of 'agent_cli.dart';

/// The 1 Hz repaint cadence for the age/cost columns while a row is live
/// (the card's refresh path). Pushes are deduped against the last render,
/// so a minute-granularity age emits one push per change, not per tick.
const _subagentBoardTickInterval = Duration(seconds: 1);

/// Owns the CLI's subagent board: derives [SubagentStatusRecord]s from the
/// retained-subagent registry on every task-machinery event, feeds the
/// [TaskBoardRegion], and pushes the rendered rows to the TUI. A 1 Hz
/// ticker re-renders the age/cost columns while anything is live; pushes
/// are deduped, so an unchanged frame costs nothing.
final class _SubagentBoardCoordinator {
  _SubagentBoardCoordinator(this._cli);

  final AgentCli _cli;

  /// The row lifecycle (spawn/settle flash/fold, AC3) lives here. The
  /// region reads the SAME clock seam the coordinator renders with (the
  /// host's waiting clock) — a second, wall-clock region clock would
  /// desync the flash end from the rendered `bright` (and break the
  /// manual-clock tests).
  late final TaskBoardRegion region = TaskBoardRegion(now: _now);

  Timer? _ticker;

  /// The last pushed render (text view) — the dedupe key.
  List<String> _lastPushed = const [];

  DateTime _now() => _cli._waitingClock();

  bool get _wired => _cli._useTui && _cli._tuiController != null;

  /// Any task-machinery event (subagent registry event, task-job start or
  /// settle): re-derive every row from the registry and refresh. Cheap —
  /// the region upsert is idempotent and the push dedupes.
  void refresh() {
    if (!_cli._useTui) return;
    for (final handle in _cli._subagentManager.handles) {
      region.upsert(subagentRecordOf(handle), at: _now());
    }
    _push();
    _syncTicker();
  }

  /// One 1 Hz tick: re-render age/cost from the timestamps (E3 — never
  /// accumulated ticks) and push — the dedupe makes the unchanged ticks
  /// free, and the tick at/after a flash END still renders (and ships)
  /// the dim collapse, which a push-only-while-flashing guard would skip
  /// exactly at the boundary (review thread 1). `_syncTicker` then
  /// disarms on the same tick once nothing is live or flashing.
  void _tick() {
    if (_wired) {
      _push();
    }
    _syncTicker();
  }

  void _syncTicker() {
    final want = _wired && (region.hasLive || region.hasFlashing);
    if (want && _ticker == null) {
      _ticker = Timer.periodic(_subagentBoardTickInterval, (_) => _tick());
    } else if (!want && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  /// Renders at the live width and pushes only a CHANGED render: the age
  /// column moves once a minute (minute granularity), cost only when the
  /// registry reports new usage. The dedupe key carries BRIGHTNESS too
  /// (review thread 1): the flash→dim collapse re-renders the same text
  /// dimmed, and a text-only key would suppress exactly that push.
  void _push() {
    final controller = _cli._tuiController;
    if (controller == null) return;
    final rows = region.rows(now: _now(), width: controller.termWidth);
    final texts = [for (final row in rows) '${row.text}|${row.bright}'];
    if (listEquals(texts, _lastPushed)) return;
    _lastPushed = texts;
    controller.setSubagentBoard(rows);
  }

  /// Session teardown: stop the ticker, drop the region.
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    region.clear();
    _lastPushed = const [];
  }
}

/// Test seams for the subagent board (gh-1415).
extension AgentCliSubagentBoardSeams on AgentCli {
  /// Test seam: fires one coordinator refresh now (the task-machinery
  /// event entry point).
  @visibleForTesting
  void subagentBoardRefreshForTest() => _subagentBoard.refresh();

  /// Test seam: the current rendered rows (the region's view, rendered at
  /// the TUI's live width — or [width] when given).
  @visibleForTesting
  List<SubagentBoardRow> subagentBoardRowsForTest({int? width}) =>
      _subagentBoard.region.rows(
        now: _waitingClock(),
        width: width ?? _tuiController?.termWidth ?? 80,
      );

  /// Test seam: the region itself (lifecycle tests drive upsert/clear).
  @visibleForTesting
  TaskBoardRegion get subagentBoardRegionForTest => _subagentBoard.region;

  /// Test seam: whether the 1 Hz repaint ticker is armed right now.
  @visibleForTesting
  bool get subagentBoardTickerArmedForTest => _subagentBoard._ticker != null;

  /// Test seam: fires one 1 Hz tick now (age/cost re-render + deduped
  /// push) without waiting on the real timer.
  @visibleForTesting
  void subagentBoardTickForTest() => _subagentBoard._tick();

  /// Test seam: the last push's rendered texts (the dedupe observable).
  @visibleForTesting
  List<String> get subagentBoardLastPushForTest => _subagentBoard._lastPushed;
}
