// Provider-phase steering interrupt (issue #1923 AC1): while the loop
// awaits a provider stream, steering had NO delivery path — the message
// queued invisibly until the submit returned (the #1916 857s stall, the
// owner's 2026-10-26 screenshot). This module makes the provider phase
// mirror the tool phase's yield: a steering arrival (in-process queue
// notification or the external probe) while the attempt is UNPRODUCTIVE
// cancels the attempt via a linked CancelToken, drains the pending
// steering, injects it into the rebuilt request, and resubmits.
//
// Unproductive (issue open question 1, card defaults):
// - zero bytes received → interrupt IMMEDIATELY on arrival;
// - bytes received → interrupt only once the stream has been silent for
//   `AgentLoopConfig.steeringStallWindow` (the existing stall window,
//   margin'd below the run-idle watchdog so the interrupt wins the race).
// A stream that keeps producing bytes is NEVER cancelled — steering keeps
// today's next-boundary semantics for healthy in-flight responses.
//
// A steering-cancel does NOT consume a retry attempt (open question 2
// default): the [SteeringInterruptFire] reason is deliberately outside the
// transient-retry ladder's resume class, and the loop's resubmit below is
// a plain `continue`, touching no retry/heal budget.

part of 'agent_loop.dart';

/// Per-event progress of one provider attempt: whether ANY event arrived
/// ("bytes") and when the last one landed. The steering-interrupt watch
/// reads it; `_consumeResponseStream` marks it.
final class _StreamProgress {
  DateTime _lastActivity = DateTime.now();

  /// Whether the attempt received at least one stream event.
  bool sawBytes = false;

  void mark() {
    sawBytes = true;
    _lastActivity = DateTime.now();
  }

  Duration get silence => DateTime.now().difference(_lastActivity);
}

/// The per-attempt steering-interrupt supervisor: listens for steering
/// arrivals and fires the interrupt by cancelling the RUN token's source
/// with [SteeringInterruptFire] when the attempt looks unproductive. The
/// run token stays THE token the provider call holds — the transient
/// ladder's watchdog-replay/reset-in-place contract (#1126/#1132/gh-1308)
/// is untouched, and a steering cancel never reaches its replay classes
/// (the resolver below owns it). One instance per attempt; [dispose]
/// always runs.
final class _SteeringYieldWatch {
  _SteeringYieldWatch({required this.config, this._runSource})
    : progress = _StreamProgress();

  final AgentLoopConfig config;
  final CancelTokenSource? _runSource;
  final _StreamProgress progress;

  StreamSubscription<void>? _sub;
  Timer? _probeTimer;
  Timer? _stallTimer;
  Timer? _decisionTimer;
  var _stallWatchArmed = false;

  /// Whether [dispose] ran. A disposed watch must NEVER touch the run
  /// token again: the token is the RUN's, it outlives this attempt's
  /// watch, and a late fire (an in-flight probe await, a deferred
  /// decision) would spuriously cancel the NEXT attempt or a tool phase
  /// (bot r1 blocker 2). Every fire path re-checks this.
  var _disposed = false;

  /// The run token the interrupt lands on (null source = a bare loop run
  /// without a source: the watch stays inert — the pre-#1923 semantics).
  CancelToken? get runToken => _runSource?.token;

  /// Whether the run latch was cancelled at all (any reason).
  bool get fired => runToken?.isCancelled ?? false;

  /// Whether the cancel was a STEERING interrupt (not a user abort or a
  /// watchdog fire riding the same token).
  bool get firedForSteering => runToken?.cancelReason is SteeringInterruptFire;

  /// Seconds of stall recorded at fire time (the AC4 notice's `Ns`).
  int get firedStallSeconds {
    final reason = runToken?.cancelReason;
    if (reason is! SteeringInterruptFire) return 0;
    return reason.duration?.inSeconds ?? 0;
  }

