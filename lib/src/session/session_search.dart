/// Session-wide archive search (issue #1380, capability A2).
///
/// `session_search` answers archive-scale questions — "what did we decide
/// about the WASM size three weeks ago?" — over the WHOLE session file,
/// including regions the current context hides or has checkpointed. It is
/// a read-only scan of the session JSONL: no new storage, no index to keep
/// consistent (v1 per Q3). Results are pointers, never content — id, kind,
/// timestamp and a clipped preview; the agent then `compact_expand`s what
/// matters (budget discipline unchanged). `mode: map` is the meta layer
/// the agent otherwise improvises with ad-hoc python: record-kind counts,
/// hidden/compacted totals and the checkpoint tree with nesting depth —
/// structure only, never content.
///
/// Correctness over cleverness: every line is decoded and matched on the
/// DECODED text (a raw-line pre-filter would miss matches across JSON
/// escapes). Cost is bounded instead (E4): the scan streams file CONTENT
/// in fixed blocks — content memory stays flat regardless of file size —
/// honors a result cap plus an explicit continuation token, and the
/// accumulator retains only IDs and structure: the id→parent map the
/// branch resolution walks (one entry per record — this is the scan's
/// one honest linear cost: record IDS, never record content) plus the
/// checkpoint span table in map mode (bounded by the referenced ids).
/// Both tree facts and spans resolve on a cheap structure-only census
/// pass, so branch scope caps TRUE branch hits (never abandoned-fork
/// hits) and map mode's span table stays bounded. E5 bounds the work: a
/// query is
/// length-capped, nested-quantifier regexes are REJECTED at parse time
/// (the classic catastrophic-backtracking shape), per-record regex input
/// is capped, and a wall-clock budget stops the scan between records
/// with an honest `truncated` report instead of a hang. Preview text
/// passes to the model as an ordinary tool result, so the redaction
/// pipeline masks it exactly like every other tool output.
library;

import 'dart:convert' as json_conv;

import '../compaction/structured/projection.dart' show recordPreviewSource;
import '../env/execution_env.dart';
import 'session_record.dart';
import 'session_storage.dart' show listSessionSegmentPaths;

/// Which part of the session tree a search covers.
enum SessionSearchScope {
  /// The active branch only (default): from the active leaf to the root.
  branch,

  /// The whole tree, forks included — an abandoned branch still happened.
  tree;

  /// The payload spelling.
  String get jsonName => name;

  /// Tolerant parse: null/unknown falls back to [branch].
  static SessionSearchScope fromName(Object? name) =>
      name == 'tree' ? tree : branch;
}

/// What a call asks the archive for.
enum SessionSearchMode {
  /// Keyword/regex search; returns hits with previews.
  search,

  /// Archive structure: counts, hidden totals, checkpoint tree.
  map;

  /// The payload spelling.
  String get jsonName => name;

  /// Tolerant parse: null/unknown falls back to [search].
  static SessionSearchMode fromName(Object? name) =>
      name == 'map' ? map : search;
}

/// Block size of the streamed file scan (the custom-record scanner's
/// measured value — see `JsonlSessionRepo.debugCustomRecordScanBlockBytes`).
const int sessionSearchScanBlockBytes = 8 << 20;

/// Hits returned per search call before the agent is told to narrow with
/// `kinds`/`before`/`after` or continue with the token. Capped hard: a
/// 1 GB session (E4) must not flood the context with pointers either.
const int defaultSessionSearchMaxHits = 40;

/// The hard ceiling for an explicit `maxHits` argument.
const int maxSessionSearchMaxHits = 200;

/// Characters one preview may carry (AC4: never full content).
const int sessionSearchPreviewChars = 160;

/// Maximum query length (E5): a 10 KB "query" is a paste, not a search.
const int maxSessionSearchQueryChars = 512;

/// Characters of one record's text a REGEX may run over (E5 DoS bound: a
/// catastrophic backtracking pattern must not own the loop forever; the
/// wall-clock budget below is the second guard).
///
/// Honest scoping: a length cap is NOT a time bound on a backtracking
/// engine. The hard guarantee is layered — nested-quantifier patterns
/// (the classic catastrophic shape) are rejected at query parse time,
/// and this cap bounds any single match attempt. The wall-clock budget
/// is checked BETWEEN records, so one unscreened pathological match
/// (ambiguous-alternation shapes like `(a|aa)+` are deliberately not
/// screened) on a capped record can still exceed the budget; that
/// residual is scoped, documented, and preferable to reimplementing a
/// regex engine.
const int sessionSearchRegexTextCapChars = 128 * 1024;

