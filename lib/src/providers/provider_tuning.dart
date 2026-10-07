/// Per-provider stall-recovery tuning (issue #1398): the tuning knobs that
/// codex-rs ships as provider-entry properties, adopted for this stack —
/// per-provider idle/connect timeouts, server-advertised backoff
/// (`Retry-After`), dual retry budgets, and the data-driven tuning recipe.
///
/// Layering: this file is the CONTRACT + RESOLUTION layer. The runtime
/// mechanics it parameterizes are #1395's recovery ladder (which consumes
/// [resolveRetryBackoff] and [RetryBudgetLedger] on landing) and #1392's
/// instrumentation (which feeds [InterChunkGapRecorder]). Naming stays out
/// of #1395's `stall_*` taxonomy on purpose — this is the tuning table,
/// not the machinery.
///
/// Pure Dart, no IO: every decision function is directly unit-testable and
/// hosts inject config through [providerTuningRegistry] (seeded at boot
/// from the provider registry entries, `bin/fah_runapp.dart`).
///
/// Reference sweep the shapes come from (issue #1398 body):
/// - codex-rs `model-provider-info`: `stream_idle_timeout_ms` is a
///   property of the provider entry, not a global constant;
/// - codex-rs `responses_retry`: dual budgets (connection vs stream) with
///   separate caps, delay doubling ladder, `retry_delay(retry_count)` —
///   the server's advertised delay wins over the ladder, capped;
/// - kimi-code kosong: timeout classification feeds the retry policy.
///
/// Deliberately NOT adopted: codex's 5 s idle default (pinned fact E1:
/// healthy inter-chunk gaps up to ~200 s were measured on glm-5.3-flash —
/// our defaults stay 180 s / 300 s and tuning is opt-in per provider).
library;

import '../exceptions.dart';
import 'provider_common.dart'
    show
        effectiveProviderConnectTimeout,
        effectiveProviderStreamIdleTimeout,
        providerConnectTimeout,
        providerStreamIdleTimeout,
        providerTimeoutsOverride;

// ── Config plumbing ───────────────────────────────────────────────────────

/// Parses one `connectTimeoutMs`/`streamIdleTimeoutMs` field from a
/// registry-entry node (issue #1398): null/absent → null; a positive
/// integer → the duration; anything else → [ConfigException] naming the
/// field and the entry it lives on (strict, like every other config
/// field — a typo must never silently keep the default).
Duration? parseProviderTimeoutMs(Object? node, String field, String where) {
  // ignore: avoid_dynamic_calls
  final value = node;
  if (value == null) return null;
  if (value is! int || value <= 0) {
    throw ConfigException(
      '"$field" on $where must be a positive integer (milliseconds), '
      'got: $value',
    );
  }
  return Duration(milliseconds: value);
}

// ── PerProviderTimeouts (AC1) ─────────────────────────────────────────────

/// Where an effective timeout value came from — rendered into the
/// startup/`[tuning]` log lines so a per-provider override is never
/// silently shadowed by a global one (or vice versa).
enum ProviderTimeoutSource {
  /// The provider registry entry declared it (`provider:<name>`).
  providerEntry,

  /// The global `providerTimeouts:` section (or env fold-in) declared it.
  globalOverride,

  /// The built-in default (180 s connect / 300 s stream-idle).
  builtIn;

  /// The log label: `provider:<name>` for entries, else `global`/`default`.
  String label(String? entryName) => switch (this) {
    providerEntry => 'provider:$entryName',
    globalOverride => 'global',
    builtIn => 'default',
  };
}

/// One resolved timeout pair for a request: the effective durations plus
/// where each came from ([describeProviderTimeouts] renders them).
final class ResolvedProviderTimeouts {
  const ResolvedProviderTimeouts({
    required this.connect,
    required this.streamIdle,
    required this.connectSource,
    required this.streamIdleSource,
    required this.sourceName,
  });

  /// The effective connect/first-headers watchdog for the request.
  final Duration connect;

  /// The effective stream-idle watchdog for the request.
  final Duration streamIdle;

  /// Where each value resolved from.
  final ProviderTimeoutSource connectSource;
  final ProviderTimeoutSource streamIdleSource;

