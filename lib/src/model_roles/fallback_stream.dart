/// The rate-limit fallback engine: a [StreamFunction] wrapper that walks an
/// ordered chain of models, rotating API keys and failing over on
/// rate-limit/quota errors — mid-turn take-over without silent degradation.
///
/// Ported (reduced) from oh-my-pi's non-compaction retry policy
/// (`docs/non-compaction-retry-policy.md`, `agent-session.ts`
/// `#handleRetryableError`). Mapping and deliberate divergences:
///
/// - omp retries at the session layer (`agent_end` → strip error →
///   `continue()`); this wrapper retries **inside one provider call** (a
///   turn), which keeps the agent loop untouched and gives every
///   [StreamFunction] consumer (agent turns, compaction summaries, plugins)
///   the same policy.
/// - omp's trigger set is broad (overloads, 5xx, network failures, stale
///   replays, refusals). Rate-limit/quota failures ([isRateLimitOrQuota])
///   trigger rotation/fallback, and transient transport failures
///   ([isTransientTransportError] — dropped connections, DNS/TLS, gateway
///   5xx) trigger in-place retries with the same backoff budget; everything
///   else is forwarded verbatim. Context overflow is explicitly excluded —
///   it belongs to the compaction path, same boundary as omp.
/// - omp's observable-output guard is kept: a stream that already emitted
///   content is never silently replayed; its failure stands.
/// - omp emits session events (`auto_retry_start`, `retry_fallback_applied`).
///   Our event types (`AssistantMessageEvent`, `AgentEvent`) are sealed
///   hierarchies in core libraries that this layer cannot extend, so the
///   no-silent-degrade note surfaces through the [FallbackNotice] listener
///   callback instead — hosts render it (the CLI prints a `[roles]` line).
///   The produced [AssistantMessage] itself always carries the fallback
///   model's identity (`provider`/`model`), so the transcript also shows
///   which model actually answered.
library;

import 'dart:async';
import 'dart:math';

import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../overflow.dart';
import '../types.dart';
import 'key_rotation.dart';
import 'roles_config.dart';

/// Patterns classifying a provider error as rate-limit/quota (retryable by
/// rotation/fallback). Kept text-based like omp's classifier
/// (`isUsageLimitError` + transient patterns); structured signal comes from
/// the parsed `Retry-After` on [ErrorEvent.retryAfter].
final _rateLimitPatterns = [
  RegExp(r'rate.?limit', caseSensitive: false),
  RegExp(r'too many requests', caseSensitive: false),
  RegExp(r'\b429\b'),
  RegExp(r'quota', caseSensitive: false),
  RegExp(r'resource.{0,30}exhausted', caseSensitive: false),
  RegExp(r'usage.?limit', caseSensitive: false),
  RegExp(r'throttl', caseSensitive: false),
];

/// Whether [message] is a rate-limit/quota failure the chain may retry.
///
/// Requires an error stop with a message, excludes context overflow (that
/// failure class belongs to compaction, mirroring omp's hard exclusion), and
/// then matches the rate-limit pattern set — HTTP 429 wordings, provider
/// quota messages (OpenAI `insufficient_quota`, Google "Resource has been
/// exhausted", Bedrock throttling) included. [retryAfter] is the structured
/// hint parsed from the `Retry-After` header; its presence alone does not
/// classify (a 500 may carry it).
bool isRateLimitOrQuota(AssistantMessage message, {Duration? retryAfter}) {
  if (message.stopReason != StopReason.error) return false;
  final text = message.errorMessage;
  if (text == null || text.isEmpty) return false;
  if (isContextOverflow(message)) return false;
  return _rateLimitPatterns.any((pattern) => pattern.hasMatch(text));
}

/// Patterns classifying a provider error as a transient transport failure:
/// dropped/refused/reset connections, DNS and TLS handshake failures, and
/// the 5xx server family (500 internal errors, 502/503/504 gateways —
/// production gateways fail with one-off "500: Internal network failure,
/// please try again later", which must retry, not kill the turn).
/// Rate-limit wordings are deliberately excluded — they follow the rotation
/// policy instead.
final _transportPatterns = [
  RegExp(r'connection closed', caseSensitive: false),
  RegExp(r'connection reset', caseSensitive: false),
  RegExp(r'connection refused', caseSensitive: false),
  RegExp(r'connection aborted', caseSensitive: false),
  RegExp(r'connection terminated', caseSensitive: false),
  RegExp(r'connection (attempt )?timed? ?out', caseSensitive: false),
  RegExp(r'socket ?exception', caseSensitive: false),
  RegExp(r'client ?exception', caseSensitive: false),
  RegExp(r'failed host lookup', caseSensitive: false),
  RegExp(r'network is unreachable', caseSensitive: false),
  RegExp(r'no route to host', caseSensitive: false),
  RegExp(r'handshake (failed|error|terminated)', caseSensitive: false),
  RegExp(r'broken pipe', caseSensitive: false),
  RegExp(r'\b50[0234]\b'),
  RegExp(r'bad gateway', caseSensitive: false),
  RegExp(r'service unavailable', caseSensitive: false),
  RegExp(r'gateway time-?out', caseSensitive: false),
  RegExp(r'internal (server|network) error', caseSensitive: false),
  RegExp(r'internal network failure', caseSensitive: false),
  RegExp(r'please try again later', caseSensitive: false),
  // Provider watchdogs surface wedged endpoints as Dart TimeoutExceptions
  // ("TimeoutException after 0:03:00.000000: Future not completed") or
  // plain request-timeout wordings — always retryable.
  RegExp(r'timeout ?exception', caseSensitive: false),
  RegExp(r'request (attempt )?timed? ?out', caseSensitive: false),
  // Truncation class (issue #312): a stream that closes without a
  // finish_reason and without committed content is a cut transport.
  RegExp(r'stream ended without finish_reason'),
];

