/// Branch summarization for session-tree navigation.
///
/// Ported from oh-my-pi `packages/agent/src/compaction/
/// branch-summarization.ts`. When the conversation navigates to a different
/// point in the session tree, the branch being left is summarized — with the
/// same [SummarizeFn] the compaction pipeline uses — into a
/// [BranchSummaryRecord] on the branch being entered, so context is not
/// lost. The record then projects into the rebuilt context as a user message
/// (see `Session.buildContextMessages`).
///
/// Deliberate divergences from the TypeScript original:
///
/// - The summary LLM call is the injected [SummarizeFn] (the compaction
///   port's seam), so the token budget is an explicit parameter instead of
///   `model.contextWindow - reserveTokens`; `tokenBudget: 0` (the default)
///   means no trimming.
/// - The budget estimate counts whole messages (omp pre-truncates tool
///   results for the estimate; [serializeConversation] still truncates them
///   in the final prompt, so only the cut point can differ).
/// - omp's telemetry, transport override, and `convertToLlm` hooks are
///   absent (no equivalents on this side).
library;

import 'dart:math' show max;

import '../cancel_token.dart';
import '../context.dart';
import '../prompts/prompts.g.dart';
import '../session/session_record.dart';
import '../session/session_tree.dart';
import '../types.dart';
import 'compaction.dart';
import 'summary_sanitizer.dart';
import 'token_estimation.dart';

export '../prompts/prompts.g.dart' show branchSummaryPrompt;

/// Outcome of [generateBranchSummary] (omp's `BranchSummaryResult`): success
/// carries [summary] plus the tracked file lists; failure carries [error]
/// (or [aborted]) instead of throwing.
final class BranchSummaryResult {
  /// Creates a [BranchSummaryResult].
  const BranchSummaryResult({
    this.summary,
    this.readFiles,
    this.modifiedFiles,
    this.aborted = false,
    this.error,
  });

  /// The generated summary (preamble and file-operation tags included).
  final String? summary;

  /// Files read on the abandoned branch (sorted).
  final List<String>? readFiles;

  /// Files modified on the abandoned branch (sorted).
  final List<String>? modifiedFiles;

  /// Whether the summarization call was aborted.
  final bool aborted;

  /// The failure description when summarization failed.
  final String? error;
}

/// Messages and file operations extracted for a branch summary (omp's
/// `BranchPreparation`).
final class BranchPreparation {
  /// Creates a [BranchPreparation].
  const BranchPreparation({
    required this.messages,
    required this.fileOps,
    required this.totalTokens,
  });

  /// Messages extracted for summarization, in chronological order.
  final List<Message> messages;

  /// File operations extracted from tool calls and nested branch summaries.
  final FileOperations fileOps;

  /// Total estimated tokens in [messages].
  final int totalTokens;
}

/// Entries collected for a branch summary plus the common ancestor between
/// the old and the new position.
typedef CollectBranchEntries = ({
  List<SessionRecord> entries,
  String? commonAncestorId,
});

/// Collect the entries to summarize when navigating from [oldLeafId] to
/// [targetId]: walks from the old leaf back to the common ancestor,
/// returning entries in chronological order (omp's
/// `collectEntriesForBranchSummary`). Compaction boundaries do NOT stop the
/// walk — their summaries become context for the branch summary.
Future<CollectBranchEntries> collectEntriesForBranchSummary(
  Session session,
  String? oldLeafId,
  String targetId,
) async {
  // No old position, nothing to summarize.
  if (oldLeafId == null) {
    return (entries: const <SessionRecord>[], commonAncestorId: null);
  }

  // Find the deepest record on both paths (the common ancestor).
  final oldPath = {
    for (final entry in await session.getBranch(fromId: oldLeafId)) entry.id,
  };
  final targetPath = await session.getBranch(fromId: targetId);
  String? commonAncestorId;
  for (var i = targetPath.length - 1; i >= 0; i--) {
    if (oldPath.contains(targetPath[i].id)) {
      commonAncestorId = targetPath[i].id;
      break;
    }
  }

  // Collect entries from the old leaf back to the common ancestor.
  final entries = <SessionRecord>[];
  String? current = oldLeafId;
  while (current != null && current != commonAncestorId) {
    final entry = await session.getEntry(current);
    if (entry == null) break;
    entries.add(entry);
    current = entry.parentId;
  }
  return (
    entries: entries.reversed.toList(growable: false),
    commonAncestorId: commonAncestorId,
  );
}