  /// The winning registry entry's name (null for global/default sources).
  final String? sourceName;

  /// The rendered source labels (`default` / `global` / `provider:<name>`),
  /// pre-applied with [sourceName] — what the log lines print.
  String get connectSourceLabel => connectSource.label(sourceName);
  String get streamIdleSourceLabel => streamIdleSource.label(sourceName);

  /// One log line: `connect 180s (default), idle 1.5s (provider:glm-relay)`.
  String describe() =>
      'connect ${_humanize(connect)} '
      '(${connectSource.label(sourceName)}), '
      'idle ${_humanize(streamIdle)} '
      '(${streamIdleSource.label(sourceName)})';
}

String _humanize(Duration d) {
  if (d.inMilliseconds != 0 && d.inMilliseconds % 1000 != 0) {
    final tenths = (d.inMilliseconds / 100).round() / 10;
    return tenths == tenths.roundToDouble()
        ? '${tenths.round()}s'
        : '${tenths}s';
  }
  return '${d.inSeconds}s';
}

/// The per-provider tuning entry registered for one provider registry row
/// (the same place `baseUrl`/keys live — issue #1398 open question 2).
final class ProviderTuningEntry {
  const ProviderTuningEntry({
    required this.name,
    required this.baseUrl,
    this.connect,
    this.streamIdle,
  });

  /// The registry entry's display name (customProviders name, models.custom
  /// key, roles chain label).
  final String name;

  /// The entry's API base URL — the lookup key on the wire: a request URL
  /// under this base (same scheme+host+path prefix) resolves to this entry.
  final String baseUrl;

  /// Connect/first-headers watchdog override; null falls through.
  final Duration? connect;

  /// Stream-idle watchdog override; null falls through.
  final Duration? streamIdle;

  /// Whether this entry overrides anything (entries with both null are
  /// never registered).
  bool get isEmpty => connect == null && streamIdle == null;
}

/// The process-wide per-provider tuning table: registry entries that
/// declare `connectTimeoutMs`/`streamIdleTimeoutMs` are seeded here at
/// boot (and re-seeded on config reload — E4: the NEXT request recomputes,
/// an in-flight one already resolved its values).
final class ProviderTuningRegistry {
  final List<ProviderTuningEntry> _entries = [];

  /// Registers (or replaces, per name+baseUrl) one entry. Entries that
  /// override nothing are ignored — they must never shadow the global
  /// section.
  void register({
    required String name,
    required String baseUrl,
    Duration? connect,
    Duration? streamIdle,
  }) {
    final entry = ProviderTuningEntry(
      name: name,
      baseUrl: baseUrl,
      connect: connect,
      streamIdle: streamIdle,
    );
    if (entry.isEmpty) return;
    _entries.removeWhere((e) => e.name == name && e.baseUrl == baseUrl);
    _entries.add(entry);
  }

  /// Bulk registration (the boot seeder's shape); later entries win per
  /// name+baseUrl.
  void registerAll(Iterable<ProviderTuningEntry> entries) {
    for (final e in entries) {
      register(
        name: e.name,
        baseUrl: e.baseUrl,
        connect: e.connect,
        streamIdle: e.streamIdle,
      );
    }
  }

  /// Drops every entry (test reset; boot re-seeds).
  void clear() => _entries.clear();

  /// Whether the table is empty — the AC6 fast path: no entries means the
  /// wire seams resolve to today's global/default values untouched.
  bool get isEmpty => _entries.isEmpty;

  /// The registered entries (boot notice rendering).
  List<ProviderTuningEntry> get entries => List.unmodifiable(_entries);

  /// The entry serving [url], or null. Match rule: same scheme + host +
  /// (optional port) and the entry's base path is a path prefix of the
  /// request's (entry `https://api.x/v1` matches
  /// `https://api.x/v1/chat/completions` and `https://api.x/v1`, never
  /// `https://api.x/v2` or another host/port).
  ProviderTuningEntry? forUrl(Uri url) {
    for (final entry in _entries) {
      if (_matchesBaseUrl(url, entry.baseUrl)) return entry;
    }
    return null;
  }