/// Whether [message] is a transient transport failure the chain may retry
/// in place: the endpoint (or the network path to it) dropped, so rotating
/// credentials is pointless — the same entry is retried with backoff, then
/// the chain fails over to the next model. Context overflow and rate limits
/// are excluded (their own policies own them).
bool isTransientTransportError(AssistantMessage message) {
  if (message.stopReason != StopReason.error) return false;
  final text = message.errorMessage;
  if (text == null || text.isEmpty) return false;
  if (isContextOverflow(message)) return false;
  if (_rateLimitPatterns.any((pattern) => pattern.hasMatch(text))) {
    return false;
  }
  return _transportPatterns.any((pattern) => pattern.hasMatch(text));
}

/// What the wrapper is about to do after a rate-limit failure.
enum FallbackNoticeKind {
  /// Sleeping, then retrying the same chain entry (omp `auto_retry_start`).
  retry,

  /// Switching to another API key of the same entry (omp credential switch).
  keyRotation,

  /// Taking the run over with the next chain entry (omp
  /// `retry_fallback_applied`).
  modelFallback,

  /// Re-trying the same entry after a transient transport failure (a
  /// dropped connection, DNS/TLS failure, or a 502/503/504) — no key
  /// rotation: the endpoint dropped, not the credential.
  transportRetry,
}

/// Why a queue entry died (issue #418 UT-kind-labeling): the exact string
/// a switch event carries. Ordered by classification precedence.
enum QueueDeathKind {
  /// HTTP 429 / quota exhaustion (cooldown follows `Retry-After`).
  quota('quota'),

  /// HTTP 401/403 — the key is dead; advance immediately, no cooldown.
  auth('auth'),

  /// Connect refused / reset / DNS / dropped connection.
  network('network'),

  /// Provider watchdog death (connect or stream-idle timeout).
  timeout('timeout'),

  /// Malformed stream: bad SSE line, non-JSON delta, abrupt close without
  /// a terminal event, 200-with-empty-stream (silent-empty-provider trap).
  malformed('malformed'),

  /// 5xx after the retry ladder is spent.
  fivexx('5xx'),

  /// Unknown/aborted wire finish_reason after transient retries (#312).
  finishReason('finish_reason');

  const QueueDeathKind(this.label);

  /// The exact string switch events and health badges carry.
  final String label;
}

/// One classified provider death: what killed the entry and how the chain
/// should react.
final class QueueDeath {
  /// Creates the classification.
  const QueueDeath({required this.kind, this.cooldown, this.immediate = false});

  /// The death kind (the switch event's label).
  final QueueDeathKind kind;

  /// The base cooldown for the dead entry; null derives from the event's
  /// `Retry-After` (quota) or the policy backoff (everything else).
  final Duration? cooldown;

  /// Whether the chain skips the retry ladder and advances at once
  /// (auth — retrying a dead key is wasted latency).
  final bool immediate;
}

/// Classifies an error event into a queue death, or null when the chain
/// must NOT advance (content_filter family, user abort) and the error
/// surfaces verbatim (issue #418: advance on ANY provider death, never on
/// safety stops).
typedef QueueDeathClassifier = QueueDeath? Function(ErrorEvent event);

/// The sticky RAM cursor and per-entry health of a provider-queue-driven
/// [FallbackStreamFunction] (issue #418). Volatile by contract — restart
/// constructs a fresh wrapper and the queue restarts at its head (AC6);
/// nothing ever persists this object.
final class ProviderQueueState {
  /// Per-entry health: cooldown deadline, consecutive failures, and the
  /// last failure's story.
  final _entries = <int, _QueueEntryHealth>{};

  var _currentIndex = 0;

  /// The entry serving requests right now (the sticky cursor).
  int get currentIndex => _currentIndex;

  /// Records a failed attempt on [index]: bumps the consecutive-failure
  /// count and stores the error story. Returns the failure count AFTER
  /// the bump (the cooldown doubling input).
  int recordFailure(int index, QueueDeathKind kind, String errorText) {
    final health = _entries.putIfAbsent(index, _QueueEntryHealth.new);
    health.consecutiveFailures++;
    health.lastError = errorText;
    health.lastErrorKind = kind;
    return health.consecutiveFailures;
  }

  /// Records a served request on [index]: counters and the error story
  /// reset (success heals — AC5).
  void recordSuccess(int index) {
    _entries.remove(index);
    _currentIndex = index;
  }

  /// Mirrors the wrapper's cooldown decision for [index].
  void recordCooldown(int index, DateTime until) {
    _entries.putIfAbsent(index, _QueueEntryHealth.new).cooldownUntil = until;
  }

  /// Mirrors the wrapper's active entry at call start.
  void recordCurrentIndex(int index) => _currentIndex = index;

