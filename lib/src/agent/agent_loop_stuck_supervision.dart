/// The stuck-call supervision runner (gh-1054): liveness heartbeats,
/// the cancel/retry/background-convert stage machine, and the escalation.
/// Split out of `agent_loop.dart` to keep it under the repo's
/// 2800-line size gate. Same library (a `part of`), so the helpers keep
/// their access to the loop's private members.
part of 'agent_loop.dart';

/// The supervised execution runner: invoke the tool executor for the call
/// under the given cancel token; the optional observer sees every partial
/// result (for the heartbeat's captured-output size and the escalation's
/// partial-output pointer) while the loop's own update emitter stays wired.
typedef _SupervisedRun =
    Future<ToolExecutionResult> Function(
      CancelToken? token, [
      void Function(ToolExecutionResult partialResult)? observe,
    ]);

/// One supervised execution attempt's outcome.
final class _SupervisedAttempt {
  _SupervisedAttempt.completed(this.result, {required this.afterStuck})
    : error = null,
      hung = false,
      cancelledBySupervisor = false,
      elapsed = Duration.zero,
      outputBytes = 0,
      partialText = '';

  _SupervisedAttempt.failed(
    this.error, {
    required this.cancelledBySupervisor,
    this.elapsed = Duration.zero,
    this.outputBytes = 0,
    this.partialText = '',
  }) : result = null,
       hung = false,
       afterStuck = false;

  _SupervisedAttempt.hung(this.elapsed, this.outputBytes, this.partialText)
    : result = null,
      error = null,
      hung = true,
      afterStuck = false,
      cancelledBySupervisor = false;

  final ToolExecutionResult? result;
  final Object? error;

  /// True when the attempt was abandoned at its threshold (the executor
  /// did not answer within the cancel grace).
  final bool hung;

  /// True when the supervisor's own threshold cancel fired during the
  /// attempt. An error landing after it is that cancel's consequence
  /// (bash's `Command aborted` once the job registry kills the process, a
  /// token-obeying executor's throw) — not a fresh failure — and it
  /// follows the same stage logic as a hang instead of short-circuiting
  /// the follow-up.
  final bool cancelledBySupervisor;

  /// True when the attempt completed only after the stuck threshold had
  /// fired (a yield-converted background hand-back lands here).
  final bool afterStuck;

  final Duration elapsed;
  final int outputBytes;
  final String partialText;
}

/// The declared shell timeout of a tool call's arguments (`bash`'s
/// `timeout` seconds), or null when the arguments declare none. The
/// stuck threshold is derived from it (2× declared, floored) so a
/// legitimately long declared-timeout call is never pestered early.
/// Whether a completed result is the bash soft-yield hand-back (the
/// command moved to a background job) rather than a genuine completion —
/// anchored on the hand-back's deterministic opening sentence
/// ([stuckBackgroundHandbackSentence]): the marker word alone shows up in
/// ordinary output (an echo, a log tail, a grep over this repo), and a
/// retry that merely QUOTES the hand-back text must not be audited as a
/// conversion (gh-1054 review round 2).
bool _isBackgroundHandback(ToolExecutionResult result) =>
    _resultOutputSize(result) > 0 &&
    _resultPartialText(
      result,
      max: 1 << 20,
    ).startsWith(stuckBackgroundHandbackSentence);

Duration? _declaredTimeoutOf(Map<String, dynamic> args, {String? toolName}) {
  // Only bash declares a seconds-based `timeout` arg. A stray `timeout`
  // key on another tool (or a tool that measures milliseconds) must not
  // inflate its stuck threshold to factor × arg and silently unsupervise
  // it — those calls supervise at the floor (gh-1054 review).
  if (toolName != 'bash') return null;
  final value = args['timeout'];
  if (value is! num || !value.isFinite || value <= 0) return null;
  return Duration(milliseconds: (value * 1000).round());
}