/// Default wall-clock budget of one file scan. Checked BETWEEN records —
/// see [sessionSearchRegexTextCapChars] for the honest per-match scoping.
const Duration sessionSearchTimeBudget = Duration(seconds: 10);

/// A validated, defaulted `session_search` argument set. Build with
/// [SessionSearchQuery.fromArgs] — it throws [FormatException] with a
/// model-readable message for every invalid input (E5: structured error,
/// never a hang and never a bare stack trace).
final class SessionSearchQuery {
  const SessionSearchQuery({
    required this.mode,
    required this.scope,
    this.query = '',
    this.kinds = const {},
    this.before,
    this.after,
    this.regex = false,
    this.maxHits = defaultSessionSearchMaxHits,
    this.continuation = 0,
  });

  /// Parses the tool arguments; throws [FormatException] with a one-line
  /// model-readable reason when a value is invalid.
  factory SessionSearchQuery.fromArgs(Map<Object?, Object?> args) {
    final mode = SessionSearchMode.fromName(args['mode']);
    final scope = SessionSearchScope.fromName(args['scope']);
    final rawQuery = args['query'];
    final query = rawQuery is String ? rawQuery.trim() : '';
    if (mode == SessionSearchMode.search && query.isEmpty) {
      throw const FormatException(
        'query is required (or pass mode: "map" for the archive structure)',
      );
    }
    if (query.length > maxSessionSearchQueryChars) {
      throw FormatException(
        'query is too long (${query.length} chars — max '
        '$maxSessionSearchQueryChars); search for a narrower phrase',
      );
    }
    final regex = args['regex'] == true;
    if (regex && query.isNotEmpty) {
      try {
        RegExp(query);
      } on FormatException catch (error) {
        throw FormatException('invalid regex: ${error.message}');
      }
      if (_hasNestedQuantifier(query)) {
        throw const FormatException(
          'regex has a nested quantifier (a "(a+)+"-shape) — catastrophic '
          'backtracking risk; rephrase the pattern without a quantifier '
          'directly on a quantified group',
        );
      }
    }
    var kinds = const <String>{};
    final rawKinds = args['kinds'];
    if (rawKinds is List) {
      kinds = {
        for (final kind in rawKinds)
          if (kind is String && kind.trim().isNotEmpty) kind.trim(),
      };
    }
    DateTime? parseStamp(String label, Object? value) {
      if (value == null) return null;
      final text = value is String ? value.trim() : '$value';
      if (text.isEmpty) return null;
      final parsed = DateTime.tryParse(text);
      if (parsed == null) {
        throw FormatException(
          '$label must be an ISO-8601 timestamp, got: $text',
        );
      }
      return parsed;
    }

    final maxHitsRaw = args['maxHits'];
    var maxHits = defaultSessionSearchMaxHits;
    if (maxHitsRaw is int && maxHitsRaw > 0) {
      maxHits = maxHitsRaw.clamp(1, maxSessionSearchMaxHits);
    }
    final continuationRaw = args['continuation'];
    final continuation = continuationRaw is int && continuationRaw > 0
        ? continuationRaw
        : 0;
    return SessionSearchQuery(
      mode: mode,
      scope: scope,
      query: query,
      kinds: kinds,
      before: parseStamp('before', args['before']),
      after: parseStamp('after', args['after']),
      regex: regex,
      maxHits: maxHits,
      continuation: continuation,
    );
  }

  /// The search phrase (search mode).
  final String query;

  final SessionSearchMode mode;

  final SessionSearchScope scope;

  /// Record types to keep (`message`, `compaction`, `compact_checkpoint`,
  /// `hidden_range`, `custom`, … — the session file's `type` values).
  /// Empty keeps every kind.
  final Set<String> kinds;

  /// Keep records strictly older / newer than these instants.
  final DateTime? before;
  final DateTime? after;

  /// Match [query] as a case-insensitive regular expression instead of a
  /// literal keyword.
  final bool regex;

  final int maxHits;

