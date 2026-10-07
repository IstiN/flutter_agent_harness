/// The session-level obligations ledger (issue #1380, capability A1).
///
/// A snapshot `custom` record (`obligationsLedgerRecordType`) carrying the
/// owner's standing rules, open asks, agent commitments and pending waits
/// as VERBATIM quotes with a pointer to the source record. The engine (not
/// the model's goodwill) maintains it, and the context projection renders
/// it as a compact block at level 0 — hide/compact/flatten at any depth
/// can never sink an obligation below the visible surface (the hard
/// invariant this slice owns; it generalizes #148's S2 open-asks rule).
///
/// Shape follows the latest-snapshot-wins session ledgers
/// (`shell_job_registry`, `subagent_registry`): every mutation appends a
/// fresh full snapshot; the LAST record wins wholesale; older snapshots
/// remain as the audit trail. Unlike those registries the entries are
/// never paraphrases or caps — the text is the exact source span (AC2);
/// the budget lives at render time only.
library;

import 'session_record.dart';
import '../types.dart';
import 'uuid.dart';

/// The `custom` record type of the obligations ledger snapshot.
const String obligationsLedgerRecordType = 'obligations_ledger';

/// Char budget of the rendered ledger block — the v1 stand-in for the
/// issue's "≤ 1% of window" proposal (~1.5k tokens on a 150k window).
/// The render never drops OPEN entries over budget (E1): closed entries
/// evict oldest-first; spilling open obligations into checkpoint text is
/// the follow-up slice that wires the real window size in.
const int obligationsBlockBudgetChars = 6000;

/// What kind of obligation an entry carries.
enum ObligationKind {
  /// A standing rule from the owner ("always run tests before pushing").
  ownerRule,

  /// An open ask the owner made that has not been discharged.
  openAsk,

  /// A follow-up the agent itself committed to.
  agentCommitment,

  /// A timer/watch the agent armed, with the reason it exists.
  pendingWait;

  /// The payload spelling (`owner-rule`, `open-ask`, …).
  String get jsonName => switch (this) {
    ownerRule => 'owner-rule',
    openAsk => 'open-ask',
    agentCommitment => 'agent-commitment',
    pendingWait => 'pending-wait',
  };

  /// Tolerant parse (E6): unknown or missing names default to [openAsk]
  /// — a forward-versioned entry must stay visible, never vanish.
  static ObligationKind fromName(Object? name) => switch (name) {
    'owner-rule' => ownerRule,
    'agent-commitment' => agentCommitment,
    'pending-wait' => pendingWait,
    _ => openAsk,
  };
}

/// Lifecycle of an entry. Entries are never deleted — closing is a status
/// change, so "you said X then Y" stays auditable (E2).
enum ObligationStatus {
  open,

  /// Explicitly discharged.
  done,

  /// Overridden by a later rule/ask; the entry stays for the audit trail.
  superseded;

  /// The payload spelling.
  String get jsonName => name;

  /// Tolerant parse (E6): unknown or missing names default to [open].
  static ObligationStatus fromName(Object? name) => switch (name) {
    'done' => done,
    'superseded' => superseded,
    _ => open,
  };
}

/// One ledger entry: a verbatim quote of a past instruction, rule,
/// commitment or armed wait, pointing at the record it came from.
final class ObligationEntry {
  const ObligationEntry({
    required this.id,
    required this.kind,
    required this.text,
    required this.sourceRecordId,
    required this.createdAt,
    this.status = ObligationStatus.open,
  });

  /// Stable entry id (uuidv7) — lifecycle updates replace by id.
  final String id;

  final ObligationKind kind;

  /// The VERBATIM source span — byte-matches the source record (AC2).
  /// Never a paraphrase: paraphrase drift is the failure mode this card
  /// kills.
  final String text;

  /// The session record id the quote came from.
  final String sourceRecordId;

  final DateTime createdAt;

  final ObligationStatus status;

  /// This entry with [status] applied (position-preserving update).
  ObligationEntry withStatus(ObligationStatus status) => ObligationEntry(
    id: id,
    kind: kind,
    text: text,
    sourceRecordId: sourceRecordId,
    createdAt: createdAt,
    status: status,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.jsonName,
    'text': text,
    'sourceRecordId': sourceRecordId,
    'createdAt': createdAt.toIso8601String(),
    'status': status.jsonName,
  };

