/// `/handoff` digest generation (gh-2102) — the core, host-agnostic half.
///
/// A handoff starts a FRESH session from an EDITABLE digest of the current
/// one: goal / work done / files / next steps, generated with the existing
/// branch-digest machinery ([generateBranchSummary] via [prepareBranchEntries]
/// and the shared [SummarizeFn] seam) but composed with a HANDOFF preamble —
/// the digest seeds a continuation session, it does not describe an abandoned
/// branch. The relevant-file list (files read / modified on the branch) rides
/// both the digest text (the `<read-files>`/`<modified-files>` tags the
/// branch summaries use) and the seeded record's `details`, so a resumed
/// session can re-surface the working set structurally.
///
/// Lossless guarantee: nothing here writes to the source session — the old
/// branch stays byte-identical and reachable (gh-2102 acceptance).
library;

import '../cancel_token.dart';
import '../session/session_record.dart';
import '../session/session_storage.dart';
import '../session/session_tree.dart';
import 'branch_summarization.dart';
import 'compaction.dart';

export 'branch_summarization.dart' show branchSummaryPrompt;

/// Fixed preamble composed into a handoff digest: the text is a checkpoint
/// of the PREVIOUS session seeding a continuation (not an abandoned branch —
/// that distinction is why this is not [branchSummaryPreamble]).
const String handoffDigestPreamble =
    'This session continues earlier work from a previous conversation '
    '(handed off by the user). Checkpoint of that earlier session:';

/// `customType` of the seeded handoff record on the fresh session
/// (`CustomMessageRecord`, projects into model context as a user message).
const String handoffDigestCustomType = 'handoff_digest';

/// Outcome of [generateHandoffDigest]: success carries [summary] — the
/// editable digest text, [handoffDigestPreamble] and the file-operation tags
/// included — plus the relevant-file lists; failure carries [error] (or
/// [aborted]) instead of throwing.
final class HandoffDigestResult {
  /// Creates a [HandoffDigestResult].
  const HandoffDigestResult({
    this.summary,
    this.readFiles = const [],
    this.modifiedFiles = const [],
    this.aborted = false,
    this.error,
  });

  /// The generated digest (`null` when generation failed or was aborted).
  final String? summary;

  /// Files read on the handed-off branch, sorted (modified files excluded).
  final List<String> readFiles;

  /// Files modified on the handed-off branch, sorted.
  final List<String> modifiedFiles;

  /// Whether the digest call was aborted rather than failed.
  final bool aborted;

  /// The failure description when generation failed.
  final String? error;

  /// Whether a digest was produced.
  bool get isSuccess => summary != null;
}

/// Collect every entry of [session]'s CURRENT branch (leaf → root,
/// chronological) for the digest — the branch-digest walk without a tree
/// move: the whole conversation is what a handoff carries over.
///
/// A resumed/booted CLI session is opened WINDOWED (`_repo.open(metadata,
/// windowed: true)`) and the resume walk keeps only the parity-budget tail
/// resident — reading the branch directly would digest just that tail and
/// seed the fresh session with it as a COMPLETE checkpoint, silently
/// (gh-2102 review, BLOCKING). The whole ledger is therefore primed first
/// ([Session.ensureWholeLedgerResident] — the read-everything escape hatch
/// the trajectory surfaces use). Past the whole-ledger backstop the priming
/// refuses with the `tooLarge` [SessionException] BEFORE any scan: hosts
/// catch it and degrade LOUDLY ([collectResidentBranchForHandoff] is the
/// partial-coverage fallback), never silently.
Future<List<SessionRecord>> collectEntriesForHandoff(
  Session session, {
  int maxWholeLedgerBytes = defaultMaxFullOpenBytes,
}) async {
  await session.ensureWholeLedgerResident(
    maxWholeLedgerBytes: maxWholeLedgerBytes,
  );
  return collectResidentBranchForHandoff(session);
}

/// The RESIDENT branch only (no whole-ledger priming): the loud-degrade
/// fallback for [collectEntriesForHandoff]'s tooLarge refusal, when the
/// host chose to digest the resident tail with a visible note.
Future<List<SessionRecord>> collectResidentBranchForHandoff(
  Session session,
) async {
  final leafId = await session.getLeafId();
  if (leafId == null) return const [];
  return session.getBranch(fromId: leafId);
}

/// Generate a handoff digest from [entries] (the current branch, per
/// [collectEntriesForHandoff]) — the branch-digest generation with the
/// handoff preamble. Never throws: failures surface on the result.
///
/// [summarizerWindow] (gh-2102 review, issue #729 parity) bounds the
/// outbound digest prompt to [summarizationPayloadBudget] of the DIGEST
/// MODEL's own window: an over-budget branch is summarized chunk-wise with
/// the fold (the whole conversation still feeds the digest), instead of one
/// provider-overflowing call on exactly the long sessions a handoff exists
/// for. `null` leaves the payload unbounded (legacy behavior).
///
/// LOSSLESS: nothing is appended to any session; the digest lives only on
/// the returned result until the host seeds the continuation session.
Future<HandoffDigestResult> generateHandoffDigest(
  List<SessionRecord> entries, {
  required SummarizeFn summarize,
  int tokenBudget = 0,
  int? summarizerWindow,
  CompactionSettings settings = defaultCompactionSettings,
  CancelToken? cancelToken,
}) async {
  if (entries.isEmpty) {
    return const HandoffDigestResult(error: 'nothing to summarize');
  }
  // Records without conversation content (labels, session metadata, empty
  // branch summaries) would come back as the branch generator's
  // 'No content to summarize' placeholder — a handoff must never seed a
  // fresh session with that placeholder dressed up as a digest.
  if (prepareBranchEntries(
    entries,
    tokenBudget: tokenBudget,
  ).messages.isEmpty) {
    return const HandoffDigestResult(error: 'no content to summarize');
  }
  final result = await generateBranchSummary(
    entries,
    summarize: summarize,
    tokenBudget: tokenBudget,
    cancelToken: cancelToken,
    preamble: handoffDigestPreamble,
    maxPromptTokens: summarizerWindow == null
        ? null
        : summarizationPayloadBudget(summarizerWindow, settings),
  );
  if (result.aborted) return const HandoffDigestResult(aborted: true);
  if (result.summary == null) {
    return HandoffDigestResult(error: result.error ?? 'digest failed');
  }
  return HandoffDigestResult(
    summary: result.summary,
    readFiles: result.readFiles ?? const [],
    modifiedFiles: result.modifiedFiles ?? const [],
  );
}

/// Seed [session] (the FRESH continuation session) with the digest: one
/// `handoff_digest` custom-message record — content is the digest text
/// (projects into model context as a user message, [CustomMessageRecord.display]
/// keeps it visible in the transcript), `details` carries the relevant-file
/// lists for structural re-surfacing. Returns the new record id.
Future<String> seedHandoffRecord(
  Session session, {
  required String digest,
  List<String> readFiles = const [],
  List<String> modifiedFiles = const [],
}) {
  return session.appendCustomMessageEntry(
    customType: handoffDigestCustomType,
    content: digest,
    display: true,
    details: {'readFiles': readFiles, 'modifiedFiles': modifiedFiles},
  );
}
