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
    this.registryNotice,
  });

  /// Running background shell jobs, one purpose per job (command + id).
  final List<String> jobs;

  /// Armed self-wake timers: due epoch ms + text preview.
  final List<({int dueMs, String preview})> timers;

  /// Background jobs the previous run of this session left running.
  final int lostJobs;

  /// The surfaced registry-lock failure (issue #2266 AC2): a manifest
  /// mutation skipped at the queued-wait bound, named — never an unlocked
  /// write. Cleared by the next mutation that runs under the lock.
  final String? registryNotice;

  /// True when nothing live is awaited (lost jobs are history, not waits).
  bool get isEmpty => jobs.isEmpty && timers.isEmpty;
}

/// The boot process snapshot (issue #478): every live pid plus, when the
/// platform reports it, its start string — the pid-reuse guard (a
/// recycled pid's start never matches the recorded one).
typedef _ProcessTable = ({Set<int> pids, Map<int, String> starts});

/// The boot reconcile's liveness verdict for one registry entry against
/// the process table (issue #2267): [dead] drops whatever the age,
/// [alive] keeps whatever the age — only [unknown] (no evidence) lets
/// the `jobs.staleHours` age belt decide.
enum _BootLiveness { dead, alive, unknown }

/// One cross-run registry entry (`running.json`): the job identity plus
/// the owner-process evidence a later boot reconciles against — the OS
/// pid, its start string (pid reuse), and the entry's own birth time
/// (the `jobs.staleHours` age belt). Legacy records carry only
/// id/command/pid; missing fields degrade per-field.
final class _ManifestEntry {
  const _ManifestEntry({
    required this.id,
    this.command,
    this.pid,
    this.pidStart,
    this.startedAtMs,
  });

  final String id;
  final String? command;
  final int? pid;

  /// The owner pid's OS start string (`ps -o lstart=`) at record time.
  final String? pidStart;

  /// When the entry was written (epoch ms) — the age belt's clock.
  final int? startedAtMs;

  /// Parses one raw JSON entry; null for anything without a usable id
  /// (tolerated and dropped — only a structurally broken FILE is
  /// quarantined).
  static _ManifestEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    return _ManifestEntry(
      id: id,
      command: raw['command'] is String ? raw['command'] as String : null,
      pid: int.tryParse('${raw['pid']}'),
      pidStart: raw['pidStart'] is String ? raw['pidStart'] as String : null,
      startedAtMs: raw['startedAtMs'] is int ? raw['startedAtMs'] as int : null,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'command': command,
    'pid': pid?.toString(),
    if (pidStart != null) 'pidStart': pidStart,
    if (startedAtMs != null) 'startedAtMs': startedAtMs,
  };
}

/// The NAMED failure a registry mutation carries when the cross-run
/// manifest lock stays held past the queued-wait bound (issue #2266
/// AC2): the mutation is skipped — never raced unlocked over a rival's
/// entry — and this name surfaces at the waiting row and the warning
/// channel instead of vanishing. The old 300ms bound treated giving up
/// as a license to write unlocked, and the resulting lost update erased
/// a live job's running.json entry: never re-adopted, never reaped,
/// invisible across runs.
final class ManifestLockTimeout implements Exception {
  const ManifestLockTimeout(this.bound);

  /// The queued-wait bound that expired.
  final Duration bound;

  @override
  String toString() =>
      'manifest lock still held after ${bound.inMilliseconds}ms — '
      'registry update skipped to avoid an unlocked write (#2266)';
}

/// Owns the visible-waiting state and its event pushes. All mutations are
/// best-effort: a snapshot (disk scan) or manifest write failure must
/// never take a run down.
final class _WaitingCoordinator {
  _WaitingCoordinator(this._cli);

  final AgentCli _cli;

  /// Previous-run jobs the boot reconcile (issue #478) dropped as lost:
  /// dead or recycled pid, no pid at all, or past the `jobs.staleHours`
  /// age belt when liveness could not verify them (a table-verified-alive
  /// pid outranks the belt — issue #2267). Live detached jobs are kept —
  /// they are not lost.
  int lostJobs = 0;

  /// The surfaced registry-lock failure (issue #2266 AC2): the named
  /// text of the last mutation skipped at the queued-wait bound, null
  /// once a mutation ran under the lock again. The waiting row carries
  /// it so a skipped update never vanishes silently.
  String? registryNotice;

  /// Whether the registry lock's exclusive-create capability is PROVEN:
  /// true only after a refusal from `createFileExclusive` is corroborated
  /// by an occupied lock path (a decorator can advertise the capability
  /// over a delegate that lacks it and answer `notSupported` — that
  /// verdict is incapability, the degraded mode). Evidence, never a
  /// timeout guess (issue #2266 AC3).
  bool _lockExclusiveProven = false;

  /// The latest exclusive-create refusal, retained until the immediately
  /// following occupancy probe distinguishes contention from a broken fs.
  FileError? _lastRegistryLockClaimError;

  /// The queued-wait bound. Sits ABOVE the stale-steal threshold so a
  /// crashed holder's lock is always stolen before this fires; only a
  /// genuinely stuck backend reaches the bound, and that fails loudly
  /// ([ManifestLockTimeout]) — it never degrades into an unlocked write.
  Duration _lockWaitBound = _defaultLockWaitBound;

  /// When the current waiting stretch began — the heartbeat's elapsed base.
  DateTime? waitingSince;

  late final WaitingHeartbeat heartbeat = WaitingHeartbeat(
    onBeat: _deliverHeartbeat,
    minutes: () => _cli.config.waiting.waitHeartbeatMinutes,
  );

  DateTime Function() get _clock => _cli._waitingClock;

  ShellJobRegistry get _jobs => _cli._shellJobs;

  ScheduledMessageQueue get _timers => _cli._scheduledMessages;

  /// Per-call foreground liveness (gh-1055): the third waiting horizon —
  /// a tool call running long in the FOREGROUND. Headless/line mode prints
  /// grep-friendly single lines (elapsed, tool name, command tail) past
  /// `toolLivenessSeconds`, then — once per stuck call — the background
  /// escape-hatch hint past `toolEscalateSeconds`. Every elapsed value
  /// rides the same waiting-clock seam the heartbeat uses (AC5: no second
  /// clock); when #1054's stuck-call heartbeat records land, its detector
  /// feeds this tracker instead of a private one.
  ///
  /// Issue #1185: an escalation is no longer console-only — it ALSO steers
  /// one model-facing nudge into the live run ([_nudgeStuckCall]) so the
  /// model itself decides wait / background / kill. The tracker therefore
  /// arms in TUI mode too (AC4); only the console LINES stay line-mode
  /// — the TUI waiting row owns that presentation.
  late final ToolLivenessTracker liveness = ToolLivenessTracker(
    onRemind: (call) {
      if (_cli._useTui) return; // the TUI waiting row owns this surface.
      _printLiveness(toolLivenessReminderLine(call, _clock()));
    },
    onEscalate: (call) {
      // Issue #1786 AC4: the watchdog's escalate rung first offers the
      // budget ladder the action — when it fires, surfacing the one-key
      // offer IS the escalation (its `foreground_budget` record, terminal
      // line and `b` affordance land via the event path) and the
      // display-only lines here would be a duplicate beat. The ladder
      // declining (no silent in-flight call / no pending steering /
      // already acted) keeps the legacy behavior byte-identical (REG-3:
      // budget-not-hit cadence unchanged).
      if (_cli._foregroundBudgetControls.requestOffer()) {
        budgetOfferRequested = true;
        return;
      }
      if (!_cli._useTui) {
        _printLiveness(toolLivenessEscalationLine(call, _clock()));
      }
      _nudgeStuckCall(call);
    },
    clock: _clock,
    livenessSeconds: () => _cli.config.waiting.toolLivenessSeconds,
    tickSeconds: () => _cli.config.waiting.toolLivenessTickSeconds,
    escalateSeconds: () => _cli.config.waiting.toolEscalateSeconds,
  );