  /// The entry registered under an exact name (the AC1 startup log and the
  /// explicit-name lookups).
  ProviderTuningEntry? forName(String name) {
    for (final entry in _entries) {
      if (entry.name == name) return entry;
    }
    return null;
  }
}

bool _matchesBaseUrl(Uri url, String baseUrl) {
  final base = Uri.tryParse(baseUrl);
  if (base == null || !base.hasScheme || !base.hasAuthority) return false;
  if (url.scheme.toLowerCase() != base.scheme.toLowerCase()) return false;
  final basePort = base.hasPort ? base.port : _defaultPort(base.scheme);
  final urlPort = url.hasPort ? url.port : _defaultPort(url.scheme);
  if (url.host.toLowerCase() != base.host.toLowerCase()) return false;
  if (urlPort != basePort) return false;
  final basePath = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  final urlPath = url.path;
  if (basePath.isEmpty) return true;
  return urlPath == basePath || urlPath.startsWith('$basePath/');
}

int? _defaultPort(String scheme) => scheme.toLowerCase() == 'https'
    ? 443
    : scheme.toLowerCase() == 'http'
    ? 80
    : null;

/// The process-wide tuning table (same pattern as
/// `providerTimeoutsOverride`: read on every request, seeded at boot,
/// tests may set it directly).
final ProviderTuningRegistry providerTuningRegistry = ProviderTuningRegistry();

/// Resolves the effective watchdog pair for one request.
///
/// Order (one, documented — issue #1398 AC1): **provider entry > the
/// global `providerTimeouts` override > the built-in defaults**, per
/// FIELD: an entry declaring only `streamIdleTimeoutMs` leaves the
/// connect leg at the global/default value.
ResolvedProviderTimeouts resolveProviderTimeouts({Uri? url, String? name}) {
  ProviderTuningEntry? entry;
  if (name != null) entry = providerTuningRegistry.forName(name);
  entry ??= url == null ? null : providerTuningRegistry.forUrl(url);
  final global = providerTimeoutsOverride;
  return ResolvedProviderTimeouts(
    connect: entry?.connect ?? global?.connect ?? providerConnectTimeout,
    streamIdle:
        entry?.streamIdle ?? global?.streamIdle ?? providerStreamIdleTimeout,
    connectSource: entry?.connect != null
        ? ProviderTimeoutSource.providerEntry
        : global?.connect != null
        ? ProviderTimeoutSource.globalOverride
        : ProviderTimeoutSource.builtIn,
    streamIdleSource: entry?.streamIdle != null
        ? ProviderTimeoutSource.providerEntry
        : global?.streamIdle != null
        ? ProviderTimeoutSource.globalOverride
        : ProviderTimeoutSource.builtIn,
    sourceName: entry?.name,
  );
}

/// The effective connect watchdog for one request URL (the
/// `sendWatchedProviderRequest` seam): the per-provider entry wins over
/// the global effective value, which already folds the section + env.
Duration providerConnectTimeoutForUrl(Uri url) {
  if (providerTuningRegistry.isEmpty) return effectiveProviderConnectTimeout;
  final entry = providerTuningRegistry.forUrl(url);
  if (entry == null) return effectiveProviderConnectTimeout;
  return entry.connect ?? effectiveProviderConnectTimeout;
}

/// The effective stream-idle watchdog for one request URL (the
/// `createSseIterator` seam). Same resolution as
/// [providerConnectTimeoutForUrl], for the idle leg.
Duration providerStreamIdleTimeoutForUrl(Uri url) {
  if (providerTuningRegistry.isEmpty) return effectiveProviderStreamIdleTimeout;
  final entry = providerTuningRegistry.forUrl(url);
  if (entry == null) return effectiveProviderStreamIdleTimeout;
  return entry.streamIdle ?? effectiveProviderStreamIdleTimeout;
}

/// The startup/boot notice line for one resolved pair:
/// `provider tuning glm-relay: connect 180s (default), idle 1.5s
/// (provider:glm-relay)`.
String describeProviderTimeouts(ResolvedProviderTimeouts resolved) =>
    'provider tuning${resolved.sourceName == null ? '' : ' ${resolved.sourceName}'}: '
    '${resolved.describe()}';

// ── ServerAdvertisedBackoff (AC2) ─────────────────────────────────────────