/// The captured-output size of a (partial) result: the total text length
/// across its text blocks.
int _resultOutputSize(ToolExecutionResult result) {
  var size = 0;
  for (final block in result.content) {
    if (block is TextContent) size += block.text.length;
  }
  return size;
}

/// The tail of a (partial) result's text, for an escalation's
/// partial-output pointer.
String _resultPartialText(ToolExecutionResult result, {int max = 300}) {
  final text = [
    for (final block in result.content)
      if (block is TextContent) block.text,
  ].join('\n').trim();
  if (text.length <= max) return text;
  return '…${text.substring(text.length - max)}';
}

/// Human elapsed for marked results (`4m05s`).
String _formatElapsed(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  if (minutes == 0) return '${duration.inMilliseconds / 1000}s';
  return '${minutes}m${seconds.toString().padLeft(2, '0')}s';
}

/// Prepends the stuck-call marks to a result's first text block.
ToolExecutionResult _prefixMarks(
  List<String> marks,
  ToolExecutionResult result,
) {
  if (marks.isEmpty) return result;
  final prefix = '${marks.join('\n')}\n';
  for (var i = 0; i < result.content.length; i++) {
    final block = result.content[i];
    if (block is TextContent) {
      final content = List<ContentBlock>.of(result.content);
      content[i] = TextContent(text: '$prefix${block.text}');
      return ToolExecutionResult(content: content, terminate: result.terminate);
    }
  }
  return ToolExecutionResult(
    content: [
      TextContent(text: prefix),
      ...result.content,
    ],
    terminate: result.terminate,
  );
}

/// Stuck-call supervision (gh-1054): runs [run] under a watchdog.
///
/// Per attempt: a per-call cancel token (linked from the run token) and a
/// per-call yield token (shadowing the phase's, linked from it) so the
/// follow-up acts on THIS call only. Heartbeats fire every
/// [StuckToolConfig.heartbeatInterval] once the attempt is past half its
/// threshold. At the threshold the follow-up runs:
///
/// - attempt 1 hung → the call is cancelled (bounded by the cancel grace —
///   a wedged executor cannot block the follow-up) and retried once, with
///   a `[stuck-call]` mark on the eventual result;
/// - attempt 2 hung → its YIELD token is cancelled: a yield-aware tool
///   (bash over a jobs-capable env) hands the call back as a background
///   job and the turn continues with the job id + log path; a tool that
///   cannot be recovered escalates — a session-visible stuck event naming
///   the call, its total duration, and the partial output — and the
///   result is a marked error. Never die silently.
///
/// Advisory mode ([StuckFollowUpMode.advisory]) stops after the advisory
/// stuck event: nothing is ever cancelled (interactive sessions with a
/// human present).
/// The follow-up stage an attempt is supervised under: attempt 1 is
/// cancelled and retried once; from attempt 2 on a further hang converts
/// to a background job before escalating.
StuckFollowUpAction _stageForAttempt(int attempt) => attempt == 1
    ? StuckFollowUpAction.cancelRetry
    : StuckFollowUpAction.backgroundConvert;

/// The mark a completed retry carries to disclose the supervision
/// history — `null` when attempt 1 finished on its own (nothing to
/// disclose). The mark must tell the truth about what happened: a
/// soft-yield hand-back names the conversion; a retry that completed its
/// own work (the yield token ignored, the finish inside the grace
/// window) is still just the marked retry (gh-1054 review).
String? _completedStuckMark({
  required int attempt,
  required _SupervisedAttempt outcome,
  required ToolCall toolCall,
  required Duration threshold,
}) {
  if (attempt <= 1) return null;
  if (outcome.afterStuck && _isBackgroundHandback(outcome.result!)) {
    return '[stuck-call] the retry of ${toolCall.name} also exceeded '
        '${_formatElapsed(threshold)} and was converted to a background '
        'job (the process was NOT killed); the turn continues.';
  }
  return '[stuck-call] ${toolCall.name} was cancelled after '
      '${_formatElapsed(threshold)} with no completion and retried '
      'once (this result is the marked retry).';
}

