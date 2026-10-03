/// Transient network retry: a [StreamFunction] wrapper that replays a
/// provider call when the failure is a socket-level disconnect — the
/// laptop switches Wi-Fi networks mid-turn and the stream dies with
/// "Connection reset by peer". Policy (user-specified): sleep a fixed
/// delay (5s default), then retry the call.
///
/// Boundary discipline:
/// - Only socket-level failures classify (reset/refused/unreachable/timed
///   out/broken pipe/TLS handshake cut). Rate limits stay with the roles
///   layer ([FallbackStreamFunction]), auth failures stand, context
///   overflow belongs to compaction, and the idle watchdog's own
///   `TimeoutException` wording deliberately does NOT match (that error
///   means "the endpoint went silent", which a retry re-arms anyway).
/// - omp's observable-output guard is kept, keyed on USER-VISIBLE content
///   (issue #964): a stream that already emitted text/tool-call content is
///   never replayed — its failure stands (a retried generation would
///   duplicate it). Thinking-only streams still replay: thinking deltas
///   buffer until the first visible event commits the attempt, so a drop
///   mid-reasoning leaves no trace and the retry regenerates the reasoning
///   (re-billed reasoning accepted, same as any retry). The buffering is
///   withheld from the host until commit/Done — a pure-reasoning phase
///   renders as silence, the price of replayability (forwarding an event
///   is committing it).
/// - Providers-never-throw is preserved: a defensive catch converts a
///   throwing inner stream into an error event.
library;

import 'dart:async';

import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../overflow.dart' show isContextOverflow;
import '../types.dart';

/// Patterns classifying a provider error as a transient network failure:
/// the wordings `dart:io` sockets and the http client produce when the
/// link drops (Wi-Fi switch, VPN flap, gateway restart), plus the gateway
/// 5xx family (issue #290): production gateways fail whole turns with
/// one-off "500: Internal network failure, ..., please try again later"
/// lines. This wrapper is the BASE stream of every host (app main loop,
/// legacy CLI wiring, compaction smol streams) — without the 5xx family a
/// classified-retryable error killed the turn wherever the roles fallback
/// engine was not in front. Mirrors the roles layer's transport set
/// (`model_roles/fallback_stream.dart`); duplicated because providers/ sits
/// below model_roles/.
final _transientNetworkPatterns = [
  RegExp(r'connection reset', caseSensitive: false),
  RegExp(r'socketexception', caseSensitive: false),
  RegExp(r'connection refused', caseSensitive: false),
  RegExp(r'connection timed? ?out', caseSensitive: false),
  RegExp(r'network is unreachable', caseSensitive: false),
  RegExp(r'connection aborted', caseSensitive: false),
  RegExp(r'broken pipe', caseSensitive: false),
  RegExp(r'no route to host', caseSensitive: false),
  RegExp(r'host is (down|unreachable)', caseSensitive: false),
  RegExp(r'software caused connection abort', caseSensitive: false),
  RegExp(r'handshake ?exception', caseSensitive: false),
  // Truncation class (issue #312): a stream that closes without a
  // finish_reason and without content is a cut transport.
  RegExp(r'stream ended without finish_reason'),
  RegExp(r'\b50[0234]\b'),
  RegExp(r'bad gateway', caseSensitive: false),
  RegExp(r'service unavailable', caseSensitive: false),
  RegExp(r'gateway time-?out', caseSensitive: false),
  RegExp(r'internal (server|network) error', caseSensitive: false),
  RegExp(r'internal network failure', caseSensitive: false),
  RegExp(r'please try again later', caseSensitive: false),
];

/// Rate-limit wordings that OWN the failure upstream (the roles rotation
/// policy): never in-place retried here even when the text also carries a
/// transport-ish phrase ("429: rate limit exceeded, please try again
/// later"). Mirrors the roles layer's rate-limit set.
final _rateLimitGuardPatterns = [
  RegExp(r'rate.?limit', caseSensitive: false),
  RegExp(r'too many requests', caseSensitive: false),
  RegExp(r'\b429\b'),
  RegExp(r'quota', caseSensitive: false),
  RegExp(r'resource.{0,30}exhausted', caseSensitive: false),
  RegExp(r'usage.?limit', caseSensitive: false),
  RegExp(r'throttl', caseSensitive: false),
];

