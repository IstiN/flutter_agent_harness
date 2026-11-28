/// gh-2492 C2 — pinned steering for task children.
///
/// A task child's own assignment (the task prompt record) and the parent's
/// latest steering are the two records a hide-only compaction must never
/// bury (the worker-A failure modes from the #2423 audit: a child that
/// cannot see its assignment keeps re-deriving the task or drifts off the
/// parent's newest instruction). The protection channel is the same one
/// every host shares — `SegmentPinRecord`s in the child's own session file
/// (`segment_pin`); nothing else changes:
///
/// - mail stays data: `isSyntheticUserText` semantics are untouched
///   (REG-6) — a pin protects the record, the classifier still reads it
///   as machine content;
/// - one steering delivery pinned at a time: a new delivery pins its
///   records and releases the previous delivery's (older steering folds);
/// - the resume belt: a child resumed from a pre-card session (no pin
///   records) gains "ensure pins" once — the first prompt record and the
///   newest steering record, never un-hiding anything already hidden.
library;

import '../context.dart';
import '../session/session_record.dart';
import '../user_text.dart';

/// The steering-record predicate over a persisted user text: the exact
/// shape the task executor renders parent mail into
/// (`'from <id>: …'` — several mails may join into ONE record). The same
/// anchor [isSyntheticUserText] classifies as synthetic: mail is data,
/// and stays data — this predicate only names the records a pin may
/// protect.
bool isChildSteeringText(String text) {
  final trimmed = text.trim();
  return trimmed.startsWith('from ') && isAgentMailText(trimmed);
}

/// The pin targets a pre-card child session needs, derived from its
/// branch records (file order): the FIRST user message record (the task
/// prompt) and the NEWEST steering record — each only when it exists and
/// is not already pinned by the replayed pin events. Never suggests
/// unpinning: a pin on an already-hidden record does not un-hide it
/// (hide tiers skip pinned ids on FUTURE passes only).
List<String> ensureChildPinTargets(List<SessionRecord> branch) {
  String? promptId;
  String? newestSteeringId;
  for (final record in branch) {
    if (record is! MessageRecord) continue;
    final message = record.message;
    if (message is! UserMessage) continue;
    final text = userMessageText(message.content);
    if (text.isEmpty) continue;
    promptId ??= record.id;
    if (isChildSteeringText(text)) newestSteeringId = record.id;
  }
  final pinned = pinnedRecordIdsOf(branch);
  return [
    if (promptId != null && !pinned.contains(promptId)) promptId,
    if (newestSteeringId != null && !pinned.contains(newestSteeringId))
      newestSteeringId,
  ];
}

/// The replayed pin state over [branch]: the record ids that are pinned
/// after applying every `segment_pin` event in file order (last one per
/// id wins) — the same semantics the structured projection applies.
Set<String> pinnedRecordIdsOf(List<SessionRecord> branch) {
  final pinned = <String>{};
  for (final record in branch) {
    if (record is SegmentPinRecord) {
      record.pinned
          ? pinned.addAll(record.recordIds)
          : pinned.removeAll(record.recordIds);
    }
  }
  return pinned;
}
