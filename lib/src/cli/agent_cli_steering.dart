/// Steering members of [AgentCli], split from agent_cli.dart to keep it
/// under the repo's 2800-line size gate. Same library (a `part of`), so the
/// extension sees the class's private members.
part of 'agent_cli.dart';

/// One mid-run steering delivery in flight: the queued message, the
/// session record it was persisted under, and its panel. Consumed by
/// identity at the step-boundary merge (the agent loop appends the SAME
/// [UserMessage] object), or reconciled by text in the leftover settle.

final class PendingSteering {
  PendingSteering({
    required this.message,
    required this.recordId,
    required this.panel,
  });

  final UserMessage message;

  /// The steering record id in the session JSONL; null when the persist
  /// failed (no session) — delivery then skips the consumed marker.
  final String? recordId;

  final DeferredPanel panel;
}

/// Session-record types of the steering persistence (issue #437). One
/// `steering` record per accepted steer (`data['text']` = the attributed
/// message; context-hidden: a [CustomRecord] never projects into model
/// context), one `steering_consumed` marker per delivery.
const String steeringRecordType = 'steering';
const String steeringConsumedType = 'steering_consumed';

/// The user-role attribution prefix, mail-parity with inbound mail.
const String steeringAttributionPrefix = '[steering from user] ';

/// Steering persistence + delivery lifecycle members of [AgentCli]
/// (issue #437). Named so the driver-test seams below stay reachable
/// from the test suite (the private members stay library-private).
extension AgentCliSteering on AgentCli {
  /// Steers [trimmed] into the running agent with the file-reference
  /// resolution applied (a pasted path becomes an explicit
  /// `[attached file: …]` marker — a bare path steered as plain text made
  /// the model miss the attachment entirely). [images] rides along when
  /// the steer originated from a composer submit carrying clipboard chips
  /// (issue #276): they become ImageContent blocks next to the text.
  void _steerResolved(
    String trimmed, {
    List<TuiImageAttachment> images = const [],
  }) {
    final resolved = resolveInteractiveFileReference(trimmed);
    if (resolved != trimmed) {
      io.writeln(_style.dim('[file] attached to steered message'));
    }
    // The message text carries the mail-parity attribution (the model is
    // told where the text came from); the panel body stays human-plain.
    final attributed = '$steeringAttributionPrefix$resolved';
    final message = images.isEmpty
        ? UserMessage.text(attributed)
        : UserMessage(
            content: [
              TextContent(text: attributed),
              for (final image in images)
                ImageContent(
                  data: base64Encode(image.bytes),
                  mimeType: image.mimeType,
                ),
            ],
            timestamp: DateTime.now(),
          );
    if (isBusy) {
      // Mid-run user steering joins the deferred-panel history — with
      // the honest delivery state: pending, or straight to dead when the
      // run's heartbeat has been silent past the stale threshold (the
      // wedged-consumer case). Either way the text is persisted NOW.
      final wedged = _runLooksWedged();
      final panel = _hubAddPanel(
        kind: DeferredPanelKind.steering,
        from: 'you',
        body: resolved,
        state: wedged ? DeferredPanelState.dead : DeferredPanelState.pending,
      );
      if (wedged) {
        // Issue #488 AC1a: the warning names the queue — the owner sees
        // HOW MUCH is saved, not just a per-message nudge; the stall
        // copy stays classifier-driven (#514): /restart + esc recovery.
        final queued = _pendingSteering.length + 1;
        io.writeln(tuiWarning(_stallBannerLine(queued: queued)));
      }
      // The FIFO entry joins SYNCHRONOUSLY — the queued count in the
      // warning above and the wedge watchdog must see every accepted
      // steer even while its session write is still in flight (issue
      // #488 AC1a); the persist below only patches the record id in.
      _pendingSteering.add(
        PendingSteering(message: message, recordId: null, panel: panel),
      );
      unawaited(_persistSteeringAccepted(message, panel));
      _agent.steer(message);
      return;
    }
    // Idle steering (issue #437 AC4, mail parity): the steer STARTS the
    // turn itself instead of queueing into a consumerless run — the
    // attributed text becomes the wake prompt, delivered at once.
    final panel = _hubAddPanel(
      kind: DeferredPanelKind.steering,
      from: 'you',
      body: resolved,
      state: DeferredPanelState.pending,
    );
    unawaited(_persistIdleSteering(message, panel));
    _startRun(attributed);
  }