  /// Records already examined by earlier calls (the continuation token) —
  /// the scan skips them, so a giant session pages deterministically.
  final int continuation;

  /// The compiled matcher, or null in map mode.
  RegExp? get pattern {
    if (mode == SessionSearchMode.map || query.isEmpty) return null;
    return regex
        ? RegExp(query, caseSensitive: false)
        : RegExp(RegExp.escape(query), caseSensitive: false);
  }
}

/// Whether [pattern] applies a quantifier to a group whose body contains
/// a quantified atom — `(a+)+`, `(a?)*`, `(?:\w+){2,}` — the classic
/// catastrophic-backtracking shape (E5). Escapes and character classes
/// are respected; non-capturing/lookaround group syntax is not mistaken
/// for a quantifier. Ambiguous-alternation shapes such as `(a|aa)+` are
/// deliberately NOT screened (see the honesty note on
/// [sessionSearchRegexTextCapChars]).
bool _hasNestedQuantifier(String pattern) {
  // Per open group: the body contains a quantified atom.
  final groupHasQuantified = <bool>[];
  var inClass = false;
  var escaped = false;
  var lastAtomQuantified = false;
  var lastAtomWasGroup = false;
  var lastGroupHasQuantified = false;
  for (var i = 0; i < pattern.length; i++) {
    final ch = pattern[i];
    if (escaped) {
      escaped = false;
      lastAtomQuantified = false;
      lastAtomWasGroup = false;
      continue;
    }
    if (inClass) {
      if (ch == r'\') {
        escaped = true;
      } else if (ch == ']') {
        inClass = false;
        lastAtomQuantified = false;
        lastAtomWasGroup = false;
      }
      continue;
    }
    switch (ch) {
      case r'\':
        escaped = true;
      case '[':
        inClass = true;
      case '(':
        groupHasQuantified.add(false);
        // `(?:`, `(?=`, `(?!` — group syntax, never a quantifier on the
        // empty atom before the body.
        if (i + 1 < pattern.length && pattern[i + 1] == '?') i++;
        lastAtomQuantified = false;
        lastAtomWasGroup = false;
      case ')':
        if (groupHasQuantified.isNotEmpty) {
          lastGroupHasQuantified = groupHasQuantified.removeLast();
          lastAtomWasGroup = true;
          lastAtomQuantified = false;
        }
      case '+' || '*':
        if (lastAtomWasGroup && lastGroupHasQuantified) return true;
        lastAtomQuantified = true;
        if (groupHasQuantified.isNotEmpty) groupHasQuantified.last = true;
      case '?':
        if (lastAtomQuantified) {
          // Lazy/possessive modifier riding the previous quantifier.
          lastAtomQuantified = false;
          break;
        }
        // `?` never nests catastrophically (the group applies once).
        lastAtomQuantified = true;
        if (groupHasQuantified.isNotEmpty) groupHasQuantified.last = true;
      case '{':
        final isQuantifier = _boundedQuantifierAt(pattern, i);
        if (!isQuantifier) {
          lastAtomQuantified = false;
          lastAtomWasGroup = false;
          break;
        }
        if (lastAtomWasGroup && lastGroupHasQuantified) return true;
        lastAtomQuantified = true;
        if (groupHasQuantified.isNotEmpty) groupHasQuantified.last = true;
      default:
        lastAtomQuantified = false;
        lastAtomWasGroup = false;
    }
  }
  return false;
}

/// Whether [pattern] has a `{n}`, `{n,}` or `{n,m}` quantifier at [at]
/// (a lone `{` is a literal in Dart regexes).
bool _boundedQuantifierAt(String pattern, int at) {
  var i = at + 1;
  if (i >= pattern.length || !_isDigit(pattern.codeUnitAt(i))) return false;
  while (i < pattern.length && _isDigit(pattern.codeUnitAt(i))) {
    i++;
  }
  if (i < pattern.length && pattern[i] == ',') {
    i++;
    while (i < pattern.length && _isDigit(pattern.codeUnitAt(i))) {
      i++;
    }
  }
  return i < pattern.length && pattern[i] == '}';
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// One search hit — a POINTER into the archive, never its content.
final class SessionSearchHit {
  const SessionSearchHit({
    required this.id,
    required this.kind,
    required this.timestamp,
    required this.preview,
  });

  final String id;

  /// The record's `type` (`message`, `compact_checkpoint`, …).
  final String kind;

  final DateTime timestamp;

  /// The clipped, single-line first look at the content.
  final String preview;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'timestamp': timestamp.toIso8601String(),
    'preview': preview,
  };
}