  /// Reasoning-phase liveness (gh-1198 tier 2): the fourth waiting
  /// horizon — a provider request with NO events yet (the model is
  /// reasoning server-side before the first streamed byte). Headless/
  /// line mode prints the grep-friendly `… reasoning Ns` line on the
  /// waiting cadence; the watch disarms the moment the first event lands.
  /// Active only while the thinking stream is OFF — with `--stream-
  /// thinking`/`output.streamThinking` the deltas print live (tier 1 owns
  /// visibility), and the TUI streams thinking regardless (its paint
  /// freeze is #1197's).
  late final ReasoningLivenessTracker reasoning = ReasoningLivenessTracker(
    onRemind: (elapsed) => _printLiveness(reasoningLivenessLine(elapsed)),
    clock: _clock,
    livenessSeconds: () => _cli.config.waiting.toolLivenessSeconds,
    tickSeconds: () => _cli.config.waiting.toolLivenessTickSeconds,
  );

  /// Streaming-phase liveness (gh-1430): the fifth waiting horizon — a
  /// provider request whose events flow but render NOTHING in the current
  /// output mode (thinking deltas with `--stream-thinking` off, the
  /// headless default). Tier 2 disarms at the first event, which is
  /// exactly when a reasoning burst starts, so the pane used to go
  /// byte-silent for minutes of healthy streaming. The heartbeat prints
  /// `… reasoning Ns (streaming)` on the same waiting cadence — and never
  /// for a stream that stopped emitting, so fa's stream-idle watchdog
  /// stays the sole arbiter of stream death.
  late final StreamLivenessHeartbeat streamHeartbeat = StreamLivenessHeartbeat(
    onRemind: (elapsed) => _printLiveness(streamLivenessLine(elapsed)),
    clock: _clock,
    livenessSeconds: () => _cli.config.waiting.toolLivenessSeconds,
    tickSeconds: () => _cli.config.waiting.toolLivenessTickSeconds,
  );

  /// A provider request went out (gh-1198 + gh-1430): arm both watches
  /// when this surface watches them — surfaces where thinking does NOT
  /// render. Since gh-1433 that is decided by the SAME log-fidelity
  /// resolution the render gate uses: TUI and log-face runs (headless)
  /// see the deltas (or tiles) live; only non-streaming line mode and
  /// the `--no-stream-thinking` hatch watch the silent window.
  void reasoningRequestStarted() {
    if (_cli._streamsThinking) return;
    reasoning.requestStarted();
    streamHeartbeat.requestStarted();
  }

  /// Any agent event after the request (gh-1198): tier 2 watches only the
  /// pre-first-event window, so ANY event is visible progress for it. The
  /// stream heartbeat classifies instead (gh-1430): rendered output
  /// disarms it, unrendered stream events prove aliveness, lifecycle ends
  /// stop it.
  void reasoningProgress(AgentEvent event) {
    reasoning.progress();
    streamHeartbeatProgress(event);
  }

  /// The gh-1430 classification of one agent event for the stream
  /// heartbeat. Rendered (disarm): text deltas (raw mode prints them
  /// live; styled surfaces flush at message end — either way the answer
  /// is on its way, E1), streamed thinking deltas, and tool rows. Live
  /// but unrendered: the stream events headless does not draw. Stops:
  /// the message/turn ends — the request phase is over, and a timer that
  /// prints over an ended stream would be a wall timer, not a liveness
  /// signal. Everything else (run bookkeeping, tool heartbeats) is
  /// neither, and leaves the watch untouched.
  void streamHeartbeatProgress(AgentEvent event) {
    switch (event) {
      case MessageUpdateEvent():
        _streamHeartbeatMessageUpdate(event);
      case MessageStartEvent():
        // Mirrors the provider stream's StartEvent: the first byte landed.
        streamHeartbeat.unrenderedEvent();
      case MessageEndEvent() || TurnEndEvent() || AgentEndEvent():
        streamHeartbeat.stop();
      case ToolExecutionStartEvent() || ToolExecutionEndEvent():
        // The tool rows print in every mode — rendered bytes.
        streamHeartbeat.renderedOutput();
      default:
        break;
    }
  }

  /// The MessageUpdateEvent arm of [streamHeartbeatProgress] (split out to
  /// keep the dispatcher under the CRAP ratchet): rendered deltas disarm
  /// (text deltas print live in raw mode; styled surfaces flush at message
  /// end — either way the answer is on its way, E1; streamed thinking
  /// deltas render with `--stream-thinking`), unrendered stream events
  /// headless does not draw still prove aliveness.
  void _streamHeartbeatMessageUpdate(MessageUpdateEvent event) {
    final rendered =
        event.assistantMessageEvent is TextDeltaEvent ||
        (event.assistantMessageEvent is ThinkingDeltaEvent &&
            _cli._streamsThinking);
    if (rendered) {
      streamHeartbeat.renderedOutput();
    } else {
      streamHeartbeat.unrenderedEvent();
    }
  }

  /// The compaction window (gh-1430 E3): summarizer requests are provider
  /// requests too, but NO agent events fire while the [AutoCompactor]
  /// runs — neither tracker would ever see its stream. Arm tier 2 over
  /// the window so a multi-minute summarization is not a byte-silent
  /// bench window: past the cadence it prints the bare `… reasoning Ns`
  /// line until the window ends (a dead summarizer stream errors through
  /// fa's own watchdog first, same as the main path). Line mode/headless
  /// only — the TUI busy row (`Compacting context…`) owns that surface.
  void compactionLivenessStart() {
    // Deliberately ignores config.streamThinking (unlike
    // reasoningRequestStarted): the summarizer's stream never reaches
    // the CLI render path, so nothing renders in this window even with
    // the flag on — tier 2 is the only signal here. Do NOT add the
    // streamThinking gate for "consistency": it would silently
    // reintroduce a byte-silent multi-minute summarization window in
    // --stream-thinking runs.
    if (_cli._useTui) return;
    reasoning.requestStarted();
  }