/// The escalation a hung retry that recovery could not save ends the turn
/// with: a session-visible record, then a plain [StateError] (an
/// operational failure — see the breaker note in
/// [_finalizeExecutedToolCall]).
Future<Never> _escalateStuckCall({
  required AgentEventSink emit,
  required ToolCall toolCall,
  required Duration totalElapsed,
  required _SupervisedAttempt outcome,
  required int lastOutputBytes,
  required String lastPartialText,
}) async {
  final partialPointer = lastOutputBytes > 0
      ? ' Partial output (~$lastOutputBytes chars) captured: '
            '"$lastPartialText"'
      : ' No output was captured.';
  final cause = outcome.error == null
      ? ''
      : ' The retry failed with: ${outcome.error}';
  await emit(
    ToolCallStuckEvent(
      toolCallId: toolCall.id,
      toolName: toolCall.name,
      args: toolCall.arguments,
      elapsed: totalElapsed,
      action: StuckFollowUpAction.escalate,
      detail:
          '${toolCall.name} could not be recovered after '
          '${_formatElapsed(totalElapsed)} '
          '(cancel + retry + background conversion all failed).'
          '$cause$partialPointer',
      timestamp: DateTime.now(),
    ),
  );
  throw StateError(
    '[stuck-call escalation] ${toolCall.name} could not be recovered '
    'after ${_formatElapsed(totalElapsed)} (cancel + retry + '
    'background conversion all failed).'
    '$cause$partialPointer',
  );
}

/// Advance one stage of the hang follow-up for a confirmed-uncompleted
/// attempt: cancelRetry gets its (now truthful) record — the stage has
/// actually advanced, so a call that completes during the cancel grace
/// never leaves a stale "cancelling and retrying once" record behind
/// (gh-1054 review); backgroundConvert escalates. Advisory hangs are
/// never abandoned and escalate is never consumed as a stage. Appends the
/// stage's ledger mark for [marks].
Future<void> _advanceStuckStage({
  required StuckFollowUpAction stage,
  required ToolCall toolCall,
  required _SupervisedAttempt outcome,
  required Duration totalElapsed,
  required AgentEventSink emit,
  required List<String> marks,
}) async {
  switch (stage) {
    case StuckFollowUpAction.cancelRetry:
      await emit(
        ToolCallStuckEvent(
          toolCallId: toolCall.id,
          toolName: toolCall.name,
          args: toolCall.arguments,
          elapsed: totalElapsed,
          action: StuckFollowUpAction.cancelRetry,
          detail:
              '${toolCall.name} was cancelled after '
              '${_formatElapsed(outcome.elapsed)} with no completion and '
              'is being retried once',
          timestamp: DateTime.now(),
        ),
      );
      marks.add(
        '[stuck-call] ${toolCall.name} was cancelled after '
        '${_formatElapsed(outcome.elapsed)} with no completion and is '
        'being retried once.',
      );
    case StuckFollowUpAction.backgroundConvert:
      // The yield cancel already fired inside the attempt and the
      // executor did not answer within the cancel grace: recovery
      // failed — escalate, session-visibly.
      await _escalateStuckCall(
        emit: emit,
        toolCall: toolCall,
        totalElapsed: totalElapsed,
        outcome: outcome,
        lastOutputBytes: outcome.outputBytes,
        lastPartialText: outcome.partialText,
      );
    case StuckFollowUpAction.advisory:
    case StuckFollowUpAction.escalate:
      break;
  }
}

/// Whether the background-convert initiation record must be emitted for a
/// resolved attempt: only when the stage actually advances — the attempt
/// was abandoned, or the executor answered the yield cancel by handing the
/// job back. A retry that finished its own work inside the grace gets no
/// record (nothing was converted) — mirroring the cancel_retry rationale
/// (gh-1054 review round 2).
bool _recordsBackgroundConvert({
  required StuckFollowUpAction stage,
  required _SupervisedAttempt outcome,
}) {
  if (stage != StuckFollowUpAction.backgroundConvert) return false;
  if (outcome.hung) return true;
  return outcome.afterStuck &&
      outcome.result != null &&
      _isBackgroundHandback(outcome.result!);
}