/// One checkpoint in the archive map: span pointers and nesting depth.
final class CheckpointMapEntry {
  const CheckpointMapEntry({
    required this.id,
    required this.firstRecordId,
    required this.lastRecordId,
    required this.coversCount,
    required this.depth,
  });

  final String id;
  final String firstRecordId;
  final String lastRecordId;

  /// How many record ids the checkpoint's `coversRecordIds` carries.
  final int coversCount;

  /// Nesting depth: 1 for a top-level checkpoint, +1 per containing
  /// checkpoint span.
  final int depth;
}

/// The archive structure `mode: map` reports — counts and spans only,
/// never content (safe by construction).
final class SessionArchiveMap {
  const SessionArchiveMap({
    required this.recordCount,
    required this.kindCounts,
    required this.hiddenRangeCount,
    required this.hiddenRecordIdCount,
    required this.checkpoints,
    required this.maxCheckpointDepth,
    required this.branchRecordCount,
    required this.leafId,
  });

  final int recordCount;
  final Map<String, int> kindCounts;

  /// Hidden/compacted totals: how many `hidden_range` fold records exist
  /// and how many record ids they cover in sum (a record under several
  /// ranges counts per range — this is a raw census, not the projection).
  final int hiddenRangeCount;
  final int hiddenRecordIdCount;

  final List<CheckpointMapEntry> checkpoints;
  final int maxCheckpointDepth;

  /// Records on the active branch (tree-wide [recordCount] minus forks).
  final int branchRecordCount;

  /// The active leaf's record id, when the scan saw one.
  final String? leafId;
}

/// The outcome of one archive search call.
final class SessionSearchOutcome {
  const SessionSearchOutcome({
    required this.hits,
    required this.recordsExamined,
    required this.recordsTotal,
    required this.truncated,
    this.nextContinuation,
    this.map,
    this.truncationReason = '',
    this.unavailableReason = '',
  });

  final List<SessionSearchHit> hits;

  /// Records this call actually looked at (after the continuation skip).
  final int recordsExamined;

  /// Records the whole file chain holds.
  final int recordsTotal;

  /// True when the call stopped early — hit cap, time budget, or a scan
  /// error — and more archive remains.
  final bool truncated;

  /// The continuation token for the next call (records already examined),
  /// set whenever [truncated] is true and the stop was clean (result cap
  /// or time budget — both resume deterministically; a scan ERROR may
  /// have stopped mid-segment, so no token is offered there).
  final int? nextContinuation;

  /// Set in map mode.
  final SessionArchiveMap? map;

  /// Why the scan stopped early (`result cap`, `time budget`, …) — empty
  /// when it ran to the end.
  final String truncationReason;

  /// Set when the archive could not be searched AT ALL (e.g. no session
  /// file backs the host) — the formatter prints it verbatim instead of
  /// rendering a completed-but-empty scan, which would dishonestly claim
  /// the archive was searched and holds nothing.
  final String unavailableReason;
}

/// The clipped single-line preview a hit carries (AC4: never full
/// content; newlines flatten so one hit is one line).
String sessionSearchPreview(String text) {
  final flat = text.replaceAll('\n', ' ').trim();
  if (flat.length <= sessionSearchPreviewChars) return flat;
  return '${flat.substring(0, sessionSearchPreviewChars - 1)}…';
}

/// The searchable text of [record] — the same flat content the context
/// projection previews draw from, plus `custom` payloads serialized (the
/// obligations ledger is a `custom` record; its entries must be
/// searchable). Image blocks collapse to kind-named placeholders, so a
/// preview never carries base64.
String sessionSearchText(SessionRecord record) {
  final base = recordPreviewSource(record);
  if (base.isNotEmpty || record is! CustomRecord) return base;
  try {
    return json_conv.jsonEncode(record.data);
  } on Object {
    return '';
  }
}