  /// The compaction window ended: drop the watch (a stale arm cannot
  /// survive into the idle session — the next agent event disarms tier 2
  /// anyway, but the explicit stop keeps the chain honest). The
  /// unconditional stop (no `streamThinking`/TUI guard) is safe by
  /// lifecycle: compaction runs BETWEEN provider requests — the watch is
  /// disarmed outside the window anyway, so the stop is a belt-and-
  /// braces no-op unless a compaction ever overlaps an in-flight request.
  void compactionLivenessEnd() {
    reasoning.stop();
  }

  /// Nudges left this turn (issue #1185 E2, the storm guard): reset at
  /// every real turn start (see [_beginUserPrompt]), spent by
  /// [_nudgeStuckCall].
  int _nudgesLeft = maxToolNudgesPerTurn;

  /// Nudges sent overall — the dedup/cap test seam's observable.
  int _nudgesSent = 0;

  /// Whether the last escalation handed the action to the budget ladder's
  /// offer (issue #1786 AC4) instead of the legacy escalation+nudge —
  /// the AC4 test seam's observable.
  bool budgetOfferRequested = false;

  /// Refills the per-turn nudge budget (issue #1185 E2).
  void resetToolNudges() {
    _nudgesLeft = maxToolNudgesPerTurn;
  }

  /// The #1185 stuck-call nudge: ONE steering message into the live run
  /// per escalated call (the tracker's `escalated` flag guarantees once
  /// per call; a NEW stuck call escalates afresh). Deliberately NOT
  /// `_agent.steer`: every steer enqueue fires `steeringArrived`, which
  /// cancels the tool-call phase's soft-yield token and would move a
  /// yield-aware bash to a background job before the model decided
  /// anything — the call must still be the model's to decide (AC3). The
  /// nudge rides the follow-up queue instead: same boundary delivery and
  /// persistence as every follow-up (`<system-notice>` user message,
  /// one extension turn per queued message — the queue is
  /// `oneAtATime`), zero yield signal — delivery happens when the run
  /// would otherwise stop, never mid-call.
  void _nudgeStuckCall(ToolLivenessCall call) {
    if (_cli._exited || !_cli.isBusy) return;
    if (!_cli.config.waiting.toolNudge) return;
    if (_nudgesLeft <= 0) return;
    _nudgesLeft--;
    _nudgesSent++;
    final text = toolNudgeNotice(call, _clock());
    // TUI transcript echo (the job-settle precedent): the notice merges
    // into context and is persisted, but steered messages skip the
    // composer echo — without this the row exists only after resume.
    _cli._tuiController?.sendOutput('$text\n');
    _cli._agent.followUp(UserMessage.text(text));
  }

  /// One liveness line, dimmed like every other run notice (the style is
  /// off in headless, so the piped output stays plain). Never after exit —
  /// the timer chain can outlive the session by a tick.
  void _printLiveness(String line) {
    if (_cli._exited) return;
    _cli.io.writeln(_cli._style.dim(line));
  }

  /// Foreground tool call started (gh-1055): arm the liveness watch. Since
  /// #1185 the tracker arms in TUI mode too (the escalation drives the
  /// model nudge there — AC4); only the console LINES stay line-mode
  /// ([_printLiveness] gates, the TUI waiting row owns the presentation).
  void toolCallStarted(String toolCallId, String toolName, String detail) {
    liveness.callStarted(toolCallId, toolName, detail);
  }

  /// Foreground tool call ended: this call's watch (and escalation state)
  /// stops with it — an end-without-start must never touch the chain
  /// while other calls are legitimately in flight.
  void toolCallEnded(String toolCallId) {
    liveness.callEnded(toolCallId);
  }

  /// The cross-run job registry (`running.json` under the job
  /// bookkeeping dir): one entry per job any fa process in this workspace
  /// still considers running. Boot reconcile (issue #478) drops entries
  /// whose owning process is gone instead of letting them sit there
  /// forever.
  String get _manifestPath => '$_jobBookkeepingDir/running.json';

  /// The job bookkeeping dir (issue #1408 AC1, review 5456649624):
  /// `<cwd>/.fah/bash_jobs` by default; the bench override
  /// (`FAH_JOB_LOG_DIR` → [AgentCliConfig.jobLogDir]) relocates the
  /// manifest + lock + retention prune WITH the logs so an unattended run
  /// leaves no `.fah/` in the graded task workspace.
  String get _jobBookkeepingDir =>
      _cli.config.jobLogDir ?? '${_cli._env.cwd}/.fah/bash_jobs';

  /// Where a corrupt registry goes before the rebuild — the evidence
  /// stays inspectable instead of being silently lost.
  String get _badManifestPath => '$_manifestPath.bad';

  /// The per-root lock guarding registry mutations: parent + subagent fa
  /// processes share `.fah/bash_jobs/` (issue #478). An exclusive-created
  /// FILE — `createDir` is a no-op over an existing dir on Dart's local
  /// fs, so a directory lock never actually contends (issue #2266).
  String get _manifestLockPath => '$_manifestPath.lock';

