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
///   replays, refusals). Per the card, only rate-limit/quota failures
///   ([isRateLimitOrQuota]) trigger rotation/fallback here; everything else
///   is forwarded verbatim. Context overflow is explicitly excluded — it
///   belongs to the compaction path, same boundary as omp.
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

/// What the wrapper is about to do after a rate-limit failure.
enum FallbackNoticeKind {
  /// Sleeping, then retrying the same chain entry (omp `auto_retry_start`).
  retry,

  /// Switching to another API key of the same entry (omp credential switch).
  keyRotation,

  /// Taking the run over with the next chain entry (omp
  /// `retry_fallback_applied`).
  modelFallback,
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

/// The attempt failed with a retryable rate-limit/quota error before any
/// observable output; nothing was forwarded.
final class _RateLimited extends _AttemptOutcome {
  const _RateLimited(this.retryAfter, this.error);

  /// The provider's `Retry-After` hint, when sent.
  final Duration? retryAfter;

  /// The terminal error message (kept for the final forward if the chain
  /// exhausts).
  final AssistantMessage error;
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
    var entryIndex = _firstAvailableIndex();
    _activeIndex = entryIndex;
    final tried = <int>{entryIndex};
    var attemptsOnEntry = 0;
    var failures = 0;
    _RateLimited? lastFailure;
    ApiKeyCredential? credential;

    // Selects the next entry after the current one gave up. Returns false
    // when the chain is exhausted (the last failure has been forwarded).
    Future<bool> failOver() async {
      final next = _failover(
        entryIndex,
        tried,
        lastFailure,
        failures: failures,
      );
      if (next == null) {
        _forwardLastFailure(out, _entries[entryIndex], lastFailure);
        return false;
      }
      entryIndex = next;
      _activeIndex = next;
      tried.add(next);
      attemptsOnEntry = 0;
      // A fresh entry always gets one attempt with its ring's best
      // credential: backoff guides key *selection*, but a benched shared
      // credential must not block the take-over (different model, often a
      // different quota bucket).
      final ring = _entries[next].keyRing;
      credential = ring.availableCredential ?? ring.currentCredential;
      return true;
    }

    // Paid same-entry retry: sleeps once, then forces the next iteration to
    // run an attempt. Returns false on abort or when control moved on.
    Future<bool> sleepAndRetry(Duration delay, String reason) async {
      attemptsOnEntry++;
      failures++;
      _notify(
        FallbackNotice(
          kind: FallbackNoticeKind.retry,
          fromModel: _entries[entryIndex].label,
          delay: delay,
          attempt: failures,
          reason: reason,
        ),
      );
      if (!await _sleeper(delay, cancelToken)) {
        _pushAborted(out, _entries[entryIndex].model);
        return false;
      }
      // After the wait: a single-key ring reuses its (benched) key — omp
      // retries the current credential after local backoff; our own bench
      // must not deadlock the retry. Multi-key rings re-select, picking up
      // any sibling whose backoff lapsed during the sleep.
      credential = _entries[entryIndex].keyRing.length == 1
          ? _entries[entryIndex].keyRing.currentCredential
          : null;
      return true;
    }

    while (true) {
      if (cancelToken?.isCancelled ?? false) {
        _pushAborted(out, _entries[entryIndex].model);
        return;
      }
      final entry = _entries[entryIndex];

      // Credential selection: affinity key unless benched (omp's
      // skip-blocked-sibling rule).
      credential ??= entry.keyRing.availableCredential;
      if (credential == null) {
        // Every key is benched right now.
        if (attemptsOnEntry >= policy.retriesPerEntry) {
          if (!await failOver()) return;
          continue;
        }
        final Duration wait;
        if (entry.keyRing.length > 1) {
          // omp's sibling-credential wait: pause until the earliest benched
          // key frees up (plus its 1s buffer).
          wait =
              entry.keyRing.earliestBackoffEnd!.difference(_now()) +
              const Duration(seconds: 1);
        } else {
          wait = _retryDelay(attemptsOnEntry + 1, lastFailure?.retryAfter);
        }
        if (wait > policy.maxWait) {
          if (!await failOver()) return;
          continue;
        }
        if (!await sleepAndRetry(
          wait,
          lastFailure == null
              ? 'all API keys in backoff'
              : _shortReasonText(lastFailure.error),
        )) {
          return;
        }
        continue;
      }

      final attemptCredential = credential;
      if (attemptCredential == null) continue;
      final outcome = await _runAttempt(
        out,
        entry,
        attemptCredential,
        context,
        cancelToken,
      );
      switch (outcome) {
        case _Forwarded():
          return;
        case _RateLimited(:final retryAfter, :final error):
          lastFailure = outcome;
          entry.keyRing.reportRateLimited(
            attemptCredential.name,
            retryAfter ?? policy.keyBackoff,
          );
          // omp order: free credential switch first, then paid retries, then
          // model fallback.
          final rotated = entry.keyRing.rotate(attemptCredential.name);
          if (rotated != null) {
            entry.keyRing.stickTo(rotated);
            failures++;
            _notify(
              FallbackNotice(
                kind: FallbackNoticeKind.keyRotation,
                fromModel: entry.label,
                apiKeyName: rotated.name,
                delay: Duration.zero,
                attempt: failures,
                reason: _shortReasonText(error),
              ),
            );
            credential = rotated;
            continue;
          }
          if (attemptsOnEntry >= policy.retriesPerEntry) {
            if (!await failOver()) return;
            continue;
          }
          final delay = _retryDelay(attemptsOnEntry + 1, retryAfter);
          if (delay > policy.maxWait) {
            if (!await failOver()) return;
            continue;
          }
          if (!await sleepAndRetry(delay, _shortReasonText(error))) return;
      }
    }
  }

  /// Picks the next chain entry after [from], skipping entries already tried
  /// in this call and entries in cooldown; marks [from]'s cooldown. Returns
  /// `null` when the chain is exhausted.
  int? _failover(
    int from,
    Set<int> tried,
    _RateLimited? lastFailure, {
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
    final buffer = <AssistantMessageEvent>[];
    var committed = false;

    await for (final event in stream) {
      if (committed) {
        out.push(event);
        if (event is DoneEvent || event is ErrorEvent) {
          return const _Forwarded();
        }
        continue;
      }
      switch (event) {
        case DoneEvent():
          buffer.forEach(out.push);
          out.push(event);
          return const _Forwarded();
        case ErrorEvent():
          if (event.reason == StopReason.error &&
              isRateLimitOrQuota(event.error, retryAfter: event.retryAfter)) {
            // Not forwarded: the buffer is discarded and the chain retries.
            return _RateLimited(event.retryAfter, event.error);
          }
          buffer.forEach(out.push);
          out.push(event);
          return const _Forwarded();
        case StartEvent():
          buffer.add(event);
        default:
          // Any content event commits the attempt (omp's observable-output
          // guard): from here events stream live and a later failure stands.
          committed = true;
          buffer.forEach(out.push);
          out.push(event);
      }
    }
    // Provider bug (stream closed without a terminal event): flush what we
    // have; the agent loop synthesizes the terminal error.
    buffer.forEach(out.push);
    return const _Forwarded();
  }

  void _forwardLastFailure(
    AssistantMessageEventStream out,
    ChainEntry entry,
    _RateLimited? lastFailure,
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