/// Whether [record] passes the query's kind/time filters.
bool _passesFilters(SessionRecord record, SessionSearchQuery query) {
  if (query.kinds.isNotEmpty && !query.kinds.contains(record.type)) {
    return false;
  }
  if (query.before != null && !record.timestamp.isBefore(query.before!)) {
    return false;
  }
  if (query.after != null && !record.timestamp.isAfter(query.after!)) {
    return false;
  }
  return true;
}

/// Whether the record's text matches the query (literal keyword or
/// case-insensitive regex — the compiled [pattern]).
bool _matches(SessionRecord record, RegExp pattern) {
  final text = sessionSearchText(record);
  if (text.isEmpty) return false;
  final capped = text.length > sessionSearchRegexTextCapChars
      ? text.substring(0, sessionSearchRegexTextCapChars)
      : text;
  return pattern.hasMatch(capped);
}

/// The accumulator one scan feeds: filters, collects, and tracks the
/// continuation state. One instance per search call — NOT reusable.
///
/// Retention (the E4 honesty note): `_parentOf` keeps one id→parentId
/// pair per record seen — record IDS only, never record content — and
/// grows with the archive's record count, not its bytes. Map mode keeps
/// ordinals ONLY for the ids checkpoints reference (seeded by a cheap
/// census pass), so the span table stays bounded by checkpoint coverage.
final class _ScanAccumulator {
  _ScanAccumulator(
    this.query, {
    DateTime? deadline,
    this.censusOnly = false,
    Set<String> ordinalWanted = const {},
    Set<String> branchIds = const {},
    // A private NAMED initializing formal is not part of the parameter
    // list, so the lint is suppressed at the parameter list instead.
    // ignore: prefer_initializing_formals
  }) : _deadline = deadline,
       _pattern = query.pattern,
       _ordinalWanted = Set<String>.of(ordinalWanted),
       _branchIds = Set<String>.of(branchIds);

  final SessionSearchQuery query;
  final DateTime? _deadline;
  final RegExp? _pattern;

  /// Census mode: a cheap first pass that collects ONLY structure — the
  /// parent/leaf tree (always), plus the checkpoint records and the ids
  /// they reference (map mode). Its product seeds the real pass: the
  /// FINAL active branch set (branch scope — so the result cap counts
  /// branch hits with full knowledge, not leaf-so-far guesses) and the
  /// wanted-ordinal table (map mode). Never feeds hits.
  final bool censusOnly;

  final _hits = <SessionSearchHit>[];
  final _parentOf = <String, String?>{};
  final _kindCounts = <String, int>{};
  final _checkpoints = <CompactCheckpointRecord>[];
  var _hiddenRangeCount = 0;
  var _hiddenRecordIdCount = 0;

  /// Map mode only: the ids whose file-order ordinals the checkpoint
  /// depth fold needs. The census pass FILLS this set; the real pass is
  /// seeded with it and records ordinals for these ids only.
  final Set<String> _ordinalWanted;
  final _ordinalOf = <String, int>{};

  /// Branch scope only: the FINAL active branch (tip-to-root chain of
  /// the archive's true active leaf), computed by the census pass and
  /// seeded here — a hit off this set never reaches the cap. Empty when
  /// no census ran (tree scope, or a census stopped by the deadline).
  final Set<String> _branchIds;
  var recordsExamined = 0;
  var recordsTotal = 0;
  var _skipped = 0;
  var _stopped = false;
  var _stopReason = '';
  String _activeLeaf = '';

  /// True once the scan should stop feeding records.
  bool get stopped => _stopped;

  void _stop(String reason) {
    _stopped = true;
    _stopReason = reason;
  }

  void checkDeadline() {
    if (_stopped) return;
    final deadline = _deadline;
    if (deadline != null && DateTime.now().isAfter(deadline)) {
      _stop('time budget');
    }
  }