  /// Boot reconcile (issue #478). Entries survive their owner's death
  /// (kill -9, crash, restart) — without this sweep they are immortal
  /// ghosts and `.fah/bash_jobs/` accumulates forever. Per boot, under
  /// the per-root lock:
  ///
  /// - a corrupt/unparseable file is quarantined as `running.json.bad`
  ///   and rebuilt empty — never double-counted (concurrent writers once
  ///   concatenated two JSON documents into it);
  /// - entries whose pid is dead — or was recycled onto another process
  ///   (start-time mismatch) — are dropped; so are entries with no pid
  ///   at all (nothing to verify). Entries past `jobs.staleHours` (the
  ///   age belt) drop too — but a table-verified-alive entry (pid
  ///   present, start string matching) outranks the belt and is KEPT
  ///   (issue #2267): a detached job legitimately outlives the run that
  ///   started it, however long — a nightly watcher or a week-long
  ///   build stays visible and `bash_job`-manageable. On a platform
  ///   that could not produce a process table the belt remains the
  ///   only guard. Every drop counts as [lostJobs] (restart honesty);
  /// - job logs older than `jobs.logRetentionDays` are deleted (24,144
  ///   files accumulated once — nothing ever pruned them).
  ///
  /// One notice line summarizes the reconcile + the GC. The recorded
  /// pids also feed the boot sweep (issue #517): previous-run jobs whose
  /// wrapper died but whose process group (toolchain grandchildren)
  /// survived get one warning line, then are reaped.
  Future<void> captureLostJobs() async {
    lostJobs = 0;
    final ({
      List<int> pids,
      bool quarantined,
      int dropped,
      int aged,
      List<_ManifestEntry> kept,
      bool probed,
    })
    reconcile;
    try {
      reconcile = await _reconcileRegistry();
    } on ManifestLockTimeout catch (error) {
      // The boot reconcile itself is skipped — never raced unlocked over
      // a rival's registry (issue #2266): surface the named failure and
      // keep the honest "reconcile unavailable" state instead of a
      // silently partial boot. A later boot retries.
      _noteRegistryLockFailure('boot reconcile skipped: $error');
      return;
    } on FileError catch (error) {
      // An unoccupied lock path makes the claim refusal a real fs failure,
      // not contention. Surface its errno + OS detail without the wait.
      _noteRegistryLockFailure('boot reconcile skipped: $error');
      return;
    }
    lostJobs = reconcile.dropped;
    // Issue #2201 AC5: manifest entries whose pid is ALIVE at boot are
    // RE-ADOPTED as real registry jobs — the waiting row shows them,
    // `bash_job` manages them, and their death notifies through the
    // settle path — instead of sitting invisible in the manifest. Only
    // verifiable pids adopt: a platform that could not produce a process
    // table (probed=false), or an entry without one, keeps today's
    // honest counting (dead/recycled entries already dropped above and
    // counted in [lostJobs]; since issue #2267 the belt no longer drops
    // aged entries liveness verified alive — they adopt here like any
    // live one).
    if (reconcile.probed) {
      for (final entry in reconcile.kept) {
        final pid = entry.pid;
        if (pid == null) continue;
        _jobs.adoptRunningEntry(
          id: entry.id,
          command: entry.command ?? '<unknown cmd>',
          pid: pid,
          pidStart: entry.pidStart,
          startedAtMs: entry.startedAtMs,
        );
      }
    }
    final pids = reconcile.pids;
    final quarantined = reconcile.quarantined;
    final dropped = reconcile.dropped;
    final aged = reconcile.aged;
    // The orphan-group reaper (issue #517) wants every previous-run pid —
    // it skips live leaders itself.
    await reapOrphanJobGroups(
      env: _cli._env,
      candidatePids: pids,
      onWarn: (message) => _cli.io.writeln(tuiWarning('⚠ $message')),
    );
    final prunedLogs = await _pruneOldJobLogs();
    final notes = <String>[
      if (quarantined) 'corrupt running.json quarantined as running.json.bad',
      if (dropped > 0)
        '$dropped stale job ${dropped == 1 ? 'entry' : 'entries'} dropped'
            '${aged > 0 ? ', $aged past the age belt' : ''}',
      if (prunedLogs > 0) '$prunedLogs old job log(s) pruned',
    ];
    if (notes.isNotEmpty) {
      _cli.io.writeln(tuiWarning('⚠ bash_jobs: ${notes.join(' · ')}'));
    }
  }

  /// The registry reconcile half of [captureLostJobs] (extracted so the
  /// public entry stays under the CRAP complexity threshold): verifies
  /// each recorded entry against the live process table, drops the dead
  /// and the past-the-age-belt ones, and rewrites the registry when
  /// anything changed. Behavior is identical to the inlined loop.
  /// [kept] carries the verified-live entries for boot re-adoption
  /// (issue #2201 AC5); [probed] says whether the platform could actually
  /// verify (a null table = unverifiable — nothing may adopt on it).
  Future<
    ({
      List<int> pids,
      bool quarantined,
      int dropped,
      int aged,
      List<_ManifestEntry> kept,
      bool probed,
    })
  >
  _reconcileRegistry() async {
    var pids = const <int>[];
    var quarantined = false;
    var dropped = 0;
    var aged = 0;
    var kept = const <_ManifestEntry>[];
    var probed = false;
    await _withRegistryLock(() async {
      final entries = await _readRegistryEntries(
        onQuarantined: () => quarantined = true,
      );
      pids = [
        for (final entry in entries)
          if (entry.pid != null) entry.pid!,
      ];
      // An empty registry has nothing to verify — skip the process probe
      // entirely (the #517 sweep has no pids to work with either).
      final table = entries.isEmpty ? null : await _bootProcessTable();
      probed = table != null;
      final staleBefore = _clock().subtract(
        Duration(hours: _cli.config.jobs.staleHours),
      );
      final live = <_ManifestEntry>[];
      for (final entry in entries) {
        final started = entry.startedAtMs;
        final tooOld =
            started != null &&
            DateTime.fromMillisecondsSinceEpoch(started).isBefore(staleBefore);
        // Issue #2267: liveness first — the belt claims only what
        // liveness could not save (dead, recycled, no pid, unverifiable).
        final liveness = _entryLiveness(entry, table);
        if (liveness == _BootLiveness.dead ||
            (tooOld && liveness == _BootLiveness.unknown)) {
          dropped++;
          if (tooOld) aged++;
          continue;
        }
        live.add(entry);
      }
      if (quarantined || live.length != entries.length) {
        await _writeRegistryEntries(live);
      }
      kept = live;
    });
    return (
      pids: pids,
      quarantined: quarantined,
      dropped: dropped,
      aged: aged,
      kept: kept,
      probed: probed,
    );
  }

  Future<void> _manifestAdd(
    String id,
    String command,
    int? pid, {
    Future<String?> Function()? pidStartProbe,
  }) async {
    await _mutateRegistry((entries) async {
      // The probe runs INSIDE the critical section (issue #2275): run
      // outside, its async gap let a fast-settling job's remove land
      // first — the add then resurrected an EXITED job as running until
      // the next boot. Under the lock, the settle's remove queues
      // behind this add instead.
      final pidStart = await pidStartProbe?.call();
      return entries.any((entry) => entry.id == id)
          ? entries
          : [
              ...entries,
              _ManifestEntry(
                id: id,
                command: command,
                pid: pid,
                pidStart: pidStart,
                startedAtMs: _clock().millisecondsSinceEpoch,
              ),
            ];
    });
  }

  Future<void> _manifestRemove(String id) async {
    await _mutateRegistry(
      (entries) async => [
        for (final entry in entries)
          if (entry.id != id) entry,
      ],
    );
  }

  /// Reads the registry under the lock, mutates, writes back ATOMICALLY.
  /// The registry is best-effort bookkeeping and the job itself is
  /// unaffected by a failure — but a lock-bound timeout (issue #2266) is
  /// never silent: the mutation is SKIPPED and the named failure
  /// surfaces, rather than racing the winner unlocked.
  Future<void> _mutateRegistry(
    Future<List<_ManifestEntry>> Function(List<_ManifestEntry>) mutate,
  ) async {
    try {
      await _withRegistryLock(() async {
        await _writeRegistryEntries(await mutate(await _readRegistryEntries()));
      });
    } on ManifestLockTimeout catch (error) {
      _noteRegistryLockFailure(error);
    } on FileError catch (error) {
      _noteRegistryLockFailure(error);
    }
  }

