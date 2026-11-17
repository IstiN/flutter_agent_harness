/// Steering members of [AgentCli], split from agent_cli.dart to keep it
/// under the repo's 2800-line size gate. Same library (a `part of`), so the
/// extension sees the class's private members.
part of 'agent_cli.dart';

/// One mid-run steering delivery in flight: the queued message, the
/// session record it was persisted under, and its panel. Consumed by
/// identity everywhere (the boundary merge, the in-flight persist patch,
/// and the leftover settle's identity zip — issue #2249 AC3), so
/// same-text steers never lose their consumed markers.

final class PendingSteering {
  PendingSteering({
    required this.message,
    required this.recordId,
    required this.panel,
    this.persistError,
  });

  final UserMessage message;

  /// The steering record id in the session JSONL; null when the persist
  /// failed (no session) — delivery then skips the consumed marker.
  final String? recordId;

  /// The raw accept-append failure, when the steering record could not
  /// be persisted — the NOT-saved truth behind the banner copy and the
  /// bounded one-shot persist re-attempt at delivery (issue #2249 AC1).
  /// Null while the write is healthy or still in flight.
  final Object? persistError;

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
  ///
  /// The mid-run branch guards the message through the intake spill
  /// ([Agent.userMessageGuard], issue #1760) BEFORE it joins the FIFO:
  /// the delivery FIFO, the accepted-steer session record and the
  /// transcript all carry the SAME (bounded) object, and the queued
  /// object identity the delivery matcher relies on holds. The idle
  /// branch lets the run's own intake seam guard it.
  Future<void> _steerResolved(
    String trimmed, {
    List<TuiImageAttachment> images = const [],
  }) async {
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
        io.writeln(
          tuiWarning(
            _stallBannerLine(
              queued: queued,
              budgetOffer: hasOutstandingBudgetOffer,
              // Issue #2119 AC3: same context-aware levers as the
              // watchdog banner — the transcript is the signal.
              hasImages: messagesContainImages(_agent.state.messages),
            ),
          ),
        );
      }
      // Issue #1760: bound an oversized steer BEFORE it joins the FIFO —
      // spill fires here, and the FIFO, the session record and the
      // transcript all carry the same bounded object. No guard installed
      // = the message verbatim, with zero awaits: the FIFO entry joins
      // synchronously and the queued-count warning above and the wedge
      // watchdog keep their synchronous view (issue #488 AC1a). WITH a
      // guard the join lands after the spill write — a few ms later; the
      // wedged warning above already counted this accept, a rapid second
      // steer mid-spill may briefly under-count, and the #488 crash
      // recovery still sees every accepted steer via the session record.
      final spillGuard = _agent.userMessageGuard;
      final delivered = spillGuard == null
          ? message
          : await spillGuard(message);
      _pendingSteering.add(
        PendingSteering(message: delivered, recordId: null, panel: panel),
      );
      unawaited(_persistSteeringAccepted(delivered, panel));
      _agent.steer(delivered);
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
      await _steerResolved(message);
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
    Object? persistError;
    try {
      final session = _session;
      if (session != null) {
        recordId = await session.appendCustomEntry(
          customType: steeringRecordType,
          data: {'text': _steerMessageText(message)},
        );
      }
    } on Object catch (error) {
      recordId = null;
      persistError = error;
    }
    await _steeringDelivered(message, recordId, panel);
    if (persistError != null) {
      // Issue #2249 AC1: the run itself still carries the text, but the
      // steering RECORD (crash-recovery attribution) is lost — say so
      // with the raw error instead of swallowing it silently. After the
      // delivered line (review digest): the delivery truth first, the
      // recovery caveat second.
      io.writeln(
        tuiWarning(
          '⚠ steering NOT saved to session (fs error: $persistError) — '
          'recovery after restart will not see it',
        ),
      );
    }
  }

  /// Whether the busy run's event heartbeat is silent past
  /// [AgentCliConfig.steeringStaleAfter] — the wedged-consumer
  /// look (issue #437 E4). gh-1617 open question 1: the notice fires at
  /// `min(ceiling, window)` — the early "still waiting" UX feedback
  /// keeps its 2m ceiling under a wide configured window, and a tight
  /// window pulls the notice earlier. (A tighter threshold is only
  /// reachable via a host-configured `runIdleTimeout` below the ceiling —
  /// the derived window is floored at `runIdleTimeout`, so a tight
  /// `providerTimeouts.streamIdleTimeoutMs` can never pull it earlier.)
  bool _runLooksWedged() {
    final last = _lastAgentEventAt;
    if (last == null) return false;
    final threshold = stallNoticeThreshold(
      noticeCeiling: config.steeringStaleAfter,
      window: _agent.runIdleWindow.window,
    );
    return DateTime.now().difference(last) > threshold;
  }

  /// Persists an accepted mid-run steer: the attributed text as a
  /// `steering` record (the crash-recovery source of truth). The FIFO
  /// entry was added synchronously by the caller; this patches the
  /// record id in (or the raw persist error, issue #2249 AC1), or
  /// consumes the entry when the run merged the message BEFORE the write
  /// completed (fast boundary) — pending never strands. A consumed entry
  /// whose write was still in flight still gets its consumed marker once
  /// the write lands (issue #2249 AC3 — the marker must not depend on
  /// which path consumed the entry).
  Future<void> _persistSteeringAccepted(
    UserMessage message,
    DeferredPanel panel,
  ) async {
    final text = _steerMessageText(message);
    String? recordId;
    Object? persistError;
    try {
      final session = _session;
      if (session != null) {
        recordId = await session.appendCustomEntry(
          customType: steeringRecordType,
          data: {'text': text},
        );
      }
    } on Object catch (error) {
      recordId = null;
      persistError = error;
      // Issue #2249 AC1: the failure is announced NOW, with the raw
      // error (#2248's surfacing discipline) — the banner must never be
      // the last word promising a save the fs refused.
      io.writeln(
        tuiWarning(
          '⚠ steering NOT saved to session (fs error: $error) — '
          'recovery after restart will not see it',
        ),
      );
    }
    final index = _pendingSteering.indexWhere(
      (entry) => identical(entry.message, message),
    );
    if (index < 0) {
      // Consumed while the write was in flight (boundary merge or the
      // settle): the record landed — close it with the consumed marker
      // here, or a crash re-delivers an already-run text (#2249 AC3).
      final id = recordId;
      final session = _session;
      if (id != null && session != null) {
        await _writeSteeringConsumed(session, id);
      }
      return;
    }
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
      persistError: persistError,
    );
  }

  /// One bounded re-attempt of a failed steering accept-append (issue
  /// #2249 AC1): exactly ONE fresh append per delivery attempt — never a
  /// retry loop into a dead fs (the #2248 wedge class). Returns the
  /// entry's record id when the persist is healthy or the retry lands;
  /// null keeps the honest unsaved state (already announced at accept
  /// time) — an in-flight write (no error, no id) is left to its own
  /// resolution, which writes the marker. A FAILED re-attempt prints the
  /// same warning the accept did (review digest parity) unless the
  /// caller announces the outcome itself.
  Future<String?> _retrySteeringPersist(
    PendingSteering entry, {
    bool announceFailure = true,
  }) async {
    final id = entry.recordId;
    if (id != null) return id;
    if (entry.persistError == null) return null;
    try {
      final session = _session;
      if (session == null) return null;
      return await session.appendCustomEntry(
        customType: steeringRecordType,
        data: {'text': _steerMessageText(entry.message)},
      );
    } on Object catch (error) {
      if (announceFailure) {
        io.writeln(
          tuiWarning(
            '⚠ steering still NOT saved to session (fs error: $error) — '
            'recovery after restart will not see it',
          ),
        );
      }
      return null;
    }
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
  Future<void> _settleLeftoverSteering() async {
    if (_exited || !_agent.hasSteering) return;
    final drained = _agent.drainSteeringQueue();
    final texts = [
      for (final message in drained)
        if (message is UserMessage) _steerMessageText(message),
    ].where((text) => text.trim().isNotEmpty).toList();
    if (texts.isEmpty) return;
    final entries = _reconcileSettledEntries(drained);
    _pendingSteering.removeWhere(entries.contains);
    if (!_abortRequested) {
      io.writeln(
        _style.dim(
          'steering arrived after the last checkpoint — running '
          '${texts.length} message(s) now',
        ),
      );
      if (isBusy) {
        // A competing submit/mail/scheduled run started before the
        // settle ran: the drained texts have no carrier left — loud
        // re-drop, never a consume-and-lose (review round 1).
        await _dropSettledSteering(entries, texts);
        return;
      }
      // Start the follow-up run BEFORE any await (review round 1): the
      // per-entry persist retries below yield the event loop, and a run
      // started in that window would make _startRun's busy guard refuse
      // with the texts already consumed. Drain → start is synchronous;
      // the retries ride the fresh run.
      _startRun(texts.join('\n'));
      for (final entry in entries) {
        // Bounded persist re-attempt (issue #2249 AC1): a failed accept
        // append gets exactly one fresh append per delivery attempt.
        final recordId = await _retrySteeringPersist(entry);
        unawaited(_steeringDelivered(entry.message, recordId, entry.panel));
      }
      return;
    }
    await _dropSettledSteering(entries, texts);
  }

  /// Reconciles the delivery FIFO with the drained leftovers by OBJECT
  /// IDENTITY (issue #2249 AC3): the same object the boundary merge and
  /// the in-flight persist consume by. Text matching here made two
  /// same-text steers lose their consumed markers (double delivery
  /// after restart); the zip pairs one entry per drained message, and
  /// only entries whose object left the queue fall back to text — one
  /// slot per drained text, so a raced persist still settles its
  /// record. Returns the consumed entries, in FIFO order.
  List<PendingSteering> _reconcileSettledEntries(List<Message> drained) {
    final drainedUserMessages = drained.whereType<UserMessage>().toList();
    final textSlots = <String, int>{};
    for (final message in drainedUserMessages) {
      final text = _steerMessageText(message);
      textSlots[text] = (textSlots[text] ?? 0) + 1;
    }
    final pool = List<PendingSteering>.of(_pendingSteering);
    final entries = <PendingSteering>[];
    for (final message in drainedUserMessages) {
      final index = pool.indexWhere(
        (entry) => identical(entry.message, message),
      );
      if (index >= 0) entries.add(pool.removeAt(index));
    }
    // Text fallback: only for entries whose object left the queue
    // without a boundary consumption (a racing persist). One slot per
    // drained text — never a same-text collapse.
    for (final entry in List<PendingSteering>.of(pool)) {
      final text = _steerMessageText(entry.message);
      final slots = textSlots[text] ?? 0;
      if (slots <= 0) continue;
      textSlots[text] = slots - 1;
      pool.remove(entry);
      entries.add(entry);
    }
    return entries;
  }

  /// The esc-drop branch (issue #2249 AC4): the panels go `aborted` —
  /// the message will never queue again, so it must not keep reading
  /// "queued (agent stalled)". A consumed marker (or a healed-fs retry
  /// that lands the record) keeps it from resurrecting on restart;
  /// [texts] prints verbatim at the end.
  Future<void> _dropSettledSteering(
    List<PendingSteering> entries,
    List<String> texts,
  ) async {
    final session = _session;
    for (final entry in entries) {
      entry.panel.state = DeferredPanelState.aborted;
      io.writeln(_style.dim(deferredPanelTransitionLine(entry.panel)));
      // The drop's own lost-print below announces a failed retry — the
      // helper's warning would double-print the same error.
      final recordId = await _retrySteeringPersist(
        entry,
        announceFailure: false,
      );
      if (recordId != null) {
        if (session != null) {
          unawaited(_writeSteeringConsumed(session, recordId));
        }
        continue;
      }
      // The drop destroys the LAST carrier: the session append failed
      // (or is still in flight), the FIFO entry is gone, the agent
      // queue is drained. Print the text verbatim — a silent drop is
      // indistinguishable from a lost message (issue #2249 AC2). The
      // in-flight shape claims loss only conditionally: the parked
      // append can still land right after this line (review round 1).
      final why = entry.persistError == null
          ? 'save still in flight — unless the parked append lands, '
                'the text is lost'
          : 'fs error: ${entry.persistError} — the text is lost';
      io.writeln(
        tuiWarning('⚠ dropped steering was NOT saved to session ($why):'),
      );
      io.writeln('  • ${_steerMessageText(entry.message)}');
    }
    _printDroppedSteering(texts);
  }

  /// The stall banner (issue #514): names the state, the cause and BOTH
  /// affordances. Replaces #437's cryptic "not responding … will deliver
  /// if the run wakes" copy that offered no recovery action. Every
  /// stall symptom — banner, panel label, busy row — reads the SAME
  /// classifier ([_runLooksWedged]).
  String _stallBannerLine({
    int queued = 0,
    bool budgetOffer = false,
    bool hasImages = true,
  }) {
    final last = _lastAgentEventAt;
    final seconds = last == null
        ? 0
        : DateTime.now().difference(last).inSeconds;
    final minutes = seconds < 60 ? 1 : seconds ~/ 60;
    // gh-1617 AC5: a configured window wider than the floor governs the
    // run — the banner names it and its source so a wide patience never
    // reads as a hang. Unset config appends nothing (byte-for-byte, AC3).
    final window = _agent.runIdleWindow;
    final windowNote = window.raised
        ? ' (${describeRunIdleWindow(window.window, window.source)} — '
              'the run keeps waiting)'
        : '';
    // Issue #2248 AC5: a session-IO failure inside the stall window
    // RECLASSIFIES the stall — the provider-stall levers (/compact,
    // image budgets) cannot unstick a failing filesystem, and the
    // incident burned 21 minutes under exactly that misleading banner.
    // The fs variant names the raw error and swaps the levers (restart
    // the host, check fds/container access).
    final threshold = stallNoticeThreshold(
      noticeCeiling: config.steeringStaleAfter,
      window: window.window,
    );
    final ioFailure = stallIsSessionIo(
      last: SessionIoHealth.lastFailure(_session?.cachedId ?? ''),
      now: DateTime.now(),
      window: threshold,
    );
    if (ioFailure) {
      final raw = SessionIoHealth.lastFailure(_session?.cachedId ?? '')!.error;
      final savedNote = queued > 0
          ? '$queued steering message(s) saved to the session; '
          : '';
      return '⚠ session IO failing: $raw — $savedNote'
          'session writes are failing; restart the host '
          '(check open fds / container access), esc aborts';
    }
    // Issue #2119 AC3: the image levers are advice about IMAGE payloads —
    // /compact and images.maxBytesPerRequest cannot unstick an image-free
    // session, so the line names the cause (still waiting on the provider)
    // and keeps the wait/abort/restart actions instead. With images in the
    // context the levers stay byte-identical (the #1786 REG-3 shape).
    final levers = hasImages
        ? '/compact (drops image data) or a lower images.maxBytesPerRequest '
              'may unstick it; '
        : 'still waiting on the provider; ';
    // Issue #488 AC1a: when the caller knows the queue size (a fresh
    // wedged steer), the banner names the count instead of the single
    // "your message" copy. When no messages are queued, it is an
    // informational notification that the run has stalled, not a false
    // claim that a message was saved.
    if (queued > 0) {
      // Issue #2249 AC1/AC4: at accept time the append has not resolved,
      // so the banner names the DELIVERY truth (queued) and leaves the
      // persistence truth to the surfaces that KNOW it — the unsaved
      // warning printed when the append fails, and the watchdog line
      // (steeringStallWarningLine) after it resolves.
      final count = queued == 1
          ? '1 steering message queued'
          : '$queued steering messages queued';
      // Issue #1786: with a budget offer outstanding, `b` is the real-time
      // affordance — background the call and deliver the steering NOW,
      // next to the post-mortem levers. budgetOffer=false keeps the line
      // byte-identical (REG-3).
      final budgetNote = budgetOffer
          ? '; press b to background the running call & deliver steering now'
          : '';
      return '⚠ agent stalled — no response for ${minutes}m$windowNote. '
          '$count: $levers/restart delivers it '
          'into a fresh run, esc aborts'
          '$budgetNote';
    }
    return 'info: agent stalled — no response for ${minutes}m$windowNote. '
        '$levers/restart starts a fresh run, esc aborts';
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
      final line = _stallBannerLine(
        queued: queued,
        budgetOffer: hasOutstandingBudgetOffer,
        // Issue #2119 AC3: the image levers render only when the session
        // context actually carries images — the transcript is the signal.
        hasImages: messagesContainImages(_agent.state.messages),
      );
      // Issue #2117: the banner obeys the console log dial — the queued
      // variant is warn-level (still visible at the default), the
      // passive `info:` variant is info-level (hidden at the interactive
      // default, shown from `--log-level info` or `/log info`; headless
      // defaults stay unfiltered). Panel/busy pushes above are unaffected.
      final level = queued > 0 ? LogLevel.warn : LogLevel.info;
      if (_consolePasses(level, LogCategory.lifecycle)) {
        io.writeln(queued > 0 ? tuiWarning(line) : _style.dim(line));
      }
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
      // The persistence truth rides the ONE clause builder (issue #2249
      // AC4): saved keeps the #437 copy byte-identical, a failed or
      // still-unresolved append reads NOT saved with the raw fs error.
      var saved = 0;
      var unsaved = 0;
      Object? firstError;
      for (final entry in _pendingSteering) {
        if (entry.recordId != null) {
          saved++;
        } else {
          unsaved++;
          firstError ??= entry.persistError;
        }
      }
      io.writeln(
        tuiWarning(
          steeringStallWarningLine(
            saved: saved,
            unsaved: unsaved,
            error: firstError,
          ),
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
    // NOT _abortRequested=true: that drops the queued steering (the
    // settle's loud-drop branch), which would lose exactly the message
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
        _steeringWakeRunning ||
        _sessionLoadsInFlight > 0) {
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
  /// mid-run input takes (panel join + agent steer queue). With the
  /// intake spill guard installed (issue #1760) the returned future must
  /// be awaited before queue-state assertions — the guard's spill write
  /// is async.
  @visibleForTesting
  Future<void> steerForTest(String text) => _steerResolved(text);

  /// Test seam: steers with clipboard chips through the same
  /// `_steerResolved` path a busy composer submit takes (issue #276).
  @visibleForTesting
  Future<void> steerImagesForTest(
    String text,
    List<TuiImageAttachment> images,
  ) => _steerResolved(text, images: images);

  /// Test seam: the run-settle steering resolution (leftover run or loud
  /// drop) so driver tests can exercise both branches deterministically
  /// instead of racing the real settle window.
  @visibleForTesting
  Future<void> settleLeftoverSteeringForTest() => _settleLeftoverSteering();

  /// Test seam: the wedge watchdog (a pending steering panel flips to
  /// `dead` only when the run's heartbeat is stale) so tests don't wait
  /// for the 2s inbox tick (issue #437 E4).
  @visibleForTesting
  void checkPendingSteeringHealthForTest() => _checkPendingSteeringHealth();

  /// Test seam: the stall banner text for a given shape (issue #2119 AC3
  /// variant coverage — the integration harness cannot put image blocks
  /// into the live transcript, so the has-images side is pinned here).
  @visibleForTesting
  String stallBannerLineForTest({
    int queued = 0,
    bool budgetOffer = false,
    bool hasImages = true,
  }) => _stallBannerLine(
    queued: queued,
    budgetOffer: budgetOffer,
    hasImages: hasImages,
  );

  /// Test seam: the shared stall classifier state (issue #514 AC1) —
  /// `true` iff the watchdog currently pushes the run as stalled.
  @visibleForTesting
  bool get runStalledForTest => _runStalledPushed;

  /// Test seam: the `/restart` affordance so tests don't route through
  /// the slash-command parser.
  @visibleForTesting
  void restartRunForTest() => _restartRun();
}
