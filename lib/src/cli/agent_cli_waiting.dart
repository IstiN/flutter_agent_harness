// The visible-waiting coordinator (issue #450): one aggregate over the two
// waiting horizons — session-scoped background shell jobs (process-local,
// [ShellJobRegistry]) and persistent self-wake timers
// ([ScheduledMessageQueue]) — pushed to the TUI waiting row on every
// waiter enter/leave (never polled per frame), a ~20-minute heartbeat
// while waiters exist, restart honesty for jobs lost across runs, and the
// headless semantics (`--wait-for-jobs` + the detach summary).
//
// Part of agent_cli.dart (same pattern as agent_cli_persist.dart): the
// state lives on this coordinator, not on [AgentCli], to keep the host
// class under the line gate.
part of 'agent_cli.dart';

/// One waiter-aggregate snapshot: what the agent is waiting for right now.
final class WaiterSnapshot {
  const WaiterSnapshot({
    required this.jobs,
    required this.timers,
    this.lostJobs = 0,
  });

  /// Running background shell jobs, one purpose per job (command + id).
  final List<String> jobs;

  /// Armed self-wake timers: due epoch ms + text preview.
  final List<({int dueMs, String preview})> timers;

  /// Background jobs the previous run of this session left running.
  final int lostJobs;

  /// True when nothing live is awaited (lost jobs are history, not waits).
  bool get isEmpty => jobs.isEmpty && timers.isEmpty;
}

/// Owns the visible-waiting state and its event pushes. All mutations are
/// best-effort: a snapshot (disk scan) or manifest write failure must
/// never take a run down.
final class _WaitingCoordinator {
  _WaitingCoordinator(this._cli);

  final AgentCli _cli;

  /// Background jobs the previous run left running (restart honesty,
  /// captured once at boot from the cross-run manifest).
  int lostJobs = 0;

  /// When the current waiting stretch began — the heartbeat's elapsed base.
  DateTime? waitingSince;

  late final WaitingHeartbeat heartbeat = WaitingHeartbeat(
    onBeat: _deliverHeartbeat,
    minutes: () => _cli.config.waiting.waitHeartbeatMinutes,
  );

  DateTime Function() get _clock => _cli._waitingClock;

  ShellJobRegistry get _jobs => _cli._shellJobs;

  ScheduledMessageQueue get _timers => _cli._scheduledMessages;

  /// The cross-run manifest of jobs this process started
  /// (`<cwd>/.fah/bash_jobs/running.json`): entries present at boot were
  /// left running by the previous run — count them, then truncate.
  String get _manifestPath => '${_cli._env.cwd}/.fah/bash_jobs/running.json';

  /// Restart honesty: count the manifest entries, then take the file over.
  /// A torn/unreadable file counts zero — never invent lost jobs.
  Future<void> captureLostJobs() async {
    lostJobs = 0;
    try {
      final text = (await _cli._env.readTextFile(_manifestPath)).valueOrNull;
      final decoded = text == null ? null : jsonDecode(text);
      if (decoded is List) lostJobs = decoded.length;
    } on Object {
      lostJobs = 0;
    }
    await _writeManifest(const []);
  }

  Future<void> _manifestAdd(String id, String command) async {
    await _mutateManifest(
      (entries) => [
        ...entries,
        {'id': id, 'command': command},
      ],
    );
  }

  Future<void> _manifestRemove(String id) async {
    await _mutateManifest(
      (entries) => entries.where((e) => e['id'] != id).toList(),
    );
  }

  Future<void> _mutateManifest(
    List<Map<String, String?>> Function(List<Map<String, String?>>) mutate,
  ) async {
    try {
      final text = (await _cli._env.readTextFile(_manifestPath)).valueOrNull;
      final decoded = text == null ? null : jsonDecode(text);
      final entries = [
        for (final entry in decoded is List ? decoded : const [])
          if (entry is Map)
            {
              'id': entry['id'] as String?,
              'command': entry['command'] as String?,
            },
      ];
      await _writeManifest(mutate(entries));
    } on Object {
      // Best-effort bookkeeping — the job itself is unaffected.
    }
  }

  Future<void> _writeManifest(List<Map<String, String?>> entries) async {
    try {
      await _cli._env.writeFile(_manifestPath, jsonEncode(entries));
    } on Object {
      // Ignore: the manifest is a best-effort provenance sidecar.
    }
  }

