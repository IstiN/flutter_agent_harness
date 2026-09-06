/// The `/trajectory` command family split from [AgentCli] to keep
/// agent_cli.dart under the repo's 2800-line size gate. Same library (a
/// `part of`), so the extension sees the class's private members.
///
/// Read-only surfaces over the active session's records: the plain-text
/// TUI fallback (`view`), the cumulative cost table (`cost`), the live
/// record follower (`tail`), and the full-detail record view
/// (`inspect <n>`). Rendering lives in `trajectory_tui.dart`; this file
/// only resolves the active session and prints.
part of 'agent_cli.dart';

/// Implementation members of [AgentCli] for the `/trajectory` family.
extension on AgentCli {
  /// `/trajectory [view|cost|tail|inspect <n>]` — bare defaults to view.
  Future<void> _handleTrajectoryCommand(String rest) async {
    final parts = rest.isEmpty ? const <String>[] : rest.split(_spaces);
    switch (parts.isEmpty ? 'view' : parts.first) {
      case 'view':
        await _trajectoryView();
      case 'cost':
        await _trajectoryCost();
      case 'tail':
        await _trajectoryTail();
      case 'inspect':
        await _trajectoryInspect(parts.length > 1 ? parts[1] : '');
      default:
        io.writeln('usage: /trajectory [view|cost|tail|inspect <n>]');
    }
  }

  Future<void> _trajectoryView() async {
    final snapshot = await _trajectorySnapshot();
    if (snapshot == null) return;
    for (final line in trajectoryLines(snapshot, width: _trajectoryWidth)) {
      io.writeln(line);
    }
  }

  Future<void> _trajectoryCost() async {
    final snapshot = await _trajectorySnapshot();
    if (snapshot == null) return;
    for (final line in trajectoryCostLines(snapshot)) {
      io.writeln(line);
    }
  }

  Future<void> _trajectoryInspect(String arg) async {
    final snapshot = await _trajectorySnapshot();
    if (snapshot == null) return;
    if (snapshot.records.isEmpty) {
      io.writeln('no records');
      return;
    }
    final index = int.tryParse(arg);
    if (index == null) {
      io.writeln('usage: /trajectory inspect <n>');
      return;
    }
    final lines = trajectoryInspectLines(snapshot, index);
    if (lines == null) {
      io.writeln(trajectoryRangeError(index, snapshot.records.length));
      return;
    }
    for (final line in lines) {
      io.writeln(line);
    }
  }

  /// Follows the active session's records, one row per appended record,
  /// until interrupted (in the live REPL, Ctrl+C also exits `fa`).
  Future<void> _trajectoryTail() async {
    final session = _session;
    if (session == null) {
      io.writeln('no active session');
      return;
    }
    io.writeln(_style.dim('following session records — Ctrl+C to stop'));
    final tailer = TrajectoryTailer(width: _trajectoryWidth);
    final interrupted = io.interrupts.first.then((_) => true);
    var stopped = false;
    while (!stopped) {
      try {
        for (final line in tailer.tail(await session.getBranch())) {
          io.writeln(line);
        }
      } on Object catch (error) {
        io.writeln(_style.red('trajectory: tail failed: $error'));
        return;
      }
      stopped = await Future.any<bool>([
        interrupted,
        Future<void>.delayed(trajectoryPollInterval).then((_) => false),
      ]);
    }
  }

  /// The active session's snapshot, or null after printing why not.
  Future<TrajectorySnapshot?> _trajectorySnapshot() async {
    final session = _session;
    if (session == null) {
      io.writeln('no active session');
      return null;
    }
    return trajectorySnapshotOf(await session.getBranch());
  }

  /// Persists the outbound-request summary so replayed sessions rebuild the
  /// Request tab. A CustomRecord is context-omitted; the ordering matters —
  /// it must land before its assistant message (the replay walk expects it
  /// as the step's predecessor), which the event order guarantees.
  Future<void> _onModelRequest(TrajectoryRequestDetail detail) async {
    final session = _session;
    if (session == null) return;
    await session.appendCustomEntry(
      customType: 'model_request_summary',
      data: detail.toJson(),
    );
  }

  int get _trajectoryWidth => io.columns > 0 ? io.columns : 80;
}

final RegExp _spaces = RegExp(r'\s+');