  /// Steers every queued TUI message into the running agent.
  Future<void> _steerTuiMessages(List<String> messages) async {
    for (final message in messages) {
      _steerResolved(message);
    }
  }

  /// Drains queued messages one-by-one as separate turns (kimi-cli
  /// semantics) — the loop itself is [drainQueueRounds]; an Esc abort
  /// discards the queue instead of starting new work.
  Future<void> _drainTuiQueue(FaTuiController controller) => drainQueueRounds(
    drain: controller.drainQueue,
    runRound: (queued) => runQueuedTurns(
      queued: queued,
      handle: _handleLine,
      settled: () => _settled,
      abortRequested: () => _abortRequested,
    ),
    abortRequested: () => _abortRequested,
    onDropped: (dropped) {
      io.writeln('queued message(s) dropped:');
      for (final text in dropped) {
        final elided = text.length <= 80 ? text : '${text.substring(0, 80)}…';
        io.writeln('  • ${elided.replaceAll('\n', ' ')}');
      }
    },
  );

  /// One dim transcript note per drift the [TermiosGuard] cleared (issue
  /// #735): names the flags a child re-enabled — the trail that says
  /// WHICH tool corrupted the tty.
  void _noteTermiosDrift(List<String> drifted) {
    io.writeln(
      tuiDim(
        'tty: ${drifted.join(', ')} re-enabled by a child process — '
        'cleared (Ctrl+S steering safe)',
      ),
    );
  }

  /// Persists an idle-steer record, then marks it delivered (the run
  /// that [text] started IS the delivery — no FIFO, no boundary wait).
  Future<void> _persistIdleSteering(
    UserMessage message,
    DeferredPanel panel,
  ) async {
    String? recordId;
    try {
      final session = _session;
      if (session != null) {
        recordId = await session.appendCustomEntry(
          customType: steeringRecordType,
          data: {'text': _steerMessageText(message)},
        );
      }
    } on Object {
      recordId = null; // delivery still works; only recovery is lost.
    }
    await _steeringDelivered(message, recordId, panel);
  }

  /// Whether the busy run's event heartbeat is silent past
  /// [AgentCliConfig.steeringStaleAfter] — the wedged-consumer
  /// look (issue #437 E4).
  bool _runLooksWedged() {
    final last = _lastAgentEventAt;
    if (last == null) return false;
    return DateTime.now().difference(last) > config.steeringStaleAfter;
  }

  /// Persists an accepted mid-run steer: the attributed text as a
  /// `steering` record (the crash-recovery source of truth). The FIFO
  /// entry was added synchronously by the caller; this patches the
  /// record id in, or consumes the entry when the run merged the message
  /// BEFORE the write completed (fast boundary) — pending never strands.
  Future<void> _persistSteeringAccepted(
    UserMessage message,
    DeferredPanel panel,
  ) async {
    final text = _steerMessageText(message);
    String? recordId;
    try {
      final session = _session;
      if (session != null) {
        recordId = await session.appendCustomEntry(
          customType: steeringRecordType,
          data: {'text': text},
        );
      }
    } on Object {
      recordId = null; // delivery still works; only recovery is lost.
    }
    final index = _pendingSteering.indexWhere(
      (entry) => identical(entry.message, message),
    );
    if (index < 0) return; // consumed while the write was in flight.
    if (_agent.state.messages.contains(message)) {
      // Already merged (the boundary beat the write): honest delivery.
      final entry = _pendingSteering.removeAt(index);
      await _steeringDelivered(entry.message, recordId, entry.panel);
      return;
    }
    _pendingSteering[index] = PendingSteering(
      message: message,
      recordId: recordId,
      panel: panel,
    );
  }

  /// Marks one steering delivery: panel `delivered`, transition notice,
  /// consumed marker referencing the accept-time record id.
  Future<void> _steeringDelivered(
    UserMessage message,
    String? recordId,
    DeferredPanel panel,
  ) async {
    panel.state = DeferredPanelState.delivered;
    io.writeln(_style.dim(deferredPanelTransitionLine(panel)));
    final id = recordId;
    final session = _session;
    if (id == null || session == null) return;
    await _writeSteeringConsumed(session, id);
  }