/// Whether [message] is a transient failure worth replaying: socket-level
/// drops and gateway 5xx. Rate limits stay with the roles layer (the
/// `FallbackStreamFunction` rotation policy — a 429 may quote "please try
/// again later"), budget/spending exhaustion is terminal and wins over
/// every net below it (issue #926 — a gateway-wrapped budget error quotes
/// "500 … please try again later"), auth failures stand, context overflow
/// belongs to compaction, and the idle watchdog's own `TimeoutException`
/// wording deliberately does NOT match (that error means "the endpoint
/// went silent", which a retry re-arms anyway).
bool isTransientNetworkError(AssistantMessage message) {
  if (message.stopReason != StopReason.error) return false;
  final text = message.errorMessage;
  if (text == null || text.isEmpty) return false;
  if (text.toLowerCase().contains('certificate')) return false;
  if (isContextOverflow(message)) return false;
  if (isBudgetExhaustion(message)) return false;
  if (_rateLimitGuardPatterns.any((pattern) => pattern.hasMatch(text))) {
    return false;
  }
  return _transientNetworkPatterns.any((pattern) => pattern.hasMatch(text));
}

/// The no-silent-retry note: fired before each retry sleep so the user
/// sees "connection lost — retrying in 5s (attempt 2/3)" instead of a
/// mysterious pause. [attempt] is the 1-based attempt that just failed;
/// [maxAttempts] the total budget; [reason] the truncated provider error.
typedef TransientRetryNotice =
    void Function(int attempt, int maxAttempts, Duration delay, String reason);

/// The host-visible retry hook (the CLI prints it + logs to fa.log).
/// Null keeps retries silent. Global like `providerTimeoutsOverride`: the
/// wrap happens deep inside [providerStreamFunction], far from any host io.
TransientRetryNotice? transientRetryNotice;

/// The retry sleep — injectable so tests don't wait real seconds. Returns
/// false when the wait was cancelled (the retry is abandoned).
Future<bool> Function(Duration delay, CancelToken? cancelToken)
transientRetrySleeper = _realTransientSleep;

Future<bool> _realTransientSleep(Duration delay, CancelToken? token) async {
  if (token == null) {
    await Future<void>.delayed(delay);
    return true;
  }
  return Future.any([
    Future<void>.delayed(delay).then((_) => true),
    token.onCancel.then((_) => false),
  ]);
}

/// Wraps [inner] with the transient-network retry policy: up to
/// [maxAttempts] total attempts (1 = no retry), [delay] between them.
StreamFunction transientRetryStreamFunction(
  StreamFunction inner, {
  int maxAttempts = 3,
  Duration delay = const Duration(seconds: 5),
}) {
  assert(maxAttempts >= 1, 'maxAttempts must be at least 1');
  return (Model model, Context context, {CancelToken? cancelToken}) {
    final out = AssistantMessageEventStream();
    unawaited(
      _drive(out, inner, model, context, cancelToken, maxAttempts, delay)
          .catchError((Object error) {
            // Defensive (providers never throw; a fake in tests might).
            out.push(
              ErrorEvent(
                reason: StopReason.error,
                error: AssistantMessage(
                  content: const [],
                  api: model.api,
                  provider: model.provider,
                  model: model.id,
                  usage: Usage.zero,
                  stopReason: StopReason.error,
                  errorMessage: '$error',
                  timestamp: DateTime.now(),
                ),
              ),
            );
          })
          .whenComplete(out.end),
    );
    return out;
  };
}