  /// A background job started (event-driven waiting-row enter): record it
  /// in the cross-run manifest and refresh the row.
  Future<void> jobStarted(ShellJobEntry job) async {
    await _manifestAdd(job.id, job.command);
    await push();
  }

  /// A background job settled (event-driven waiting-row leave): drop it
  /// from the manifest and refresh the row.
  Future<void> jobSettled(ShellJobEntry job) async {
    await _manifestRemove(job.id);
    await push();
  }

  /// Headless entry point: stay for the waiters (`--wait-for-jobs`) or
  /// print the honest detach summary before exiting.
  Future<void> waitForJobsOrSummarize({required bool waitForJobs}) async {
    if (waitForJobs) return waitForJobsCeiling();
    return printHeadlessDetachSummary();
  }

  /// The aggregate: live jobs + deliverable timers. A settled job or a
  /// fired timer drops out of the next snapshot (AC1).
  Future<WaiterSnapshot> snapshot() async {
    final jobs = [
      for (final job in _jobs.jobs)
        if (job.isRunning) _jobPurpose(job),
    ];
    final timers = [
      for (final record in await _timers.pendingRecords())
        if (record.dueMs != null)
          (
            dueMs: record.dueMs!,
            preview: record.text.replaceAll('\n', ' ').trim(),
          ),
    ];
    return WaiterSnapshot(jobs: jobs, timers: timers, lostJobs: lostJobs);
  }

  String _jobPurpose(ShellJobEntry job) => '${job.command} (${job.id})';

  /// Recomputes the snapshot and pushes it at the TUI row + heartbeat.
  /// Callers fire-and-forget this on every waiter event: job start/settle,
  /// timer schedule/fire, turn settle, boot.
  Future<void> push() async {
    final snap = await snapshot();
    _syncHeartbeat(snap);
    if (snap.isEmpty && lostJobs == 0) return;
    _cli._tuiController?.setWaiting(
      jobs: snap.jobs,
      timers: snap.timers,
      lostJobs: snap.lostJobs,
    );
  }

  /// Arms the heartbeat while waiters exist (a resolved-then-remaining
  /// wait restarts the full period, E2) and stops it when the last
  /// waiter resolves (AC3: a resolved wait never beats again).
  void _syncHeartbeat(WaiterSnapshot snap) {
    if (snap.isEmpty) {
      waitingSince = null;
      heartbeat.stop();
    } else {
      waitingSince ??= _clock();
      heartbeat.pulse();
    }
  }

  /// The waiting heartbeat beat: a status round through the same self-wake
  /// channel as the scheduled-message deliveries. Idle-only — while busy
  /// the busy row already shows what is happening (and E3 keeps waiters
  /// running underneath); the next beat after the turn catches up.
  Future<void> _deliverHeartbeat() =>
      (_beatBlocked || _cli._viewer != null) ? Future.value() : _beatActive();

  /// Idle-only: while busy the busy row already shows what is happening
  /// (E3 keeps waiters running underneath); the next beat catches up.
  bool get _beatBlocked => _cli._headlessMode || _cli._exited || _cli.isBusy;

  /// The active beat: no waiters left — sync the chain off; otherwise a
  /// status round through the same self-wake channel as the
  /// scheduled-message deliveries.
  Future<void> _beatActive() async {
    final snap = await snapshot();
    if (snap.isEmpty) return _syncHeartbeat(snap);
    return _runBeat(snap);
  }

  /// Starts the ONE short status round for an active beat.
  void _runBeat(WaiterSnapshot snap) {
    _cli._startRun(
      '<system-notice>Waiting heartbeat: you have been waiting for '
      '${waitingMinutesElapsed(waitingSince, _clock())} min. Still pending: '
      '${describe(snap)}. Emit ONE short status line to the user about what '
      "you are still waiting for (e.g. 'still waiting for CI run X, Nm "
      "elapsed'). Do not start new work unless a waiter resolved."
      '</system-notice>',
    );
  }

  /// One-line human description of a snapshot ("1 background job (…), "
  /// 2 timers armed").
  String describe(WaiterSnapshot snap) => waitingDescribe(snap);

