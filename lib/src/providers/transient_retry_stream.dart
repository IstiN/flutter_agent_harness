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
///   never REPLAYED from scratch — but a CONNECTION-class failure after
///   COMPLETED blocks resumes from that prefix instead of standing
///   (issue #1168: the same resume machinery as the abort class), and a
///   non-connection post-commit failure (auth, validation, rate limit)
///   still stands. Since issue #1323 the first THINKING delta commits too:
///   reasoning streams live (the TUI's progress signal for reasoning
///   models), and a mid-reasoning transport death resumes from the prefix
///   the host already saw — the still-open thinking block rides the anchor,
///   never a from-scratch replay over deltas already on screen. The #964
///   replayable-reasoning tradeoff (thinking buffers in silence until the
///   first visible delta) remains available through
///   [transientRetryBufferThinking].
/// - Providers-never-throw is preserved: a defensive catch converts a
///   throwing inner stream into an error event.
library;

import 'dart:async';
import 'dart:math';

import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../overflow.dart' show isContextOverflow;
import '../types.dart';
import 'provider_common.dart' show providerStreamIdleTimeout;
import 'provider_tuning.dart'
    show
        explicitConnectForModel,
        explicitStreamIdleForModel,
        formatProviderTimeout,
        zeroByteAttemptBudget;

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
///
/// The structural tag the connect watchdog's exhaustion error carries:
/// `watchdogTimedOut()` in `provider_common.dart` builds its message with
/// it, and the classifier below matches the CONSTANT — the producer and
/// consumer of the wording are pinned together (issue #1121, review r1).
const String connectWatchdogTag = '(connect watchdog)';

/// The structural tag the zero-byte stall terminal carries (gh-1308):
/// the endpoint accepted every request and produced nothing across the
/// replay budget — the run-idle watchdog killed the silent attempts.
/// Classified retryable/transport by this file's ladder and the roles
/// ladder (a hung primary fails over to the next configured model, the
/// 429 take-over path) and as a timeout death by the queue classifier.
/// Producer and consumers pin the constant, [connectWatchdogTag]-style.
const String zeroByteStallTag = '(zero-byte stall)';

/// The zero-byte replay budget (gh-1308): consecutive PRE-COMMIT attempts
/// killed by the run-idle watchdog — zero bytes ever reached the caller —
/// before the ladder stops replaying and fails the call with the
/// zero-byte terminal instead of spending the remaining budget. 2 on
/// purpose: every kill costs a full watchdog interval (default 8 min), so
/// the third attempt the generic budget allows pushed the bench's
/// zero-token trials past their caps — they died as `agent_timeout` with
/// 0 tokens mid-attempt while the ladder still had "budget" left. With
/// the bound, the verdict lands at ≈ 2×watchdog-interval as a truthful
/// retryable error. The generic [maxAttempts] budget keeps governing
/// every other failure class.
const int maxZeroByteWatchdogAttempts = 2;

