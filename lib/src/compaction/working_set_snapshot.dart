// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// The agent's working set (issue #2423, C1): the snapshot record, the
/// latest-wins read rule and the system-channel block.
///
/// The working set is the agent's OWN status — decisions made, the red
/// list (never do), next steps, the rules it must keep — written through
/// the `working_set` tool and pinned into the **system channel of every
/// request** on every host. It generalises gh-210's goal-recitation slot
/// (`working_set.dart`, the tail block) and retires its tool:
///
/// - **Pinned by construction (I1).** The slot is a `custom` record (the
///   gh-210 shape, [workingSetRecordType]). Every hide, fold, checkpoint,
///   trim and summary pass walks PROJECTING records; a `custom` record
///   never projects, so no tier can see — let alone remove — the slot
///   ("exemption by absence"). After any of them the next request carries
///   the newest text byte-for-byte, and a resumed session re-reads it
///   from the file (latest wins).
/// - **System channel, not chat (I2).** [renderWorkingSetSystemBlock]
///   renders `<working-set source="agent" updated="HH:MM">…</working-set>`
///   and [appendWorkingSetToSystemPrompt] appends it to the system prompt
///   of the request. It is never a user, assistant or tool message, never
///   tagged, never hides and never counts as a real user turn.
/// - **No block, no bytes (I3).** No snapshot (or a cleared one) renders
///   nothing: a fresh or pre-#2423 session builds the byte-identical
///   request. The static system prompt stays byte-stable across writes —
///   only the suffix changes (F1).
/// - **Data, never authority (I8).** The text is the agent's notes: no
///   approval decision, tier, redaction rule, misuse policy or ttsr rule
///   reads it; secrets are redacted before the record is written
///   (`working_set_store.dart`); it never leaves the session.
///
/// The cap ([workingSetMaxChars]) is enforced at WRITE — the `working_set`
/// tool refuses a longer text instead of clipping it — so the render is
/// verbatim and never clips.
library;

import '../session/session_record.dart';
import 'working_set.dart'
    show GoalRecitation, goalRecitationFromPayload, goalRecitationRecordType;

/// The `custom` record type of the working-set snapshot (append-only,
/// latest-wins; an empty `text` payload is the agent's CLEAR event).
const String workingSetRecordType = 'working_set';

/// The char cap of the working-set text ([String.length] of the trimmed,
/// redacted text). Owner default (OQ1): 4 KB ≈ 1k tokens on every request.
/// Pinned by test so it can be lowered by one constant.
const int workingSetMaxChars = 4096;

/// The record types the latest-wins read consults: the working-set record
/// plus the retired gh-210 goal recitation (a legacy snapshot renders as
/// the working set until a `working_set` record exists on the branch —
/// a read-time rule, no file rewrite).
const Set<String> workingSetRecordTypes = {
  workingSetRecordType,
  goalRecitationRecordType,
};

/// One working-set snapshot: the agent's text plus the write time. The
/// block's only provenance is the model ([legacy] marks a snapshot read
/// from a gh-210 `goal_recitation` record).
final class WorkingSetSnapshot {
  /// Creates a [WorkingSetSnapshot].
  const WorkingSetSnapshot({
    required this.text,
    required this.updatedAt,
    this.legacy = false,
  });

  /// The working-set text, verbatim (trimmed at the write).
  final String text;

  /// When the snapshot was written.
  final DateTime updatedAt;

  /// Whether this snapshot was read from a legacy `goal_recitation`
  /// record (gh-210) rather than a `working_set` record.
  final bool legacy;

  /// The text length in chars — the number the tool result, the TUI line
  /// and the HEP frame report.
  int get chars => text.length;

  /// The CLEAR event: an empty text renders no block.
  bool get isClear => text.isEmpty;

  /// The snapshot payload for `Session.appendCustomEntry`.
  Map<String, Object?> toPayload() => {
    'text': text,
    'updatedAt': updatedAt.toIso8601String(),
    'chars': text.length,
  };