  /// The headless detach summary (AC7): exactly the contract's line, on
  /// stderr, whenever waiters outlive the run. The settle notice is NOT
  /// delivered to this (dead) process — a follow-up run re-enters instead.
  Future<void> printHeadlessDetachSummary() async {
    final snap = await snapshot();
    if (snap.isEmpty) return;
    _cli.io.writeln(waitingDetachSummary(snap));
  }

  /// `--wait-for-jobs` (opt-in): stay alive for the waiters, bounded by
  /// `waiting.waitCeilingMinutes` (default 30). Job settles start their
  /// follow-up run through the normal settle handler; due timers deliver
  /// through the queue and wake the idle run via the inbox path; every
  /// heartbeat cadence a stderr line keeps the wait observable (AC5).
  Future<void> waitForJobsCeiling() async {
    final snap = await snapshot();
    if (snap.isEmpty) return;
    _cli.io.writeln('⏳ waiting: ${describe(snap)}');
    final settled = await _ceilingWait(snap);
    _cli.io.writeln('⏳ waiters resolved — ${waitingDetachSummary(settled)}');
  }

  /// The ceiling wait loop: sleeps to the nearest wake source (a job
  /// settle, a timer due, the heartbeat cadence, or the ceiling —
  /// whichever lands first), pumps wake turns, and re-snapshots until
  /// either the waiters resolve or `waiting.waitCeilingMinutes` runs out.
  Future<WaiterSnapshot> _ceilingWait(WaiterSnapshot snap) async {
    final ceilingMin = _cli.config.waiting.waitCeilingMinutes;
    final deadline = _clock().add(Duration(minutes: ceilingMin));
    final hbMin = _cli.config.waiting.waitHeartbeatMinutes;
    var lastHeartbeat = _clock();
    while (!snap.isEmpty) {
      if (_hitCeiling(snap, deadline, ceilingMin)) return snap;
      final now = _clock();
      // Sleep until the nearest wake source — see [_hitCeiling] for the
      // ceiling leg.
      await _sleepUntilWake(now, deadline, snap, lastHeartbeat, hbMin);
      await _pumpWakeTurns();
      lastHeartbeat = await _beatIfDue(lastHeartbeat, hbMin);
      snap = await snapshot();
    }
    return snap;
  }

  /// Prints the ceiling-exit line once `waiting.waitCeilingMinutes` have
  /// passed; true when the wait must stop (AC5 ceiling).
  bool _hitCeiling(WaiterSnapshot snap, DateTime deadline, int ceilingMin) {
    final now = _clock();
    if (now.isBefore(deadline)) return false;
    _cli.io.writeln(
      '⏳ ${waitingDetachSummary(snap)} — wait ceiling ($ceilingMin min)'
      ' reached, exiting',
    );
    return true;
  }

  /// Deliver due timers and let any wake turn (job-settle or timer
  /// delivery) finish before the loop re-snapshots. A failed wake turn
  /// must not kill the wait loop.
  Future<void> _pumpWakeTurns() async {
    await _timers.deliverDue();
    await _cli._wakeOnInboxMail();
    if (_cli.isBusy) {
      try {
        await _cli._settled;
      } on Object {
        // Swallowed: the next snapshot reports the real state.
      }
    }
  }

  /// Emit the periodic `still waiting` beat when [heartbeatMin] has
  /// elapsed since [lastHeartbeat]; returns the (possibly new) beat time.
  Future<DateTime> _beatIfDue(DateTime lastHeartbeat, int heartbeatMin) async {
    if (!waitingBeatDue(
      now: _clock(),
      lastHeartbeat: lastHeartbeat,
      heartbeatMin: heartbeatMin,
    )) {
      return lastHeartbeat;
    }
    final beatSnap = await snapshot();
    if (beatSnap.isEmpty) return _clock();
    _cli.io.writeln('⏳ still waiting: ${describe(beatSnap)}');
    return _clock();
  }

  /// Sleep until the nearest wake source: a job settle, a timer due, the
  /// heartbeat cadence, or the ceiling — whichever lands first.
  Future<void> _sleepUntilWake(
    DateTime now,
    DateTime deadline,
    WaiterSnapshot snap,
    DateTime lastHeartbeat,
    int hbMin,
  ) async {
    final delay = nextWakeDelay(
      now: now,
      deadline: deadline,
      heartbeatMin: hbMin,
      lastHeartbeat: lastHeartbeat,
      timerDueMs: snap.timers.map((t) => t.dueMs),
    );
    if (delay <= Duration.zero) return;
    await Future.any([_cli._waitingSleep(delay), ..._runningJobWakes()]);
  }