  /// Tolerant parse (E6): missing fields default (kind → open-ask, status
  /// → open, createdAt → epoch), junk entries never throw.
  static ObligationEntry fromJson(Object? json) {
    final map = json is Map ? json : const {};
    return ObligationEntry(
      id: map['id'] is String ? map['id'] as String : uuidv7(),
      kind: ObligationKind.fromName(map['kind']),
      text: map['text'] is String ? map['text'] as String : '',
      sourceRecordId: map['sourceRecordId'] is String
          ? map['sourceRecordId'] as String
          : '',
      createdAt: map['createdAt'] is String
          ? DateTime.tryParse(map['createdAt'] as String) ??
                DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.fromMillisecondsSinceEpoch(0),
      status: ObligationStatus.fromName(map['status']),
    );
  }
}

/// The ledger state: entries in insertion order (lifecycle updates keep
/// position). Immutable — mutators return the next state.
final class ObligationsLedger {
  const ObligationsLedger(this.entries);

  final List<ObligationEntry> entries;

  bool get isEmpty => entries.isEmpty;

  /// Parses the snapshot payload of an `obligations_ledger` record
  /// (tolerantly — E6). Anything that is not an entry list parses as an
  /// empty ledger.
  factory ObligationsLedger.fromPayload(Object? data) {
    if (data is! List) return const ObligationsLedger([]);
    return ObligationsLedger([
      for (final item in data)
        if (item is Map) ObligationEntry.fromJson(item),
    ]);
  }

  /// The snapshot payload for [appendCustomEntry].
  List<Map<String, Object?>> toPayload() => [
    for (final entry in entries) entry.toJson(),
  ];

  /// Appends [entry], or replaces in place when its id already exists
  /// (lifecycle updates keep the audit position).
  ObligationsLedger withEntry(ObligationEntry entry) {
    final index = entries.indexWhere((e) => e.id == entry.id);
    if (index < 0) return ObligationsLedger([...entries, entry]);
    final next = [...entries];
    next[index] = entry;
    return ObligationsLedger(next);
  }

  /// The entry with [id] re-statused, or this ledger unchanged.
  ObligationsLedger withStatus(String id, ObligationStatus status) {
    final index = entries.indexWhere((e) => e.id == id);
    if (index < 0) return this;
    return withEntry(entries[index].withStatus(status));
  }
}

/// The latest snapshot in file order, or null when the session has none.
/// Scan runs over ALL entries, not the branch path — the ledger is
/// session-level (A1), not branch state.
// ponytail: getEntries scan, no raw-file fallback — the windowed
// side-leaf edge (issue #488) gets the subagentRegistryRows treatment if
// a regression ever shows a missed snapshot.
ObligationsLedger? latestObligationsLedgerIn(List<SessionRecord> entries) {
  ObligationsLedger? latest;
  for (final entry in entries) {
    if (entry is CustomRecord &&
        entry.customType == obligationsLedgerRecordType &&
        entry.data is List) {
      latest = ObligationsLedger.fromPayload(entry.data);
    }
  }
  return latest;
}

/// The block the projection appends at level 0 (issue #1380 A1): every
/// open obligation is visible after any hide/compact/flatten depth.
///
/// Open entries ALWAYS render (never sink an obligation); over budget the
/// oldest closed entries drop first (E1). Empty ledger renders as an
/// empty string — no block.
String renderObligationsBlock(
  ObligationsLedger ledger, {
  int maxChars = obligationsBlockBudgetChars,
}) {
  if (ledger.isEmpty) return '';
  String line(ObligationEntry e) =>
      '- [${e.status.jsonName}] ${e.kind.jsonName}: ${e.text} '
      '(record ${e.sourceRecordId})';
  const heading =
      'obligations ledger (engine-maintained; verbatim quotes with their '
      'source record — still owed unless marked done/superseded):';
  final open = [
    for (final e in ledger.entries)
      if (e.status == ObligationStatus.open) e,
  ];
  // Closed entries trail oldest-last; the budget eats them from the top
  // (oldest first) once the open block plus heading no longer fit.
  final closed = [
    for (final e in ledger.entries)
      if (e.status != ObligationStatus.open) e,
  ];
  final keptClosedNewestFirst = <ObligationEntry>[];
  var used = heading.length + 4; // envelope tags + their newlines
  for (final e in open) {
    used += line(e).length + 1;
  }
  // The budget eats the closed tail oldest-first (E1): walk newest→oldest
  // keeping what fits, then restore chronological order for display.
  for (final e in closed.reversed) {
    final cost = line(e).length + 1;
    if (used + cost > maxChars) break;
    used += cost;
    keptClosedNewestFirst.add(e);
  }
  final keptClosed = keptClosedNewestFirst.reversed.toList();
  if (open.isEmpty && keptClosed.isEmpty) return '';
  return [
    '<system-notice>',
    heading,
    for (final e in open) line(e),
    for (final e in keptClosed) line(e),
    '</system-notice>',
  ].join('\n');
}