  /// The attributed text of a steered message (string or content-block
  /// content).
  String _steerMessageText(UserMessage message) {
    final content = message.content;
    if (content is String) return content;
    for (final block in content as List<ContentBlock>) {
      if (block is TextContent) return block.text;
    }
    return content.toString();
  }

  /// Writes the consumed marker for a steering record (best-effort: a
  /// lost marker can only cause a post-crash re-delivery, never a live
  /// one).
  Future<void> _writeSteeringConsumed(Session session, String id) async {
    try {
      await session.appendCustomEntry(
        customType: steeringConsumedType,
        data: {'id': id},
      );
    } on Object {
      // Best-effort.
    }
  }

  /// The steering still queued after a run settled, or null when there
  /// is nothing left to settle (or the session already exited).
  LeftoverSteering? _leftoverSteeringOutcome() {
    if (_exited || !_agent.hasSteering) return null;
    return resolveLeftoverSteering(
      drain: _agent.drainSteeringQueue,
      abortRequested: _abortRequested,
    );
  }

  /// Prints exactly what was discarded — a silent drop is
  /// indistinguishable from a lost message.
  void _printDroppedSteering(List<String> texts) {
    io.writeln(_style.dim('dropped steering message(s) after interrupt:'));
    for (final text in texts) {
      final elided = text.length <= 80 ? text : '${text.substring(0, 80)}…';
      io.writeln(_style.dim('  • ${elided.replaceAll('\n', ' ')}'));
    }
  }

  /// Runs or loudly drops the steering messages still queued after a run
  /// settled (they missed every drain point: raced past the last poll, or
  /// the run was interrupted). Running keeps "typed but never answered"
  /// from happening; dropping prints exactly what was discarded — a silent
  /// drop is indistinguishable from a lost message.
  void _settleLeftoverSteering() {
    final outcome = _leftoverSteeringOutcome();
    if (outcome == null) return;
    // Reconcile the delivery FIFO with the drained leftovers: whatever
    // the settle branch now does to a text, its record must not stay
    // pending (the next boot would re-deliver it).
    final entries = [
      for (final entry in _pendingSteering)
        if (outcome.texts.contains(_steerMessageText(entry.message))) entry,
    ];
    _pendingSteering.removeWhere(entries.contains);
    if (outcome.run) {
      io.writeln(
        _style.dim(
          'steering arrived after the last checkpoint — running '
          '${outcome.texts.length} message(s) now',
        ),
      );
      for (final entry in entries) {
        unawaited(
          _steeringDelivered(entry.message, entry.recordId, entry.panel),
        );
      }
      _startRun(outcome.texts.join('\n'));
      return;
    }
    // Dropped by user interrupt: dead panels, consumed markers (the drop
    // was a live decision — the record must not resurrect on restart).
    final session = _session;
    for (final entry in entries) {
      entry.panel.state = DeferredPanelState.dead;
      io.writeln(_style.dim(deferredPanelTransitionLine(entry.panel)));
      final id = entry.recordId;
      if (id != null && session != null) {
        unawaited(_writeSteeringConsumed(session, id));
      }
    }
    _printDroppedSteering(outcome.texts);
  }

  /// The stall banner (issue #514): names the state, the cause and BOTH
  /// affordances. Replaces #437's cryptic "not responding … will deliver
  /// if the run wakes" copy that offered no recovery action. Every
  /// stall symptom — banner, panel label, busy row — reads the SAME
  /// classifier ([_runLooksWedged]).
  String _stallBannerLine({int queued = 0}) {
    final last = _lastAgentEventAt;
    final seconds = last == null
        ? 0
        : DateTime.now().difference(last).inSeconds;
    final minutes = seconds < 60 ? 1 : seconds ~/ 60;
    // Issue #488 AC1a: when the caller knows the queue size (a fresh
    // wedged steer), the banner names the count instead of the single
    // "your message" copy. When no messages are queued, it is an
    // informational notification that the run has stalled, not a false
    // claim that a message was saved.
    if (queued > 0) {
      final saved = queued == 1
          ? '1 steering message saved to the session'
          : '$queued steering messages saved to the session';
      return '⚠ agent stalled — no response for ${minutes}m. '
          '$saved: /restart delivers it into a fresh run, esc aborts';
    }
    return 'info: agent stalled — no response for ${minutes}m. '
        '/restart starts a fresh run, esc aborts';
  }

