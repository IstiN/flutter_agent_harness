/// The per-session token-usage ledger schema (gh-1241).
///
/// `usage.json` is the FOLDED artifact produced by [UsageChainFolder] over
/// a session's record chain: one record per sessionId forever (I1), with
/// `total == Σ(segments)` at every write (I2), per-segment/per-total
/// `source` markers (I3: `reported` | `estimated` | `mixed` — estimated
/// never silently substitutes reported), a per-model `byModel` split
/// inside each segment and the total (I5), and a `chain` fingerprint so a
/// corrupted or stale artifact is detected and rebuilt instead of merged
/// into (E3). The schema carries ONLY sessionId, model ids, ISO timestamps
/// and integer counts — no prompt text, no keys, no paths (I4; the
/// byte-scan in `usage_hygiene.dart` asserts it on every write).
///
/// All timestamps are derived from chain record timestamps, never from
/// wall clock — running the fold twice over the same chain yields
/// byte-identical output (I6), and clock skew across resume hosts cannot
/// reorder segments (E4: ordering is chain sequence, `at` is
/// informational).
library;

/// Provenance of a token count: the provider reported it inline, the fold
/// estimated it (chars/4 heuristic), or a mix of both kinds inside one
/// segment/total.
enum UsageSource {
  /// Every request in the scope carried provider-reported usage.
  reported,

  /// At least one request in the scope lacked provider usage and was
  /// priced by the estimator; none were reported.
  estimated,

  /// Both reported and estimated requests are present in the scope.
  mixed;

  /// The wire name written into usage.json.
  String get wire => name;

  /// Parses a wire name; tolerates unknown values by treating them as
  /// [UsageSource.estimated] — forward-compat: an older reader must not
  /// mislabel unseen future sources as provider-reported, so the
  /// conservative fallback is `estimated`, never `mixed` (which would
  /// overstate provenance as partly reported).
  factory UsageSource.parse(String? wire) => switch (wire) {
    'reported' => UsageSource.reported,
    'estimated' || null => UsageSource.estimated,
    'mixed' => UsageSource.mixed,
    _ => UsageSource.estimated,
  };
}

/// Integer token totals for one scope (a segment, one model's slice of a
/// scope, or the cumulative total).
final class UsageModelTotals {
  /// Creates [UsageModelTotals].
  const UsageModelTotals({
    this.requests = 0,
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.reasoning,
  });

  /// Every field zero.
  static const zero = UsageModelTotals();

  /// Number of provider requests folded into this scope.
  final int requests;

  /// Prompt (input) tokens.
  final int input;

  /// Completion (output) tokens.
  final int output;

  /// Input tokens served from a provider cache.
  final int cacheRead;

  /// Input tokens written into a provider cache.
  final int cacheWrite;

  /// Reasoning/thinking tokens, when at least one contributing provider
  /// reported them; `null` when no contributor did.
  final int? reasoning;

  /// Adds [other] into a new [UsageModelTotals].
  UsageModelTotals operator +(UsageModelTotals other) => UsageModelTotals(
    requests: requests + other.requests,
    input: input + other.input,
    output: output + other.output,
    cacheRead: cacheRead + other.cacheRead,
    cacheWrite: cacheWrite + other.cacheWrite,
    reasoning: reasoning != null
        ? (other.reasoning ?? 0) + reasoning!
        : other.reasoning,
  );

  /// The flat integer fields in schema order (shared by [UsageSegment] and
  /// [UsageLedgerTotal] serialization — one shape, two hosts).
  Map<String, dynamic> totalsJson() => {
    'requests': requests,
    'input': input,
    'output': output,
    'cacheRead': cacheRead,
    'cacheWrite': cacheWrite,
    if (reasoning != null) 'reasoning': reasoning,
  };