  /// Cooldown remaining on [index], or null when healthy.
  Duration? cooldownRemaining(int index, DateTime now) {
    final until = _entries[index]?.cooldownUntil;
    if (until == null) return null;
    if (now.isBefore(until)) return until.difference(now);
    return null;
  }

  /// The entry's consecutive failure count (0 when healthy).
  int consecutiveFailures(int index) =>
      _entries[index]?.consecutiveFailures ?? 0;

  /// The entry's last error text, or null when it never failed.
  String? lastError(int index) => _entries[index]?.lastError;

  /// The entry's last death kind, or null when it never failed.
  QueueDeathKind? lastErrorKind(int index) => _entries[index]?.lastErrorKind;
}

/// Mutable per-entry health of [ProviderQueueState].
final class _QueueEntryHealth {
  DateTime? cooldownUntil;
  var consecutiveFailures = 0;
  String? lastError;
  QueueDeathKind? lastErrorKind;
}

/// The no-silent-degrade note: emitted through the listener callback before
/// every retry/rotation/failover so the degradation is always visible.
final class FallbackNotice {
  /// Creates a notice.
  const FallbackNotice({
    required this.kind,
    required this.fromModel,
    this.toModel,
    this.apiKeyName,
    required this.delay,
    required this.attempt,
    required this.reason,
  });

  /// What happens next.
  final FallbackNoticeKind kind;

  /// The `provider/modelId` that just failed.
  final String fromModel;

  /// The `provider/modelId` taking over (modelFallback only).
  final String? toModel;

  /// The secrets-store name of the key taking over (keyRotation only) — the
  /// name, never the value.
  final String? apiKeyName;

  /// The sleep before the next attempt (zero for key/model switches, per
  /// omp's delay-0-on-switch rule).
  final Duration delay;

  /// 1-based count of rate-limit failures seen in this provider call.
  final int attempt;

  /// The classified failure (truncated provider error text).
  final String reason;

  /// One-line rendering for hosts (the CLI prints it verbatim).
  String describe() {
    final wait = delay == Duration.zero
        ? ''
        : ' in ${(delay.inMilliseconds / 1000).toStringAsFixed(1)}s';
    return switch (kind) {
      FallbackNoticeKind.retry =>
        'rate limited on $fromModel — retrying$wait '
            '(attempt ${attempt + 1})',
      FallbackNoticeKind.keyRotation =>
        'rate limited on $fromModel — rotating API key to $apiKeyName',
      FallbackNoticeKind.modelFallback =>
        'rate limited on $fromModel — falling back to $toModel',
      FallbackNoticeKind.transportRetry =>
        'connection lost on $fromModel — retrying$wait '
            '(attempt ${attempt + 1})',
    };
  }
}

/// One entry of a [FallbackStreamFunction]'s chain: the model to call, its
/// key ring, and the per-key stream factory.
final class ChainEntry {
  /// Creates a chain entry.
  const ChainEntry({
    required this.model,
    required this.keyRing,
    required this.streamForKey,
  });

  /// The model this entry calls (carries provider/baseUrl/limits).
  final Model model;

  /// This entry's API-key stack (round-robin + backoff).
  final ApiKeyRing keyRing;

  /// Builds the provider [StreamFunction] bound to one API key value.
  final StreamFunction Function(String apiKey) streamForKey;

  /// The `provider/modelId` display label.
  String get label => '${model.provider}/${model.id}';
}

sealed class _AttemptOutcome {
  const _AttemptOutcome();
}

/// The attempt's events (or its terminal failure) were forwarded to the
/// caller; the wrapper's work is done.
final class _Forwarded extends _AttemptOutcome {
  const _Forwarded({this.succeeded = false, this.death, this.deathText});

  /// Issue #418 (UT-26): a post-commit (mid-answer) queue death — the
  /// turn stands, but the cursor advances for the NEXT call.
  final QueueDeath? death;

  /// The death's short error text (for the queue health story).
  final String? deathText;

  /// Whether a DoneEvent was forwarded — the entry served the request and
  /// its health counters reset (queue mode bookkeeping).
  final bool succeeded;
}

/// The attempt failed with a retryable error (rate-limit/quota or a
/// transient transport failure) before any observable output; nothing was
/// forwarded.
final class _Retryable extends _AttemptOutcome {
  const _Retryable(
    this.retryAfter,
    this.error, {
    this.isTransport = false,
    this.deathKind,
    this.deathCooldown,
    this.immediate = false,
  });

  /// The provider's `Retry-After` hint, when sent.
  final Duration? retryAfter;

  /// The terminal error message (kept for the final forward if the chain
  /// exhausts).
  final AssistantMessage error;

  /// True for transient transport failures (dropped connection, DNS/TLS,
  /// 502/503/504): retried in place — key rotation is pointless when the
  /// endpoint, not the credential, failed.
  final bool isTransport;

  /// Issue #418: the queue death kind (null in roles mode).
  final QueueDeathKind? deathKind;

  /// Issue #418: the death's explicit base cooldown (quota default when
  /// the provider sent no `Retry-After`); null derives from [retryAfter]
  /// and the policy backoff.
  final Duration? deathCooldown;

  /// Issue #418: skip the retry ladder and advance to the next entry at
  /// once (auth — the key is dead).
  final bool immediate;
}