List<Message> _entryToMessages(SessionRecord entry) {
  return switch (entry) {
    MessageRecord(:final message) => [message],
    CustomMessageRecord(:final content, :final timestamp) => [
      UserMessage(content: content, timestamp: timestamp),
    ],
    BranchSummaryRecord(:final summary, :final timestamp) =>
      summary.isEmpty
          ? const []
          : [
              UserMessage.text(
                '$branchSummaryPrefix'
                // Issue #1131: heal before summarizing — raw poison must
                // not ride the summarizer input and be paraphrased forward.
                '${sanitizeSummary(summary).text}'
                '$branchSummarySuffix',
                timestamp: timestamp,
              ),
            ],
    // Unlike compaction, branch summarization includes earlier compaction
    // summaries as context (omp parity).
    CompactionRecord(:final summary, :final timestamp) => [
      UserMessage.text(
        '$compactionSummaryPrefix'
        '${sanitizeSummary(summary).text}'
        '$compactionSummarySuffix',
        timestamp: timestamp,
      ),
    ],
    _ => const [],
  };
}

/// Cumulative file tracking from nested branch summaries, so file lists
/// survive summarization-of-summaries (omp parity).
void _accumulateNestedFileOps(
  List<SessionRecord> entries,
  FileOperations fileOps,
) {
  for (final entry in entries) {
    if (entry is BranchSummaryRecord && entry.details is Map) {
      final details = entry.details! as Map;
      final readFiles = details['readFiles'];
      if (readFiles is List) fileOps.read.addAll(readFiles.whereType<String>());
      final modifiedFiles = details['modifiedFiles'];
      if (modifiedFiles is List) {
        fileOps.edited.addAll(modifiedFiles.whereType<String>());
      }
    }
  }
}

/// Whether adding [tokens] to [totalTokens] would exceed [tokenBudget]
/// (`tokenBudget: 0` means no limit).
bool _exceedsBudget(int tokenBudget, int totalTokens, int tokens) {
  return tokenBudget > 0 && totalTokens + tokens > tokenBudget;
}

/// Summary entries squeeze in anyway when nearly full — they are important
/// context (omp parity).
bool _squeezeInSummaryEntry(
  SessionRecord entry,
  int tokenBudget,
  int totalTokens,
) {
  return (entry is CompactionRecord || entry is BranchSummaryRecord) &&
      totalTokens < tokenBudget * 0.9;
}

/// Prepare entries for summarization within [tokenBudget] (omp's
/// `prepareBranchEntries`): walks NEWEST to OLDEST, keeping the most recent
/// context when the branch is too long. File operations accumulate from ALL
/// entries — including nested branch-summary details — even past the budget.
/// `tokenBudget: 0` means no limit.
BranchPreparation prepareBranchEntries(
  List<SessionRecord> entries, {
  int tokenBudget = 0,
}) {
  final messages = <Message>[];
  final fileOps = createFileOps();
  var totalTokens = 0;

  // First pass: cumulative file tracking from nested branch summaries, so
  // file lists survive summarization-of-summaries (omp parity).
  _accumulateNestedFileOps(entries, fileOps);

  // Second pass: newest to oldest, until the token budget is exhausted.
  for (var i = entries.length - 1; i >= 0; i--) {
    final entry = entries[i];
    final entryMessages = _entryToMessages(entry);
    if (entryMessages.isEmpty) continue;
    for (final message in entryMessages) {
      extractFileOpsFromMessage(message, fileOps);
    }
    final tokens = entryMessages.fold<int>(
      0,
      (sum, message) => sum + estimateTokens(message),
    );
    if (_exceedsBudget(tokenBudget, totalTokens, tokens)) {
      if (_squeezeInSummaryEntry(entry, tokenBudget, totalTokens)) {
        messages.insertAll(0, entryMessages);
        totalTokens += tokens;
      }
      break;
    }
    messages.insertAll(0, entryMessages);
    totalTokens += tokens;
  }
  return BranchPreparation(
    messages: messages,
    fileOps: fileOps,
    totalTokens: totalTokens,
  );
}

