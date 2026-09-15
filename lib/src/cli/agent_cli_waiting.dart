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
  Future<void> _deliverHeartbeat() async {
    final cli = _cli;
    if (cli._headlessMode || cli._exited || cli.isBusy) return;
    if (cli._viewer != null) return; // viewers observe, never drive runs
    final snap = await snapshot();
    if (snap.isEmpty) {
      _syncHeartbeat(snap);
      return;
    }
    final since = waitingSince;
    final elapsedMin = since == null ? 0 : _clock().difference(since).inMinutes;
    cli._startRun(
      '<system-notice>Waiting heartbeat: you have been waiting for '
      '$elapsedMin min. Still pending: ${describe(snap)}. Emit ONE short '
      'status line to the user about what you are still waiting for '
      "(e.g. 'still waiting for CI run X, Nm elapsed'). Do not start new "
      'work unless a waiter resolved.</system-notice>',
    );
  }

  /// One-line human description of a snapshot ("1 background job (…), "
  /// 2 timers armed").
  String describe(WaiterSnapshot snap) {
    final parts = <String>[
      if (snap.jobs.isNotEmpty)
        '${snap.jobs.length} background job${snap.jobs.length == 1 ? '' : 's'}'
            ' (${snap.jobs.first})',
      if (snap.timers.isNotEmpty)
        '${snap.timers.length} timer${snap.timers.length == 1 ? '' : 's'}'
            ' armed',
    ];
    return parts.isEmpty ? 'nothing' : parts.join(', ');
  }

  /// The headless detach summary (AC7): exactly the contract's line, on
  /// stderr, whenever waiters outlive the run. The settle notice is NOT
  /// delivered to this (dead) process — a follow-up run re-enters instead.
  Future<void> printHeadlessDetachSummary() async {
    final snap = await snapshot();
    if (snap.isEmpty) return;
    _cli.io.writeln(_summaryLine(snap));
  }

  String _summaryLine(WaiterSnapshot snap) {
    final jobs = snap.jobs.length;
    final timers = snap.timers.length;
    return '$jobs background job${jobs == 1 ? '' : 's'} detached '
        '(logs: .fah/bash_jobs/) · '
        '$timers timer${timers == 1 ? '' : 's'} armed';
  }

  /// `--wait-for-jobs` (opt-in): stay alive for the waiters, bounded by
  /// `waiting.waitCeilingMinutes` (default 30). Job settles start their
  /// follow-up run through the normal settle handler; due timers deliver
  /// through the queue and wake the idle run via the inbox path; every
  /// heartbeat cadence a stderr line keeps the wait observable (AC5).
  Future<void> waitForJobsCeiling() async {
    var snap = await snapshot();
    if (snap.isEmpty) return;
    final ceilingMin = _cli.config.waiting.waitCeilingMinutes;
    final deadline = _clock().add(Duration(minutes: ceilingMin));
    final hbMin = _cli.config.waiting.waitHeartbeatMinutes;
    _cli.io.writeln('⏳ waiting: ${describe(snap)}');
    var lastHeartbeat = _clock();
    while (!snap.isEmpty) {
      final now = _clock();
      if (!now.isBefore(deadline)) {
        _cli.io.writeln(
          '⏳ ${_summaryLine(snap)} — wait ceiling ($ceilingMin min)'
          ' reached, exiting',
        );
        return;
      }
      // Sleep until the nearest wake source: a job settle, a timer due,
      // the heartbeat cadence, or the ceiling — whichever lands first.
      var delay = deadline.difference(now);
      final jobWakes = [
        for (final job in _jobs.jobs)
          if (job.isRunning) job.settled,
      ];
      for (final timer in snap.timers) {
        final due = Duration(
          milliseconds: timer.dueMs - now.millisecondsSinceEpoch,
        );
        if (due < delay) delay = due;
      }
      if (hbMin > 0) {
        final nextBeat =
            lastHeartbeat.difference(now) + Duration(minutes: hbMin);
        if (nextBeat < delay) delay = nextBeat;
      }
      if (delay > Duration.zero) {
        await Future.any([_cli._waitingSleep(delay), ...jobWakes]);
      }
      // Due timers: deliver, then wake the idle run through the inbox
      // path (the headless run has no inbox watcher of its own).
      await _timers.deliverDue();
      await _cli._wakeOnInboxMail();
      // A job settle (or timer delivery) starts its run via the normal
      // handlers — let it finish before re-snapshotting.
      if (_cli.isBusy) {
        try {
          await _cli._settled;
        } on Object {
          // A failed wake turn must not kill the wait loop.
        }
      }
      if (hbMin > 0 &&
          !_clock().isBefore(lastHeartbeat.add(Duration(minutes: hbMin)))) {
        lastHeartbeat = _clock();
        final beatSnap = await snapshot();
        if (!beatSnap.isEmpty) {
          _cli.io.writeln('⏳ still waiting: ${describe(beatSnap)}');
        }
      }
      snap = await snapshot();
    }
    _cli.io.writeln('⏳ waiters resolved — ${_summaryLine(snap)}');
  }
}

/// Test seams for the visible-waiting layer (issue #450).
extension AgentCliWaitingSeams on AgentCli {
  /// Test seam: fires one waiting-heartbeat beat now (mirrors
  /// [heartbeatTickForTest] for #383).
  @visibleForTesting
  void waitingHeartbeatTickForTest() => _waiting.heartbeat.tick();

  /// Test seam: the current waiter aggregate — jobs, timers, lost jobs.
  @visibleForTesting
  Future<WaiterSnapshot> waitersSnapshotForTest() => _waiting.snapshot();
}