  /// Starts the steering listeners: the in-process arrival stream, plus
  /// the same 2s external probe cadence the tool phase uses.
  void start() {
    _sub = config.steeringNotifications?.listen((_) => _onSteeringSignal());
    final probe = config.hasPendingSteering;
    if (probe != null) {
      _probeTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        try {
          if (await probe()) _onSteeringSignal();
        } on Object {
          // A probe failure must never break the attempt.
        }
      });
    }
  }

  /// A steering arrival: decide immediately — zero bytes means the submit
  /// never produced anything, so interrupt now; an already-silent stream
  /// (silence past the stall window) is unproductive, interrupt now;
  /// otherwise arm the one-shot stall watch that fires if the stream goes
  /// quiet for the window. A productive stream is never cancelled here.
  void _onSteeringSignal() {
    if (_disposed || fired) return;
    // The decision defers one macrotask: a stream whose first events are
    // already buffered in the response controller but not yet consumed
    // (events pushed and the steer landing in the same synchronous block
    // — deterministic fakes do exactly this) would otherwise read as
    // zero-byte. `await for` drains its microtasks before the deferred
    // timer runs, so buffered bytes count; a genuinely stalled connect
    // still reads zero-byte here. Cost: well under a millisecond of the
    // AC1 latency budget.
    _decisionTimer = Timer(Duration.zero, () {
      if (_disposed || fired) return;
      if (!progress.sawBytes) {
        _fire('steering arrived with no provider bytes yet');
        return;
      }
      final window = config.steeringStallWindow;
      if (window <= Duration.zero) return; // mid-stream interrupts disabled
      if (progress.silence >= window) {
        _fire('steering arrived on a stream silent for the stall window');
        return;
      }
      _armStallWatch();
    });
  }

  /// One-shot re-arming stall timer: fires the interrupt exactly when
  /// silence reaches the window; a byte in the meantime re-arms for the
  /// remaining budget. Exact timing, no polling.
  void _armStallWatch() {
    if (_stallWatchArmed) return;
    _stallWatchArmed = true;
    _rearmStallTimer();
  }

  void _rearmStallTimer() {
    _stallTimer?.cancel();
    final window = config.steeringStallWindow;
    final remaining = window - progress.silence;
    _stallTimer = Timer(
      remaining <= Duration.zero ? Duration.zero : remaining,
      () {
        if (fired) return;
        if (progress.silence >= window) {
          _fire('stream silent for the stall window after steering arrived');
        } else {
          _rearmStallTimer();
        }
      },
    );
  }

  void _fire(String detail) {
    final source = _runSource;
    // The disposed guard is load-bearing (bot r1 blocker 2): every path
    // here may resume after [dispose] (the probe's async await, a
    // decision timer that already left the gate) and the run token
    // outlives this watch.
    if (_disposed) return;
    if (source == null || source.token.isCancelled) return;
    _stallTimer?.cancel();
    source.cancel(
      SteeringInterruptFire(
        'steering interrupt: $detail '
        '(stalled ${progress.silence.inSeconds}s, '
        '${progress.sawBytes ? 'mid-stream' : 'zero bytes'})',
        progress.silence,
      ),
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
    _probeTimer?.cancel();
    _stallTimer?.cancel();
    _decisionTimer?.cancel();
  }
}

/// The steering-interrupt resubmit: reports the AC4 notice, drains the
/// pending steering into the transcript (the same truthful
/// MessageStart/End pair the boundary injection emits — gh-1577) and hands
/// back the context the rebuilt request rides. The caller `continue`s the
/// attempt loop — no retry budget is touched.
Future<Context> _steeringInterruptResubmit(
  List<Message> steering,
  Context context,
  AgentLoopConfig config,
  AgentEventSink emit,
  List<Message> newMessages,
  int stallSeconds,
) async {
  config.steeringInterruptNotice?.call(
    'steering queued — provider stalled $stallSeconds seconds, '
    'interrupting to deliver',
  );
  await _injectPendingMessages(steering, emit, context, newMessages);
  config.steeringInterruptNotice?.call(
    'steering delivered into rebuilt request',
  );
  return context;
}

/// What the attempt loop does with one finished attempt: return
/// [turn] (the run path takes it), or adopt [context] as the new loop
/// context and RESUBMIT (a steering interrupt — never a retry), or adopt
/// the retry instruction's context and flags (a heal consumed its
/// one-shot). Extracted so the loop body stays under the CRAP ratchet.
///
/// The steering-interrupt path also RE-ARMS the run latch
/// (`CancelToken.reset`): the interrupt cancelled the run token with
/// [SteeringInterruptFire] to abort the unproductive submit, and the
/// resubmit is a fresh attempt of the SAME run — the latch re-opens in
/// place exactly like the ladder's watchdog replays (#1132 discipline),
/// keeping later user aborts and watchdog fires live. A cancel landing in
/// the microtask-scale reset window is dropped (the `reset` contract's
/// accepted sharp edge — the same class #1121 accepted for the watchdog
/// resume).
Future<_AttemptOutcome> _resolveAttemptOutcome({
  required _AttemptResult result,
  required _SteeringYieldWatch steer,
  required CancelToken? cancelToken,
  required Future<List<Message>> Function() drainSteering,
  required Context context,
  required AgentLoopConfig config,
  required AgentEventSink emit,
  required List<Message> newMessages,
}) async {
  switch (result) {
    case _AttemptReturn():
      if (steer.firedForSteering) {
        final steering = await drainSteering();
        if (steering.isNotEmpty) {
          // Re-arm the latch BEFORE the resubmit (see the doc): the
          // interrupt abort owned the cancel; the fresh attempt rides a
          // live token again.
          cancelToken?.reset();
          return _AttemptOutcome(
            context: await _steeringInterruptResubmit(
              steering,
              context,
              config,
              emit,
              newMessages,
              steer.firedStallSeconds,
            ),
          );
        }
        // Cap exhausted (or a lost race): the aborted turn ends the run
        // and the undelivered steering stays queued for the next run.
      }
      return _AttemptOutcome(turn: result.turn);
    case _AttemptRetry():
      return _AttemptOutcome(
        context: result.nextContext,
        reliefUsed: result.reliefUsed,
        pairingHealed: result.pairingHealed,
      );
  }
}