/// Generate a summary of abandoned-branch [entries] (omp's
/// `generateBranchSummary`): serializes them into `<conversation>` tags,
/// ends with the fixed branch-summary prompt (or [customInstructions]), and
/// prepends the branch preamble ([preamble] — the default is the branch
/// preamble; the `/handoff` digest passes its own, gh-2102) plus the
/// file-operation tags. Never throws:
/// failures surface as [BranchSummaryResult.error].
///
/// [maxPromptTokens] (issue #729 parity, gh-2102 review) bounds the outbound
/// payload when set: over-budget branches are summarized CHUNK-WISE — each
/// chunk under the budget ([truncateForSummaryBudget], the explicit
/// truncation note for a single oversized message), every later call
/// folding the prior summary in as `<previous-checkpoint>` — and the result
/// is the LAST fold. `null` (the default) leaves the prompt byte-identical
/// to the unbounded path.
Future<BranchSummaryResult> generateBranchSummary(
  List<SessionRecord> entries, {
  required SummarizeFn summarize,
  int tokenBudget = 0,
  String? customInstructions,
  CancelToken? cancelToken,
  String preamble = branchSummaryPreamble,
  int? maxPromptTokens,
}) async {
  final preparation = prepareBranchEntries(entries, tokenBudget: tokenBudget);
  if (preparation.messages.isEmpty) {
    return const BranchSummaryResult(summary: 'No content to summarize');
  }

  final instructions = customInstructions ?? branchSummaryPrompt;

  // One summarizer call, wrapped so a provider error keeps the never-throw
  // contract (the legacy single-call shape).
  Future<SummarizationResult> runOne(String prompt) async {
    try {
      return await summarize(
        SummarizationRequest(prompt: prompt, cancelToken: cancelToken),
      );
    } catch (error) {
      return SummarizationResult.failure('Branch summarization failed: $error');
    }
  }

  String build(String conversation, String? prior) {
    final buffer = StringBuffer()
      ..write('<conversation>\n')
      ..write(conversation)
      ..write('\n</conversation>\n');
    if (prior != null) {
      buffer.write('<previous-checkpoint>\n$prior\n</previous-checkpoint>\n');
    }
    buffer
      ..write('\n')
      ..write(instructions);
    return buffer.toString();
  }

  // One summarizer pass settles the prose: a single call when the prompt
  // fits the payload budget (or is unbounded), chunk-wise folds otherwise
  // (#729 parity) — see [_sumarizeBranchText].
  final outcome = await _sumarizeBranchText(
    preparation.messages,
    runOne: runOne,
    build: build,
    instructions: instructions,
    maxPromptTokens: maxPromptTokens,
  );
  if (outcome.aborted) return const BranchSummaryResult(aborted: true);
  if (outcome.error != null) return BranchSummaryResult(error: outcome.error);
  final text = outcome.text ?? '';

  final fileLists = computeFileLists(preparation.fileOps);
  // Issue #1131: the summary persists and re-renders every turn — strip
  // ephemeral, time-scoped claims from the LLM prose before recording it.
  final sanitized = sanitizeSummary(text);
  final summary =
      '$preamble\n${sanitized.text}'
      '${formatFileOperations(fileLists.readFiles, fileLists.modifiedFiles)}';
  return BranchSummaryResult(
    summary: summary.isEmpty ? 'No summary generated' : summary,
    readFiles: fileLists.readFiles,
    modifiedFiles: fileLists.modifiedFiles,
  );
}

/// The settled conversation prose of one [generateBranchSummary] pass:
/// [text] on success; [aborted]/[error] carry the never-throw contract's
/// failure exits instead (the caller maps them onto [BranchSummaryResult]).
final class _BranchTextOutcome {
  const _BranchTextOutcome.text(this.text) : aborted = false, error = null;
  const _BranchTextOutcome.aborted()
    : text = null,
      aborted = true,
      error = null;
  const _BranchTextOutcome.error(this.error) : text = null, aborted = false;
  final String? text;
  final bool aborted;
  final String? error;
}

