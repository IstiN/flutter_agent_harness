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
///
/// Rehydration (the #488 lesson, review-blocking on this slice): the
/// latest snapshot routinely lies BELOW a windowed session's resident
/// tail, and a writer that trusts the resident view then appends a
/// latest-wins snapshot that silently ERASES every earlier entry.
/// Rehydration must go through the raw file scan
/// (`JsonlSessionRepo.readCustomRecordsOfType`) — never
/// `Session.getEntries()`; the projection's resident lookup carries the
/// scan as a fallback (see `Session.customRecordScan`).
library;

import 'ledger_caps.dart';
import 'session_record.dart';
import '../user_text.dart';
import 'uuid.dart';

/// The `custom` record type of the obligations ledger snapshot.
const String obligationsLedgerRecordType = 'obligations_ledger';

/// Char budget of the rendered ledger block — the v1 stand-in for the
/// issue's "≤ 1% of window" proposal (~1.5k tokens on a 150k window).
///
/// NOT a hard bound on the block: open entries render in full up to
/// [maxRenderedOpenEntries], each line's text clipped to
/// [ledgerTextCapChars] — beyond those, open obligations are COUNTED in a
/// trailing "and M more" line, never silently dropped (E1 keeps them out
/// of the budget eviction like every open entry; the verbatim span stays
/// on the record, addressable by id). Spilling open obligations into
/// checkpoint text is the follow-up slice that wires the real window in.
const int obligationsBlockBudgetChars = 6000;

/// How many open entries the block renders before the "and M more" tail
/// (review guardrail: a chatty session must not grow the level-0 block
/// without bound). Newest first — the most recent obligations are the
/// ones the current context needs.
const int maxRenderedOpenEntries = 12;

/// User messages longer than this never open entries (classifier
/// precision guard): a 10 KB paste that happens to contain "please" is
/// content, not an obligation.
const int maxClassifiedUserTextChars = 4000;

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
/// change, so "you said X then Y" stays auditable (E2). Open entries are
/// closed explicitly (`obligation_mark_done`); the owner overriding a
/// rule supersedes the old entry (kept, auditable).
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

