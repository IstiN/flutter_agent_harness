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

/// The boot process snapshot (issue #478): every live pid plus, when the
/// platform reports it, its start string — the pid-reuse guard (a
/// recycled pid's start never matches the recorded one).
typedef _ProcessTable = ({Set<int> pids, Map<int, String> starts});

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

/// Owns the visible-waiting state and its event pushes. All mutations are
/// best-effort: a snapshot (disk scan) or manifest write failure must
/// never take a run down.
final class _WaitingCoordinator {
  _WaitingCoordinator(this._cli);

  final AgentCli _cli;

  /// Previous-run jobs the boot reconcile (issue #478) dropped as lost:
  /// dead or recycled pid, no pid at all, or past the `jobs.staleHours`
  /// age belt. Live detached jobs are kept — they are not lost.
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
      case MessageUpdateEvent(:final assistantMessageEvent):
        final rendered =
            assistantMessageEvent is TextDeltaEvent ||
            (assistantMessageEvent is ThinkingDeltaEvent &&
                _cli._streamsThinking);
        if (rendered) {
          streamHeartbeat.renderedOutput();
        } else {
          streamHeartbeat.unrenderedEvent();
        }
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
  /// processes share `.fah/bash_jobs/` (issue #478).
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
  ///   at all (nothing to verify) and entries past `jobs.staleHours`
  ///   (the age belt). Live entries are KEPT — a detached job
  ///   legitimately outlives the run that started it. Every drop counts
  ///   as [lostJobs] (restart honesty);
  /// - job logs older than `jobs.logRetentionDays` are deleted (24,144
  ///   files accumulated once — nothing ever pruned them).
  ///
  /// One notice line summarizes the reconcile + the GC. The recorded
  /// pids also feed the boot sweep (issue #517): previous-run jobs whose
  /// wrapper died but whose process group (toolchain grandchildren)
  /// survived get one warning line, then are reaped.
  Future<void> captureLostJobs() async {
    lostJobs = 0;
    final reconcile = await _reconcileRegistry();
    lostJobs = reconcile.dropped;
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
  Future<({List<int> pids, bool quarantined, int dropped, int aged})>
  _reconcileRegistry() async {
    var pids = const <int>[];
    var quarantined = false;
    var dropped = 0;
    var aged = 0;
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
      final staleBefore = _clock().subtract(
        Duration(hours: _cli.config.jobs.staleHours),
      );
      final kept = <_ManifestEntry>[];
      for (final entry in entries) {
        final started = entry.startedAtMs;
        final tooOld =
            started != null &&
            DateTime.fromMillisecondsSinceEpoch(started).isBefore(staleBefore);
        if (tooOld || !_entryAlive(entry, table)) {
          dropped++;
          if (tooOld) aged++;
          continue;
        }
        kept.add(entry);
      }
      if (quarantined || kept.length != entries.length) {
        await _writeRegistryEntries(kept);
      }
    });
    return (pids: pids, quarantined: quarantined, dropped: dropped, aged: aged);
  }

  Future<void> _manifestAdd(
    String id,
    String command,
    int? pid, {
    String? pidStart,
  }) async {
    await _mutateRegistry(
      (entries) => [
        ...entries,
        _ManifestEntry(
          id: id,
          command: command,
          pid: pid,
          pidStart: pidStart,
          startedAtMs: _clock().millisecondsSinceEpoch,
        ),
      ],
    );
  }

  Future<void> _manifestRemove(String id) async {
    await _mutateRegistry(
      (entries) => [
        for (final entry in entries)
          if (entry.id != id) entry,
      ],
    );
  }

  /// Reads the registry under the lock, mutates, writes back ATOMICALLY.
  /// A failure anywhere is swallowed — the registry is best-effort
  /// bookkeeping and the job itself is unaffected.
  Future<void> _mutateRegistry(
    List<_ManifestEntry> Function(List<_ManifestEntry>) mutate,
  ) async {
    await _withRegistryLock(() async {
      await _writeRegistryEntries(mutate(await _readRegistryEntries()));
    });
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

  /// The per-root registry lock: `createDir` is an atomic
  /// exclusive-create on the local filesystem — the loser's call fails.
  /// Bounded wait; a stale lock (no mutation runs this long — the holder
  /// crashed) is stolen. Backends without exclusive create (memory, web)
  /// degrade to unlocked single writes, like the session lease degrades
  /// without rename.
  static const _lockStaleAfter = Duration(seconds: 60);
  static const _lockWaitBound = Duration(milliseconds: 300);

  Future<void> _withRegistryLock(Future<void> Function() body) async {
    // The lock dir lives under the job bookkeeping dir — make sure the
    // parent exists or the exclusive create fails for the wrong reason and
    // every mutation pays the full contention wait.
    await _cli._env.createDir(_jobBookkeepingDir);
    if (!await _acquireRegistryLock()) return body();
    try {
      await body();
    } finally {
      await _cli._env.remove(_manifestLockPath, recursive: true, force: true);
    }
  }

  Future<bool> _acquireRegistryLock() async {
    final deadline = _clock().add(_lockWaitBound);
    for (;;) {
      if ((await _cli._env.createDir(
        _manifestLockPath,
        recursive: false,
      )).isOk) {
        return true;
      }
      final info = await _cli._env.fileInfo(_manifestLockPath);
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

  /// The OS start string of [pid] (`ps -o lstart=`), or null when the
  /// platform cannot tell (the entry then has no pid-reuse protection
  /// but still gets plain liveness checks + the age belt).
  Future<String?> _pidStart(int? pid) async {
    if (pid == null) return null;
    return pidStartSnapshot(pid);
  }

  /// Whether the entry's owning process is alive: a dead pid is a ghost;
  /// a pid whose start string drifted from the recorded one was recycled
  /// onto an unrelated process — equally gone.
  bool _entryAlive(_ManifestEntry entry, _ProcessTable? table) {
    final pid = entry.pid;
    if (pid == null) return false;
    final t = table;
    if (t == null) return true;
    if (!t.pids.contains(pid)) return false;
    final recorded = entry.pidStart;
    final actual = t.starts[pid];
    return recorded == null || actual == null || recorded == actual;
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
  /// pid from the real owner.
  Future<void> jobStarted(ShellJobEntry job) async {
    await _manifestAdd(
      job.id,
      job.command,
      job.pid,
      pidStart: await _pidStart(job.pid),
    );
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
    return WaiterSnapshot(jobs: jobs, timers: timers, lostJobs: lostJobs);
  }

  String _jobPurpose(ShellJobEntry job) {
    final preview = shellJobCommandPreview(job.command);
    final clipped = preview.length > 48
        ? '${preview.substring(0, 48)}…'
        : preview;
    return '$clipped (${job.id})';
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
    );
  }

  /// Arms the heartbeat while waiters exist (a resolved-then-remaining
  /// wait restarts the full period, E2) and stops it when the last
  /// waiter resolves (AC3: a resolved wait never beats again).
  void _syncHeartbeat(WaiterSnapshot snap) {    if (snap.isEmpty) {
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
    _cli.io.writeln('${_pendingGlyph()} waiters resolved — ${waitingDetachSummary(settled)}');
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
String waitingDescribe(WaiterSnapshot snap) {  final parts = <String>[
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
    io.writeln(
      _style.dim('[bash] ${job.id} exited(${job.exitCode}) — ${job.logPath}'),
    );
    if (_exited) return;
    final message =
        '<system-notice>\n'
        'Background shell job ${job.id} finished with exit code '
        '${job.exitCode}.\n'
        // Issue #599: the preview, never the multi-line body — this
        // notice is echoed into the transcript verbatim, and the full
        // command lives in the job log (right below).
        'Command: ${shellJobCommandPreview(job.command)}\n'
        'Log: ${job.logPath}\n'
        'Check the result with bash_job (action: output) or by reading the '
        'log file, and act on it when the result was awaited.\n'
        '</system-notice>';
    // The notice is a persisted user message: echo it into the live
    // transcript through the same system-notice renderer the replay path
    // uses (#446), so resume matches live 1:1. Steered messages skip the
    // composer echo — without this the rows exist only after resume.
    _tuiController?.sendOutput('$message\n');
    if (isBusy) {
      // Mid-run: the steering queue delivers it at the next step boundary.
      _agent.steer(UserMessage.text(message));
    } else {
      _startRun(message);
    }
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

  /// Test seam: re-runs the boot-time restart-honesty capture so tests
  /// can seed the cross-run manifest and observe the lost-jobs count.
  @visibleForTesting
  Future<void> waitingCaptureLostJobsForTest() => _waiting.captureLostJobs();

  /// Test seam: the current restart-honesty count.
  @visibleForTesting
  int get waitingLostJobsForTest => _waiting.lostJobs;

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