/// Where a retry delay came from — the AC4 trace contract names it on
/// every line (`delay=ladder:10s` / `delay=server:12s` / `delay=clamp:60s`).
enum RetryDelaySource {
  /// The ladder's own step for that attempt.
  ladder,

  /// The server's `Retry-After`, taken verbatim (within the ceiling).
  server,

  /// The server advertised more than the ceiling; the ceiling won and the
  /// advertised value is named on the trace line.
  clamp;

  /// The AC4 label.
  String get label => switch (this) {
    ladder => 'ladder',
    server => 'server',
    clamp => 'clamp',
  };
}

/// The backoff ceiling: no advertised delay may push a wait past 60 s
/// regardless of what the server says (issue #1398 AC2). The ladder's own
/// top step equals it, so the ladder never needs clamping.
const retryBackoffCeiling = Duration(seconds: 60);

/// One backoff decision: the delay to wait, where it came from, and the
/// diagnostic bits the trace line renders.
final class RetryBackoffDecision {
  const RetryBackoffDecision({
    required this.delay,
    required this.source,
    this.advertised,
    this.malformedHeader = false,
    this.rawHeader,
  });

  /// The delay to wait before the next attempt.
  final Duration delay;

  /// Where the delay came from ([RetryDelaySource]).
  final RetryDelaySource source;

  /// The server's advertised delay, when a parseable `Retry-After` was
  /// present (verbatim, pre-clamp — the clamp line names it).
  final Duration? advertised;

  /// E3: a `Retry-After` header was present but unparseable (non-numeric
  /// or an HTTP-date) — the ladder applies and the trace line notes it.
  final bool malformedHeader;

  /// The raw header value when [malformedHeader] (the trace note quotes it).
  final String? rawHeader;
}

/// The doubling ladder for [attempt] (1-based): 5 → 10 → 20 → 40 s, then
/// the 60 s ceiling holds (`stallBackoffCeiling`'s value — #1395's ladder
/// consumes this step function so the source of truth stays here).
Duration retryBackoffLadderStep(int attempt) {
  final clamped = attempt < 1 ? 1 : attempt;
  final seconds = 5 << (clamped - 1).clamp(0, 4);
  return Duration(seconds: seconds > 60 ? 60 : seconds);
}

/// Resolves ONE attempt's backoff delay (issue #1398 AC2):
///
/// - a parseable delta-seconds `Retry-After` wins over the ladder for that
///   attempt ([RetryDelaySource.server]), hard-capped at
///   [retryBackoffCeiling] ([RetryDelaySource.clamp] — the trace names the
///   advertised value the ceiling overrode);
/// - `Retry-After: 0` counts as absent (E2 — the server says "go now",
///   which is what the ladder's short step already does);
/// - a malformed header (non-numeric, negative, or the HTTP-date form)
///   falls back to the ladder and flags [RetryBackoffDecision
///   .malformedHeader] so the trace line can note it (E3).
///
/// Pure: no sleeping, no clock — the caller performs the wait (fake-clock
/// tests assert the DECISION).
RetryBackoffDecision resolveRetryBackoff({
  String? retryAfter,
  required int attempt,
  Duration? ladderStep,
}) {
  final step = ladderStep ?? retryBackoffLadderStep(attempt);
  final raw = retryAfter?.trim() ?? '';
  if (raw.isEmpty) {
    return RetryBackoffDecision(delay: step, source: RetryDelaySource.ladder);
  }
  final seconds = int.tryParse(raw);
  if (seconds == null || seconds < 0) {
    // E3: non-numeric / negative — and the HTTP-date form too (the stall
    // ladder honors delta-seconds only; codex's retry_delay is
    // delta-seconds as well).
    return RetryBackoffDecision(
      delay: step,
      source: RetryDelaySource.ladder,
      malformedHeader: true,
      rawHeader: raw,
    );
  }
  if (seconds == 0) {
    // E2: "0" is absence — the ladder applies.
    return RetryBackoffDecision(delay: step, source: RetryDelaySource.ladder);
  }
  final advertised = Duration(seconds: seconds);
  if (advertised > retryBackoffCeiling) {
    return RetryBackoffDecision(
      delay: retryBackoffCeiling,
      source: RetryDelaySource.clamp,
      advertised: advertised,
    );
  }
  return RetryBackoffDecision(
    delay: advertised,
    source: RetryDelaySource.server,
    advertised: advertised,
  );
}