  /// Pushes the stall state to every consumer (issue #514 AC1): the busy
  /// row gets [FaTuiController.setRunStalled], the transcript gets the
  /// banner once per stall EPISODE (edge — not per watchdog tick).
  void _setRunStalled(bool stalled) {
    if (stalled == _runStalledPushed) return;
    _runStalledPushed = stalled;
    _tuiController?.setRunStalled(stalled);
    if (stalled) {
      final queued = _pendingSteering.length;
      final line = _stallBannerLine(queued: queued);
      io.writeln(queued > 0 ? tuiWarning(line) : _style.dim(line));
    }
  }

  /// Wedge watchdog, called on the inbox tick (issue #437 AC3 + #514):
  /// the shared classifier ([_runLooksWedged]) drives the stall state —
  /// banner + busy row flip on the episode edge, pending steering
  /// panels flip to the queued-stalled label. The FIFO entries STAY —
  /// a late boundary merge still consumes them (delivered-after-stall
  /// is honest recovery), and the persisted record keeps the message
  /// recoverable across restarts.
  void _checkPendingSteeringHealth() {
    if (!isBusy) {
      _setRunStalled(false);
      return;
    }
    final wedged = _runLooksWedged();
    _setRunStalled(wedged);
    if (_pendingSteering.isEmpty || !wedged) return;
    var flipped = 0;
    for (final entry in _pendingSteering) {
      if (entry.panel.state == DeferredPanelState.pending) {
        entry.panel.state = DeferredPanelState.dead;
        io.writeln(_style.dim(deferredPanelTransitionLine(entry.panel)));
        flipped++;
      }
    }
    if (flipped > 0) {
      // One warning per stall episode, with the full queued count — the
      // owner sees the queue size, not a per-message nudge (issue #488).
      io.writeln(
        tuiWarning(
          '⚠ agent not responding — ${_pendingSteering.length} steering '
          '${_pendingSteering.length == 1 ? 'message' : 'messages'} saved '
          'to session, will deliver if the run wakes',
        ),
      );
    }
  }

  /// The `/restart` affordance (issue #514): aborts the stalled run
  /// WITHOUT the interrupt's drop flag — the settle path then re-runs
  /// the saved steering as a fresh turn (the #437 persisted records
  /// ride it; a no-steering stall just gets its run back).
  void _restartRun() {
    if (!isBusy) {
      io.writeln(_style.dim('agent is idle — nothing to restart'));
      return;
    }
    io.writeln(
      tuiWarning(
        'restarting the stalled run — saved steering delivers '
        'into the fresh turn',
      ),
    );
    // NOT _abortRequested=true: that drops the queued steering
    // (resolveLeftoverSteering), which would lose exactly the message
    // the user is trying to recover.
    _agent.abort();
  }

  /// Scans a loaded session for persisted-but-unconsumed steering
  /// records (the crash residue: accepted, never delivered). Returns
  /// them in file order; empty when everything was delivered or the
  /// scan fails (never break the session load on recovery).
  Future<List<({String recordId, String text})>> _recoverSessionSteering(
    Session session,
  ) async {
    try {
      final pendingIds = <String>[];
      final consumedIds = <String>{};
      final texts = <String, String>{};
      // getEntries() is the windowed storage's RESIDENT BRANCH — custom
      // records are side-leaves and drop out on a restart (exactly the
      // crash-recovery case). The Jsonl repo's raw file scan sees them
      // all; other repo implementations degrade to no recovery.
      final records = await (_repo as JsonlSessionRepo).readCustomRecordsOfType(
        await session.getMetadata(),
        {steeringRecordType, steeringConsumedType},
      );
      for (final entry in records) {
        if (entry.customType == steeringRecordType) {
          pendingIds.add(entry.id);
          texts[entry.id] = ((entry.data as Map?)?['text'] as String?) ?? '';
        } else if (entry.customType == steeringConsumedType) {
          final id = (entry.data as Map?)?['id'];
          if (id is String) consumedIds.add(id);
        }
      }
      return [
        for (final id in pendingIds)
          if (!consumedIds.contains(id) && texts[id]!.isNotEmpty)
            (recordId: id, text: texts[id]!),
      ];
    } on Object {
      return const [];
    }
  }