Future<void> _drive(
  AssistantMessageEventStream out,
  StreamFunction inner,
  Model model,
  Context context,
  CancelToken? cancelToken,
  int maxAttempts,
  Duration delay,
) async {
  final startedAt = DateTime.now();
  final attemptLog = <String>[];
  AssistantMessage? lastFailure;
  // Issue #1126: the resume-from-prefix state. `attemptContext` changes
  // only when a mid-stream abort resumes (the tail request carries the
  // completed prefix as the anchor); the caller's token stays THE token.
  var attemptContext = context;
  final resume = _ResumeState();
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    if (cancelToken?.isCancelled ?? false) {
      _pushAborted(out, model, lastFailure, resume: resume);
      return;
    }
    final outcome = await _runAttempt(
      out,
      inner,
      model,
      attemptContext,
      cancelToken,
      resume: resume.isEmpty ? null : resume,
    );
    switch (outcome) {
      case _Forwarded():
        return;
      case _TransientFailure(:final error):
        lastFailure = error;
        attemptLog.add(_shortReason(error.errorMessage));
        if (attempt >= maxAttempts) {
          // Budget exhausted (issue #290 AC2): the surfaced error carries
          // the retry story — attempts, elapsed, per-attempt outcomes,
          // next-step hint — never the naked provider line as headline.
          // A resume prefix already streamed rides on the terminal
          // (issue #1132 review: the transcript must keep it).
          final terminal = ErrorEvent(
            reason: StopReason.error,
            error: _exhausted(model, attemptLog, startedAt),
          );
          out.push(
            resume.isEmpty ? terminal : _resumeEvent(terminal, resume),
          );
          return;
        }
        transientRetryNotice?.call(
          attempt,
          maxAttempts,
          delay,
          _shortReason(error.errorMessage),
        );
        final survived = await transientRetrySleeper(delay, cancelToken);
        if (!survived) {
          _pushAborted(out, model, lastFailure, resume: resume);
          return;
        }
      case _AbortedPartial(:final snapshot, :final keptBlocks):
        lastFailure = snapshot;
        attemptLog.add(_shortReason(snapshot.errorMessage));
        if (attempt >= maxAttempts) {
          // Budget exhausted mid-chain (issue #1126 AC2): loud death with
          // the full partial content preserved — never an infinite retry.
          // The rewrite prefixes the state from EARLIER attempts only: the
          // snapshot's own blocks already ride inside the error message.
          out.push(
            _resumeEvent(
              ErrorEvent(reason: StopReason.aborted, error: snapshot),
              resume,
            ),
          );
          return;
        }
        resume.absorb(snapshot, keptBlocks);
        transientRetryNotice?.call(
          attempt,
          maxAttempts,
          Duration.zero,
          'mid-stream abort — resuming from '
          '${resume.blocks.length} completed block(s)',
        );
        // The tail request continues from the anchor: the completed prefix
        // rides as the last assistant message (issue #1126 AC1).
        //
        // The anchor stops at the first completed ToolCall, and the state
        // DROPS the dead call(s) from that point on (issue #1132 r2): the
        // dead call never executed (its attempt aborted before a tool
        // phase ran), so the tail regenerates it — and the regenerated
        // twin must be the only copy in the final message, else the loop's
        // tool phase executes the action twice. Hosts saw the dead call
        // stream, but the transcript settles on what actually executes.
        final boundary = resume.blocks
            .indexWhere((block) => block is ToolCall);
        resume.dropFrom(boundary);
        final anchor = _anchorMessage(model, resume.blocks);
        attemptContext = Context(
          systemPrompt: context.systemPrompt,
          messages: [
            ...context.messages,
            ?anchor,
          ],
          tools: context.tools,
        );
        // A watchdog-cancelled token re-arms IN PLACE (issue #1132
        // review): `CancelToken.reset` re-opens the latch on the SAME
        // object every holder shares, so the loop's tool phases, a later
        // `Agent.abort()`, and the tail request itself all observe a live
        // token again. A user cancel (bare reason) never reaches this
        // branch — `_resumableAbort` stands it.
        cancelToken?.reset();
    }
  }
}

/// The first line of a provider error, bounded for notices and the
/// per-attempt log.
String _shortReason(String? errorMessage) {
  final text = errorMessage ?? 'network error';
  final line = text.split('\n').first;
  return line.length <= 120 ? line : '${line.substring(0, 120)}...';
}

/// The exhaustion terminal message (issue #290 AC2): the story is the
/// headline; the raw provider lines ride inside as per-attempt evidence.
AssistantMessage _exhausted(
  Model model,
  List<String> attemptLog,
  DateTime startedAt,
) {
  final elapsed = DateTime.now().difference(startedAt);
  final elapsedText = elapsed.inSeconds < 1 ? '<1s' : '${elapsed.inSeconds}s';
  final log = attemptLog
      .map(
        (line) =>
            line.endsWith('.') ? line.substring(0, line.length - 1) : line,
      )
      .join('; ');
  return AssistantMessage(
    content: const [],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: StopReason.error,
    errorMessage:
        'Provider call failed after ${attemptLog.length} attempt(s) '
        'over $elapsedText — the endpoint kept failing. '
        'Attempts: $log. '
        'Check the provider status or try again later.',
    timestamp: DateTime.now(),
  );
}