/// One classifier hit: kind + the verbatim span it quotes.
final class ObligationCandidate {
  const ObligationCandidate({required this.kind, required this.text});

  final ObligationKind kind;
  final String text;
}

/// Rule phrasing of an owner-rule (v1 heuristic — precision over recall:
/// a misclassifying judge must never invent obligations, Q1).
final RegExp _ownerRulePattern = RegExp(
  r'\b(always|never|whenever|from now on|make sure|remember that|'
  r'keep in mind|rule:)\b',
  caseSensitive: false,
);

/// Explicit second-person request phrasing of an open-ask. Bare questions
/// ("what did we decide about X?") are recall, not obligation — they must
/// NOT open entries.
final RegExp _openAskPattern = RegExp(
  r'\b(please|can you|could you|would you|will you|i need you to)\b',
  caseSensitive: false,
);

/// Synthetic harness content (system-notice envelopes, agent mail, TTSR
/// injections, branch summaries) never classifies — mirrors
/// `isSyntheticUserText` locally: importing the compaction library back
/// from the session layer would close a dependency cycle.
final RegExp _syntheticUserPattern = RegExp(
  r'^\[(widget|ext:)|^<system-notice>|^<system-interrupt'
  r'|^from \S+: |^The following is a summary of a branch',
);

/// The rule-based v1 classifier (Q1 proposal): derives obligation
/// candidates from a persisted user message. Deterministic, conservative;
/// a message can carry both a rule and an ask (two candidates, same
/// verbatim span).
List<ObligationCandidate> deriveObligations(String text) {
  if (text.isEmpty || _syntheticUserPattern.hasMatch(text)) return const [];
  return [
    if (_ownerRulePattern.hasMatch(text))
      ObligationCandidate(kind: ObligationKind.ownerRule, text: text),
    if (_openAskPattern.hasMatch(text))
      ObligationCandidate(kind: ObligationKind.openAsk, text: text),
  ];
}

/// The flat user text a ledger candidate derives from (the same fold the
/// context ledger uses — the persisted record's text span).
String obligationsUserText(Object content) {
  if (content is String) return content;
  if (content is! List) return '';
  return [
    for (final block in content)
      if (block is TextContent) block.text,
  ].join(' ');
}

/// Maintains the ledger across a session: cumulative in-memory state,
/// rehydrated from the session's latest snapshot, persisting a new full
/// snapshot whenever a classification lands. Population fires once per
/// real user message (low frequency), so the gh-1073 snapshot deduper is
/// not wired — a per-turn classifier (second tier) must add it.
final class ObligationsLedgerWriter {
  ObligationsLedgerWriter({
    ObligationsLedger initial = const ObligationsLedger([]),
  }) : _ledger = initial;

  ObligationsLedger _ledger;

  ObligationsLedger get ledger => _ledger;

  /// Classifies [text] (a persisted user message's text) into the ledger.
  /// Returns the new full snapshot payload to append, or null when
  /// nothing changed: no candidates, or [sourceRecordId] already
  /// classified (idempotent re-ingest — a record never opens twice).
  List<Map<String, Object?>>? ingest({
    required String text,
    required String sourceRecordId,
    DateTime? at,
  }) {
    if (_ledger.entries.any((e) => e.sourceRecordId == sourceRecordId)) {
      return null;
    }
    final candidates = deriveObligations(text);
    if (candidates.isEmpty) return null;
    final timestamp = at ?? DateTime.now();
    for (final candidate in candidates) {
      _ledger = _ledger.withEntry(
        ObligationEntry(
          id: uuidv7(),
          kind: candidate.kind,
          text: candidate.text,
          sourceRecordId: sourceRecordId,
          createdAt: timestamp,
        ),
      );
    }
    return _ledger.toPayload();
  }

  /// Applies a lifecycle transition directly (the `obligation_mark_done`
  /// tool slice builds on this). Returns the payload to append, or null
  /// when no entry carries [id].
  List<Map<String, Object?>>? markStatus(String id, ObligationStatus status) {
    final next = _ledger.withStatus(id, status);
    if (identical(next, _ledger)) return null;
    _ledger = next;
    return _ledger.toPayload();
  }
}