/// The deferred background-convert initiation record — emitted only once
/// the stage actually advances (see [_recordsBackgroundConvert]).
ToolCallStuckEvent _backgroundConvertRecord({
  required ToolCall toolCall,
  required _SupervisedAttempt outcome,
  required Duration threshold,
}) {
  return ToolCallStuckEvent(
    toolCallId: toolCall.id,
    toolName: toolCall.name,
    args: toolCall.arguments,
    elapsed: outcome.elapsed,
    action: StuckFollowUpAction.backgroundConvert,
    detail:
        '${toolCall.name} exceeded ${_formatElapsed(threshold)}; '
        'moving the retry to a background job',
    timestamp: DateTime.now(),
  );
}

Future<ToolExecutionResult> _superviseToolExecution({
  required ToolCall toolCall,
  required _SupervisedRun run,
  required CancelToken? runToken,
  required StuckToolConfig stuck,
  required AgentEventSink emit,
}) async {
  final declared = _declaredTimeoutOf(
    toolCall.arguments,
    toolName: toolCall.name,
  );
  final threshold = stuck.stuckThreshold(declared);
  final heartbeatStart = stuck.heartbeatStart(declared);
  final marks = <String>[];
  var attempt = 0;
  var totalElapsed = Duration.zero;

  while (true) {
    attempt++;
    final stage = _stageForAttempt(attempt);
    final outcome = await _supervisedAttempt(
      toolCall: toolCall,
      run: run,
      runToken: runToken,
      stuck: stuck,
      emit: emit,
      attempt: attempt,
      threshold: threshold,
      heartbeatStart: heartbeatStart,
      stageIfHung: stage,
    );
    totalElapsed += outcome.elapsed;

    // The run is over (user abort / host teardown) — no follow-up stages
    // may outlive it; the loop's abort handling owns the result.
    if (runToken != null && runToken.isCancelled) {
      throw CancelledException(runToken.cancelReason);
    }
    if (outcome.error != null) {
      // A failure before the threshold is the executor's own — rethrow.
      // A failure after the supervisor's cancel is that cancel's
      // consequence (bash's `Command aborted` once the job registry kills
      // the process, a token-obeying executor's throw): it follows the
      // same stage logic as a hang below, so the follow-up (retry /
      // background conversion / escalation) still runs.
      if (!outcome.cancelledBySupervisor) throw outcome.error!;
    }
    if (outcome.error == null && !outcome.hung) {
      final mark = _completedStuckMark(
        attempt: attempt,
        outcome: outcome,
        toolCall: toolCall,
        threshold: threshold,
      );
      if (mark != null) marks.add(mark);
      if (_recordsBackgroundConvert(stage: stage, outcome: outcome)) {
        // The stage actually advanced (the executor handed the job back):
        // the initiation record is only now truthful.
        await emit(
          _backgroundConvertRecord(
            toolCall: toolCall,
            outcome: outcome,
            threshold: threshold,
          ),
        );
      }
      return _prefixMarks(marks, outcome.result!);
    }

    if (_recordsBackgroundConvert(stage: stage, outcome: outcome)) {
      // The stage actually advanced (the attempt was abandoned): the
      // initiation record is only now truthful.
      await emit(
        _backgroundConvertRecord(
          toolCall: toolCall,
          outcome: outcome,
          threshold: threshold,
        ),
      );
    }

    await _advanceStuckStage(
      stage: stage,
      toolCall: toolCall,
      outcome: outcome,
      totalElapsed: totalElapsed,
      emit: emit,
      marks: marks,
    );
  }
}