  /// Deserializes the flat integer fields from [json].
  factory UsageModelTotals.totalsFrom(Map<String, dynamic> json) =>
      UsageModelTotals(
        requests: json['requests'] as int? ?? 0,
        input: json['input'] as int? ?? 0,
        output: json['output'] as int? ?? 0,
        cacheRead: json['cacheRead'] as int? ?? 0,
        cacheWrite: json['cacheWrite'] as int? ?? 0,
        reasoning: json['reasoning'] as int?,
      );
}

/// Parses a `byModel` map from raw JSON; entries that are not
/// `string → object` pairs are skipped (tolerant reader).
Map<String, UsageModelTotals> usageByModelFromJson(Object? raw) => {
  if (raw is Map)
    for (final entry in raw.entries)
      if (entry.value is Map)
        entry.key as String: UsageModelTotals.totalsFrom(
          (entry.value as Map).cast<String, dynamic>(),
        ),
};

/// Merges [a] and [b] per model key (I5).
Map<String, UsageModelTotals> mergeUsageByModel(
  Map<String, UsageModelTotals> a,
  Map<String, UsageModelTotals> b,
) {
  final merged = Map<String, UsageModelTotals>.of(a);
  for (final entry in b.entries) {
    merged[entry.key] =
        (merged[entry.key] ?? UsageModelTotals.zero) + entry.value;
  }
  return Map.unmodifiable(merged);
}

/// One closed-or-open segment of a session's usage: the fold of every
/// provider request between two resume boundaries (gh-1241 I1/I2).
final class UsageSegment {
  /// Creates a [UsageSegment].
  const UsageSegment({
    required this.index,
    required this.totals,
    required this.byModel,
    required this.source,
    this.model,
    this.openedAt,
    this.closedAt,
  });

  /// 0-based position in the session's segment sequence (chain order — a
  /// resume APPENDS, never reorders, E4).
  final int index;

  /// The segment's LAST-SEEN model id (gh-1460): the model that served the
  /// segment's final request — the id stamped into the `fa-tokens:`
  /// segment-close line so downstream consumers can price the row.
  /// `null` on segments that never observed a model (legacy chains, or
  /// only zero-filled fallbacks) — the log line then keeps its legacy
  /// shape. Deliberately NOT part of the usage.json schema: it is
  /// rebuildable from the chain and consumed by the log line only.
  final String? model;

  /// Request/token sums over the segment.
  final UsageModelTotals totals;

  /// Per-model split of [totals] (I5); model ids are provider-controlled
  /// strings — schema-validated data, never shell-interpolated.
  final Map<String, UsageModelTotals> byModel;

  /// Provenance marker for this segment (I3).
  final UsageSource source;

  /// When the segment opened (the `usage_segment_start` marker's chain
  /// timestamp, or the first contributing record's). Informational only —
  /// ordering never derives from timestamps (E4).
  final DateTime? openedAt;

  /// When the segment last carried usage (the last contributing record's
  /// chain timestamp). `null` while the segment is open and empty.
  final DateTime? closedAt;

  /// Serializes to a JSON map (schema order fixed for byte-determinism).
  Map<String, dynamic> toJson() => {
    'index': index,
    if (openedAt != null) 'openedAt': openedAt!.toIso8601String(),
    if (closedAt != null) 'closedAt': closedAt!.toIso8601String(),
    ...totals.totalsJson(),
    'byModel': {
      for (final entry in byModel.entries) entry.key: entry.value.totalsJson(),
    },
    'source': source.wire,
  };

  /// Deserializes from a JSON map; unknown fields are ignored
  /// (forward-compat, UT-1).
  factory UsageSegment.fromJson(Map<String, dynamic> json) => UsageSegment(
    index: json['index'] as int? ?? 0,
    totals: UsageModelTotals.totalsFrom(json),
    byModel: usageByModelFromJson(json['byModel']),
    source: UsageSource.parse(json['source'] as String?),
    openedAt: DateTime.tryParse(json['openedAt'] as String? ?? ''),
    closedAt: DateTime.tryParse(json['closedAt'] as String? ?? ''),
  );
}