/// Pushes a terminal aborted event, reusing the last failure's text when
/// one exists (the transcript shows WHAT was interrupted). With a resume
/// prefix already streamed, the rewrite prefixes the accumulated blocks
/// and usage onto the terminal message (issue #1132 review: the
/// transcript must keep what the host already saw).
void _pushAborted(
  AssistantMessageEventStream out,
  Model model,
  AssistantMessage? lastFailure, {
  _ResumeState? resume,
}) {
  final event = ErrorEvent(
    reason: StopReason.aborted,
    error: AssistantMessage(
      content: const [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.aborted,
      errorMessage: lastFailure?.errorMessage ?? 'Request was aborted',
      timestamp: DateTime.now(),
    ),
  );
  out.push(resume == null || resume.isEmpty ? event : _resumeEvent(event, resume));
}

sealed class _AttemptOutcome {
  const _AttemptOutcome();
}

/// The attempt's events (or its terminal failure) reached the caller.
final class _Forwarded extends _AttemptOutcome {
  const _Forwarded();
}

/// The attempt failed transiently before any observable output.
final class _TransientFailure extends _AttemptOutcome {
  const _TransientFailure(this.error);

  /// The terminal error message (kept for the final forward on exhaustion).
  final AssistantMessage error;
}

/// The attempt aborted mid-stream AFTER observable output (issue #1126):
/// the accumulated snapshot returns to [_drive], which resumes from the
/// completed prefix instead of forwarding the failure.
final class _AbortedPartial extends _AttemptOutcome {
  const _AbortedPartial(this.snapshot, this.keptBlocks);

  /// The aborted attempt's accumulated message (full content, dead usage).
  final AssistantMessage snapshot;

  /// How many leading content blocks completed (their end event arrived).
  /// The remainder is the in-flight block at the abort and drops from the
  /// anchor (E1: a truncated tool call never executes).
  final int keptBlocks;
}

/// Issue #312: a wire finish_reason carries the structured verdict —
/// terminal (content_filter family) never retries, transient and unknown
/// vendor words do; without one the text nets decide. Pre-commit
/// ([_runAttempt]) and mid-answer ([_midAnswer]) failures share the
/// classification; a non-error reason is never retryable.
bool _retryableWireFailure(ErrorEvent event) {
  if (event.reason != StopReason.error) return false;
  final retryClass = finishReasonRetryClass(event.error);
  final transient = retryClass != null
      ? retryClass != FinishReasonClass.terminal
      : isTransientNetworkError(event.error);
  return transient;
}

/// One attempt's streaming state (issue #1132 CRAP gate: `_runAttempt`
/// was CC 25 — buffering, commit detection, and resume forwarding now
/// live here, and the two phase classifiers below make the branching
/// decision).
final class _AttemptRun {
  _AttemptRun(this.out, this.resume);

  final AssistantMessageEventStream out;

  /// Non-null in resume mode (issue #1126): every forwarded event is
  /// rewritten onto the anchor.
  final _ResumeState? resume;

  /// Events withheld until the attempt commits (issue #964) or ends.
  final buffer = <AssistantMessageEvent>[];

  /// Set by the first user-visible content event; from there a failure
  /// can no longer be replayed (the transcript already holds deltas).
  var committed = false;

  /// Highest content index whose end event arrived in this attempt;
  /// blocks after it were in-flight at an abort and drop from the anchor
  /// (issue #1126 E1: a truncated tool call with best-effort JSON must
  /// never execute, and a truncated block is better regenerated than
  /// resumed).
  var lastEnded = -1;

  /// Forwards [event] to the host; in resume mode the tail's start event
  /// is swallowed (the host already saw one) and everything else is
  /// rewritten onto the anchor — shifted indices, prefixed partials.
  void forward(AssistantMessageEvent event) {
    final anchor = resume;
    if (anchor != null) {
      if (event is StartEvent) return;
      event = _resumeEvent(event, anchor);
    }
    out.push(event);
  }

  /// Flushes the withheld buffer, in order.
  void flushBuffer() {
    for (final buffered in buffer) {
      forward(buffered);
    }
    buffer.clear();
  }

  /// Commits the attempt on its first user-visible event: the buffer
  /// flushes and the event rides (forwarding an event IS committing it).
  void commitWith(AssistantMessageEvent event) {
    committed = true;
    flushBuffer();
    forward(event);
  }
}

/// Runs one attempt, buffering until the first observable output commits
/// it (the same guard as the roles fallback: a pre-content failure leaves
/// no trace, a post-content failure stands).
///
/// With [resume] set (a mid-stream abort is being recovered, issue #1126)
/// every forwarded event is rewritten onto the anchor — shifted content
/// indices, partials prefixed with the completed blocks — and the attempt's
/// own [StartEvent] is swallowed, so hosts observe one continuous logical
/// message: the prefix they already streamed plus the tail's continuation.
Future<_AttemptOutcome> _runAttempt(
  AssistantMessageEventStream out,
  StreamFunction inner,
  Model model,
  Context context,
  CancelToken? cancelToken, {
  _ResumeState? resume,
}) async {
  final run = _AttemptRun(out, resume);
  await for (final event in inner(model, context, cancelToken: cancelToken)) {
    final outcome = run.committed
        ? _committedOutcome(run, event, cancelToken)
        : _bufferedOutcome(run, event, cancelToken);
    if (outcome != null) return outcome;
  }
  // The stream closed without a terminal event: flush what we held.
  run.flushBuffer();
  return const _Forwarded();
}

/// The terminal outcome of a POST-commit event, or null to keep streaming.
_AttemptOutcome? _committedOutcome(
  _AttemptRun run,
  AssistantMessageEvent event,
  CancelToken? cancelToken,
) {
  switch (event) {
    case TextEndEvent(:final contentIndex):
    case ThinkingEndEvent(:final contentIndex):
    case ToolCallEndEvent(:final contentIndex):
      if (contentIndex > run.lastEnded) run.lastEnded = contentIndex;
      run.forward(event);
      return null;
    case ErrorEvent():
      if (_resumableAbort(event, cancelToken) && run.lastEnded >= 0) {
        return _AbortedPartial(event.error, run.lastEnded + 1);
      }
      // The #290 hygiene wrap applies on the resume path too (issue
      // #1132 review): non-retryable wordings pass through unchanged,
      // retryable ones get the mid-answer story instead of a naked
      // provider dump. The rewrite below prefixes the streamed prefix
      // onto whatever content the terminal carries.
      run.forward(_midAnswer(event));
      return const _Forwarded();
    case DoneEvent():
      run.forward(event);
      return const _Forwarded();
    default:
      run.forward(event);
      return null;
  }
}

/// Whether a PRE-commit failure replays the attempt (buffer discarded):
/// the transient wire classes always do; in resume mode the abort class
/// also replays the tail — the anchor prefix in the request context is
/// untouched (issue #1126), while a first attempt keeps today's forward
/// rule.
bool _replaysAttempt(
  ErrorEvent event,
  CancelToken? cancelToken,
  bool resuming,
) {
  if (_retryableWireFailure(event)) return true;
  return resuming && _resumableAbort(event, cancelToken);
}

/// The terminal outcome of a PRE-commit event, or null to keep streaming.
_AttemptOutcome? _bufferedOutcome(
  _AttemptRun run,
  AssistantMessageEvent event,
  CancelToken? cancelToken,
) {
  switch (event) {
    case DoneEvent():
      run.flushBuffer();
      run.forward(event);
      return const _Forwarded();
    case ErrorEvent():
      if (_replaysAttempt(event, cancelToken, run.resume != null)) {
        // Not forwarded: the buffer is discarded and the call retries.
        return _TransientFailure(event.error);
      }
      run.flushBuffer();
      run.forward(event);
      return const _Forwarded();
    case ThinkingStartEvent() ||
        ThinkingDeltaEvent() ||
        ThinkingEndEvent():
      // Issue #964: thinking deltas are not user-visible content — they
      // buffer like the start event, so a stream that dies mid-reasoning
      // (minutes of thinking, zero visible deltas) is retried under the
      // existing policy with no trace of the dead attempt. The buffered
      // reasoning flushes in order when the attempt commits or ends.
      //
      // Visibility tradeoff (issue #964 review): until the first visible
      // delta (or the terminal event) the host sees NOTHING of the
      // reasoning — a thinking-only phase renders as silence, where the
      // pre-#964 behavior showed it live. That is the price of
      // replayability, not an oversight: forwarding an event IS
      // committing it (the host may have rendered it), and a committed
      // stream can never be replayed — the same reason omp's original
      // guard withheld all content. Providers that emit visible content
      // early are unaffected; pure-reasoning marathons are the case this
      // retry exists for.
      run.buffer.add(event);
      return null;
    case StartEvent():
      run.buffer.add(event);
      return null;
    default:
      // The first user-visible content event (text/tool-call family)
      // commits the attempt (issue #964). From there the post-content
      // semantics are unchanged: the transcript already holds visible
      // deltas, so a replay would duplicate them — the failure stands.
      run.commitWith(event);
      return null;
  }
}

/// Issue #1126: the mid-stream abort class — [StopReason.aborted] —
/// resumes from the completed prefix instead of killing the run, EXCEPT
/// when the abort was host intent (issue #1132 review):
///
/// - healthy (or absent) token: the provider/gateway emitted the abort
///   itself — the incident class, resume;
/// - token cancelled bare (or any non-watchdog reason — a user abort,
///   host teardown, the external harness kill, a compaction budget's
///   plain [TimeoutException] kill): stands, never resumed;
/// - token cancelled with a [RunIdleWatchdogFire]: the run-idle
///   watchdog's fire (`agent.dart _onRunWatchdogFired`) — the one
///   machine cancel; the resume re-arms the latch in place
///   (`CancelToken.reset`) so the loop's tool phases and later user
///   aborts keep working on the SAME token.
///
/// Mid-stream transport wordings (connection reset family) deliberately
/// keep the #290 AC4 stand-rule — this card reclassifies the abort
/// signature only.
bool _resumableAbort(ErrorEvent event, CancelToken? cancelToken) {
  if (event.reason != StopReason.aborted) return false;
  if (cancelToken == null || !cancelToken.isCancelled) return true;
  return cancelToken.cancelReason is RunIdleWatchdogFire;
}

/// A post-commit transport failure stands (issue #290 AC4 — the transcript
/// already holds the deltas; a replay would duplicate text), but it must
/// not surface as a naked provider dump either: the terminal error names
/// the mid-answer failure and keeps the provider line as evidence.
ErrorEvent _midAnswer(ErrorEvent event) {
  final error = event.error;
  // Issue #312: a classified non-terminal finish_reason mid-answer gets
  // the same hygiene wrap (the transcript already holds the deltas); a
  // TERMINAL verdict (content_filter family) keeps its verbatim story.
  if (!_retryableWireFailure(event)) {
    return event;
  }
  return ErrorEvent(
    reason: event.reason,
    retryAfter: event.retryAfter,
    error: AssistantMessage(
      content: error.content,
      api: error.api,
      provider: error.provider,
      model: error.model,
      usage: error.usage,
      stopReason: error.stopReason,
      errorMessage:
          'Provider failed mid-answer: the stream died after output was '
          'already delivered (not retried — a replay would duplicate the '
          'transcript). Provider error: ${_shortReason(error.errorMessage)}',
      rawStopReason: error.rawStopReason,
      timestamp: error.timestamp,
    ),
  );
}

/// Accumulated completed prefix across a resume chain (issue #1126): the
/// content blocks finished before each mid-stream abort, plus the dead
/// attempts' usage — billed once, in the resumed terminal message.
final class _ResumeState {
  final blocks = <ContentBlock>[];

  var usage = Usage.zero;

  bool get isEmpty => blocks.isEmpty;

  void absorb(AssistantMessage snapshot, int keptBlocks) {
    blocks.addAll(snapshot.content.take(keptBlocks));
    usage = _sumUsage(usage, snapshot.usage);
  }

  /// Drops completed blocks from [index] on (issue #1132 r2: the anchor's
  /// truncation point — a dead attempt's completed tool call never
  /// executed, and if it rides the final message next to its regenerated
  /// twin the tool phase runs the action twice). The kept prefix's indices
  /// are unchanged, so event rewriting stays aligned. No-op when [index]
  /// is negative or past the end.
  void dropFrom(int index) {
    if (index < 0 || index >= blocks.length) return;
    blocks.removeRange(index, blocks.length);
  }
}

/// The anchor assistant message handed to the tail request: the completed
/// prefix as a plain message the model continues from (issue #1126 AC1).
///
/// Callers guarantee the prefix is ToolCall-free (`_drive` drops dead
/// calls at the truncation point first, issue #1132 r2): a wrapper-built
/// anchor rides into the tail REQUEST, and Anthropic/OpenAI hard-400 a
/// tool_use with no following tool_result — the loop's pairing repair
/// never sees wrapper-built anchors. Null when nothing remains: the tail
/// then reissues on the original context.
AssistantMessage? _anchorMessage(Model model, List<ContentBlock> blocks) {
  if (blocks.isEmpty) return null;
  return AssistantMessage(
    content: List.of(blocks),
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.now(),
  );
}

/// Sums two usage reports (issue #1126: the dead attempt's tokens ride in
/// the resumed terminal message — counted once, never twice).
Usage _sumUsage(Usage a, Usage b) {
  int? sum(int? x, int? y) =>
      x == null && y == null ? null : (x ?? 0) + (y ?? 0);
  return Usage(
    input: a.input + b.input,
    output: a.output + b.output,
    cacheRead: a.cacheRead + b.cacheRead,
    cacheWrite: a.cacheWrite + b.cacheWrite,
    cacheWrite1h: sum(a.cacheWrite1h, b.cacheWrite1h),
    reasoning: sum(a.reasoning, b.reasoning),
    totalTokens: a.totalTokens + b.totalTokens,
    cost: UsageCost(
      input: a.cost.input + b.cost.input,
      output: a.cost.output + b.cost.output,
      cacheRead: a.cost.cacheRead + b.cost.cacheRead,
      cacheWrite: a.cost.cacheWrite + b.cost.cacheWrite,
      total: a.cost.total + b.cost.total,
    ),
  );
}

/// Rewrites a tail-attempt event onto the resume anchor (issue #1126):
/// content indices shift by the prefix length — index consumers (the
/// stream-JSON host protocol, TTSR block lookup) stay valid — and every
/// partial/final message carries the prefix blocks, so hosts observe ONE
/// logical assistant message: the prefix they already streamed plus the
/// tail's continuation.
AssistantMessageEvent _resumeEvent(
  AssistantMessageEvent event,
  _ResumeState resume,
) {
  final shift = resume.blocks.length;
  AssistantMessage prefixed(AssistantMessage tail) =>
      tail.copyWith(content: [...resume.blocks, ...tail.content]);

  return switch (event) {
    // Unreachable — the tail's start event is swallowed in [_runAttempt] —
    // but the switch must stay exhaustive.
    StartEvent() => event,
    TextStartEvent(:final contentIndex, :final partial) => TextStartEvent(
      contentIndex: contentIndex + shift,
      partial: prefixed(partial),
    ),
    TextDeltaEvent(:final contentIndex, :final delta, :final partial) =>
      TextDeltaEvent(
        contentIndex: contentIndex + shift,
        delta: delta,
        partial: prefixed(partial),
      ),
    TextEndEvent(:final contentIndex, :final content, :final partial) =>
      TextEndEvent(
        contentIndex: contentIndex + shift,
        content: content,
        partial: prefixed(partial),
      ),
    ThinkingStartEvent(:final contentIndex, :final partial) =>
      ThinkingStartEvent(
        contentIndex: contentIndex + shift,
        partial: prefixed(partial),
      ),
    ThinkingDeltaEvent(:final contentIndex, :final delta, :final partial) =>
      ThinkingDeltaEvent(
        contentIndex: contentIndex + shift,
        delta: delta,
        partial: prefixed(partial),
      ),
    ThinkingEndEvent(:final contentIndex, :final content, :final partial) =>
      ThinkingEndEvent(
        contentIndex: contentIndex + shift,
        content: content,
        partial: prefixed(partial),
      ),
    ToolCallStartEvent(:final contentIndex, :final partial) =>
      ToolCallStartEvent(
        contentIndex: contentIndex + shift,
        partial: prefixed(partial),
      ),
    ToolCallDeltaEvent(:final contentIndex, :final delta, :final partial) =>
      ToolCallDeltaEvent(
        contentIndex: contentIndex + shift,
        delta: delta,
        partial: prefixed(partial),
      ),
    ToolCallEndEvent(:final contentIndex, :final toolCall, :final partial) =>
      ToolCallEndEvent(
        contentIndex: contentIndex + shift,
        toolCall: toolCall,
        partial: prefixed(partial),
      ),
    DoneEvent(:final reason, :final message) => DoneEvent(
      // The dead attempts' usage lands here, exactly once.
      reason: reason,
      message: prefixed(message).copyWith(
        usage: _sumUsage(resume.usage, message.usage),
      ),
    ),
    ErrorEvent(:final reason, :final error, :final retryAfter) => ErrorEvent(
      reason: reason,
      retryAfter: retryAfter,
      error: prefixed(error).copyWith(
        usage: _sumUsage(resume.usage, error.usage),
      ),
    ),
  };
}