/// Mutable state of one [_drive] call, extracted so the event-loop phases
/// can live in small methods instead of closures over shared locals.
final class _DriveState {
  _DriveState(this.entryIndex, this.startedAt) : tried = {entryIndex};

  /// The chain entry currently being attempted.
  int entryIndex;

  /// Entries already tried in this call.
  final Set<int> tried;

  /// Paid retries spent on the current entry.
  var attemptsOnEntry = 0;

  /// Rate-limit failures seen in this call.
  var failures = 0;

  /// The most recent retryable failure (forwarded if the chain exhausts).
  _Retryable? lastFailure;

  /// The credential for the next attempt (null = re-select).
  ApiKeyCredential? credential;

  /// When the call started (the exhaustion story reports the elapsed time).
  final DateTime startedAt;

  /// One bounded line per failed attempt (the exhaustion story's
  /// per-attempt outcomes, issue #290 AC2).
  final List<String> attemptLog = [];
}

/// Rewrites a post-commit retryable-class failure into the mid-answer
/// terminal error (AC4). Other failures keep their own story (auth,
/// overflow — those policies own them).
ErrorEvent _midAnswerEvent(ErrorEvent event) {
  final error = event.error;
  // Issue #312: a classified non-terminal finish_reason mid-answer gets
  // the same hygiene wrap (the transcript already holds the deltas); a
  // TERMINAL verdict (content_filter family) keeps its verbatim story.
  final retryClass = finishReasonRetryClass(error);
  final retryable =
      event.reason == StopReason.error &&
      (isRateLimitOrQuota(error, retryAfter: event.retryAfter) ||
          isTransientTransportError(error) ||
          (retryClass != null && retryClass != FinishReasonClass.terminal));
  if (!retryable) return event;
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
          'transcript). Provider error: '
          '${FallbackStreamFunction._shortReasonText(error)}',
      rawStopReason: error.rawStopReason,
      timestamp: error.timestamp,
    ),
  );
}

/// Compact cooldown ETA for queue notices (`45s`, `12m`).
String _etaText(Duration remaining) => remaining.inMinutes >= 1
    ? '${remaining.inMinutes}m'
    : '${remaining.inSeconds}s';

/// Buffers one attempt's events until the first observable output commits
/// the attempt (omp's observable-output guard): a rate-limited attempt that
/// fails before any content leaves no trace in the caller's transcript.
final class _AttemptBuffer {
  _AttemptBuffer([this._queueClassifier]);

  /// Issue #418: the queue death classifier, or null in roles mode.
  final QueueDeathClassifier? _queueClassifier;

  final _buffer = <AssistantMessageEvent>[];
  var _committed = false;

  /// Feeds one event; returns the terminal outcome, or null to keep
  /// streaming.
  _AttemptOutcome? accept(
    AssistantMessageEventStream out,
    AssistantMessageEvent event,
  ) {
    if (_committed) {
      return _forwardCommitted(out, event);
    }
    switch (event) {
      case DoneEvent():
        _buffer.forEach(out.push);
        out.push(event);
        return const _Forwarded(succeeded: true);
      case ErrorEvent():
        return _forwardOrRetryable(out, event);
      case StartEvent():
        _buffer.add(event);
        return null;
      default:
        // Any content event commits the attempt (omp's observable-output
        // guard): from here events stream live and a later failure stands.
        _committed = true;
        _buffer.forEach(out.push);
        out.push(event);
        return null;
    }
  }

  /// Post-commit events stream live; a terminal event ends the attempt. A
  /// retryable-class failure here stands (issue #290 AC4 — observable
  /// output already left; a replay would duplicate the transcript), but it
  /// surfaces as a clean mid-answer error, never a naked provider dump.
  _AttemptOutcome? _forwardCommitted(
    AssistantMessageEventStream out,
    AssistantMessageEvent event,
  ) {
    if (event is ErrorEvent) {
      out.push(_midAnswerEvent(event));
      // The turn stands (no replay — issue #290), but the queue records
      // the death and advances the cursor for the next call (UT-26).
      return _Forwarded(
        death: _queueClassifier?.call(event),
        deathText: (event.error.errorMessage ?? '').split('\n').first,
      );
    }
    if (event is DoneEvent) {
      out.push(event);
      // A completed answer is a success for queue health even when content
      // already streamed (mid-answer completions heal the entry — AC5).
      return const _Forwarded(succeeded: true);
    }
    out.push(event);
    return null;
  }

  /// A pre-commit error: a retryable rate-limit or transport failure is
  /// held back (the buffer is discarded and the chain retries); anything
  /// else is forwarded verbatim.
  _AttemptOutcome _forwardOrRetryable(
    AssistantMessageEventStream out,
    ErrorEvent event,
  ) {
    // Issue #418: queue mode — the classifier is the single decision
    // point. A death rides the retry ladder (or advances at once for
    // auth); a null answer (content_filter family, user abort, unknown)
    // surfaces verbatim.
    final classifier = _queueClassifier;
    if (classifier != null) {
      final death = event.reason == StopReason.error ? classifier(event) : null;
      if (death == null) {
        _buffer.forEach(out.push);
        out.push(event);
        return const _Forwarded();
      }
      return _Retryable(
        event.retryAfter,
        event.error,
        isTransport: true,
        deathKind: death.kind,
        deathCooldown: death.cooldown,
        immediate: death.immediate,
      );
    }
    if (event.reason == StopReason.error &&
        isRateLimitOrQuota(event.error, retryAfter: event.retryAfter)) {
      // Not forwarded: the buffer is discarded and the chain retries.
      return _Retryable(event.retryAfter, event.error);
    }
    final retryClass = finishReasonRetryClass(event.error);
    if (event.reason == StopReason.error &&
        (retryClass != null
            ? retryClass != FinishReasonClass.terminal
            : isTransientTransportError(event.error))) {
      // Not forwarded: same retry path, but the in-place policy (no key
      // rotation) — see [_onRetryable]. A classified finish_reason
      // (issue #312) rides it too: terminal (content_filter family)
      // never retries, transient/unknown vendor words do.
      return _Retryable(event.retryAfter, event.error, isTransport: true);
    }
    _buffer.forEach(out.push);
    out.push(event);
    return const _Forwarded();
  }