/// The cumulative view of a ledger: `total == Σ(segments)` at every write
/// (I2), with the per-model breakdown attached (I5) and a total-scope
/// provenance marker (I3).
final class UsageLedgerTotal {
  /// Creates a [UsageLedgerTotal].
  const UsageLedgerTotal({
    required this.totals,
    required this.byModel,
    required this.source,
  });

  /// Cumulative sums over every segment.
  final UsageModelTotals totals;

  /// Per-model cumulative split.
  final Map<String, UsageModelTotals> byModel;

  /// Provenance across the whole ledger (`mixed` when some segments are
  /// reported and others estimated).
  final UsageSource source;

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    ...totals.totalsJson(),
    'byModel': {
      for (final entry in byModel.entries) entry.key: entry.value.totalsJson(),
    },
    'source': source.wire,
  };

  /// Deserializes from a JSON map; unknown fields are ignored.
  factory UsageLedgerTotal.fromJson(Map<String, dynamic> json) =>
      UsageLedgerTotal(
        totals: UsageModelTotals.totalsFrom(json),
        byModel: usageByModelFromJson(json['byModel']),
        source: UsageSource.parse(json['source'] as String?),
      );
}

/// The top-level usage.json artifact: one record per sessionId, forever
/// (I1).
final class UsageLedger {
  /// Creates a [UsageLedger].
  const UsageLedger({
    required this.sessionId,
    required this.segments,
    required this.total,
    required this.chainRecords,
    required this.chainHash,
  });

  /// usage.json schema version written by this build.
  static const schemaVersion = 1;

  /// The session this ledger belongs to.
  final String sessionId;

  /// Number of `--continue`/`--resume` boundaries the session crossed:
  /// `segments.length - 1` (I1).
  int get resumedCount => segments.isEmpty ? 0 : segments.length - 1;

  /// Per-segment folds, chain order.
  final List<UsageSegment> segments;

  /// The cumulative view (I2).
  final UsageLedgerTotal total;

  /// Number of record lines on the session chain this fold consumed —
  /// mismatch with a fresh scan means the artifact is stale (E3).
  final int chainRecords;

  /// `sha256:`-prefixed fingerprint over every non-header chain line —
  /// hand-edits and crash remnants are detected, never merged into (E3).
  final String chainHash;

  /// Serializes to the artifact JSON map (schema order fixed for
  /// byte-determinism, I6).
  Map<String, dynamic> toJson() => {
    'version': schemaVersion,
    'sessionId': sessionId,
    'resumedCount': resumedCount,
    'segments': [for (final segment in segments) segment.toJson()],
    'total': total.toJson(),
    'chain': {'records': chainRecords, 'hash': chainHash},
  };

  /// Deserializes from a JSON map; unknown fields are ignored so newer
  /// writers never brick older readers (UT-1 forward-compat).
  factory UsageLedger.fromJson(Map<String, dynamic> json) {
    final rawSegments = json['segments'];
    final segments = <UsageSegment>[
      if (rawSegments is List)
        for (final segment in rawSegments)
          if (segment is Map)
            UsageSegment.fromJson(segment.cast<String, dynamic>()),
    ];
    final rawTotal = json['total'];
    final rawChain = json['chain'];
    return UsageLedger(
      sessionId: json['sessionId'] as String? ?? '',
      segments: segments,
      total: rawTotal is Map
          ? UsageLedgerTotal.fromJson(rawTotal.cast<String, dynamic>())
          : const UsageLedgerTotal(
              totals: UsageModelTotals.zero,
              byModel: {},
              source: UsageSource.estimated,
            ),
      chainRecords: rawChain is Map ? rawChain['records'] as int? ?? 0 : 0,
      chainHash: rawChain is Map ? rawChain['hash'] as String? ?? '' : '',
    );
  }
}