final _transientNetworkPatterns = [
  RegExp(r'connection reset', caseSensitive: false),
  RegExp(r'socketexception', caseSensitive: false),
  RegExp(r'connection refused', caseSensitive: false),
  // Connect-timeout wordings (issue #1168): the TCP connect leg's OS
  // timeout — macOS reports "Operation timed out" (errno 60, matched by
  // the socketexception rule), Windows "connection attempt timed out".
  RegExp(r'connection( attempt)? timed? ?out', caseSensitive: false),
  RegExp(r'connection closed', caseSensitive: false),
  RegExp(r'connection terminated', caseSensitive: false),
  RegExp(r'failed host lookup', caseSensitive: false),
  RegExp(r'network is unreachable', caseSensitive: false),
  RegExp(r'connection aborted', caseSensitive: false),
  RegExp(r'broken pipe', caseSensitive: false),
  RegExp(r'no route to host', caseSensitive: false),
  RegExp(r'host is (down|unreachable)', caseSensitive: false),
  RegExp(r'software caused connection abort', caseSensitive: false),
  RegExp(r'handshake ?exception', caseSensitive: false),
  // The connect watchdog's kill (issue #1121): a request aborted before a
  // single response byte — trivially safe to replay, nothing was streamed.
  // Deliberately distinct from the idle watchdog's "stream idle timeout"
  // wording below: mid-stream silence follows the #290 AC4 stand-rule.
  // Matched via [connectWatchdogTag] — the constant `watchdogTimedOut()`
  // builds its message with — so rewording the display string cannot
  // silently drop a #1125 ladder exhaustion out of this ladder
  // (review r1, thread 2).
  RegExp(RegExp.escape(connectWatchdogTag)),
  // The zero-byte stall terminal (gh-1308): this ladder's own verdict for
  // a wedged endpoint that produced nothing across its watchdog-replay
  // budget. Retryable on sight so a re-entered ladder (a roles failover
  // target builds a fresh one) treats it like any transport failure.
  RegExp(RegExp.escape(zeroByteStallTag)),
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

/// Whether [text] carries a rate-limit/quota wording (the guard set above).
/// Public so hosts can classify retry notices the ladder announces — the
/// CLI separates `[net] connection lost` from `[net] rate limited` lines
/// and appends the `429_retry` session record for the rate-limit class.
bool matchesRateLimitWording(String text) =>
    _rateLimitGuardPatterns.any((pattern) => pattern.hasMatch(text));

/// Whether [message] is a rate-limit/quota failure the ladder retries in
/// place with backoff (gh-1602): a single transient quota blip must not
/// kill a run that has no roles chain above this ladder to rotate or fail
/// over. Budget/spending exhaustion stays terminal (issue #926 —
/// `insufficient_quota` matches the wording set but is dead until the
/// budget reset, never a backoff case); context overflow belongs to
/// compaction; auth failures stand.
bool isRateLimitError(AssistantMessage message) {
  if (message.stopReason != StopReason.error) return false;
  final text = message.errorMessage;
  if (text == null || text.isEmpty) return false;
  if (isContextOverflow(message)) return false;
  if (isBudgetExhaustion(message)) return false;
  return matchesRateLimitWording(text);
}

/// The rate-limit retry budget (gh-1602): in-place replays after a
/// pre-commit 429 before the ladder fails the call with the exhaustion
/// terminal. Deliberately separate from the transport budget
/// ([maxAttempts] of [transientRetryStreamFunction]): a quota blip heals
/// on the scale of seconds. Each class counts its own attempts
/// (`_DriveState.rateLimitRetries` vs `_DriveState.transportAttempts` —
/// gh-1602 review r1 thread 2), so neither eats the other's budget; the
/// ladder's loop bound is the sum of the two, the alternation safety net.
const int maxRateLimitRetries = 3;

/// The rate-limit backoff floor (gh-1602): the first retry waits at least
/// this long — a sub-second retry against a 429 is a guaranteed second
/// 429.
const Duration rateLimitBackoffBase = Duration(seconds: 2);

/// The rate-limit backoff ceiling (gh-1602): no single in-call retry wait
/// exceeds this, so the ladder's whole budget stays inside a bench
/// trial's wrap-up margin.
const Duration rateLimitBackoffCap = Duration(seconds: 60);

/// The capped exponential backoff for a rate-limit retry: `base * 2^(n-1)`
/// (n = 1-based retry index) capped at [rateLimitBackoffCap], with up to
/// 25% upward jitter via [jitterFraction] (0..1) so concurrent fa
/// processes don't retry in lockstep — the same shape the roles layer's
/// `ModelRolesRetryPolicy.backoffFor` uses.
Duration rateLimitBackoffFor(int retry, double jitterFraction) {
  var ms =
      rateLimitBackoffBase.inMilliseconds * (1 << (retry - 1).clamp(0, 20));
  if (ms > rateLimitBackoffCap.inMilliseconds) {
    ms = rateLimitBackoffCap.inMilliseconds;
  }
  final jitter = (ms * 0.25 * jitterFraction.clamp(0.0, 1.0)).round();
  return Duration(milliseconds: ms + jitter);
}

/// The remaining wall-clock budget a rate-limit retry may spend, or null
/// when no session deadline is armed (the ladder is then bounded only by
/// its attempt budget). Wired by hosts from `SessionDeadline` (gh-1556) —
/// the bench exports `FA_DEADLINE_EPOCH_MS = cap − 120s`, so bounding by
/// this value can never eat the wrap-up window. Global like
/// [transientRetryNotice]: the wrap happens deep inside
/// [providerStreamFunction], far from any host io.
Duration? Function()? transientRetryDeadlineLeft;

/// The deadline rest a rate-limit retry must never eat (gh-1602): when the
/// armed deadline has less than [transientRetryWrapUpMargin] +
/// backoff left, the ladder stops retrying and fails with the deadline
/// terminal — the margin stays reserved for the wrap-up answer. Mirrors
/// the harbor adapter's 120s wrap-up margin
/// (bench/harbor_fa/fa_agent.py). Injectable for tests.
Duration transientRetryWrapUpMargin = const Duration(seconds: 120);

/// The jitter source for [rateLimitBackoffFor]. Injectable for
/// deterministic tests; defaults to [Random.nextDouble].
double Function() transientRetryJitter = Random().nextDouble;

/// Whether [message] is a transient failure worth replaying: socket-level
/// drops and gateway 5xx. Rate limits stay with the roles layer (the
/// `FallbackStreamFunction` rotation policy — a 429 may quote "please try
/// again later"), budget/spending exhaustion is terminal and wins over
/// every net below it (issue #926 — a gateway-wrapped budget error quotes
/// "500 … please try again later"), auth failures stand, context overflow
/// belongs to compaction, and the idle watchdog's own `TimeoutException`
/// wording deliberately does NOT match (that error means "the endpoint
/// went silent", which a retry re-arms anyway) — while the connect
/// watchdog's zero-byte wording DOES via [connectWatchdogTag] (issue
/// #1121: a never-started request is replayed, a silent mid-stream one
/// is not).
///
/// gh-1602 boundary note: "rate limits stay with the roles layer" holds
/// for THIS classifier (a 429 is not a transport replay), but the ladder
/// itself now owns an in-place rate-limit class — see [isRateLimitError].
bool isTransientNetworkError(AssistantMessage message) {
  if (message.stopReason != StopReason.error) return false;
  final text = message.errorMessage;
  if (text == null || text.isEmpty) return false;
  if (text.toLowerCase().contains('certificate')) return false;
  if (isContextOverflow(message)) return false;
  if (isBudgetExhaustion(message)) return false;
  // A resumed-exhaustion terminal (issue #1168) is a consumed verdict:
  // its per-attempt evidence quotes raw transport wordings, but the
  // chain already spent its budget - upper layers must neither rewrap
  // ("not retried" would be false) nor rotate on a false pretext.
  if (isTransientExhaustionStory(text)) return false;
  if (_rateLimitGuardPatterns.any((pattern) => pattern.hasMatch(text))) {
    return false;
  }
  return _transientNetworkPatterns.any((pattern) => pattern.hasMatch(text));
}

/// The headline of a resumed-exhaustion terminal (issue #1168): a retry
/// chain that resumed from its completed prefix and STILL spent its
/// budget. Classification layers (here and in the roles ladder above)
/// treat the signature as terminal - no further retries, no "not
/// retried" rewrap of an already-consumed verdict.
const String transientExhaustionHeadline =
    'Provider retry chain exhausted after';

/// Whether [errorMessage] is a resumed-exhaustion terminal (see
/// [transientExhaustionHeadline]).
bool isTransientExhaustionStory(String? errorMessage) =>
    (errorMessage ?? '').startsWith(transientExhaustionHeadline);

/// The no-silent-retry note: fired before each retry sleep so the user
/// sees "connection lost — retrying in 5s (attempt 2/3)" instead of a
/// mysterious pause. [attempt] is the 1-based attempt that just failed;
/// [maxAttempts] the total budget; [reason] the provider error text
/// UNTRUNCATED (gh-1602 review r1 thread 5) — faces classify on it and
/// truncate display-only.
typedef TransientRetryNotice =
    void Function(int attempt, int maxAttempts, Duration delay, String reason);

/// The hidden session-JSONL record type the CLI appends when the ladder
/// announces a rate-limit retry (gh-1602): the post-mortem surface that
/// shows a bench trial absorbed a quota blip instead of dying as
/// `ApiRateLimitError`. Payload: `attempt` (the 1-based attempt that just
/// failed — the faces render `attempt + 1`, the retry about to run, out
/// of `max_attempts`; gh-1602 review r1 thread 1), `max_attempts` (the
/// rate-limit budget total), `delay_ms` (0 = an immediate replay — the
/// watchdog janitor or a mid-answer resume; a cancelled wait records
/// nothing, gh-1602 review r1 thread 6), `reason` (the first line of the
/// provider error, display-truncated), `ts`.
const String rateLimitRetryRecordType = '429_retry';

/// The host-visible retry hook (the CLI prints it + logs to fa.log).
/// Null keeps retries silent. Global like `providerTimeoutsOverride`: the
/// wrap happens deep inside [providerStreamFunction], far from any host io.
TransientRetryNotice? transientRetryNotice;

/// The retry sleep — injectable so tests don't wait real seconds. Returns
/// false when the wait was cancelled (the retry is abandoned).
Future<bool> Function(Duration delay, CancelToken? cancelToken)
transientRetrySleeper = _realTransientSleep;

/// The #964 escape hatch (issue #1323): when true, PRE-commit thinking
/// deltas buffer like the start event until the first visible delta (or
/// the terminal) commits — a pure-reasoning phase renders as silence and a
/// mid-reasoning drop replays with no trace. Default false: the first
/// thinking delta commits the attempt, reasoning streams live, and a
/// mid-reasoning transport death resumes from the streamed prefix (never a
/// from-scratch replay — that would duplicate thinking the host already
/// rendered). Global like [transientRetryNotice]: the wrap happens deep
/// inside [providerStreamFunction], far from any host io.
bool transientRetryBufferThinking = false;

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

/// The budget-exhausted terminal for a PRE-COMMIT transport failure
/// (issue #290 AC2): the surfaced error carries the retry story —
/// attempts, elapsed, per-attempt outcomes, next-step hint — never the
/// naked provider line as headline. A resume prefix already streamed
/// rides on the terminal (issue #1132 review: the transcript keeps it).
ErrorEvent _transientExhaustedTerminal(
  Model model,
  List<String> attemptLog,
  DateTime startedAt,
) => ErrorEvent(
  reason: StopReason.error,
  error: _exhausted(model, attemptLog, startedAt),
);

/// The budget-exhausted terminal for a MID-ANSWER death (issue #1126
/// AC2): loud death with the full partial content preserved — never an
/// infinite retry. The failure's own reason rides (issue #1168): a
/// transport death surfaces as error, never as "aborted".
///
/// A TRANSPORT-class death (issue #1168 review) carries the exhaustion
/// story instead of the raw provider wording: the roles ladder above
/// this wrapper classifies the raw wording as retryable and would
/// rewrap it as "not retried" — false after this chain spent its
/// budget — and the story's signature makes every classification layer
/// treat it as the consumed verdict it is. The abort class keeps the
/// snapshot verbatim (its wording is never classified retryable).
ErrorEvent _partialExhaustionTerminal(
  Model model,
  AssistantMessage snapshot,
  StopReason reason,
  List<String> attemptLog,
  _ResumeState resume,
  DateTime startedAt,
) => reason == StopReason.error
    ? ErrorEvent(
        reason: reason,
        error: _resumedExhaustion(
          model,
          snapshot,
          attemptLog,
          resume,
          startedAt,
        ),
      )
    : ErrorEvent(reason: reason, error: snapshot);

/// The tail-request context for a mid-answer resume: the completed
/// prefix rides as the last assistant message (issue #1126 AC1).
///
/// The anchor stops at the first completed ToolCall, and the state
/// DROPS the dead call(s) from that point on (issue #1132 r2): the
/// dead call never executed (its attempt aborted before a tool phase
/// ran), so the tail regenerates it — and the regenerated twin must be
/// the only copy in the final message, else the loop's tool phase
/// executes the action twice. Hosts saw the dead call stream, but the
/// transcript settles on what actually executes.
Context _resumeAnchor(Context context, Model model, _ResumeState resume) {
  final boundary = resume.blocks.indexWhere((block) => block is ToolCall);
  resume.dropFrom(boundary);
  final anchor = _anchorMessage(model, resume.blocks);
  return Context(
    systemPrompt: context.systemPrompt,
    messages: [...context.messages, ?anchor],
    tools: context.tools,
  );
}

/// The [transientRetryNotice] wording for a mid-answer resume: names
/// the failure class and how much completed content survived it.
String _midStreamResumeNotice(StopReason reason, int completedBlocks) =>
    'mid-stream '
    '${reason == StopReason.aborted ? 'abort' : 'connection failure'} '
    '— resuming from $completedBlocks completed block(s)';

/// The replay reason shared by the attempt log and the [transientRetryNotice]
/// (issue #1121 review r1): names the machine trigger when the run-idle
/// watchdog motivated the replay — "Request was aborted" alone has meant
/// USER intent on the [net] surface, and a forensics reader must be able
/// to tell a watchdog replay from a provider-emitted abort. gh-1617: the
/// replay event carries the governing idle window (`idle window Xs
/// (source)`) so the replay log tells which patience ruled the kill.
String _replayReason(
  bool watchdogReplay,
  AssistantMessage error,
  _ZeroByteWindowStory windowStory,
) => watchdogReplay
    ? 'run-idle watchdog replay of zero-byte request '
          '(idle window ${formatProviderTimeout(windowStory.window)} '
          'from ${windowStory.source}): ${_shortReason(error.errorMessage)}'
    : _shortReason(error.errorMessage);

/// The [transientRetryNotice] reason (gh-1602 review r1 thread 5): the
/// UNTRUNCATED provider line — the CLI face classifies rate-limit wording
/// on the full text and truncates display-only, so rate-limit wording
/// late in a long structured render still reads as rate limited on the
/// `[net]` face and lands in the `429_retry` record. The watchdog naming
/// rides here too: the `[net]` surface must say what motivated the replay
/// (issue #1121 review r1, thread 1) — and WHICH patience governed it
/// (gh-1617 AC5). The per-attempt evidence log keeps its truncated
/// [_replayReason] form.
String _noticeReason(
  bool watchdogReplay,
  AssistantMessage error,
  _ZeroByteWindowStory windowStory,
) {
  final text = error.errorMessage ?? 'network error';
  return watchdogReplay
      ? 'run-idle watchdog replay of zero-byte request '
            '(idle window ${formatProviderTimeout(windowStory.window)} '
            'from ${windowStory.source}): $text'
      : text;
}

/// Re-arms a watchdog-cancelled latch IN PLACE once the failure was
/// classed as a replay (the #1132 discipline, issue #1121): the loop's
/// tool phases, a later `Agent.abort()`, and the tail request observe a
/// live token again. A user cancel never reaches this —
/// `_replaysAttempt` stands it before the outcome exists.
void _rearmWatchdogLatch(CancelToken? cancelToken, bool watchdogReplay) {
  if (watchdogReplay) {
    cancelToken?.reset();
  }
}

/// Runs the inter-attempt pause of the transient ladder: sleeps the
/// backoff delay (racing the token), ANNOUNCES the replay with the
/// truthful schedule — a survived wait retries in `delay`, a watchdog
/// fire absorbed mid-sleep retries immediately (0s; issue #1121 review
/// r1, thread 1) — and absorbs a watchdog fire landing INSIDE the sleep
/// the same way as one landing on the failure (machine cancel, latch
/// reset, retry — the #1132 discipline). A USER cancel ends the call
/// here — silently on the `[net]` face (gh-1602 review r1 thread 6: no
/// retry follows a cancelled wait, so no notice and no `429_retry`
/// record may describe one; the aborted terminal tells the story).
/// Returns true when the loop continues to the next attempt, false after
/// the aborted terminal was pushed.
Future<bool> _pauseBetweenAttempts(
  AssistantMessageEventStream out,
  Model model,
  AssistantMessage lastFailure,
  _ResumeState resume,
  CancelToken? cancelToken,
  Duration delay,
  int attempt,
  int maxAttempts,
  String reason,
) async {
  final survived = await transientRetrySleeper(delay, cancelToken);
  if (!survived && cancelToken?.cancelReason is! RunIdleWatchdogFire) {
    _pushAborted(out, model, lastFailure, resume: resume);
    return false;
  }
  transientRetryNotice?.call(
    attempt,
    maxAttempts,
    survived ? delay : Duration.zero,
    reason,
  );
  if (survived) return true;
  cancelToken?.reset();
  return true;
}

/// The mutable state of one retry chain ([_drive]): the per-attempt story,
/// the last failure, the gh-1308 zero-byte kill streak, and the context the
/// next attempt runs with.
final class _DriveState {
  _DriveState(this.context) : startedAt = DateTime.now();

  /// The chain's clock: every terminal story reports its elapsed time.
  final DateTime startedAt;

  /// The per-attempt story — rides every terminal message as evidence.
  final attemptLog = <String>[];

  /// The last failure message, reused by the aborted terminal so the
  /// transcript shows WHAT was interrupted.
  AssistantMessage? lastFailure;

  /// Consecutive pre-commit attempts the run-idle watchdog killed with
  /// zero output (gh-1308). Only back-to-back full-interval silences prove
  /// the wedged-endpoint class: any non-watchdog failure resets the
  /// streak, and a mid-stream resume (partial progress) leaves it
  /// standing — the terminal then carries the preserved prefix.
  var zeroByteKills = 0;

  /// Rate-limit retries spent in this call (gh-1602), separate from the
  /// transport budget — a quota blip heals on the scale of seconds and
  /// the two classes alternate, so they must not eat each other's budget.
  var rateLimitRetries = 0;

  /// Transport-class attempts spent in this call (gh-1602 review r1
  /// thread 2): pre-commit transport failures, zero-byte watchdog kills,
  /// and mid-answer resume attempts — everything the [maxAttempts] budget
  /// governs. Counted beside [rateLimitRetries] so the transport bound
  /// reads its own class's spend, never the shared [attemptLog] (whose
  /// length mixes both classes and would let rate-limit retries erode
  /// the transport budget in a mixed chain).
  var transportAttempts = 0;

  /// The context the NEXT attempt runs with — the resume anchor after a
  /// mid-stream abort (issue #1126); the caller's token stays THE token.
  Context context;
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
  final state = _DriveState(context);
  final resume = _ResumeState();
  // The loop bound is the SUM of the two pre-commit budgets (gh-1602):
  // transport failures stop at [maxAttempts] inside their handler, the
  // rate-limit class at [maxRateLimitRetries] inside its own — the outer
  // bound is only the alternation safety net.
  final attemptBound = maxAttempts + maxRateLimitRetries;
  for (var attempt = 1; attempt <= attemptBound; attempt++) {
    if (cancelToken?.isCancelled ?? false) {
      _pushAborted(out, model, state.lastFailure, resume: resume);
      return;
    }
    final outcome = await _runAttempt(
      out,
      inner,
      model,
      state.context,
      cancelToken,
      resume: resume.isEmpty ? null : resume,
    );
    switch (outcome) {
      case _Forwarded():
        return;
      case _TransientFailure():
        if (!await _afterTransientFailure(
          out,
          model,
          outcome,
          state,
          cancelToken,
          resume,
          delay,
          maxAttempts,
        )) {
          return;
        }
      case _AbortedPartial(:final snapshot, :final keptBlocks, :final reason):
        state.lastFailure = snapshot;
        state.attemptLog.add(_shortReason(snapshot.errorMessage));
        // The mid-answer class spends the TRANSPORT budget (gh-1602
        // review r1 thread 2): its attempts count beside the rate-limit
        // class's own, never against the shared log.
        state.transportAttempts++;
        if (state.transportAttempts >= maxAttempts) {
          _pushTerminal(
            out,
            _partialExhaustionTerminal(
              model,
              snapshot,
              reason,
              state.attemptLog,
              resume,
              state.startedAt,
            ),
            resume,
          );
          return;
        }
        state.context = _resumeAfterPartial(
          model,
          snapshot,
          keptBlocks,
          reason,
          state.transportAttempts,
          maxAttempts,
          context,
          resume,
          cancelToken,
        );
    }
  }
}

/// The [_drive] handler for a PRE-commit transient failure: records the
/// attempt, re-arms a watchdog-cancelled latch, enforces the gh-1308
/// zero-byte bound and the generic budget — a bound hit pushes the matching
/// terminal and ends the call — and otherwise runs the inter-attempt
/// pause. Returns true when the ladder continues to the next attempt.
///
/// The failure itself is stored here (`state.lastFailure = failure.error`
/// is the handler's first statement — this handler owns the chain state it
/// touches, so the field and the parameter cannot diverge). The
/// rate-limit class (gh-1602) branches to its own policy after the shared
/// bookkeeping.
Future<bool> _afterTransientFailure(
  AssistantMessageEventStream out,
  Model model,
  _TransientFailure failure,
  _DriveState state,
  CancelToken? cancelToken,
  _ResumeState resume,
  Duration delay,
  int maxAttempts,
) async {
  final error = failure.error;
  state.lastFailure = error;
  // A machine-cancelled latch re-arms IN PLACE (the issue #1132
  // discipline): the run-idle watchdog fired over a request that never
  // received a byte, and the replay re-opens the SAME token so the loop,
  // tool phases and a later user abort keep working (issue #1121). A user
  // cancel never reaches this branch — `_resumableAbort` stands it before
  // the outcome exists.
  final watchdogReplay = cancelToken?.cancelReason is RunIdleWatchdogFire;
  // gh-1617: the fire's OWN duration is the watchdog interval that
  // governed this kill (the agent arms the timer with the derived
  // window) — the replay-budget math and the terminal story read it
  // BEFORE the latch re-arms (the reset wipes the reason).
  final watchdogWindow = cancelToken?.cancelReason is RunIdleWatchdogFire
      ? (cancelToken!.cancelReason as RunIdleWatchdogFire).duration
      : null;
  final windowStory = _zeroByteWindowStory(model, watchdogWindow);
  state.attemptLog.add(_replayReason(watchdogReplay, error, windowStory));
  _rearmWatchdogLatch(cancelToken, watchdogReplay);
  // gh-1308: replaying into an endpoint that produced NOTHING is bounded
  // separately from the generic budget — every watchdog kill costs a full
  // watchdog interval, so the third attempt the generic budget allows
  // burned the caller's whole cap (bench run 37418229569: 11 trials died
  // as agent_timeout with 0 tokens while the ladder still had "budget").
  // Past the bound the call fails fast and truthfully: a retryable
  // provider error the roles ladder can fail over on, never a caller
  // timeout.
  //
  // gh-1617 I2/AC4: an EXPLICITLY configured connectTimeoutMs bounds the
  // replay patience on top — a budget below the idle window buys no
  // replay at all, and the terminal names both values.
  //
  // gh-1617 E1: the killed attempt's request may still complete
  // server-side — the first request IS aborted via the cancel token and
  // its (zero-byte) partial stream dropped before the replay, but any
  // billing dedup for the abandoned generation is the provider's job;
  // fa never replays into a cancel that has not landed.
  state.zeroByteKills = watchdogReplay ? state.zeroByteKills + 1 : 0;
  final zeroByteBudget = zeroByteAttemptBudget(
    ladderBound: maxZeroByteWatchdogAttempts,
    idleWindow: windowStory.window,
    connectBudget: windowStory.connectBudget?.$1,
  );
  if (state.zeroByteKills >= zeroByteBudget) {
    _pushTerminal(
      out,
      _zeroByteStallTerminal(
        model,
        state.attemptLog,
        state.startedAt,
        windowStory,
      ),
      resume,
    );
    return false;
  }
  // gh-1602: the rate-limit class follows its own policy — its own retry
  // budget, capped exponential backoff honoring `Retry-After`, and the
  // session-deadline bound. The transport budget below does not govern it
  // (each class counts its own attempts — see [_DriveState
  // .transportAttempts]).
  if (failure.isRateLimit) {
    return _afterRateLimitFailure(
      out,
      model,
      failure,
      state,
      resume,
      cancelToken,
      maxAttempts,
    );
  }
  state.transportAttempts++;
  if (state.transportAttempts >= maxAttempts) {
    _pushTerminal(
      out,
      _transientExhaustedTerminal(model, state.attemptLog, state.startedAt),
      resume,
    );
    return false;
  }
  return _pauseBetweenAttempts(
    out,
    model,
    error,
    resume,
    cancelToken,
    delay,
    state.transportAttempts,
    maxAttempts,
    // The notice reason is the UNTRUNCATED provider line (gh-1602 review
    // r1 thread 5): the CLI face classifies rate-limit wording on the
    // full text and truncates display-only, so "429" late in a long
    // structured render still reads as rate limited and records. gh-1617
    // AC5: the watchdog replay names the governing window + its source.
    _noticeReason(watchdogReplay, error, windowStory),
  );
}

/// The gh-1602 rate-limit retry handler: spends one of
/// [maxRateLimitRetries], honors the provider's `Retry-After` verbatim up
/// to [rateLimitBackoffCap] (a larger hint waits the cap — no unbounded
/// sleeps) or backs off exponentially with jitter, and never sleeps past
/// the armed session deadline minus [transientRetryWrapUpMargin] — the
/// wrap-up window stays reserved for the final answer. A budget or
/// deadline bound hit fails the call with a terminal whose story embeds
/// the raw 429 evidence, so every classifier above (the roles layer's
/// rotation policy, the providers queue, the bench's anchored 429
/// classifier) still sees the rate-limit class.
Future<bool> _afterRateLimitFailure(
  AssistantMessageEventStream out,
  Model model,
  _TransientFailure failure,
  _DriveState state,
  _ResumeState resume,
  CancelToken? cancelToken,
  int maxAttempts,
) async {
  state.rateLimitRetries++;
  if (state.rateLimitRetries > maxRateLimitRetries ||
      state.attemptLog.length >= maxAttempts + maxRateLimitRetries) {
    _pushTerminal(
      out,
      _transientExhaustedTerminal(model, state.attemptLog, state.startedAt),
      resume,
    );
    return false;
  }
  var wait =
      failure.retryAfter ??
      rateLimitBackoffFor(state.rateLimitRetries, transientRetryJitter());
  if (wait > rateLimitBackoffCap) wait = rateLimitBackoffCap;
  final deadlineLeft = transientRetryDeadlineLeft?.call();
  if (deadlineLeft != null) {
    final allowance = deadlineLeft - transientRetryWrapUpMargin;
    if (allowance <= Duration.zero || wait >= allowance) {
      _pushTerminal(
        out,
        ErrorEvent(
          reason: StopReason.error,
          error: _rateLimitDeadlineTerminal(
            model,
            state.attemptLog,
            state.startedAt,
          ),
        ),
        resume,
      );
      return false;
    }
  }
  return _pauseBetweenAttempts(
    out,
    model,
    failure.error,
    resume,
    cancelToken,
    wait,
    // The notice speaks the rate-limit budget only — and the FAILED
    // attempt convention (gh-1602 review r1 thread 1): the 1-based
    // attempt that just failed, out of 1 + maxRateLimitRetries. The
    // faces render attempt + 1 (the retry about to run); passing the
    // upcoming number double-incremented the display past the budget.
    state.rateLimitRetries,
    1 + maxRateLimitRetries,
    // Untruncated — see the transport branch above (gh-1602 review r1
    // thread 5): the face classifies the full line.
    failure.error.errorMessage ?? 'network error',
  );
}

/// Absorbs a mid-stream abort's completed prefix (issue #1126) and builds
/// the tail-request context for the next attempt: the anchor carries the
/// finished blocks, the dead in-flight block dropped (issue #1132 r2).
Context _resumeAfterPartial(
  Model model,
  AssistantMessage snapshot,
  int keptBlocks,
  StopReason reason,
  int attempt,
  int maxAttempts,
  Context context,
  _ResumeState resume,
  CancelToken? cancelToken,
) {
  resume.absorb(snapshot, keptBlocks);
  transientRetryNotice?.call(
    attempt,
    maxAttempts,
    Duration.zero,
    _midStreamResumeNotice(reason, resume.blocks.length),
  );
  // A watchdog-cancelled token re-arms IN PLACE (issue #1132 review):
  // `CancelToken.reset` re-opens the latch on the SAME object every holder
  // shares, so the loop's tool phases, a later `Agent.abort()`, and the
  // tail request itself all observe a live token again. A user cancel
  // (bare reason) never reaches this branch — `_resumableAbort` stands it.
  cancelToken?.reset();
  return _resumeAnchor(context, model, resume);
}

/// Pushes a terminal error event, preserving an already-streamed resume
/// prefix (issue #1132 review: the transcript keeps what the host saw).
void _pushTerminal(
  AssistantMessageEventStream out,
  ErrorEvent terminal,
  _ResumeState resume,
) => out.push(resume.isEmpty ? terminal : _resumeEvent(terminal, resume));

/// The first line of a provider error, bounded for notices and the
/// per-attempt log.
String _shortReason(String? errorMessage) {
  final text = errorMessage ?? 'network error';
  final line = text.split('\n').first;
  return line.length <= 120 ? line : '${line.substring(0, 120)}...';
}

/// The zero-byte stall terminal (gh-1308): the endpoint accepted every
/// request and produced nothing — the run-idle watchdog killed the silent
/// attempts — so the ladder stops replaying and fails the call fast and
/// truthfully: a retryable provider error carrying the [zeroByteStallTag]
/// classification, never a caller timeout.
ErrorEvent _zeroByteStallTerminal(
  Model model,
  List<String> attemptLog,
  DateTime startedAt,
  _ZeroByteWindowStory windowStory,
) => ErrorEvent(
  reason: StopReason.error,
  error: _zeroByteStallMessage(model, attemptLog, startedAt, windowStory),
);

/// Where the zero-byte attempts' patience came from (gh-1617 AC4/AC5):
/// the governing idle window + its precedence source, and the explicit
/// connect budget when one clipped the replay.
final class _ZeroByteWindowStory {
  const _ZeroByteWindowStory({
    required this.window,
    required this.source,
    this.connectBudget,
  });

  /// The idle window the watchdog kills ran under: the fire's own
  /// duration (the interval the agent armed — the derived window),
  /// else the model's explicit window, else the provider default.
  final Duration window;

  /// The rendered precedence source (`role <role> override` /
  /// `provider:<name>` / `global` / `default`).
  final String source;

  /// The explicitly configured connect budget, when one is (AC4).
  final (Duration, String)? connectBudget;
}

/// Resolves the window story for a zero-byte verdict (gh-1617): the
/// watchdog interval that actually killed the attempts wins ([fireWindow]
/// — the fire carries the agent's derived window), falling back to the
/// gh-1554 precedence and then the provider default for direct-ladder
/// callers whose cancel reason carries no duration.
_ZeroByteWindowStory _zeroByteWindowStory(Model model, Duration? fireWindow) {
  final explicit = explicitStreamIdleForModel(model);
  final window = fireWindow ?? explicit?.$1 ?? providerStreamIdleTimeout;
  return _ZeroByteWindowStory(
    window: window,
    source: explicit?.$2 ?? 'default',
    connectBudget: explicitConnectForModel(model),
  );
}

/// The per-attempt evidence line every exhaustion terminal embeds: the
/// attempt log joined with `; ` and trailing-dot stripping, so the
/// sentences read cleanly (the shared terminal-story shape, gh-1602
/// review r1 thread 4).
String _storyLog(List<String> attemptLog) => attemptLog
    .map(
      (line) => line.endsWith('.') ? line.substring(0, line.length - 1) : line,
    )
    .join('; ');

/// The elapsed text every terminal story reports: whole seconds, `<1s`
/// under the second.
String _storyElapsed(DateTime startedAt) {
  final elapsed = DateTime.now().difference(startedAt);
  return elapsed.inSeconds < 1 ? '<1s' : '${elapsed.inSeconds}s';
}

/// The shared terminal-story builder (gh-1602 review r1 thread 4): the
/// exhaustion terminals (issue #290 AC2, gh-1308, gh-1602) differ only in
/// their headline story — the message shell (empty content, the model's
/// identity, zero usage, error stop) and the evidence format are one
/// shape, so a future evidence-format change stays single-touch.
/// [_resumedExhaustion] keeps its own shell (the snapshot's content,
/// usage, and raw vendor verdict ride along) but shares the evidence
/// helpers above.
AssistantMessage _terminalStory(
  Model model,
  List<String> attemptLog,
  DateTime startedAt,
  String story,
) => AssistantMessage(
  content: const [],
  api: model.api,
  provider: model.provider,
  model: model.id,
  usage: Usage.zero,
  stopReason: StopReason.error,
  errorMessage: story,
  timestamp: DateTime.now(),
);

/// The zero-byte stall story (see [_zeroByteStallTerminal]).
AssistantMessage _zeroByteStallMessage(
  Model model,
  List<String> attemptLog,
  DateTime startedAt,
  _ZeroByteWindowStory windowStory,
) {
  // gh-1617 AC5: the terminal names the effective window and its
  // precedence source, and suggests raising streamIdleTimeoutMs for a
  // genuinely warming-up model. The window head is single-sourced
  // (review r2): only the connect-budget branch appends the extra
  // clause.
  final head =
      'Idle window ${formatProviderTimeout(windowStory.window)} '
      '(${windowStory.source})';
  // gh-1617 AC4: a connect budget below the window stopped the replay —
  // both values are named so the config conflict is readable at a glance.
  final connect = windowStory.connectBudget;
  final windowNote = connect != null && connect.$1 < windowStory.window
      ? '$head; the configured connectTimeoutMs '
            '${formatProviderTimeout(connect.$1)} (${connect.$2}) stopped the '
            'replay budget at ${attemptLog.length} attempt(s).'
      : '$head.';
  return _terminalStory(
    model,
    attemptLog,
    startedAt,
    'Provider zero-byte stall after ${attemptLog.length} attempt(s) '
    'over ${_storyElapsed(startedAt)} — the endpoint accepted the request '
    'but never produced output; the run-idle watchdog killed every silent '
    'attempt ($zeroByteStallTag). Attempts: ${_storyLog(attemptLog)}. '
    '$windowNote To wait longer on a warming-up model, raise '
    'providerTimeouts.streamIdleTimeoutMs. The failure is retryable: a '
    'fallback model may take over, or check the provider status / try '
    'again later.',
  );
}

/// The exhaustion terminal message (issue #290 AC2): the story is the
/// headline; the raw provider lines ride inside as per-attempt evidence.
AssistantMessage _exhausted(
  Model model,
  List<String> attemptLog,
  DateTime startedAt,
) => _terminalStory(
  model,
  attemptLog,
  startedAt,
  'Provider call failed after ${attemptLog.length} attempt(s) '
  'over ${_storyElapsed(startedAt)} — the endpoint kept failing. '
  'Attempts: ${_storyLog(attemptLog)}. '
  'Check the provider status or try again later.',
);

/// The gh-1602 deadline terminal: the provider is still rate limited and
/// the armed session deadline has no retry budget left past the wrap-up
/// margin — retrying would eat the window reserved for the final answer,
/// so the ladder fails now and truthfully. The headline names the rate
/// limit (every classifier above keys on it) and the raw 429 lines ride
/// as per-attempt evidence, exactly like [_exhausted].
AssistantMessage _rateLimitDeadlineTerminal(
  Model model,
  List<String> attemptLog,
  DateTime startedAt,
) => _terminalStory(
  model,
  attemptLog,
  startedAt,
  'Provider rate limit persisted across ${attemptLog.length} '
  'attempt(s) over ${_storyElapsed(startedAt)} — the session deadline '
  'leaves no retry budget past the wrap-up margin, so the run stops '
  'here. Attempts: ${_storyLog(attemptLog)}. Check the provider status '
  'or try again later.',
);

/// The resumed-exhaustion terminal (issue #1168 review): a transport
/// chain that resumed from its completed prefix and STILL spent its
/// budget surfaces the full story - attempts, elapsed, the resume
/// provenance - instead of the raw provider wording. The
/// [transientExhaustionHeadline] signature lets every classification
/// layer above (this file's, the roles ladder's) recognize the consumed
/// verdict: no further retries, no "not retried" rewrap. The snapshot's
/// own content blocks and raw vendor verdict ride along unchanged; the
/// `_resumeEvent` rewrite adds the earlier attempts' prefix and usage.
AssistantMessage _resumedExhaustion(
  Model model,
  AssistantMessage snapshot,
  List<String> attemptLog,
  _ResumeState resume,
  DateTime startedAt,
) {
  final resumeNote = resume.isEmpty
      ? ''
      : ' The turn resumed from ${resume.blocks.length} completed '
            'block(s) after each failure; the preserved partial answer is '
            'above.';
  return AssistantMessage(
    content: snapshot.content,
    api: snapshot.api,
    provider: snapshot.provider,
    model: snapshot.model,
    usage: snapshot.usage,
    stopReason: StopReason.error,
    errorMessage:
        '$transientExhaustionHeadline ${attemptLog.length} attempt(s) '
        'over ${_storyElapsed(startedAt)} - the endpoint kept failing. '
        'Attempts: ${_storyLog(attemptLog)}.'
        '$resumeNote This verdict is final - no further retries.',
    rawStopReason: snapshot.rawStopReason,
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
  out.push(
    resume == null || resume.isEmpty ? event : _resumeEvent(event, resume),
  );
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
  const _TransientFailure(
    this.error, {
    this.retryAfter,
    this.isRateLimit = false,
  });

  /// The terminal error message (kept for the final forward on exhaustion).
  final AssistantMessage error;

  /// The provider's `Retry-After` hint, when the event carried one
  /// (gh-1602: the rate-limit backoff honors it verbatim, capped at
  /// [rateLimitBackoffCap] — a larger hint waits the cap).
  final Duration? retryAfter;

  /// Whether the failure classed as rate-limit/quota (gh-1602): the
  /// retry then follows the rate-limit policy — its own budget, capped
  /// exponential backoff honoring [retryAfter], and the deadline bound —
  /// instead of the fixed-delay transport policy.
  final bool isRateLimit;
}

/// The attempt aborted mid-stream AFTER observable output (issue #1126):
/// the accumulated snapshot returns to [_drive], which resumes from the
/// completed prefix instead of forwarding the failure. Issue #1168: a
/// connection-class failure after completed blocks rides the same class.
final class _AbortedPartial extends _AttemptOutcome {
  const _AbortedPartial(this.snapshot, this.keptBlocks, this.reason);

  /// The aborted attempt's accumulated message (full content, dead usage).
  final AssistantMessage snapshot;

  /// How many leading content blocks completed (their end event arrived).
  /// The remainder is the in-flight block at the abort and drops from the
  /// anchor (E1: a truncated tool call never executes).
  final int keptBlocks;

  /// The failure's own terminal reason (issue #1168): an aborted attempt
  /// dies as [StopReason.aborted], a connection-class failure as
  /// [StopReason.error] — the budget-exhausted terminal and the retry
  /// notice carry the real reason instead of flattening both classes.
  final StopReason reason;
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

  /// Events withheld until the attempt commits (the start event always;
  /// thinking deltas only under [transientRetryBufferThinking]) or ends.
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

  /// The prefix a resumable mid-stream failure keeps (issue #1126): every
  /// COMPLETED block, plus — since issue #1323 — a still-open THINKING
  /// block. Live streaming (issue #1323) put those reasoning deltas on the
  /// host's screen; the resume anchor must carry them, or the tail attempt
  /// regenerates the reasoning over deltas already rendered — duplicate
  /// thinking in the transcript. An in-flight TEXT or TOOL-CALL block
  /// keeps the drop rule (issue #1126 E1): a truncated call must never
  /// execute, and a truncated block is better regenerated than resumed.
  int resumeKeptBlocks(AssistantMessage snapshot) {
    final kept = lastEnded + 1;
    final inFlight = kept < snapshot.content.length
        ? snapshot.content[kept]
        : null;
    return inFlight is ThinkingContent ? kept + 1 : kept;
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
      final resumable =
          _resumableAbort(event, cancelToken) ||
          _resumableTransportFailure(event, cancelToken);
      if (resumable) {
        final keptBlocks = run.resumeKeptBlocks(event.error);
        if (keptBlocks > 0) {
          return _AbortedPartial(event.error, keptBlocks, event.reason);
        }
        // Nothing survived to anchor a resume (a snapshotless fake): the
        // mid-answer wrap stands — truthful, never a from-scratch replay.
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
/// the transient wire classes always do, and so does the abort class when
/// no one intends the abort — a zero-byte request killed by the run-idle
/// watchdog (issue #1121 bench repro: the watchdog fired at 8 min while
/// the connect ladder was still waiting out a black-holed endpoint) or by
/// the provider/gateway itself with a healthy token (the E5 incident
/// class). A USER abort (bare cancel) stands, and once the transcript
/// holds content the #290 stand-rule owns the failure (post-commit path).
bool _replaysAttempt(ErrorEvent event, CancelToken? cancelToken) {
  if (_retryableWireFailure(event)) return true;
  return _resumableAbort(event, cancelToken);
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
      // gh-1602: a pre-commit rate-limit failure replays under its own
      // policy — checked FIRST, because a 429 wording can also carry a
      // transport-ish phrase ("429: rate limit exceeded, please try again
      // later") and the rate-limit class owns the failure.
      final rateLimited = isRateLimitError(event.error);
      if (rateLimited || _replaysAttempt(event, cancelToken)) {
        // Not forwarded: the buffer is discarded and the call retries.
        return _TransientFailure(
          event.error,
          retryAfter: event.retryAfter,
          isRateLimit: rateLimited,
        );
      }
      run.flushBuffer();
      run.forward(event);
      return const _Forwarded();
    case ThinkingStartEvent() || ThinkingDeltaEvent() || ThinkingEndEvent():
      // Issue #1323, default: the first thinking delta COMMITS the attempt
      // (omp semantics) — reasoning streams live, restoring the pre-#964
      // TUI liveness for reasoning models whose thinking runs minutes
      // ahead of the first text delta. A mid-reasoning transport death
      // then cannot replay from scratch (that would duplicate the deltas
      // already on screen): `resumeKeptBlocks` keeps the streamed thinking
      // in the resume anchor. The #964 replayable-reasoning tradeoff stays
      // one knob away (issue #1323 AC4): with [transientRetryBufferThinking]
      // the deltas buffer in silence until a visible delta commits, so a
      // mid-reasoning drop leaves no trace and the retry regenerates the
      // reasoning (re-billed reasoning accepted, same as any retry).
      if (transientRetryBufferThinking) {
        run.buffer.add(event);
        return null;
      }
      run.commitWith(event);
      return null;
    case StartEvent():
      run.buffer.add(event);
      return null;
    default:
      // The first user-visible content event (text/tool-call family)
      // commits the attempt (issue #964). Post-content semantics: a
      // replay from scratch would duplicate the visible deltas, so a
      // failure can only RESUME from the completed prefix (issue #1168 —
      // transport classes; non-connection failures stand).
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
/// Mid-stream transport wordings are the [#1168] transport class below —
/// they resume too, via the same prefix machinery.
bool _resumableAbort(ErrorEvent event, CancelToken? cancelToken) {
  if (event.reason != StopReason.aborted) return false;
  if (cancelToken == null || !cancelToken.isCancelled) return true;
  return cancelToken.cancelReason is RunIdleWatchdogFire;
}

/// Issue #1168: the mid-stream TRANSPORT class — a connection-class
/// failure ([StopReason.error] carrying a socket drop, connect timeout,
/// DNS cut, or the vendor-transient family) resumes from the completed
/// prefix via the same machinery as the abort class. The transcript keeps
/// the streamed deltas through the anchor rewrite; a replay from scratch
/// would still duplicate text, the resume does not. Non-connection
/// classes (auth, rate limit, overflow, budget, validation) never
/// resume: [_retryableWireFailure] stands them here.
///
/// Cancel contract (aligned with [_resumableAbort], issue #1168 review):
/// a bare user cancel is host intent and stands; a
/// [RunIdleWatchdogFire]-cancelled token is machine intent — the same
/// exception the abort class grants — so the transport class resumes and
/// `_drive` re-arms the latch in place.
bool _resumableTransportFailure(ErrorEvent event, CancelToken? cancelToken) {
  if (cancelToken != null &&
      cancelToken.isCancelled &&
      cancelToken.cancelReason is! RunIdleWatchdogFire) {
    return false;
  }
  return _retryableWireFailure(event);
}

/// A post-commit failure that cannot resume (issue #1168: a connection
/// class with a cancelled token, or any non-connection class) must not
/// surface as a naked provider dump either: retryable ones get the
/// mid-answer story, non-retryable ones pass through verbatim.
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
      message: prefixed(
        message,
      ).copyWith(usage: _sumUsage(resume.usage, message.usage)),
    ),
    ErrorEvent(:final reason, :final error, :final retryAfter) => ErrorEvent(
      reason: reason,
      retryAfter: retryAfter,
      error: prefixed(
        error,
      ).copyWith(usage: _sumUsage(resume.usage, error.usage)),
    ),
  };
}
