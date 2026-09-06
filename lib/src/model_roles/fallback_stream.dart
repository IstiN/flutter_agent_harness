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
  const _Forwarded();
}

/// The attempt failed with a retryable error (rate-limit/quota or a
/// transient transport failure) before any observable output; nothing was
/// forwarded.
final class _Retryable extends _AttemptOutcome {
  const _Retryable(this.retryAfter, this.error, {this.isTransport = false});

  /// The provider's `Retry-After` hint, when sent.
  final Duration? retryAfter;

  /// The terminal error message (kept for the final forward if the chain
  /// exhausts).
  final AssistantMessage error;

  /// True for transient transport failures (dropped connection, DNS/TLS,
  /// 502/503/504): retried in place — key rotation is pointless when the
  /// endpoint, not the credential, failed.
  final bool isTransport;
}

/// Mutable state of one [_drive] call, extracted so the event-loop phases
/// can live in small methods instead of closures over shared locals.
final class _DriveState {
  _DriveState(this.entryIndex) : tried = {entryIndex};

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
}

/// Buffers one attempt's events until the first observable output commits
/// the attempt (omp's observable-output guard): a rate-limited attempt that
/// fails before any content leaves no trace in the caller's transcript.
final class _AttemptBuffer {
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
        return const _Forwarded();
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

  /// Post-commit events stream live; a terminal event ends the attempt.
  _AttemptOutcome? _forwardCommitted(
    AssistantMessageEventStream out,
    AssistantMessageEvent event,
  ) {
    out.push(event);
    if (event is DoneEvent || event is ErrorEvent) {
      return const _Forwarded();
    }
    return null;
  }

  /// A pre-commit error: a retryable rate-limit or transport failure is
  /// held back (the buffer is discarded and the chain retries); anything
  /// else is forwarded verbatim.
  _AttemptOutcome _forwardOrRetryable(
    AssistantMessageEventStream out,
    ErrorEvent event,
  ) {
    if (event.reason == StopReason.error &&
        isRateLimitOrQuota(event.error, retryAfter: event.retryAfter)) {
      // Not forwarded: the buffer is discarded and the chain retries.
      return _Retryable(event.retryAfter, event.error);
    }
    if (event.reason == StopReason.error &&
        isTransientTransportError(event.error)) {
      // Not forwarded: same retry path, but the in-place policy (no key
      // rotation) — see [_onRetryable].
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
    final state = _DriveState(_firstAvailableIndex());
    _activeIndex = state.entryIndex;

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
      case _Forwarded():
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
  bool _failOver(AssistantMessageEventStream out, _DriveState state) {
    final next = _failover(
      state.entryIndex,
      state.tried,
      state.lastFailure,
      failures: state.failures,
    );
    if (next == null) {
      _forwardLastFailure(out, _entries[state.entryIndex], state.lastFailure);
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
  int? _failover(
    int from,
    Set<int> tried,
    _Retryable? lastFailure, {
    required int failures,
  }) {
    _cooldownUntil[from] = _now().add(
      lastFailure?.retryAfter ?? policy.keyBackoff,
    );
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
          reason: lastFailure == null
              ? 'rate limited'
              : _shortReasonText(lastFailure.error),
        ),
      );
      return index;
    }
    return null;
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
    final attempt = _AttemptBuffer();

    await for (final event in stream) {
      final outcome = attempt.accept(out, event);
      if (outcome != null) return outcome;
    }
    // Provider bug (stream closed without a terminal event): flush what we
    // have; the agent loop synthesizes the terminal error.
    attempt.flushTo(out);
    return const _Forwarded();
  }

  void _forwardLastFailure(
    AssistantMessageEventStream out,
    ChainEntry entry,
    _Retryable? lastFailure,
  ) {
    final error =
        lastFailure?.error ??
        _terminalMessage(
          entry.model,
          StopReason.error,
          'All API keys for ${entry.label} are rate limited',
        );
    out.push(ErrorEvent(reason: StopReason.error, error: error));
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