  /// The loud half of the #2266 contract: a skipped mutation rides the
  /// warning channel here and the waiting row's registry notice until
  /// the next successful mutation clears it.
  void _noteRegistryLockFailure(Object error) {
    registryNotice = '$error';
    _cli.io.writeln(tuiWarning('⚠ bash_jobs: $error'));
  }

  /// Reads + parses the registry: missing → empty; a structurally broken
  /// file → quarantined ([onQuarantined] fired) and rebuilt empty; raw
  /// entries without a usable id dropped; duplicate ids (concurrent
  /// double-writes) deduped keeping the first.
  Future<List<_ManifestEntry>> _readRegistryEntries({
    void Function()? onQuarantined,
  }) async {
    final text = (await _cli._env.readTextFile(_manifestPath)).valueOrNull;
    if (text == null) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on Object {
      decoded = null;
    }
    if (decoded is! List) {
      await _quarantineCorruptRegistry();
      onQuarantined?.call();
      return const [];
    }
    final seen = <String>{};
    return [
      for (final raw in decoded)
        if (_ManifestEntry.tryParse(raw) case final entry?
            when seen.add(entry.id))
          entry,
    ];
  }

  /// Moves the corrupt file aside (`.bad`) so the next reader starts
  /// clean; without a rename capability it is removed — either way the
  /// registry rebuilds instead of double-counting the broken file.
  Future<void> _quarantineCorruptRegistry() async {
    final env = _cli._env;
    var renamed = false;
    if (env case final RenamableFileSystem renamable) {
      renamed = (await renamable.renamePath(
        _manifestPath,
        _badManifestPath,
      )).isOk;
    }
    if (!renamed) await env.remove(_manifestPath, force: true);
  }

  Future<void> _writeRegistryEntries(List<_ManifestEntry> entries) =>
      _writeRegistry(jsonEncode([for (final e in entries) e.toJson()]));

  /// Writes the registry ATOMICALLY (tmp + rename, issue #478): several
  /// fa processes share `.fah/bash_jobs/`, and a plain overwrite can be
  /// torn by a crash or read mid-write. Backends without rename (memory,
  /// web — single-writer anyway) degrade to a plain write.
  Future<void> _writeRegistry(String json) async {
    final env = _cli._env;
    try {
      if (env case final RenamableFileSystem renamable) {
        final tmp = '$_manifestPath.tmp';
        await env.writeFile(tmp, json);
        if ((await renamable.renamePath(tmp, _manifestPath)).isOk) return;
      }
      await env.writeFile(_manifestPath, json);
    } on Object {
      // Ignore: the registry is a best-effort provenance sidecar.
    }
  }

  /// The per-root registry lock: an exclusive-created lock FILE
  /// (`createFileExclusive` — O_EXCL; a loser's call fails) on the local
  /// filesystem, and the loser QUEUES (issue #2266): a mutation either
  /// lands under the lock or is skipped with a named, surfaced failure
  /// ([ManifestLockTimeout]). It never degrades to an unlocked
  /// read-modify-write over a rival's entry — that race once erased a
  /// live job's running.json record, and a ghosted entry is never
  /// re-adopted or reaped. The wait bound exists only as the
  /// no-infinite-wait guarantee and sits above the stale threshold, so a
  /// crashed holder's lock is always stolen first. Backends without the
  /// exclusive-create capability (memory, web) can never even contend —
  /// their lock degrades to a claim that always succeeds, the documented
  /// unlocked mode, decided by the backend's declared CAPABILITY, never
  /// by a timeout (issue #2266 AC3).
  static const _lockStaleAfter = Duration(seconds: 60);
  static const _defaultLockWaitBound = Duration(seconds: 70);

  Future<void> _withRegistryLock(Future<void> Function() body) async {
    // The lock file lives under the job bookkeeping dir — make sure the
    // parent exists or the exclusive create fails for the wrong reason
    // and every mutation pays the full contention wait.
    await _cli._env.createDir(_jobBookkeepingDir);
    if (!await _acquireRegistryLock()) {
      if (!_lockExclusiveProven) {
        // Capability-decided degraded mode (AC3): this backend never
        // proven to exclusive-create (memory, web, or a decorator
        // answering notSupported) — unlocked single writes are the
        // documented behavior here, not a lost update racing a winner
        // that does not exist.
        return body();
      }
      // A proven exclusive-create backend must never run the body
      // unlocked: skip the mutation and name the failure.
      throw ManifestLockTimeout(_lockWaitBound);
    }
    registryNotice = null;
    try {
      await body();
    } finally {
      await _cli._env.remove(_manifestLockPath, recursive: true, force: true);
    }
  }