/// One supervised attempt: run the executor under per-call cancel/yield
/// tokens with the heartbeat + stuck timers. See [_superviseToolExecution].
/// Mutable state one supervised attempt tracks across its timers and its
/// final classification (gh-1054). Grouped into one object so the stuck
/// timer's callback can be a top-level function under the CRAP ratchet
/// (12.0) instead of a closure whose branches fold into
/// [_supervisedAttempt].
final class _AttemptClock {
  _AttemptClock() : stopwatch = Stopwatch()..start();

  final Stopwatch stopwatch;

  /// Unblocks the attempt's wait once the abandoned call has had its
  /// cancel grace; completed immediately at zero grace.
  final Completer<void> graceGate = Completer<void>();
  Timer? heartbeatTimer;
  Timer? stuckTimer;
  Timer? graceTimer;

  /// Cleared when the attempt is over: the timers must then become
  /// no-ops (no records may outlive the run).
  bool alive = true;
  bool stuckFired = false;

  // Distinct from [stuckFired]: "the threshold fired" is not "we
  // cancelled". In advisory mode nothing is ever cancelled, so an error
  // landing after the advisory must propagate as the executor's own
  // failure — never re-executed (gh-1054 review, blocking).
  bool supervisorCancelled = false;
  int outputBytes = 0;
  String partialText = '';

  void disarm() {
    heartbeatTimer?.cancel();
    stuckTimer?.cancel();
    graceTimer?.cancel();
  }
}

/// The stuck threshold's callback for one supervised attempt: emit the
/// mode's record (advisory notice, or the background-convert initiation
/// record), then act — cancel+retry, or yield the retry into a background
/// job — and open the cancel grace window. The cancel_retry record waits
/// until the stage actually advances (in [_superviseToolExecution]) so a
/// call that completes during the grace never leaves a "cancelling and
/// retrying once" record behind (gh-1054 review).
void _fireStuckThreshold({
  required _AttemptClock clock,
  required ToolCall toolCall,
  required StuckToolConfig stuck,
  required StuckFollowUpAction stageIfHung,
  required void Function(AgentEvent event) enqueue,
  required CancelTokenSource callSource,
  required CancelTokenSource yieldSource,
}) {
  if (!clock.alive) return;
  clock.stuckFired = true;
  if (stuck.followUp == StuckFollowUpMode.advisory) {
    enqueue(
      ToolCallStuckEvent(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        args: toolCall.arguments,
        elapsed: clock.stopwatch.elapsed,
        action: StuckFollowUpAction.advisory,
        detail:
            '${toolCall.name} has been running for '
            '${_formatElapsed(clock.stopwatch.elapsed)} (no action taken in '
            'advisory mode)',
        timestamp: DateTime.now(),
      ),
    );
    return;
  }
  // The background-convert record no longer fires here: it waits until
  // the stage actually advances — a retry that ignores the yield token
  // and finishes its own work inside the grace must not leave an
  // initiated-conversion record behind a plain marked result (gh-1054
  // review round 2, mirroring the cancel_retry rationale).
  switch (stageIfHung) {
    case StuckFollowUpAction.cancelRetry:
      clock.supervisorCancelled = true;
      callSource.cancel(
        StuckCallFollowUp('stuck call cancelled after exceeding threshold'),
      );
    case StuckFollowUpAction.backgroundConvert:
      clock.supervisorCancelled = true;
      yieldSource.cancel(
        StuckCallFollowUp('stuck retry converted to a background job'),
      );
    case StuckFollowUpAction.advisory || StuckFollowUpAction.escalate:
      break;
  }
  if (clock.graceGate.isCompleted) return;
  if (stuck.cancelGrace > Duration.zero) {
    clock.graceTimer = Timer(stuck.cancelGrace, clock.graceGate.complete);
  } else {
    clock.graceGate.complete();
  }
}