  @override
  String toString() =>
      'WorkingSetSnapshot(${text.length} chars'
      '${legacy ? ', legacy' : ''})';
}

/// Tolerant parse (the obligations E6 rule): anything that does not carry
/// a `text` string parses to `null` — a junk snapshot renders nothing, it
/// never throws. An EMPTY text is a valid payload: the CLEAR event.
WorkingSetSnapshot? workingSetFromPayload(Object? data) {
  if (data is! Map) return null;
  final text = data['text'];
  if (text is! String) return null;
  return WorkingSetSnapshot(
    text: text,
    updatedAt:
        DateTime.tryParse(data['updatedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// The latest working-set snapshot in file order over [records], or `null`
/// when none exists. Both record kinds compete on ORDER alone: the newest
/// of the two wins, so a `working_set` record supersedes every older
/// `goal_recitation`, a `working_set` clear after a legacy snapshot
/// clears it, and a branch that only ever knew gh-210 still renders its
/// goal. RESIDENT VIEW ONLY for the caller: on a windowed session the
/// latest snapshot can lie below the resident tail — the session's scan
/// fallback (`Session.workingSetSnapshot`) is the complete reader.
WorkingSetSnapshot? latestWorkingSetIn(Iterable<SessionRecord> records) {
  WorkingSetSnapshot? latest;
  for (final record in records) {
    if (record is! CustomRecord) continue;
    if (record.customType == workingSetRecordType) {
      latest = workingSetFromPayload(record.data);
    } else if (record.customType == goalRecitationRecordType) {
      latest = _fromLegacy(record.data, record.timestamp);
    }
  }
  return latest;
}

WorkingSetSnapshot? _fromLegacy(Object? data, DateTime fallback) {
  GoalRecitation? recitation;
  try {
    recitation = goalRecitationFromPayload(data);
  } on Object {
    // A malformed legacy payload is junk: renders nothing, never throws.
    return null;
  }
  if (recitation == null) return null;
  return WorkingSetSnapshot(
    text: recitation.goal,
    updatedAt: recitation.updatedAt.millisecondsSinceEpoch == 0
        ? fallback
        : recitation.updatedAt,
    legacy: true,
  );
}

/// Renders the working-set block for [snapshot]:
/// `<working-set source="agent" updated="HH:MM">` + the verbatim text +
/// `</working-set>`. Empty string when there is no snapshot or the slot
/// is cleared — the caller then leaves the system prompt untouched (I3).
/// The clock is the snapshot's LOCAL time of day; the header names the
/// provenance (`source="agent"`): the block is the agent's own notes,
/// never a grant of anything.
String renderWorkingSetSystemBlock(WorkingSetSnapshot? snapshot) {
  if (snapshot == null || snapshot.isClear) return '';
  final local = snapshot.updatedAt.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '<working-set source="agent" updated="$hh:$mm">\n'
      '${snapshot.text}\n'
      '</working-set>';
}

/// The system prompt of a request with the working-set block appended
/// (gh-2423 C1 — the system channel every adapter already carries:
/// Anthropic `system`, OpenAI-compatible `role: system`, Google
/// `systemInstruction`). No block ⇒ the [systemPrompt] object is returned
/// UNCHANGED, so a session without a snapshot builds the byte-identical
/// request (I3); with one, the static prompt stays a byte-stable prefix
/// and only the suffix changes (F1). A prompt-less agent carries the
/// block alone.
String? appendWorkingSetToSystemPrompt(
  String? systemPrompt,
  WorkingSetSnapshot? snapshot,
) {
  final block = renderWorkingSetSystemBlock(snapshot);
  if (block.isEmpty) return systemPrompt;
  if (systemPrompt == null || systemPrompt.isEmpty) return block;
  return '$systemPrompt\n$block';
}