  /// Flushes the buffered events (stream closed without a terminal event).
  void flushTo(AssistantMessageEventStream out) => _buffer.forEach(out.push);
}

/// A [StreamFunction] over an ordered [ChainEntry] list with omp's
/// rate-limit policy: rotate keys for free, retry the entry with capped
/// exponential backoff, then fail over to the next entry — every step
/// announced through [onNotice].
///
/// One instance is stateful and long-lived (a session): entry cooldowns and
/// the [activeIndex] persist across calls, and a later call starts at the
/// first entry not in cooldown (omp's `cooldown-expiry` revert policy — the
/// primary model is retried once its cooldown lapses).
final class FallbackStreamFunction {
  /// Creates the wrapper. [entries] must be non-empty. [jitterFraction] and
  /// [sleeper] are injectable for deterministic tests.
  FallbackStreamFunction({
    required List<ChainEntry> entries,
    this.policy = const ModelRolesRetryPolicy(),
    this.onNotice,
    DateTime Function()? now,
    double Function()? jitterFraction,
    Future<bool> Function(Duration delay, CancelToken? cancelToken)? sleeper,

    /// Issue #418: when set, the queue death classifier decides what
    /// advances (7 death kinds) and what surfaces verbatim
    /// (content_filter/user abort). Null keeps the classic rate-limit +
    /// transport policy byte-identical.
    this.queueClassifier,

    /// Issue #418: the sticky-cursor/health state the queue editor reads.
    /// Null in roles mode.
    this.queueState,
  }) : _entries = List.unmodifiable(entries),
       _now = now ?? DateTime.now,
       _jitterFraction = jitterFraction ?? Random().nextDouble,
       _sleeper = sleeper ?? _defaultSleeper {
    if (entries.isEmpty) {
      throw ArgumentError.value(
        entries,
        'entries',
        'a fallback chain needs at least one entry',
      );
    }
  }

  /// The queue death classifier (issue #418); null in roles mode.
  final QueueDeathClassifier? queueClassifier;

  /// The queue's sticky cursor + per-entry health; null in roles mode.
  final ProviderQueueState? queueState;

  final List<ChainEntry> _entries;
  final DateTime Function() _now;
  final double Function() _jitterFraction;
  final Future<bool> Function(Duration delay, CancelToken? cancelToken)
  _sleeper;
  final _cooldownUntil = <int, DateTime>{};

  /// Retry/fallback knobs.
  final ModelRolesRetryPolicy policy;

  /// Receives a [FallbackNotice] before every retry/rotation/failover.
  final void Function(FallbackNotice notice)? onNotice;

  /// The chain entry the last call started on (display state for `/model`).
  int get activeIndex => _activeIndex;
  var _activeIndex = 0;

  /// The chain entry count.
  int get length => _entries.length;

  /// The model currently considered primary for this chain (first entry not
  /// in cooldown).
  Model get currentModel => _entries[_firstAvailableIndex()].model;

  /// Whether chain entry [index] is cooling down right now.
  bool isInCooldown(int index) {
    final until = _cooldownUntil[index];
    if (until == null) return false;
    if (_now().isBefore(until)) return true;
    _cooldownUntil.remove(index);
    return false;
  }

  /// Remaining cooldown of entry [index], or null when not cooling down.
  Duration? cooldownRemaining(int index) {
    if (!isInCooldown(index)) return null;
    return _cooldownUntil[index]!.difference(_now());
  }