/// The attempt loop's next action — see [_resolveAttemptOutcome]. `turn`
/// non-null ends the streamed response; otherwise [context] is adopted
/// (resubmit or heal retry) with the cross-attempt one-shot flags.
class _AttemptOutcome {
  const _AttemptOutcome({
    this.turn,
    this.context,
    this.reliefUsed,
    this.pairingHealed,
  });

  final (AssistantMessage, Context)? turn;
  final Context? context;
  final bool? reliefUsed;
  final bool? pairingHealed;
}

// The streamed-response driver the interrupt watches own: moved here
// with the steering-yield work (issue #1923) so agent_loop.dart stays
// under the 2800-line gate — same library (a `part of`), private
// access unchanged.
/// Retries a degenerate-empty completion with the same context (bounded by
/// `config.maxEmptyRetries`; a blank answer never ends a run on the first
/// try). The retried messages stay in the transcript (truthful record) and
/// the gh-1577 hiccup policy lives in `agent_loop_empty_completion.dart`.
Future<(AssistantMessage, Context)> _retryDegenerateEmpty(
  AssistantMessage message,
  Context context,
  AgentLoopConfig config,
  AgentEventSink emit,
  StreamFunction streamFunction,
  CancelToken? cancelToken, {
  required List<Message> newMessages,
  required Future<List<Message>> Function() drainSteering,
  CancelTokenSource? cancelTokenSource,
}) => retryEmptyCompletion(
  message,
  context,
  config,
  emit,
  streamFunction,
  cancelToken,
  newMessages: newMessages,
  drainSteering: drainSteering,
  cancelTokenSource: cancelTokenSource,
);

/// Streams one assistant response from the provider, emitting message
/// lifecycle events and keeping the partial message in [context.messages]
/// up to date (partial-first). Port of pi's `streamAssistantResponse`.
///
/// Issue #1923 AC1: each attempt runs under a steering-interrupt watch —
/// a steering arrival while the attempt is UNPRODUCTIVE (zero bytes, or
/// silent past `config.steeringStallWindow`) cancels it, drains the
/// pending steering via [drainSteering], injects it into the rebuilt
/// request (preserving the partial per existing abort semantics), and
/// resubmits WITHOUT consuming a retry attempt. Productive streams are
/// never cancelled — steering keeps its next-boundary semantics.
Future<(AssistantMessage, Context)> _streamAssistantResponse(
  Context context,
  AgentLoopConfig config,
  AgentEventSink emit,
  StreamFunction streamFunction,
  CancelToken? cancelToken, {
  required List<Message> newMessages,
  required Future<List<Message>> Function() drainSteering,
  CancelTokenSource? cancelTokenSource,
}) async {
  var reliefUsed = false;
  var pairingHealed = false;
  // gh-1680: one-shot message-cap heal state; when armed, the next
  // rebuilt payload coalesces toward its target.
  final capState = _CapHealState();
  // Issue #1750: one-shot image-cap heal state; the learned cap rides
  // the retried request build and latches for the run.
  final imageCapState = _ImageCapHealState();
  // Issue #862: drain the armed corrective note once per streamed response
  // (not per built context) so a mid-turn retry re-attaches it.
  final misuseNote = config.toolMisuseBreaker?.drainPendingNote();
  // Hardening over pi: short-circuit an already-cancelled token instead of
  // relying on the provider to surface the abort as an error event.
  if (_isCancelRequested(cancelToken)) {
    return await _abortedTurn(context, config, emit);
  }
  for (var attempt = 0; ; attempt++) {
    final steer = _SteeringYieldWatch(
      config: config,
      runSource: cancelTokenSource,
    );
    final progress = steer.progress;
    steer.start();
    _AttemptResult result;
    try {
      result = await _streamAttempt(
        context,
        config,
        emit,
        streamFunction,
        cancelToken,
        misuseNote: misuseNote,
        capState: capState,
        imageCapState: imageCapState,
        reliefUsed: reliefUsed,
        pairingHealed: pairingHealed,
        progress: progress,
      );
    } finally {
      await steer.dispose();
    }
    final outcome = await _resolveAttemptOutcome(
      result: result,
      steer: steer,
      cancelToken: cancelToken,
      drainSteering: drainSteering,
      context: context,
      config: config,
      emit: emit,
      newMessages: newMessages,
    );
    if (outcome.turn != null) return outcome.turn!;
    // Adopt and loop again: a steering-interrupt resubmit (deliberately
    // NOT counted as a retry attempt — issue #1923 open question 2
    // default: user-driven, not a failure) or a heal's one-shot retry.
    context = outcome.context!;
    if (outcome.reliefUsed != null) reliefUsed = outcome.reliefUsed!;
    if (outcome.pairingHealed != null) {
      pairingHealed = outcome.pairingHealed!;
    }
  }
}