// ── DualRetryBudgets (AC3) ────────────────────────────────────────────────

/// Which retry budget an attempt draws from (issue #1398 AC3): connect-
/// watchdog/RST/DNS-class failures draw from [connection], idle-watchdog/
/// mid-stream silence from [stream]. A connection storm can never eat the
/// stream budget and vice versa — the counters are fully independent.
enum RetryBudgetClass {
  connection,

  stream;

  /// The AC4 label.
  String get label => switch (this) {
    connection => 'connection',
    stream => 'stream',
  };
}

/// The per-run dual retry budgets (issue #1398 AC3): two independent
/// counters, one per [RetryBudgetClass], each with its own cap — the
/// connection class defaults to 4 (codex-rs order), the stream class to 3.
/// One ledger per run: create it where #1395's per-run state lives.
final class RetryBudgetLedger {
  RetryBudgetLedger({int connectionRetries = 4, int streamRetries = 3})
    : _caps = {
        RetryBudgetClass.connection: connectionRetries,
        RetryBudgetClass.stream: streamRetries,
      };

  final Map<RetryBudgetClass, int> _caps;
  final Map<RetryBudgetClass, int> _used = {
    RetryBudgetClass.connection: 0,
    RetryBudgetClass.stream: 0,
  };

  /// The cap for [kind] (injectable for tests).
  int cap(RetryBudgetClass kind) => _caps[kind]!;

  /// How many attempts of [kind] were consumed so far.
  int used(RetryBudgetClass kind) => _used[kind]!;

  /// Whether [kind]'s budget is spent.
  bool isExhausted(RetryBudgetClass kind) => used(kind) >= cap(kind);

  /// Consumes one attempt of [kind]; false when that budget is exhausted
  /// (the caller escalates instead). Never touches the other counter.
  bool tryConsume(RetryBudgetClass kind) {
    if (isExhausted(kind)) return false;
    _used[kind] = used(kind) + 1;
    return true;
  }

  /// E5: the terminal-error story fragment carrying BOTH counters, so a
  /// dead run reports exactly what each budget spent:
  /// `retry budgets exhausted (connection 4/4, stream 3/3)`.
  String terminalStory() =>
      'retry budgets exhausted '
      '(connection ${used(RetryBudgetClass.connection)}/'
      '${cap(RetryBudgetClass.connection)}, '
      'stream ${used(RetryBudgetClass.stream)}/'
      '${cap(RetryBudgetClass.stream)})';
}

// ── AC4 — the retry trace line ────────────────────────────────────────────

/// The retry trace line format contract (issue #1398 AC4): every retry
/// names the budget it drew from, the attempt (`n/cap`, 1-based), and the
/// delay source with its value.
///
/// - `budget=connection attempt=2/4 delay=ladder:10s`
/// - `budget=stream attempt=1/3 delay=server:12s`
/// - `budget=stream attempt=2/3 delay=clamp:60s (server advertised 300s)`
/// - a malformed header appends ` retry-after malformed ("soon")` (E3).
String formatRetryTraceLine({
  required RetryBudgetClass budget,
  required int attempt,
  required int cap,
  required RetryBackoffDecision decision,
}) {
  final buffer = StringBuffer(
    'budget=${budget.label} attempt=$attempt/$cap '
    'delay=${decision.source.label}:${_traceDuration(decision.delay)}',
  );
  if (decision.source == RetryDelaySource.clamp) {
    buffer.write(
      ' (server advertised ${_traceDuration(decision.advertised!)})',
    );
  }
  if (decision.malformedHeader) {
    buffer.write(' retry-after malformed ("${decision.rawHeader}")');
  }
  return buffer.toString();
}

/// Trace durations render as bare seconds (`12s`) — the format the AC4 UT
/// pins.
String _traceDuration(Duration d) => '${d.inSeconds}s';

// ── DataDrivenTuning (AC5) ────────────────────────────────────────────────