  Future<bool> _acquireRegistryLock() async {
    final deadline = _clock().add(_lockWaitBound);
    for (;;) {
      if (await _claimRegistryLock()) return true;
      final info = await _cli._env.fileInfo(_manifestLockPath);
      final claimError = _lastRegistryLockClaimError;
      if (claimError != null) {
        // Only an occupied path verifies that the refusal was contention.
        // Otherwise surface the real fs failure instead of inventing a
        // rival and paying the full queued-wait bound.
        if (!info.isOk) throw claimError;
        _lockExclusiveProven = true;
      }
      final stale =
          info.isOk &&
          DateTime.fromMillisecondsSinceEpoch(
            info.valueOrNull!.mtimeMs,
          ).isBefore(_clock().subtract(_lockStaleAfter));
      if (stale) {
        await _cli._env.remove(_manifestLockPath, recursive: true, force: true);
        continue;
      }
      if (_clock().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  /// One atomic claim attempt of the lock path: an exclusive file create
  /// where the capability is advertised (only one contender's call can
  /// succeed), the plain create elsewhere (memory's never fails — the
  /// no-op claim of the degraded mode). A `notSupported` answer is a
  /// decorator advertising over an incapable delegate: that verdict
  /// resolves to incapability and falls through to the plain create.
  Future<bool> _claimRegistryLock() async {
    final env = _cli._env;
    _lastRegistryLockClaimError = null;
    if (env case final ExclusiveCreateFileSystem exclusive) {
      final claimed = await exclusive.createFileExclusive(_manifestLockPath);
      if (claimed.isOk) return true;
      final refusal = claimed.errorOrNull!;
      if (refusal.code != FileErrorCode.notSupported) {
        // The following occupancy probe decides whether this is a rival's
        // lock or a non-contention fs failure with its own cause to report.
        _lastRegistryLockClaimError = refusal;
        return false;
      }
      // A decorator advertising the capability over an incapable
      // delegate answers notSupported: fall through to the plain
      // create, the degraded mode's claim.
    }
    return (await env.createDir(_manifestLockPath, recursive: false)).isOk;
  }

  /// Test seam: replaces the boot process probe. Null (default) reads
  /// the real process table straight from the OS (Process.run), outside
  /// the environment's shell stream — infrastructure evidence, never a
  /// recorded command.
  Future<_ProcessTable?> Function()? _liveProcesses;

  /// The boot process snapshot: the injected seam when a test set one,
  /// else the real probe.
  Future<_ProcessTable?> _bootProcessTable() =>
      _liveProcesses?.call() ?? _probeLiveProcesses();

  /// One `ps` round-trip: every live pid plus its start string (the
  /// pid-reuse guard). Null when the platform cannot report it — entries
  /// are then kept rather than destroyed on unverifiable evidence.
  Future<_ProcessTable?> _probeLiveProcesses() async {
    final raw = await processTableSnapshot();
    if (raw == null) return null;
    final pids = <int>{};
    final starts = <int, String>{};
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      final space = trimmed.indexOf(' ');
      if (space <= 0) continue;
      final pid = int.tryParse(trimmed.substring(0, space));
      if (pid == null) continue;
      pids.add(pid);
      starts[pid] = trimmed.substring(space + 1).trim();
    }
    return (pids: pids, starts: starts);
  }

  /// The per-job pid start probe (issue #478 pid-reuse guard): the
  /// injected seam when a test set one, else the real `ps` snapshot.
  Future<String?> Function(int pid)? _pidStartProbe;

  /// The OS start string of [pid] (`ps -o lstart=`), or null when the
  /// platform cannot tell (the entry then has no pid-reuse protection
  /// but still gets plain liveness checks + the age belt).
  Future<String?> _pidStart(int? pid) async {
    if (pid == null) return null;
    return _pidStartProbe?.call(pid) ?? pidStartSnapshot(pid);
  }

  /// The boot liveness verdict for one registry entry (issue #2267
  /// split the old bool so the age belt could stop outranking evidence):
  ///
  /// - [dead]: no pid at all, the pid is gone from the table, or the
  ///   pid was recycled onto another process (start-string mismatch —
  ///   the impersonation guard). Dropped whatever the entry's age;
  /// - [alive]: the table VERIFIED the pid live with a matching start
  ///   string (a missing start string on either side counts as a
  ///   match). Kept whatever the entry's age — a >staleHours live
  ///   detached job (nightly watcher, week-long build) stays visible
  ///   and `bash_job`-manageable;
  /// - [unknown]: the platform could not produce a table — no evidence
  ///   either way; only the age belt disposes of the entry.
  _BootLiveness _entryLiveness(_ManifestEntry entry, _ProcessTable? table) {
    final pid = entry.pid;
    if (pid == null) return _BootLiveness.dead;
    final t = table;
    if (t == null) return _BootLiveness.unknown;
    if (!t.pids.contains(pid)) return _BootLiveness.dead;
    final recorded = entry.pidStart;
    final actual = t.starts[pid];
    if (recorded != null && actual != null && recorded != actual) {
      return _BootLiveness.dead;
    }
    return _BootLiveness.alive;
  }

  /// Boot log GC (issue #478): deletes `*.log` files older than
  /// `jobs.logRetentionDays` (`0` keeps all) and returns how many went.
  Future<int> _pruneOldJobLogs() async {
    final days = _cli.config.jobs.logRetentionDays;
    if (days <= 0) return 0;
    final listed = await _cli._env.listDir(_jobBookkeepingDir);
    if (listed.isErr) return 0;
    final cutoffMs =
        _clock().millisecondsSinceEpoch - days * Duration.millisecondsPerDay;
    var pruned = 0;
    for (final info in listed.valueOrNull!) {
      if (!info.name.endsWith('.log')) continue;
      if (info.mtimeMs >= cutoffMs) continue;
      if ((await _cli._env.remove(info.path, force: true)).isOk) pruned++;
    }
    return pruned;
  }

  /// A background job started (event-driven waiting-row enter): record it
  /// in the cross-run registry and refresh the row. The pid's OS start
  /// time rides along (issue #478) so a later boot can tell a recycled
  /// pid from the real owner — probed INSIDE the manifest lock (issue
  /// #2275) so a fast-settling job's remove can only land after this add.
  Future<void> jobStarted(ShellJobEntry job) async {
    await _manifestAdd(
      job.id,
      job.command,
      job.pid,
      pidStartProbe: () => _pidStart(job.pid),
    );
    await push();
  }

  /// A background job settled (event-driven waiting-row leave): drop it
  /// from the manifest and refresh the row. Settled jobs leave the
  /// manifest — EXCEPT a stopped ADOPTED job whose process group did not
  /// verify gone (issue #2260): the entry is the only record of the
  /// leader pid, and the boot sweep (`reapOrphanJobGroups`) reaps the
  /// surviving group members keyed by it. Verified-gone stops (and every
  /// natural settle) remove as before.
  Future<void> jobSettled(ShellJobEntry job) async {
    if (!adoptedStopKeepsManifestRecord(job)) await _manifestRemove(job.id);
    await push();
  }

  /// Headless entry point: stay for the waiters (`--wait-for-jobs`) or
  /// print the honest detach summary before exiting.
  Future<void> waitForJobsOrSummarize({required bool waitForJobs}) async {
    if (waitForJobs) return waitForJobsCeiling();
    return printHeadlessDetachSummary();
  }

  /// The aggregate: live jobs + deliverable timers. A settled job or a
  /// fired timer drops out of the next snapshot (AC1). Running background
  /// children (`task` jobs) count as waiters too (issue #520 AC3): a main
  /// agent with children in flight is visibly waiting on them.
  Future<WaiterSnapshot> snapshot() async {
    final jobs = [
      for (final job in _jobs.jobs)
        if (job.isRunning) _jobPurpose(job),
      ...[
        for (final job in _cli._taskConfig.jobManager.jobs)
          if (job.status == TaskJobStatus.queued ||
              job.status == TaskJobStatus.running)
            _taskJobPurpose(job),
      ],
    ];
    final timers = [
      for (final record in await _timers.pendingRecords())
        if (record.dueMs != null)
          (
            dueMs: record.dueMs!,
            preview: record.text.replaceAll('\n', ' ').trim(),
          ),
    ];
    return WaiterSnapshot(
      jobs: jobs,
      timers: timers,
      lostJobs: lostJobs,
      registryNotice: registryNotice,
    );
  }

  String _jobPurpose(ShellJobEntry job) {
    final preview = shellJobCommandPreview(job.command);
    final clipped = preview.length > 48
        ? '${preview.substring(0, 48)}…'
        : preview;
    // Issue #2201: adopted processes announce what they are.
    final marker = job.isAdopted ? 'adopted: ' : '';
    return '$marker$clipped (${job.id})';
  }

  /// One awaited child's purpose: `<id> (<task preview>) · <status>` —
  /// the owner reads «waiting: fix503 (test run) · running» (issue #520
  /// AC3), never silence.
  String _taskJobPurpose(TaskJob job) {
    final preview = job.task.replaceAll('\n', ' ').trim();
    final clipped = preview.length > 48
        ? '${preview.substring(0, 48)}…'
        : preview;
    return '${job.id} ($clipped) · ${job.status.name}';
  }

  /// Recomputes the snapshot and pushes it at the TUI row + heartbeat.
  /// Callers fire-and-forget this on every waiter event: job start/settle,
  /// timer schedule/fire, turn settle, boot.
  Future<void> push() async {
    final snap = await snapshot();
    _syncHeartbeat(snap);
    // The empty push IS the leave event: setWaiting REPLACES the whole
    // row state, so skipping it when the last waiter resolves strands the
    // stale waiting row above the composer forever (issue #615).
    // Always deliver — the empty snapshot included.
    _cli._tuiController?.setWaiting(
      jobs: snap.jobs,
      timers: snap.timers,
      lostJobs: snap.lostJobs,
      registryNotice: snap.registryNotice,
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
    _cli.io.writeln('${_pendingGlyph()} waiting: ${describe(snap)}');
    final settled = await _ceilingWait(snap);
    _cli.io.writeln(
      '${_pendingGlyph()} waiters resolved — ${waitingDetachSummary(settled)}',
    );
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
      '${_pendingGlyph()} ${waitingDetachSummary(snap)} — wait ceiling ($ceilingMin min)'
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
    _cli.io.writeln('${_pendingGlyph()} still waiting: ${describe(beatSnap)}');
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

/// The waiting rows' pending glyph (gh-1446 AC8): `status.pending`
/// resolves through the session symbol table — no hardcoded `⏳` survives
/// in chrome code; the ascii preset emits its ASCII mapping (E8).
String _pendingGlyph() => FaThemeController.instance.sym('status.pending');

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

/// The console dim line for an adopted job's settle (issue #450,
/// survivor-aware per issue #2260): a stop whose process group did not
/// verify gone admits it instead of the plain "no longer running"; a
/// leader that survived the kill rounds is never called "stopped".
/// Branch ladder kept flat and tiny — every branch is unit-pinned in
/// adopted_shell_jobs_test (the CRAP ratchet reads their coverage).
String adoptedJobSettleDimText(ShellJobEntry job) {
  if (!job.stopAttempted) return _plainAdoptedSettleDim(job);
  final survivors = job.stopSurvivors;
  if (survivors == null) return _unverifiedStopDim(job);
  if (survivors.isEmpty) return _plainAdoptedSettleDim(job);
  return stopLeaderSurvived(job)
      ? _leaderSurvivedStopDim(job)
      : _membersAliveStopDim(job, survivors);
}

String _plainAdoptedSettleDim(ShellJobEntry job) =>
    '${job.id} is no longer running (adopted pid ${job.pid}, '
    'liveness-only)';

String _unverifiedStopDim(ShellJobEntry job) =>
    '${job.id} stopped (adopted pid ${job.pid}) — its process group is '
    'unverified; survivors may remain';

String _leaderSurvivedStopDim(ShellJobEntry job) =>
    '${job.id} NOT stopped — pid ${job.pid} survived the kill signals; '
    'group member(s) still alive: '
    '${stopSurvivorPidList(job.stopSurvivors!)}';

String _membersAliveStopDim(ShellJobEntry job, List<ShellSurvivor> survivors) =>
    '${job.id} stopped (adopted pid ${job.pid}) — '
    '${survivors.length} group member(s) still alive: '
    '${stopSurvivorPidList(survivors)}';

/// Settle notifications for session-scoped background shell jobs: the
/// transcript/board note plus the model-facing system-notice (steered
/// mid-run, a fresh run while idle). Lives here with the rest of the
/// job-settle flow (issue #450) to keep the host class under the
/// 2800-line gate.
extension AgentCliShellJobSettle on AgentCli {
  /// Called when a background shell job settles (the same async-result
  /// flow as task-job completions): a transcript note, then a
  /// system-notice steered into the running turn or run as a fresh turn
  /// while idle.
  void _onShellJobSettled(ShellJobEntry job) {
    _onShellJobSettledBlock(job);
    // Event-driven waiting-row leave (issue #450).
    unawaited(_waiting.jobSettled(job));
    // An inline consumer (a foreground bash that settled before any
    // steer) already reported this result to the model — skip only the
    // model-facing notice. The board/waiting bookkeeping above always
    // runs, or the Running count never drains (issue #562).
    if (!job.notifyOnSettle) return;
    // Issue #2201: adopted jobs are liveness-only — no exit code, no log
    // path; the honest line replaces the exited() shape. Issue #2260: a
    // stop whose group did not verify gone never prints "no longer
    // running" — it names the survivors or admits the unverified group.
    io.writeln(
      job.isAdopted
          ? _style.dim(adoptedJobSettleDimText(job))
          : _style.dim(
              '[bash] ${job.id} exited(${job.exitCode}) — ${job.logPath}',
            ),
    );
    // gh-1589: after the run's exit wrap-up (or the REPL quit), the settle
    // was bookkeeping-only — no model-facing notice, no reaction run.
    if (_exited || _reactionRunsSealed) return;
    // The shared composer (gh-1604): the command rides the bounded
    // first/last ~120-char label, never the full body. Adopted deaths
    // (issue #2201 AC3) get their own honest notice text.
    final message = job.isAdopted
        ? adoptedJobSettleNoticeText(job)
        : shellJobSettleNoticeText(job);
    // Issue #2118: NO transcript echo. The settle card the board drain
    // painted a moment ago already carries id, exit code, command and log
    // path — echoing the notice painted the same command a SECOND time
    // one row below the card (the issue's "same command line printed
    // repeatedly" across the two emitters). The notice stays model-facing
    // (steered below / fresh idle run) and headless-visible through the
    // [bash] line above, both byte-identical; on resume the persisted
    // notice still replays through the #446 renderer.
    // Mid-run: the steering queue delivers it at the next step boundary.
    _deliverJobNotice(message);
  }

  /// The shared delivery for every model-facing job notice (settle,
  /// adoption, liveness): after the run's exit wrap-up (gh-1589) or the
  /// REPL quit the notice is bookkeeping-only; mid-run it rides the
  /// steering queue to the next step boundary; idle it starts a fresh
  /// reaction run.
  void _deliverJobNotice(String message) {
    if (_exited || _reactionRunsSealed) return;
    if (isBusy) {
      _agent.steer(UserMessage.text(message));
    } else {
      _startRun(message);
    }
  }

  /// Survivors adopted (issue #2201): ONE model-facing notice per batch —
  /// steered into the live run, a fresh run while idle — so the agent
  /// learns detached work is now tracked (the evidence gap: "nohup … & —
  /// сам я о завершении не узнаю"). Adoptions a tool reported inline
  /// (the bash result text) skip this via `notify: false`. The user-facing
  /// dim line prints regardless.
  void _onSurvivorsAdopted(
    List<ShellJobEntry> adopted, {
    required String source,
  }) {
    io.writeln(
      _style.dim(
        '[bash] adopted ${adopted.length} background process'
        '${adopted.length == 1 ? '' : 'es'} — completion will be reported',
      ),
    );
    _deliverJobNotice(
      '<system-notice>\n'
      '${adoptedSurvivorsNoticeText(adopted, source: source)}\n'
      '</system-notice>',
    );
  }

  /// Still-running reminder for an adopted process (issue #2201 AC4,
  /// default cadence 0 = never fires): the dim console line prints always;
  /// the model is reminded only mid-run — an idle reminder would start a
  /// run for nothing, and the waiting row already shows the job
  /// continuously.
  void _onAdoptedLiveness(ShellJobEntry job, Duration elapsed) {
    if (_exited) return;
    final text = adoptedLivenessNoticeText(job, elapsed);
    io.writeln(_style.dim('[bash] $text'));
    _steerAdoptedLiveness(text);
  }

  /// Still-running reminders never START a run — an idle reminder would
  /// burn a reaction run for nothing, and the waiting row already shows
  /// the job continuously. Only a live run gets the steer.
  void _steerAdoptedLiveness(String text) {
    if (!isBusy || _reactionRunsSealed) return;
    _agent.steer(UserMessage.text('<system-notice>\n$text\n</system-notice>'));
  }
}

/// Test seams for the visible-waiting layer (issue #450).
extension AgentCliWaitingSeams on AgentCli {
  /// Test seam: the session's background-shell-job registry (the headless
  /// drain tests inspect and suppress live jobs, gh-1459).
  @visibleForTesting
  ShellJobRegistry get shellJobsRegistryForTest => _shellJobs;

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

  /// Test seam: records a started background job in the cross-run
  /// manifest (issue #2266 contention tests drive the lock from the
  /// contender side without spawning processes).
  @visibleForTesting
  Future<void> waitingJobStartedForTest(ShellJobEntry job) =>
      _waiting.jobStarted(job);

  /// Test seam: fires the settle-side manifest leave — the unawaited
  /// chain `onSettled` drives (issue #2275's race test races it against
  /// [waitingJobStartedForTest]).
  @visibleForTesting
  Future<void> waitingJobSettledForTest(ShellJobEntry job) =>
      _waiting.jobSettled(job);

  /// Test seam: replaces the per-job pid start probe (issue #2275) —
  /// the settle race needs a probe slow enough to lose to the settle
  /// chain. Null restores the real `ps -o lstart=` snapshot.
  @visibleForTesting
  set waitingPidStartProbeForTest(Future<String?> Function(int pid)? probe) =>
      _waiting._pidStartProbe = probe;

  /// Test seam: shrinks the registry lock's queued-wait bound (issue
  /// #2266 AC2) — the real default sits above the stale-steal threshold
  /// so only a stuck backend ever reaches it.
  @visibleForTesting
  set waitingLockWaitBoundForTest(Duration bound) =>
      _waiting._lockWaitBound = bound;

  /// Test seam: the surfaced registry-lock failure (issue #2266 AC2) —
  /// null once a mutation ran under the lock again.
  @visibleForTesting
  String? get waitingRegistryNoticeForTest => _waiting.registryNotice;

  /// Test seam: replaces the boot process probe (issue #478 reconcile).
  /// Null restores the real `ps` probe.
  @visibleForTesting
  set waitingProcessTableForTest(
    Future<({Set<int> pids, Map<int, String> starts})?> Function()? probe,
  ) => _waiting._liveProcesses = probe;

  /// Test seam: arms a real self-addressed timer so tests can drive the
  /// ceiling-wait loop through an actual wake source.
  @visibleForTesting
  Future<String> waitingScheduleTimerForTest(String text, Duration delay) =>
      _waiting._timers.schedule(text: text, delay: delay);

  /// Test seam: fires one tool-liveness evaluation now (gh-1055), the
  /// analog of [waitingHeartbeatTickForTest] for #450.
  @visibleForTesting
  void toolLivenessTickForTest() => _waiting.liveness.tick();

  /// Test seam: the watched foreground calls, oldest first (gh-1055).
  @visibleForTesting
  List<ToolLivenessCall> get toolLivenessCallsForTest =>
      _waiting.liveness.inFlight;

  /// Test seam: feeds the liveness watch directly, bypassing the agent
  /// event path — the TUI-gate test drives this.
  @visibleForTesting
  void toolCallStartedForTest(String id, String name, String detail) =>
      _waiting.toolCallStarted(id, name, detail);

  /// Test seam: ends the watched call started by [toolCallStartedForTest].
  @visibleForTesting
  void toolCallEndedForTest(String id) => _waiting.toolCallEnded(id);

  /// Test seam: the stuck-call nudges sent so far (issue #1185) — the
  /// dedup/cap observable (a nudge steers into the agent queue; counting
  /// sends is exact regardless of run shape).
  @visibleForTesting
  int get toolNudgesSentForTest => _waiting._nudgesSent;

  /// Test seam: refills the stuck-call nudge budget (issue #1185 E2) —
  /// the same reset a fresh turn performs, without driving a new prompt.
  @visibleForTesting
  void resetToolNudgesForTest() => _waiting.resetToolNudges();

  /// Test seam: whether the last escalation routed through the budget
  /// ladder's offer (issue #1786 AC4) instead of the legacy nudge.
  @visibleForTesting
  bool get budgetOfferRequestedForTest => _waiting.budgetOfferRequested;

  /// Test seam: fires one reasoning-liveness evaluation now (gh-1198),
  /// the analog of [toolLivenessTickForTest].
  @visibleForTesting
  void reasoningLivenessTickForTest() => _waiting.reasoning.tick();

  /// Test seam: whether the reasoning watch is armed right now (gh-1198)
  /// — the request-out/first-event observable.
  @visibleForTesting
  bool get reasoningLivenessActiveForTest => _waiting.reasoning.armed;

  /// Test seam: fires one stream-liveness evaluation now (gh-1430), the
  /// analog of [reasoningLivenessTickForTest].
  @visibleForTesting
  void streamLivenessTickForTest() => _waiting.streamHeartbeat.tick();

  /// Test seam: whether the stream heartbeat is armed right now (gh-1430)
  /// — the request-out/rendered-output observable.
  @visibleForTesting
  bool get streamLivenessActiveForTest => _waiting.streamHeartbeat.armed;

  /// Test seam: whether an unrendered event arrived in the heartbeat's
  /// window since the last print (gh-1430) — the aliveness observable an
  /// integration test waits on after pushing a stream event.
  @visibleForTesting
  bool get streamLivenessDirtyForTest {
    final heart = _waiting.streamHeartbeat;
    // ignore: invalid_use_of_visible_for_testing_member
    return heart.armed && heart.dirtyForTest;
  }

  /// Test seam: opens the compaction liveness window (gh-1430 E3) without
  /// running a real compaction pass.
  @visibleForTesting
  void compactionLivenessStartForTest() => _waiting.compactionLivenessStart();

  /// Test seam: closes the compaction liveness window (gh-1430 E3).
  @visibleForTesting
  void compactionLivenessEndForTest() => _waiting.compactionLivenessEnd();
}
