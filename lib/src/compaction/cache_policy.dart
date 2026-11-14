/// Cache-aware routing + usage accounting for the compaction run's LM
/// calls (gh-2101).
///
/// ## The routing policy
///
/// The digest (checkpoint/summary) and judge calls used to opt OUT of
/// prompt caching entirely: every call shipped `cacheRetention: 'none'` and
/// a fresh routing session id, so providers discarded the prefix after each
/// call and every pass of a compaction run paid the full uncached input
/// price again. [CompactionCachePolicy.affine] flips that deliberately:
///
/// - ONE stable run-scoped routing session id shared by every digest/judge
///   call of a compaction run — providers with session affinity (OpenAI
///   `prompt_cache_key`, OpenRouter `x-session-id`) route the run's calls
///   into one cache bucket, so the next pass's request prefix can be served
///   from the cache the previous pass wrote (append-style prefix reuse);
///   Anthropic-family adapters mark the request with ephemeral
///   `cache_control` breakpoints under the `short` retention.
/// - A retention value per call class ([judgeRetention]/[digestRetention],
///   both `'short'` today): ephemeral breakpoints are enough to cover one
///   compaction run's pass ladder — minutes — and never pay the 24h
///   premium; the constants are the single place to tune per class.
/// - The id is NOT the parent conversation's session id, so compaction
///   still never reads from nor writes to the session's cache-affinity
///   bucket (the invariant the legacy `callCompleteSimple` shape existed
///   for).
///
/// Cache semantics vary by provider: adapters without cache knobs (e.g. the
/// Google adapter, implicit caching only) ignore the routing override, so
/// the policy degrades to the uncached behavior there with no extra work.
/// [CompactionCachePolicy.isolated] reproduces the legacy shape verbatim
/// (retention `'none'`, a fresh id per call) as a kill switch and for
/// tests.
///
/// ## The usage accounting
///
/// [CompactionUsageAccumulator] folds the metered `Usage` of the run's LM
/// calls (the adapters surface it through an `onUsage` callback) into
/// [CompactionUsageTotals] — the call count, the token breakdown and the
/// USD cost the pass reports render (duration/cost/cache-hit visibility).
library;

import '../agent/agent_loop.dart' show StreamCacheRouting;
import '../session/uuid.dart' show uuidv7;
import '../types.dart' show Usage;

/// Which compaction LM call class a routing decision is made for.
enum CompactionCallClass {
  /// The structured engine's hide judge (one call per hide pass).
  judge,

  /// The summarizer/digest: checkpoint folds (structured) and the classic
  /// engine's summary calls.
  digest,
}

/// The routing values one compaction LM call rides.
typedef CompactionCacheRouting = ({String? sessionId, String cacheRetention});

/// Per-call-class cache routing for one compaction run's digest/judge
/// calls. See the library docs for the design.
final class CompactionCachePolicy {
  /// The deliberate cache-retention policy per call class (gh-2101).
  ///
  /// `'short'` — ephemeral cache breakpoints / affinity keys, enough to
  /// cover one compaction run's pass ladder, never the 24h retention
  /// premium. The classes are separate constants so a class can be tuned
  /// (or flopped to `'none'`) without touching the call-construction layer.
  static const String judgeRetention = 'short';

  /// See [judgeRetention] — the digest/checkpoint summarizer class.
  static const String digestRetention = 'short';

  const CompactionCachePolicy._(this._routingFor);

  final CompactionCacheRouting Function(CompactionCallClass klass)
      _routingFor;

  /// The cache-affine policy (the default): one stable run-scoped routing
  /// session id shared by every call, retention per call class. [sessionId]
  /// seeds the id (tests / callers that own run identity); null mints a
  /// fresh uuidv7 — one per policy, i.e. one per compaction run.
  factory CompactionCachePolicy.affine({String? sessionId}) {
    final id = sessionId ?? uuidv7();
    return CompactionCachePolicy._(
      (klass) => (
        sessionId: id,
        cacheRetention: klass == CompactionCallClass.judge
            ? judgeRetention
            : digestRetention,
      ),
    );
  }

  /// The legacy kill switch: `cacheRetention: 'none'` plus a fresh routing
  /// session id PER CALL — the pre-gh-2101 shape, kept for tests and for a
  /// config-level opt-out. Never routes through the session's bucket.
  factory CompactionCachePolicy.isolated() {
    return CompactionCachePolicy._(
      (_) => (sessionId: uuidv7(), cacheRetention: 'none'),
    );
  }