  /// Load-time hook: scans the session and queues any recovered
  /// steering for the idle wake (panels render as pending).
  ///
  /// The scan is fire-and-forget (off the load critical path), so a
  /// `/resume` session switch can land mid-scan: publishing A's results
  /// into B's `_recoveredSteering` would deliver A's steering into B's
  /// run and write A's `steering_consumed` markers into B's file. The
  /// identity check drops stale results; the empty-scan branch clears a
  /// previous session's leftover instead of leaving it reachable.
  Future<void> _queueRecoveredSteering(Session session) async {
    final recovered = await _recoverSessionSteering(session);
    if (!identical(session, _session)) return; // switched away mid-scan
    if (recovered.isEmpty) {
      _recoveredSteering = null;
      return;
    }
    _recoveredSteering = [
      for (final item in recovered)
        (
          recordId: item.recordId,
          text: item.text,
          panel: _hubAddPanel(
            kind: DeferredPanelKind.steering,
            from: 'you',
            body: item.text.startsWith(steeringAttributionPrefix)
                ? item.text.substring(steeringAttributionPrefix.length)
                : item.text,
            state: DeferredPanelState.pending,
          ),
        ),
    ];
  }

  /// The idle-wake hook (rides the inbox tick): recovered steering from
  /// the previous session starts a run on its own — mail-parity wake.
  /// The texts are delivered INSIDE the run prompt (attributed); the
  /// records are consumed at wake START, so a crash mid-run cannot
  /// re-deliver them (exactly-once by record id, issue #437 E1).
  void _wakeOnRecoveredSteering() {
    final recovered = _recoveredSteering;
    final session = _session;
    if (recovered == null ||
        session == null ||
        _exited ||
        isBusy ||
        _steeringWakeRunning) {
      return;
    }
    _recoveredSteering = null;
    _steeringWakeRunning = true;
    io.writeln(
      _style.dim(
        '[btw] recovered ${recovered.length} undelivered steering '
        'message(s) from the previous session — running them now',
      ),
    );
    unawaited(_consumeRecoveredSteering(session, recovered));
    _startRun(
      '<system-notice>\n'
      '${recovered.length} steering message(s) you were sent in the '
      'previous session were saved but never delivered (the session '
      'ended before they reached you). They follow below — read and act '
      'on them now.\n'
      '</system-notice>\n'
      '${[for (final item in recovered) item.text].join('\n')}',
    );
    unawaited(_settled.whenComplete(() => _steeringWakeRunning = false));
  }

  /// Marks recovered records consumed (wake-start) and flips their
  /// panels to delivered.
  Future<void> _consumeRecoveredSteering(
    Session session,
    List<({String recordId, String text, DeferredPanel panel})> recovered,
  ) async {
    for (final item in recovered) {
      item.panel.state = DeferredPanelState.delivered;
      io.writeln(_style.dim(deferredPanelTransitionLine(item.panel)));
      try {
        await session.appendCustomEntry(
          customType: steeringConsumedType,
          data: {'id': item.recordId},
        );
      } on Object {
        // Best-effort.
      }
    }
  }

  /// Test seam: queues a steer through the same `_steerResolved` path
  /// mid-run input takes (panel join + agent steer queue).
  @visibleForTesting
  void steerForTest(String text) => _steerResolved(text);

  /// Test seam: steers with clipboard chips through the same
  /// `_steerResolved` path a busy composer submit takes (issue #276).
  @visibleForTesting
  void steerImagesForTest(String text, List<TuiImageAttachment> images) =>
      _steerResolved(text, images: images);

  /// Test seam: the run-settle steering resolution (leftover run or loud
  /// drop) so driver tests can exercise both branches deterministically
  /// instead of racing the real settle window.
  @visibleForTesting
  void settleLeftoverSteeringForTest() => _settleLeftoverSteering();

  /// Test seam: the wedge watchdog (a pending steering panel flips to
  /// `dead` only when the run's heartbeat is stale) so tests don't wait
  /// for the 2s inbox tick (issue #437 E4).
  @visibleForTesting
  void checkPendingSteeringHealthForTest() => _checkPendingSteeringHealth();

  /// Test seam: the shared stall classifier state (issue #514 AC1) —
  /// `true` iff the watchdog currently pushes the run as stalled.
  @visibleForTesting
  bool get runStalledForTest => _runStalledPushed;

  /// Test seam: the `/restart` affordance so tests don't route through
  /// the slash-command parser.
  @visibleForTesting
  void restartRunForTest() => _restartRun();
}