/// The per-model gap summary: nearest-rank percentiles over the recorded
/// inter-chunk gaps plus the idle-watchdog fire count.
final class GapSummary {
  const GapSummary({
    required this.model,
    required this.samples,
    required this.p50,
    required this.p95,
    required this.watchdogFires,
  });

  /// The model id the samples were recorded under.
  final String model;

  /// How many gap samples were recorded.
  final int samples;

  /// Nearest-rank 50th percentile inter-chunk gap.
  final Duration p50;

  /// Nearest-rank 95th percentile inter-chunk gap.
  final Duration p95;

  /// How many idle-watchdog fires were recorded for this model.
  final int watchdogFires;

  /// The tuning recipe (issue #1398 AC5): set `streamIdleTimeoutMs ≈
  /// 2× p95` — tight enough to catch a wedged stream, loose enough never
  /// to false-fire on healthy thinking gaps.
  Duration get recipeSuggestion => p95 * 2;
}

/// Records inter-chunk gap samples and idle-watchdog fires per model.
///
/// This is the report/seam half of DataDrivenTuning: #1392's LatencyMeter
/// (chunk timestamps) and the idle-watchdog fire sites feed it; the run
/// report renders [renderTuningReport]. All methods are cheap (append +
/// counter) and safe to call from stream paths.
final class InterChunkGapRecorder {
  final Map<String, List<Duration>> _gaps = {};
  final Map<String, int> _fires = {};

  /// Records one gap between consecutive chunks for [model].
  void recordGap(String model, Duration gap) {
    _gaps.putIfAbsent(model, () => []).add(gap);
  }

  /// Records one idle-watchdog fire for [model].
  void recordWatchdogFire(String model) {
    _fires[model] = (_fires[model] ?? 0) + 1;
  }

  /// The summary for [model], or null when nothing was recorded.
  GapSummary? summary(String model) {
    final gaps = _gaps[model];
    final fires = _fires[model] ?? 0;
    if ((gaps == null || gaps.isEmpty) && fires == 0) return null;
    final sorted = [...?gaps]..sort();
    return GapSummary(
      model: model,
      samples: sorted.length,
      p50: _nearestRank(sorted, 0.50),
      p95: _nearestRank(sorted, 0.95),
      watchdogFires: fires,
    );
  }

  /// Every model with recorded data, sorted by model id.
  Map<String, GapSummary> get summaries => {
    for (final model
        in (_gaps.keys.toSet()..addAll(_fires.keys)).toList()..sort())
      model: summary(model)!,
  };

  /// Drops all recorded data (test reset / per-run scope).
  void clear() {
    _gaps.clear();
    _fires.clear();
  }
}

/// Nearest-rank percentile over a SORTED sample list (empty → zero).
Duration _nearestRank(List<Duration> sorted, double p) {
  if (sorted.isEmpty) return Duration.zero;
  final rank = (p * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

/// The process-wide recorder — the seam #1392's meter and the watchdog
/// fire sites feed; hosts may swap it per run.
final InterChunkGapRecorder interChunkGapRecorder = InterChunkGapRecorder();

/// Renders the tuning report (issue #1398 AC5): per-model p50/p95
/// inter-chunk gap, watchdog-fire counts, and the recipe line
/// (`streamIdleTimeoutMs ≈ 2× p95 → <value>`). Empty string when no
/// instrumentation data is present — the report section simply does not
/// render (AC5's "when instrumentation data is present").
String renderTuningReport({InterChunkGapRecorder? recorder}) {
  final summaries = (recorder ?? interChunkGapRecorder).summaries;
  if (summaries.isEmpty) return '';
  final buffer = StringBuffer('tuning report (inter-chunk gap):\n');
  for (final summary in summaries.values) {
    buffer
      ..write(
        '  ${summary.model}: p50 ${_humanize(summary.p50)} '
        'p95 ${_humanize(summary.p95)} '
        '(n=${summary.samples}, watchdog fires ${summary.watchdogFires})',
      )
      ..write(
        ' — recipe: streamIdleTimeoutMs ≈ 2× p95 → '
        '${_humanize(summary.recipeSuggestion)}\n',
      );
  }
  return buffer.toString();
}