  /// The [StreamFunction] entry point. The passed [model] is ignored — the
  /// chain position decides which model is called (the loop passes its
  /// configured model; the resolver keeps `AgentState.model` in sync).
  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final out = AssistantMessageEventStream();
    unawaited(
      _drive(out, context, cancelToken)
          .catchError((Object error) {
            // Defensive (providers never throw; a fake in tests might):
            // convert into the errors-as-events contract.
            final failure = _terminalMessage(
              _entries[_activeIndex].model,
              StopReason.error,
              '$error',
            );
            out.push(ErrorEvent(reason: StopReason.error, error: failure));
          })
          .whenComplete(out.end),
    );
    return out;
  }

  Future<void> _drive(
    AssistantMessageEventStream out,
    Context context,
    CancelToken? cancelToken,
  ) async {
    final state = _DriveState(_firstAvailableIndex(), _now());
    _activeIndex = state.entryIndex;
    queueState?.recordCurrentIndex(state.entryIndex);
    // Issue #418 (UT-23): every entry cooling — die loud with per-entry
    // ETAs instead of silently hammering a benched head.
    final queue = queueState;
    if (queue != null) {
      final now = _now();
      final etas = <String>[
        for (var index = 0; index < _entries.length; index++)
          if (queue.cooldownRemaining(index, now) case final left?)
            '${_entries[index].label} ready in ${_etaText(left)}',
      ];
      if (etas.length == _entries.length) {
        out.push(
          ErrorEvent(
            reason: StopReason.error,
            error: _terminalMessage(
              _entries.first.model,
              StopReason.error,
              'Provider queue cooling down: every entry is in cooldown — '
              '${etas.join(', ')}.',
            ),
          ),
        );
        return;
      }
    }
    while (true) {
      if (cancelToken?.isCancelled ?? false) {
        _pushAborted(out, _entries[state.entryIndex].model);
        return;
      }
      final entry = _entries[state.entryIndex];

      // Credential selection: affinity key unless benched (omp's
      // skip-blocked-sibling rule).
      state.credential ??= entry.keyRing.availableCredential;
      final credential = state.credential;
      if (credential == null) {
        if (!await _onNoCredential(out, state, entry, cancelToken)) return;
        continue;
      }

      if (!await _runAndDispatch(
        out,
        state,
        entry,
        credential,
        context,
        cancelToken,
      )) {
        return;
      }
    }
  }

  /// Runs one attempt on [entry] and dispatches its outcome: forwarded
  /// events end the run (returns false); a retryable rate-limit runs omp's
  /// rotate/retry/fail-over policy and reports whether the loop continues.
  Future<bool> _runAndDispatch(
    AssistantMessageEventStream out,
    _DriveState state,
    ChainEntry entry,
    ApiKeyCredential credential,
    Context context,
    CancelToken? cancelToken,
  ) async {
    final outcome = await _runAttempt(
      out,
      entry,
      credential,
      context,
      cancelToken,
    );
    switch (outcome) {
      case _Forwarded(:final succeeded, :final death):
        if (succeeded) queueState?.recordSuccess(state.entryIndex);
        if (death != null) {
          _markMidAnswerDeath(state, death, outcome.deathText);
        }
        return false;
      case _Retryable():
        return _onRetryable(
          out,
          state,
          entry,
          credential,
          outcome,
          cancelToken,
        );
    }
  }

  /// Selects the next entry after the current one gave up. Returns false
  /// when the chain is exhausted (the last failure has been forwarded).
  bool _failOver(
    AssistantMessageEventStream out,
    _DriveState state, {
    bool noCooldown = false,
  }) {
    final next = _failover(
      state.entryIndex,
      state.tried,
      state.lastFailure,
      failures: state.failures,
      noCooldown: noCooldown,
    );
    if (next == null) {
      _forwardLastFailure(out, state);
      return false;
    }
    state.entryIndex = next;
    _activeIndex = next;
    state.tried.add(next);
    state.attemptsOnEntry = 0;
    // A fresh entry always gets one attempt with its ring's best
    // credential: backoff guides key *selection*, but a benched shared
    // credential must not block the take-over (different model, often a
    // different quota bucket).
    final ring = _entries[next].keyRing;
    state.credential = ring.availableCredential ?? ring.currentCredential;
    return true;
  }

  /// Issue #418 (UT-26): a mid-answer death stands (the turn is already
  /// on the wire), but the queue health records it and the sticky cursor
  /// advances so the NEXT call starts on the next entry.
  void _markMidAnswerDeath(
    _DriveState state,
    QueueDeath death,
    String? errorText,
  ) {
    final qState = queueState;
    if (qState == null) return;
    final from = state.entryIndex;
    final count = qState.recordFailure(from, death.kind, errorText ?? '');
    if (!death.immediate) {
      final base = death.cooldown ?? policy.keyBackoff;
      final doubled = base * (1 << (count - 1).clamp(0, 7));
      final cap = const Duration(hours: 24);
      final until = _now().add(doubled > cap ? cap : doubled);
      _cooldownUntil[from] = until;
      qState.recordCooldown(from, until);
    }
    final next = (from + 1) % _entries.length;
    qState.recordCurrentIndex(next);
    _activeIndex = next;
  }

  /// Paid same-entry retry: sleeps once, then forces the next iteration to
  /// run an attempt. Returns false on abort or when control moved on.
  Future<bool> _sleepAndRetry(
    AssistantMessageEventStream out,
    _DriveState state,
    Duration delay,
    String reason,
    CancelToken? cancelToken, {
    bool isTransport = false,
  }) async {
    state.attemptsOnEntry++;
    state.failures++;
    _notify(
      FallbackNotice(
        kind: isTransport
            ? FallbackNoticeKind.transportRetry
            : FallbackNoticeKind.retry,
        fromModel: _entries[state.entryIndex].label,
        delay: delay,
        attempt: state.failures,
        reason: reason,
      ),
    );
    if (!await _sleeper(delay, cancelToken)) {
      _pushAborted(out, _entries[state.entryIndex].model);
      return false;
    }
    // After the wait: a single-key ring reuses its (benched) key — omp
    // retries the current credential after local backoff; our own bench
    // must not deadlock the retry. Multi-key rings re-select, picking up
    // any sibling whose backoff lapsed during the sleep.
    state.credential = _entries[state.entryIndex].keyRing.length == 1
        ? _entries[state.entryIndex].keyRing.currentCredential
        : null;
    return true;
  }

  /// Every key of [entry] is benched right now: wait for the earliest to
  /// free up, or fail over when the retries are spent / the wait exceeds
  /// the cap. Returns false when the run ends (exhausted or aborted).
  Future<bool> _onNoCredential(
    AssistantMessageEventStream out,
    _DriveState state,
    ChainEntry entry,
    CancelToken? cancelToken,
  ) async {
    if (state.attemptsOnEntry >= policy.retriesPerEntry) {
      return _failOver(out, state);
    }
    final Duration wait;
    if (entry.keyRing.length > 1) {
      // omp's sibling-credential wait: pause until the earliest benched
      // key frees up (plus its 1s buffer).
      wait =
          entry.keyRing.earliestBackoffEnd!.difference(_now()) +
          const Duration(seconds: 1);
    } else {
      wait = _retryDelay(
        state.attemptsOnEntry + 1,
        state.lastFailure?.retryAfter,
      );
    }
    if (wait > policy.maxWait) {
      return _failOver(out, state);
    }
    final lastFailure = state.lastFailure;
    return _sleepAndRetry(
      out,
      state,
      wait,
      lastFailure == null
          ? 'all API keys in backoff'
          : _shortReasonText(lastFailure.error),
      cancelToken,
    );
  }

  /// Handles a retryable failure. Rate-limits follow omp's order: free
  /// credential switch first, then paid retries, then model fallback.
  /// Transport failures skip the credential layer entirely (the endpoint
  /// dropped, not the key) and go straight to paid in-place retries, then
  /// fall over. Returns false when the run ends (exhausted or aborted).
  Future<bool> _onRetryable(
    AssistantMessageEventStream out,
    _DriveState state,
    ChainEntry entry,
    ApiKeyCredential attemptCredential,
    _Retryable outcome,
    CancelToken? cancelToken,
  ) async {
    state.lastFailure = outcome;
    state.attemptLog.add('${entry.label}: ${_shortReasonText(outcome.error)}');
    // Issue #418 (UT-10): auth is a dead key — no retries, no cooldown,
    // advance to the next entry at once.
    if (outcome.immediate) {
      return _failOver(out, state, noCooldown: true);
    }
    if (!outcome.isTransport) {
      entry.keyRing.reportRateLimited(
        attemptCredential.name,
        outcome.retryAfter ?? policy.keyBackoff,
      );
      final rotated = entry.keyRing.rotate(attemptCredential.name);
      if (rotated != null) {
        entry.keyRing.stickTo(rotated);
        state.failures++;
        _notify(
          FallbackNotice(
            kind: FallbackNoticeKind.keyRotation,
            fromModel: entry.label,
            apiKeyName: rotated.name,
            delay: Duration.zero,
            attempt: state.failures,
            reason: _shortReasonText(outcome.error),
          ),
        );
        state.credential = rotated;
        return true;
      }
    }
    if (state.attemptsOnEntry >= policy.retriesPerEntry) {
      return _failOver(out, state);
    }
    final delay = _retryDelay(state.attemptsOnEntry + 1, outcome.retryAfter);
    if (delay > policy.maxWait) {
      return _failOver(out, state);
    }
    return _sleepAndRetry(
      out,
      state,
      delay,
      _shortReasonText(outcome.error),
      cancelToken,
      isTransport: outcome.isTransport,
    );
  }

  /// Picks the next chain entry after [from], skipping entries already tried
  /// in this call and entries in cooldown; marks [from]'s cooldown. Returns
  /// `null` when the chain is exhausted.
  ///
  /// Issue #418: in queue mode the failure is recorded into the sticky
  /// state (kind + count), the cooldown doubles with each consecutive
  /// failure (capped at 24h), and the switch reason carries the exact
  /// death-kind label (UT-17). [noCooldown] (auth deaths) advances
  /// without benching the dead entry.
  int? _failover(
    int from,
    Set<int> tried,
    _Retryable? lastFailure, {
    required int failures,
    bool noCooldown = false,
  }) {
    final failure = lastFailure;
    final queueState = this.queueState;
    Duration cooldown;
    String reason;
    if (failure == null) {
      cooldown = policy.keyBackoff;
      reason = 'rate limited';
    } else if (queueState != null) {
      final count = queueState.recordFailure(
        from,
        failure.deathKind ?? QueueDeathKind.network,
        _shortReasonText(failure.error),
      );
      final base =
          failure.deathCooldown ?? failure.retryAfter ?? policy.keyBackoff;
      final doubled = base * (1 << (count - 1).clamp(0, 7));
      final cap = const Duration(hours: 24);
      final clamped = doubled > cap;
      cooldown = clamped ? cap : doubled;
      reason =
          '${failure.deathKind?.label ?? 'error'}: '
          '${_shortReasonText(failure.error)}'
          '${clamped ? ' (cooldown clamped to 24h)' : ''}';
    } else {
      cooldown = failure.retryAfter ?? policy.keyBackoff;
      reason = _shortReasonText(failure.error);
    }
    if (!noCooldown) {
      final until = _now().add(cooldown);
      _cooldownUntil[from] = until;
      queueState?.recordCooldown(from, until);
    }
    for (var index = 0; index < _entries.length; index++) {
      if (tried.contains(index)) continue;
      if (isInCooldown(index)) continue;
      final entry = _entries[index];
      onNotice?.call(
        FallbackNotice(
          kind: FallbackNoticeKind.modelFallback,
          fromModel: _entries[from].label,
          toModel: entry.label,
          delay: Duration.zero,
          attempt: failures,
          reason: reason,
        ),
      );
      return index;
    }
    return null;
  }

  /// Per-entry health for the exhausted-chain terminal (UT-24): every
  /// entry with its last death kind, error line, and failure count.
  String _queueHealthSummary() {
    final state = queueState!;
    return [
      for (var index = 0; index < _entries.length; index++)
        '${_entries[index].label}: '
            '${state.lastErrorKind(index)?.label ?? 'unknown'}'
            '${state.consecutiveFailures(index) > 0 ? ' x${state.consecutiveFailures(index)}' : ''}'
            '${state.lastError(index) == null ? '' : ' — ${state.lastError(index)}'}',
    ].join('; ');
  }

  Duration _retryDelay(int attempt, Duration? retryAfter) {
    if (retryAfter != null) return retryAfter;
    return policy.backoffFor(attempt, _jitterFraction());
  }

  /// First entry not in cooldown (omp's cooldown-expiry revert policy);
  /// falls back to entry 0 when every entry is cooling down.
  int _firstAvailableIndex() {
    for (var index = 0; index < _entries.length; index++) {
      if (!isInCooldown(index)) return index;
    }
    return 0;
  }

  /// Streams one attempt, buffering events until the first observable output
  /// so a rate-limited attempt leaves no trace in the caller's transcript.
  Future<_AttemptOutcome> _runAttempt(
    AssistantMessageEventStream out,
    ChainEntry entry,
    ApiKeyCredential credential,
    Context context,
    CancelToken? cancelToken,
  ) async {
    final stream = entry.streamForKey(credential.value)(
      entry.model,
      context,
      cancelToken: cancelToken,
    );
    final attempt = _AttemptBuffer(queueClassifier);

    await for (final event in stream) {
      final outcome = attempt.accept(out, event);
      if (outcome != null) return outcome;
    }
    // Provider bug (stream closed without a terminal event): flush what we
    // have; the agent loop synthesizes the terminal error.
    attempt.flushTo(out);
    return const _Forwarded();
  }

  /// Chain exhausted (issue #290 AC2/E1): the terminal error carries the
  /// retry story — attempts, elapsed, per-attempt outcomes, the
  /// whole-chain-failed wording, a next-step hint — with the raw provider
  /// lines only as evidence inside, never as the headline.
  void _forwardLastFailure(AssistantMessageEventStream out, _DriveState state) {
    final entry = _entries[state.entryIndex];
    final failure = state.lastFailure;
    if (failure == null) {
      out.push(
        ErrorEvent(
          reason: StopReason.error,
          error: _terminalMessage(
            entry.model,
            StopReason.error,
            'Provider chain exhausted: every chain model is rate limited and '
            'cooling down. The primary model is retried automatically '
            'once its cooldown lapses — check the provider status or try '
            'again later.',
          ),
        ),
      );
      return;
    }
    final elapsed = _now().difference(state.startedAt);
    final elapsedText = elapsed.inSeconds < 1 ? '<1s' : '${elapsed.inSeconds}s';
    final log = state.attemptLog
        .map(
          (line) =>
              line.endsWith('.') ? line.substring(0, line.length - 1) : line,
        )
        .join('; ');
    final queueLines = queueState == null
        ? ''
        : ' Queue health: ${_queueHealthSummary()}.';
    final story =
        'Provider chain exhausted: ${state.tried.length} of '
        '${_entries.length} chain model(s) failed after '
        '${state.attemptLog.length} attempt(s) over $elapsedText. '
        'Attempts: $log.$queueLines '
        'All available models failed with provider-side errors — likely an '
        'outage or quota exhaustion, not a key problem. '
        'Check the provider status or try again later.';
    out.push(
      ErrorEvent(
        reason: StopReason.error,
        error: _terminalMessage(entry.model, StopReason.error, story),
      ),
    );
  }

  void _pushAborted(AssistantMessageEventStream out, Model model) {
    final message = _terminalMessage(
      model,
      StopReason.aborted,
      'Request was aborted',
    );
    out.push(ErrorEvent(reason: StopReason.aborted, error: message));
  }

  AssistantMessage _terminalMessage(
    Model model,
    StopReason reason,
    String text,
  ) {
    return AssistantMessage(
      content: const [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: reason,
      errorMessage: text,
      timestamp: _now(),
    );
  }

  void _notify(FallbackNotice notice) => onNotice?.call(notice);

  static String _shortReasonText(AssistantMessage error) {
    final text = (error.errorMessage ?? 'rate limited').split('\n').first;
    return text.length <= 120 ? text : '${text.substring(0, 120)}...';
  }

  /// Default sleeper: waits [delay], resolving `false` early when
  /// [cancelToken] fires.
  static Future<bool> _defaultSleeper(
    Duration delay,
    CancelToken? cancelToken,
  ) async {
    if (cancelToken == null) {
      await Future<void>.delayed(delay);
      return true;
    }
    final cancelled = await Future.any([
      Future<void>.delayed(delay).then((_) => false),
      cancelToken.onCancel.then((_) => true),
    ]);
    return !cancelled;
  }
}