  /// Feeds one decoded record, in file order.
  void seeRecord(SessionRecord record) {
    if (_stopped) return;
    recordsTotal++;
    if (censusOnly) {
      _trackTree(record);
      switch (record) {
        case CompactCheckpointRecord checkpoint:
          _checkpoints.add(checkpoint);
          _ordinalWanted
            ..add(checkpoint.firstRecordId)
            ..add(checkpoint.lastRecordId)
            ..addAll(checkpoint.coversRecordIds);
        default:
          break;
      }
      return;
    }
    if (_skipped < query.continuation) {
      _skipped++;
      // Continued scans still need tree facts (leaf/parents) to stay
      // correct — bookkeeping runs even for skipped records.
      _trackTree(record);
      return;
    }
    recordsExamined++;
    _trackTree(record);
    _kindCounts.update(record.type, (n) => n + 1, ifAbsent: () => 1);
    switch (record) {
      case HiddenRangeRecord(:final recordIds):
        _hiddenRangeCount++;
        _hiddenRecordIdCount += recordIds.length;
      case CompactCheckpointRecord checkpoint:
        _checkpoints.add(checkpoint);
      default:
        break;
    }
    if (query.mode == SessionSearchMode.map) return;
    final pattern = _pattern;
    if (pattern == null) return;
    if (!_passesFilters(record, query)) return;
    if (!_matches(record, pattern)) return;
    if (query.scope == SessionSearchScope.branch &&
        _branchIds.isNotEmpty &&
        !_branchIds.contains(record.id)) {
      // An abandoned-fork hit, known OFF the archive's FINAL active
      // branch (the census pass resolved the true leaf): finish() would
      // drop it, so it must not consume the result cap — the default
      // scope has to deliver full branch pages, not page fork records
      // (the under-delivery + O(n²)-paging bug).
      return;
    }
    if (_hits.length >= query.maxHits) {
      // Cap reached BEFORE this record — stop here; the continuation
      // token re-enters AT this record (recordsTotal counts it), so a
      // capped scan never silently drops the boundary hit.
      _stop('result cap');
      return;
    }
    _hits.add(
      SessionSearchHit(
        id: record.id,
        kind: record.type,
        timestamp: record.timestamp,
        preview: sessionSearchPreview(sessionSearchText(record)),
      ),
    );
  }

  void _trackTree(SessionRecord record) {
    // Leaf semantics match the storage's own (`leafIdAfterSessionRecord`):
    // every appended record becomes the active tip unless an explicit
    // LeafRecord moves the pointer. The tip must track the WHOLE scan —
    // pinning it to the first record would walk the branch set from a
    // stale root and silently drop every branch hit but the root's.
    switch (record) {
      case LeafRecord(:final targetId?):
        if (targetId.isNotEmpty) _activeLeaf = targetId;
      default:
        _activeLeaf = record.id;
    }
    _parentOf[record.id] = record.parentId;
    if (query.mode == SessionSearchMode.map &&
        _ordinalWanted.contains(record.id)) {
      _ordinalOf[record.id] = recordsTotal - 1;
    }
  }

  /// The leaf→root chain of [fromId] (tip included), cycle-safe.
  Set<String> _walkChain(String fromId) {
    final chain = <String>{};
    var cursor = fromId;
    while (cursor.isNotEmpty && chain.add(cursor)) {
      cursor = _parentOf[cursor] ?? '';
    }
    return chain;
  }

  /// Decodes one JSONL line and feeds it. Malformed lines (crash-torn
  /// tails) are skipped, never fatal.
  void seeLine(String line) {
    if (_stopped || line.isEmpty) return;
    final Object? json;
    try {
      json = json_conv.jsonDecode(line);
    } on Object {
      return; // torn tail line from a crash — skip.
    }
    if (json is! Map) return;
    final SessionRecord record;
    try {
      record = SessionRecord.fromJson(json.cast<String, dynamic>());
    } on Object {
      return; // unknown/future record shape (E6) — skip.
    }
    seeRecord(record);
  }