  /// The settled-futures of every running shell job — each resolves as
  /// soon as its job settles and wakes the wait early.
  List<Future<void>> _runningJobWakes() => [
    for (final job in _jobs.jobs)
      if (job.isRunning) job.settled,
  ];
}

/// Whether a `still waiting` heartbeat beat is due now (issue #450):
/// cadence must be enabled and [lastHeartbeat] plus [heartbeatMin] must
/// have passed. Pure — unit-tested directly.
bool waitingBeatDue({
  required DateTime now,
  required DateTime lastHeartbeat,
  required int heartbeatMin,
}) {
  if (heartbeatMin <= 0) return false;
  return !now.isBefore(lastHeartbeat.add(Duration(minutes: heartbeatMin)));
}

/// Nearest wake delay for the `--wait-for-jobs` loop (issue #450): the
/// minimum of the ceiling deadline, each armed timer's due moment, and the
/// heartbeat cadence. Pure — unit-tested directly.
Duration nextWakeDelay({
  required DateTime now,
  required DateTime deadline,
  required int heartbeatMin,
  required DateTime lastHeartbeat,
  required Iterable<int> timerDueMs,
}) {
  var delay = deadline.difference(now);
  for (final due in timerDueMs) {
    final d = Duration(milliseconds: due - now.millisecondsSinceEpoch);
    if (d < delay) delay = d;
  }
  if (heartbeatMin > 0) {
    final beat =
        lastHeartbeat.difference(now) + Duration(minutes: heartbeatMin);
    if (beat < delay) delay = beat;
  }
  return delay;
}

/// One-line human description of a snapshot (issue #450): "1 background
/// job (…), 2 timers armed". Pure — unit-tested directly.
String waitingDescribe(WaiterSnapshot snap) {
  final parts = <String>[
    if (snap.jobs.isNotEmpty)
      '${snap.jobs.length} background job'
          '${snap.jobs.length == 1 ? '' : 's'} (${snap.jobs.first})',
    if (snap.timers.isNotEmpty)
      '${snap.timers.length} timer'
          '${snap.timers.length == 1 ? '' : 's'} armed',
  ];
  if (parts.isEmpty) return 'nothing';
  return parts.join(', ');
}

/// The headless detach summary line (issue #450 AC7): "N background jobs
/// detached (logs: .fah/bash_jobs/) · M timers armed". Pure.
String waitingDetachSummary(WaiterSnapshot snap) {
  final jobs = snap.jobs.length;
  final timers = snap.timers.length;
  return '$jobs background job${jobs == 1 ? '' : 's'} detached '
      '(logs: .fah/bash_jobs/) · '
      '$timers timer${timers == 1 ? '' : 's'} armed';
}

/// Whole minutes elapsed since the current waiting stretch began
/// (issue #450): 0 while unknown, otherwise floor of the difference. Pure.
int waitingMinutesElapsed(DateTime? since, DateTime now) =>
    since == null ? 0 : now.difference(since).inMinutes;

/// Test seams for the visible-waiting layer (issue #450).
extension AgentCliWaitingSeams on AgentCli {
  /// Test seam: fires one waiting-heartbeat beat now (mirrors
  /// [heartbeatTickForTest] for #383).
  @visibleForTesting
  void waitingHeartbeatTickForTest() => _waiting.heartbeat.tick();

  /// Test seam: the current waiter aggregate — jobs, timers, lost jobs.
  @visibleForTesting
  Future<WaiterSnapshot> waitersSnapshotForTest() => _waiting.snapshot();

  /// Test seam: re-runs the boot-time restart-honesty capture so tests
  /// can seed the cross-run manifest and observe the lost-jobs count.
  @visibleForTesting
  Future<void> waitingCaptureLostJobsForTest() => _waiting.captureLostJobs();

  /// Test seam: the current restart-honesty count.
  @visibleForTesting
  int get waitingLostJobsForTest => _waiting.lostJobs;
}