/// FNV-1a (32-bit) over the UTF-16 code units — stable across processes
/// and versions (String.hashCode is not), so a legacy id-less entry keeps
/// ONE addressable id for its lifetime.
///
/// WEB-SAFE (validation_failed: dart2js rejects 64-bit literals —
/// "integer literal can't be represented exactly in JavaScript"): the
/// multiply is split hi/lo so every intermediate stays below 2^53 and is
/// bit-exact on BOTH the VM and dart2js — no 64-bit literals, no
/// platform-dependent wraparound.
String _fnv1a(String input) {
  const offsetBasis = 0x811c9dc5;
  const prime = 0x01000193;
  var hash = offsetBasis;
  for (var i = 0; i < input.length; i++) {
    hash ^= input.codeUnitAt(i);
    final lo = (hash & 0xffff) * prime; // < 2^40 — exact everywhere
    final hi = (hash >>> 16) * prime; // < 2^40 — exact everywhere
    hash = (lo + ((hi & 0xffff) << 16)) & 0x7fffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// Deterministic fallback id for a legacy entry missing its `id` field:
/// derived from the entry's content, so two parses of the same payload
/// agree and `obligation_mark_done` can address the entry (review round 2:
/// a freshly minted uuid per parse was unaddressable and round-trip
/// unstable).
String stableEntryId({
  required String sourceRecordId,
  required String kind,
  required String text,
}) => 'obl-${_fnv1a('$sourceRecordId|$kind|$text')}';

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
  /// → open, createdAt → epoch, id → deterministic content hash), junk
  /// entries never throw.
  static ObligationEntry fromJson(Object? json) {
    final map = json is Map ? json : const {};
    final kind = ObligationKind.fromName(map['kind']);
    final text = map['text'] is String ? map['text'] as String : '';
    final sourceRecordId = map['sourceRecordId'] is String
        ? map['sourceRecordId'] as String
        : '';
    return ObligationEntry(
      id: map['id'] is String && (map['id'] as String).isNotEmpty
          ? map['id'] as String
          : stableEntryId(
              sourceRecordId: sourceRecordId,
              kind: kind.jsonName,
              text: text,
            ),
      kind: kind,
      text: text,
      sourceRecordId: sourceRecordId,
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

  /// The open entries, oldest first.
  List<ObligationEntry> get open => [
    for (final e in entries)
      if (e.status == ObligationStatus.open) e,
  ];

  /// Parses the snapshot payload of an `obligations_ledger` record
  /// (tolerantly — E6). Anything that is not an entry list parses as an
  /// empty ledger; junk maps (empty text AND empty sourceRecordId —
  /// `{}`, `{'kind': 'x'}`) are SKIPPED, not defaulted: they would parse
  /// as permanent, unclosable garbage lines at level 0 (review round 2).
  factory ObligationsLedger.fromPayload(Object? data) {
    if (data is! List) return const ObligationsLedger([]);
    final entries = <ObligationEntry>[];
    for (final item in data) {
      if (item is! Map) continue;
      final entry = ObligationEntry.fromJson(item);
      if (entry.text.isEmpty && entry.sourceRecordId.isEmpty) continue;
      entries.add(entry);
    }
    return ObligationsLedger(entries);
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

/// The latest snapshot in file order over [entries], or null when the
/// list has none. THIS IS THE RESIDENT VIEW ONLY: on a windowed session
/// the latest snapshot can lie below the resident tail — callers on the
/// resume path must fall back to the raw scan
/// (`JsonlSessionRepo.readCustomRecordsOfType`; see the library doc).
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

/// One rendered ledger line — text clipped to the display cap (the
/// verbatim span stays on the record; the pointer addresses it).
String _obligationLine(ObligationEntry e) =>
    '- [${e.status.jsonName}] ${e.kind.jsonName}: '
    '${capLedgerText(e.text) ?? ''} (id ${e.id}, record ${e.sourceRecordId})';

/// The block the projection appends at level 0 (issue #1380 A1): every
/// open obligation is visible — or explicitly counted — after any
/// hide/compact/flatten depth.
///
/// Layout: up to [maxRenderedOpenEntries] open lines (newest last), a
/// counting tail when more are open, then closed entries oldest-last
/// while the budget allows — the budget eats closed entries OLDEST first
/// (E1) and never touches open lines. Every line's text is display-clipped
/// (AC2 lives at the record level). Empty ledger renders as an empty
/// string — no block.
String renderObligationsBlock(
  ObligationsLedger ledger, {
  int maxChars = obligationsBlockBudgetChars,
}) {
  if (ledger.isEmpty) return '';
  const heading =
      'obligations ledger (engine-maintained; verbatim quotes with their '
      'source record — still owed unless marked done/superseded):';
  final open = ledger.open;
  final closed = [
    for (final e in ledger.entries)
      if (e.status != ObligationStatus.open) e,
  ];

  // Open entries: newest last, capped with an honest counting tail.
  final renderedOpen = open.length > maxRenderedOpenEntries
      ? open.sublist(open.length - maxRenderedOpenEntries)
      : open;
  final surplus = open.length - renderedOpen.length;

  // Closed entries trail oldest-last; the budget eats them from the top
  // (oldest first) once the open block plus heading no longer fit.
  final keptClosedNewestFirst = <ObligationEntry>[];
  var used =
      heading.length + 32; // envelope tags, separators, surplus-tail line
  if (surplus > 0) {
    used +=
        '\n… and $surplus more open obligations (read '
                'the ledger record for the full list)'
            .length;
  }
  for (final e in renderedOpen) {
    used += _obligationLine(e).length + 1;
  }
  for (final e in closed.reversed) {
    final cost = _obligationLine(e).length + 1;
    if (used + cost > maxChars) break;
    used += cost;
    keptClosedNewestFirst.add(e);
  }
  final keptClosed = keptClosedNewestFirst.reversed.toList();
  if (renderedOpen.isEmpty && keptClosed.isEmpty && surplus == 0) return '';
  return [
    '<system-notice>',
    heading,
    for (final e in renderedOpen) _obligationLine(e),
    if (surplus > 0)
      '… and $surplus more open obligations (read the ledger record for '
          'the full list)',
    for (final e in keptClosed) _obligationLine(e),
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

/// The rule-based v1 classifier (Q1 proposal): derives obligation
/// candidates from a persisted user message. Deterministic, conservative;
/// a message can carry both a rule and an ask (two candidates, same
/// verbatim span).
///
/// Never classifies: synthetic harness content (the ONE canonical
/// predicate — agent mail is data, never an instruction), and oversized
/// messages (a paste that happens to contain "please" is content, not an
/// obligation — see [maxClassifiedUserTextChars]).
List<ObligationCandidate> deriveObligations(String text) {
  if (text.isEmpty ||
      text.length > maxClassifiedUserTextChars ||
      isSyntheticUserText(text)) {
    return const [];
  }
  return [
    if (_ownerRulePattern.hasMatch(text))
      ObligationCandidate(kind: ObligationKind.ownerRule, text: text),
    if (_openAskPattern.hasMatch(text))
      ObligationCandidate(kind: ObligationKind.openAsk, text: text),
  ];
}

/// Maintains the ledger across a session: cumulative in-memory state,
/// rehydrated from the session's latest snapshot (RAW SCAN — see the
/// library doc; a resident-view rehydration silently erases everything
/// below a windowed tail), persisting a new full snapshot whenever a
/// classification or lifecycle transition lands. Population fires once
/// per real user message (low frequency), so the gh-1073 snapshot deduper
/// is not wired — a per-turn classifier (second tier) must add it.
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

  /// Applies a lifecycle transition (the `obligation_mark_done` close
  /// path). Returns the payload to append, or null when no entry carries
  /// [id].
  List<Map<String, Object?>>? markStatus(String id, ObligationStatus status) {
    final next = _ledger.withStatus(id, status);
    if (identical(next, _ledger)) return null;
    _ledger = next;
    return _ledger.toPayload();
  }

  /// Records an armed timer/watch (issue #1380 AC5): a `pending-wait`
  /// entry whose text is the timer's reason — verbatim from the
  /// `schedule_message` call — and whose [sourceRecordId] points at the
  /// scheduled-message record (the queue's own id; pending records live
  /// under `<messagesRoot>/_scheduled/`, not the session file), so a
  /// fired timer re-enters a context that already knows why it exists.
  /// Returns the payload to append, or null when the text is empty or
  /// [sourceRecordId] was already recorded (re-arming never duplicates).
  List<Map<String, Object?>>? ingestPendingWait({
    required String text,
    required String sourceRecordId,
    DateTime? at,
  }) {
    if (text.trim().isEmpty || sourceRecordId.isEmpty) return null;
    if (_ledger.entries.any((e) => e.sourceRecordId == sourceRecordId)) {
      return null;
    }
    _ledger = _ledger.withEntry(
      ObligationEntry(
        id: uuidv7(),
        kind: ObligationKind.pendingWait,
        text: text,
        sourceRecordId: sourceRecordId,
        createdAt: at ?? DateTime.now(),
      ),
    );
    return _ledger.toPayload();
  }
}