  /// Folds the collected state into the call outcome.
  SessionSearchOutcome finish() {
    final inMapMode = query.mode == SessionSearchMode.map;
    List<CheckpointMapEntry> checkpointEntries = const [];
    var maxDepth = 0;
    final entries = <CheckpointMapEntry>[];
    if (inMapMode && _checkpoints.isNotEmpty) {
      // Nesting depth over file-order record spans: a checkpoint's span
      // runs from its first to its last covered record; another
      // checkpoint NESTS it when its span is a strict superset. Ids the
      // scan never saw (off-chain references) degrade to the
      // checkpoint's own position — depth stays computable, never fatal.
      int spanStart(CompactCheckpointRecord checkpoint, int fallback) =>
          _ordinalOf[checkpoint.firstRecordId] ?? fallback;
      int spanEnd(CompactCheckpointRecord checkpoint, int fallback) =>
          _ordinalOf[checkpoint.lastRecordId] ?? fallback;
      for (var i = 0; i < _checkpoints.length; i++) {
        final checkpoint = _checkpoints[i];
        final start = spanStart(checkpoint, i);
        final end = spanEnd(checkpoint, i);
        var depth = 1;
        for (var j = 0; j < _checkpoints.length; j++) {
          if (j == i) continue;
          final otherStart = spanStart(_checkpoints[j], j);
          final otherEnd = spanEnd(_checkpoints[j], j);
          final strictlyContains =
              (otherStart < start && otherEnd >= end) ||
              (otherStart <= start && otherEnd > end);
          if (strictlyContains) depth++;
        }
        maxDepth = depth > maxDepth ? depth : maxDepth;
        entries.add(
          CheckpointMapEntry(
            id: checkpoint.id,
            firstRecordId: checkpoint.firstRecordId,
            lastRecordId: checkpoint.lastRecordId,
            coversCount: checkpoint.coversRecordIds.length,
            depth: depth,
          ),
        );
      }
      checkpointEntries = entries;
    }
    // Branch scope, search mode: the census-seeded FINAL branch set is
    // the truth (hits were already capped against it at collection);
    // without a census (tree scope, map mode) the walk from the leaf
    // decides, exactly as before.
    final branchIds = _branchIds.isNotEmpty
        ? _branchIds
        : _walkChain(_activeLeaf);
    final hits = query.scope == SessionSearchScope.branch
        ? [
            for (final hit in _hits)
              if (branchIds.contains(hit.id)) hit,
          ]
        : _hits;
    return SessionSearchOutcome(
      hits: hits,
      recordsExamined: recordsExamined,
      recordsTotal: recordsTotal,
      truncated: _stopped,
      nextContinuation:
          _stopped &&
              (_stopReason == 'result cap' || _stopReason == 'time budget')
          ? recordsTotal - 1
          : null,
      map: inMapMode
          ? SessionArchiveMap(
              recordCount: recordsTotal,
              kindCounts: _kindCounts,
              hiddenRangeCount: _hiddenRangeCount,
              hiddenRecordIdCount: _hiddenRecordIdCount,
              checkpoints: checkpointEntries,
              maxCheckpointDepth: maxDepth,
              branchRecordCount: branchIds.length,
              leafId: _activeLeaf.isEmpty ? null : _activeLeaf,
            )
          : null,
      truncationReason: _stopReason,
    );
  }
}

/// Searches an in-memory record list — the pure core the file scan feeds
/// (and the unit tests drive directly). Records must be in file order.
/// Map mode and branch scope run a cheap census pass first: map mode
/// seeds the ordinal table the checkpoint-depth fold needs (bounded by
/// checkpoint-referenced ids), branch scope resolves the archive's FINAL
/// active branch so the result cap counts true branch hits at
/// collection time (the E4 retention note covers the census's cost).
SessionSearchOutcome searchRecords(
  List<SessionRecord> records,
  SessionSearchQuery query,
) {
  final needsCensus =
      query.mode == SessionSearchMode.map ||
      (query.mode == SessionSearchMode.search &&
          query.scope == SessionSearchScope.branch);
  var ordinalWanted = const <String>{};
  var branchIds = const <String>{};
  if (needsCensus) {
    final census = _ScanAccumulator(query, censusOnly: true);
    for (final record in records) {
      census.seeRecord(record);
    }
    ordinalWanted = census._ordinalWanted;
    branchIds = census._walkChain(census._activeLeaf);
  }
  final accumulator = _ScanAccumulator(
    query,
    ordinalWanted: ordinalWanted,
    branchIds: branchIds,
  );
  for (final record in records) {
    accumulator.seeRecord(record);
    if (accumulator.stopped) break;
  }
  return accumulator.finish();
}