Future<_SupervisedAttempt> _supervisedAttempt({
  required ToolCall toolCall,
  required _SupervisedRun run,
  required CancelToken? runToken,
  required StuckToolConfig stuck,
  required AgentEventSink emit,
  required int attempt,
  required Duration threshold,
  required Duration heartbeatStart,
  required StuckFollowUpAction stageIfHung,
}) async {
  final callSource = CancelTokenSource();
  final yieldSource = CancelTokenSource();
  final phaseYield = currentYieldToken();
  // Link: the run token cancels this call; the phase yield (a real steering
  // arrival) yields this call — the follow-up tokens stay call-local.
  if (runToken != null) {
    unawaited(
      runToken.onCancel.then((_) => callSource.cancel(runToken.cancelReason)),
    );
  }
  if (phaseYield != null) {
    unawaited(
      phaseYield.onCancel.then((_) => yieldSource.cancel('steering arrived')),
    );
  }

  final clock = _AttemptClock();

  // Serialized event chain: heartbeats/stuck events never interleave with
  // each other, and the attempt drains the chain before reporting so the
  // records land between tool start and tool end in the ledger.
  var chain = Future<void>.value();
  void enqueue(AgentEvent event) {
    chain = chain
        .then((_) => emit(event))
        .then((_) {})
        .catchError((Object _) {});
  }

  // Observes partial results for the heartbeat's captured-output size and
  // the escalation's partial-output pointer. Forwarding to the loop's
  // update emitter stays inside `run` — this only reads.
  void observe(ToolExecutionResult partial) {
    if (!clock.alive) return;
    clock.outputBytes = _resultOutputSize(partial);
    clock.partialText = _resultPartialText(partial);
  }

  final inner = runZoned<Future<ToolExecutionResult>>(
    () => run(callSource.token, observe),
    zoneValues: {yieldTokenZoneKey: yieldSource.token},
  );

  clock.stuckTimer = Timer(threshold, () {
    _fireStuckThreshold(
      clock: clock,
      toolCall: toolCall,
      stuck: stuck,
      stageIfHung: stageIfHung,
      enqueue: enqueue,
      callSource: callSource,
      yieldSource: yieldSource,
    );
  });
  clock.heartbeatTimer = Timer.periodic(stuck.heartbeatInterval, (_) {
    if (!clock.alive) return;
    final elapsed = clock.stopwatch.elapsed;
    if (elapsed < heartbeatStart) return;
    enqueue(
      ToolCallHeartbeatEvent(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        args: toolCall.arguments,
        elapsed: elapsed,
        outputBytes: clock.outputBytes,
        attempt: attempt,
        timestamp: DateTime.now(),
      ),
    );
  });
  // The run ending disarms everything and unblocks the wait: no timers may
  // outlive the run (they would pin the host's process at exit).
  if (runToken != null) {
    unawaited(
      runToken.onCancel.then((_) {
        clock.disarm();
        callSource.cancel(runToken.cancelReason);
        if (!clock.graceGate.isCompleted) clock.graceGate.complete();
      }),
    );
  }

  ToolExecutionResult? completedResult;
  Object? completedError;
  final waiter = inner.then<void>(
    (result) => completedResult = result,
    onError: (Object error) {
      completedError = error;
    },
  );
  await Future.any<void>([waiter, clock.graceGate.future]);
  clock.alive = false;
  clock.disarm();
  await chain;
  if (completedError != null) {
    return _SupervisedAttempt.failed(
      completedError!,
      // Only a supervisor that actually issued a cancel reclassifies the
      // error as that cancel's consequence. An advisory-mode error (or any
      // error before the autonomous cancel fired) is the executor's own
      // failure and propagates (gh-1054 review, blocking).
      cancelledBySupervisor: clock.supervisorCancelled,
      elapsed: clock.stopwatch.elapsed,
      outputBytes: clock.outputBytes,
      partialText: clock.partialText,
    );
  }
  if (completedResult != null) {
    return _SupervisedAttempt.completed(
      completedResult!,
      afterStuck: clock.stuckFired,
    );
  }
  return _SupervisedAttempt.hung(
    clock.stopwatch.elapsed,
    clock.outputBytes,
    clock.partialText,
  );
}