/// The conversation-settling half of [generateBranchSummary]: one
/// summarizer call when the serialized region fits [maxPromptTokens] (or is
/// unbounded — `null`), chunk-wise folds over budget — each chunk bounded by
/// [truncateForSummaryBudget] (the explicit truncation note for a single
/// oversized message), every later call folding the prior summary in as
/// `<previous-checkpoint>` — and the settled prose is the LAST fold. Never
/// throws: aborts and failures surface on the [_BranchTextOutcome].
Future<_BranchTextOutcome> _sumarizeBranchText(
  List<Message> messages, {
  required Future<SummarizationResult> Function(String prompt) runOne,
  required String Function(String conversation, String? prior) build,
  required String instructions,
  required int? maxPromptTokens,
}) async {
  final full = build(serializeConversation(messages), null);
  if (maxPromptTokens == null ||
      estimateStringTokens(full) <= maxPromptTokens) {
    final result = await runOne(full);
    if (result.isAborted) return const _BranchTextOutcome.aborted();
    final text = result.text ?? '';
    if (text.isEmpty && result.error != null) {
      return _BranchTextOutcome.error(result.error);
    }
    return _BranchTextOutcome.text(text);
  }
  // Over the payload budget (#729 parity, gh-2102 review): chunk the
  // region, fold chunk-wise — the result is the LAST fold.
  var prior = '';
  final chunks = chunkSummarizableMessages(
    messages,
    max(maxPromptTokens - _chunkPlanReserveTokens, 256),
  );
  for (var i = 0; i < chunks.length; i++) {
    final conversation = truncateForSummaryBudget(
      serializeConversation(chunks[i]),
      budgetTokens: maxPromptTokens,
      envelopeChars: _foldEnvelopeChars(
        prior: prior,
        instructions: instructions,
      ),
    );
    final result = await runOne(
      build(conversation, prior.isEmpty ? null : prior),
    );
    if (result.isAborted) return const _BranchTextOutcome.aborted();
    final fold = result.text;
    if (fold == null) {
      return _BranchTextOutcome.error(
        result.error ?? 'Branch summarization failed',
      );
    }
    prior = fold;
  }
  return _BranchTextOutcome.text(prior);
}

/// Prompt overhead reserved per chunk before the conversation text (parity
/// with the compaction fold's `_chunkEnvelopeReserveTokens`): tags, the
/// previous-checkpoint block and the instruction tail. The exact fit is
/// enforced by [truncateForSummaryBudget]; this only sizes the chunk plan.
const _chunkPlanReserveTokens = 4096;

/// Everything around the conversation in a fold prompt (tags, the
/// previous-checkpoint block, the instructions), measured — the envelope
/// [truncateForSummaryBudget] subtracts from the budget.
int _foldEnvelopeChars({required String prior, required String instructions}) {
  final prompt = StringBuffer()..write('<conversation>\n</conversation>\n');
  if (prior.isNotEmpty) {
    prompt.write('<previous-checkpoint>\n$prior\n</previous-checkpoint>\n');
  }
  prompt.write(instructions);
  return prompt.length;
}

/// Navigate [session] to [targetId] (omp's tree navigation with branch
/// summarization): the branch being left is summarized via [summarize] into
/// a `branch_summary` record prepended to the context of the branch being
/// entered, and the active leaf moves. Returns the new `branch_summary`
/// record id, or `null` when no summary was written (no-op navigation,
/// nothing to summarize, or summarization failed/aborted).
///
/// This is the wiring point for tree navigation: hosts that expose branch
/// switching call this instead of [Session.moveTo] directly. Summarization
/// failure never blocks navigation — the abandoned branch stays in the tree
/// regardless; the summary is a convenience projection, not the only copy.
Future<String?> navigateSessionTree(
  Session session,
  String? targetId, {
  required SummarizeFn summarize,
  int tokenBudget = 0,
  String? customInstructions,
  bool? fromHook,
  CancelToken? cancelToken,
}) async {
  final oldLeafId = await session.getLeafId();
  if (oldLeafId == targetId) return null;

  String? summary;
  Object? details;
  if (oldLeafId != null && targetId != null) {
    final collected = await collectEntriesForBranchSummary(
      session,
      oldLeafId,
      targetId,
    );
    if (collected.entries.isNotEmpty) {
      final result = await generateBranchSummary(
        collected.entries,
        summarize: summarize,
        tokenBudget: tokenBudget,
        customInstructions: customInstructions,
        cancelToken: cancelToken,
      );
      if (result.aborted) return null;
      if (result.summary != null) {
        summary = result.summary;
        details = {
          'readFiles': result.readFiles ?? const <String>[],
          'modifiedFiles': result.modifiedFiles ?? const <String>[],
        };
      }
    }
  }
  return session.moveTo(
    targetId,
    summary: summary,
    details: details,
    fromHook: fromHook,
  );
}