  /// The routing values the call class should run under.
  CompactionCacheRouting routingFor(CompactionCallClass klass) =>
      _routingFor(klass);

  /// Installs the class's routing as the zone override the provider
  /// adapters read ([StreamCacheRouting.runWith] body helper).
  T runWith<T>(T Function() body, CompactionCallClass klass) {
    final routing = routingFor(klass);
    return StreamCacheRouting.runWith(
      body,
      sessionId: routing.sessionId,
      cacheRetention: routing.cacheRetention,
    );
  }
}

/// The metered usage of a set of compaction LM calls — immutable totals the
/// pass records carry and the reports render.
final class CompactionUsageTotals {
  const CompactionUsageTotals({
    required this.calls,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
    required this.costUsd,
  });

  final int calls;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final double costUsd;

  static const zero = CompactionUsageTotals(
    calls: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    costUsd: 0,
  );

  /// Share of input tokens served from the prompt cache:
  /// `cacheRead / (input + cacheRead + cacheWrite)`. `null` when the call
  /// set consumed no input at all (or no usage was reported).
  double? get cacheHitRatio {
    final total = inputTokens + cacheReadTokens + cacheWriteTokens;
    if (total == 0) return null;
    return cacheReadTokens / total;
  }

  /// The growth over an earlier snapshot of the same run, clamped at zero
  /// per field (usage counters are monotonic within a run).
  CompactionUsageTotals deltaFrom(CompactionUsageTotals earlier) {
    int clamp(int now, int then) => now > then ? now - then : 0;
    return CompactionUsageTotals(
      calls: clamp(calls, earlier.calls),
      inputTokens: clamp(inputTokens, earlier.inputTokens),
      outputTokens: clamp(outputTokens, earlier.outputTokens),
      cacheReadTokens: clamp(cacheReadTokens, earlier.cacheReadTokens),
      cacheWriteTokens: clamp(cacheWriteTokens, earlier.cacheWriteTokens),
      costUsd: costUsd > earlier.costUsd ? costUsd - earlier.costUsd : 0,
    );
  }
}

/// Mutable fold of one compaction run's LM usage. The adapters write through
/// [add] (wired as their `onUsage` callback); the engines snapshot/fold
/// deltas per pass.
final class CompactionUsageAccumulator {
  int _calls = 0;
  int _inputTokens = 0;
  int _outputTokens = 0;
  int _cacheReadTokens = 0;
  int _cacheWriteTokens = 0;
  double _costUsd = 0;

  /// Folds one provider-reported response usage into the totals. Zero usage
  /// (a provider that reports nothing) contributes nothing.
  void add(Usage usage) {
    if (usage.totalTokens == 0 &&
        usage.input == 0 &&
        usage.cacheRead == 0 &&
        usage.cacheWrite == 0) {
      return;
    }
    _calls++;
    _inputTokens += usage.input;
    _outputTokens += usage.output;
    _cacheReadTokens += usage.cacheRead;
    _cacheWriteTokens += usage.cacheWrite;
    _costUsd += usage.cost.total;
  }

  /// The totals accumulated so far.
  CompactionUsageTotals snapshot() => CompactionUsageTotals(
        calls: _calls,
        inputTokens: _inputTokens,
        outputTokens: _outputTokens,
        cacheReadTokens: _cacheReadTokens,
        cacheWriteTokens: _cacheWriteTokens,
        costUsd: _costUsd,
      );
}

/// Renders a pass duration for the compaction reports (gh-2101): `0.9s`
/// under a second, `12.4s` under a minute, `2m05s` under an hour, `1h02m`
/// beyond. `null`/non-positive input renders `null` — the reports omit the
/// metric instead of printing a zero.
String? formatPassDuration(int? milliseconds) {
  if (milliseconds == null || milliseconds <= 0) return null;
  final seconds = milliseconds / 1000;
  if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) {
    final rest = (seconds - minutes * 60).round();
    return '${minutes}m${rest.toString().padLeft(2, '0')}s';
  }
  final hours = minutes ~/ 60;
  final rest = minutes - hours * 60;
  return '${hours}h${rest.toString().padLeft(2, '0')}m';
}