/// Streams one session segment, feeding every decoded record to
/// [accumulator]. Blocks stream through a bounded carry buffer (a line
/// may span blocks — the custom-record scanner's technique), so file
/// CONTENT memory stays flat regardless of file size (E4); the
/// accumulator's per-record ID bookkeeping is the documented linear cost
/// (see [_ScanAccumulator]). Malformed lines (crash-torn tails) are
/// skipped, never fatal. Library-private: an implementation detail of
/// [searchSessionFile], not public API.
Future<void> _scanSessionSegment(
  FileSystem fs,
  String path,
  _ScanAccumulator accumulator, {
  int blockBytes = sessionSearchScanBlockBytes,
}) async {
  // The Object bridge is the repo's flow-analysis workaround (the same
  // trick as session_repair's _repairIoSurface): promoting a
  // FileSystem-typed variable to the RangedReadFileSystem SUBTYPE inside
  // a ternary does not stick, so upcast first and probe that.
  final Object maybeRanged = fs;
  final ranged = maybeRanged is RangedReadFileSystem ? maybeRanged : null;
  if (ranged == null) {
    final read = await fs.readTextLines(path);
    if (read.isErr) return;
    for (final line in read.valueOrNull ?? const <String>[]) {
      accumulator.seeLine(line);
      if (accumulator.stopped) return;
      accumulator.checkDeadline();
    }
    return;
  }
  final info = await fs.fileInfo(path);
  if (info.isErr) return;
  final meta = info.valueOrNull;
  if (meta == null || meta.kind != FileKind.file) return;
  final size = meta.size;
  var offset = 0;
  // Partial line carried as raw BYTES (the session_chunk_reader
  // technique): a UTF-8 multibyte sequence split at a block boundary
  // stays intact because lines are decoded only once they are complete.
  var carry = <int>[];
  while (offset < size) {
    final end = (offset + blockBytes).clamp(0, size);
    final read = await ranged.readRange(path, offset, end);
    if (read.isErr) return;
    offset = end;
    final block = read.valueOrNull!;
    var start = 0;
    for (;;) {
      final nl = block.indexOf(0x0A, start);
      if (nl < 0) break;
      if (carry.isNotEmpty) {
        carry.addAll(block.sublist(start, nl));
        accumulator.seeLine(json_conv.utf8.decode(carry, allowMalformed: true));
        carry = <int>[];
      } else {
        accumulator.seeLine(
          json_conv.utf8.decode(block.sublist(start, nl), allowMalformed: true),
        );
      }
      if (accumulator.stopped) return;
      start = nl + 1;
    }
    if (start < block.length) carry.addAll(block.sublist(start));
    accumulator.checkDeadline();
    if (accumulator.stopped) return;
  }
  if (carry.isNotEmpty) {
    accumulator.seeLine(json_conv.utf8.decode(carry, allowMalformed: true));
  }
}

/// Searches a whole session file chain — the production path behind the
/// `session_search` tool. Streams every segment (rotations included, per
/// `listSessionSegmentPaths`) under the query's continuation token and a
/// wall-clock [timeBudget] (E4/E5); never loads the file into memory.
/// Map mode and branch scope pay one extra read-only census pass first
/// (structure only — see [searchRecords]): the real pass then keeps its
/// ordinal table bounded and caps true branch hits with full knowledge.
Future<SessionSearchOutcome> searchSessionFile(
  FileSystem fs,
  String sessionPath,
  SessionSearchQuery query, {
  Duration timeBudget = sessionSearchTimeBudget,
  int blockBytes = sessionSearchScanBlockBytes,
}) async {
  final deadline = DateTime.now().add(timeBudget);
  final segments = await listSessionSegmentPaths(fs, sessionPath);
  final needsCensus =
      query.mode == SessionSearchMode.map ||
      (query.mode == SessionSearchMode.search &&
          query.scope == SessionSearchScope.branch);
  var ordinalWanted = const <String>{};
  var branchIds = const <String>{};
  if (needsCensus) {
    final census = _ScanAccumulator(
      query,
      deadline: deadline,
      censusOnly: true,
    );
    for (final segment in segments) {
      await _scanSessionSegment(fs, segment, census, blockBytes: blockBytes);
      if (census.stopped) break;
    }
    ordinalWanted = census._ordinalWanted;
    branchIds = census._walkChain(census._activeLeaf);
  }
  final accumulator = _ScanAccumulator(
    query,
    deadline: deadline,
    ordinalWanted: ordinalWanted,
    branchIds: branchIds,
  );
  for (final segment in segments) {
    await _scanSessionSegment(fs, segment, accumulator, blockBytes: blockBytes);
    if (accumulator.stopped) break;
  }
  return accumulator.finish();
}
