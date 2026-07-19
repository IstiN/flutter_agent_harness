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

import '../cancel_token.dart';
import '../context.dart';
import '../prompts/prompts.g.dart';
import '../session/session_record.dart';
import '../session/session_tree.dart';
import '../types.dart';
import 'compaction.dart';
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
                '$branchSummaryPrefix$summary$branchSummarySuffix',
                timestamp: timestamp,
              ),
            ],
    // Unlike compaction, branch summarization includes earlier compaction
    // summaries as context (omp parity).
    CompactionRecord(:final summary, :final timestamp) => [
      UserMessage.text(
        '$compactionSummaryPrefix$summary$compactionSummarySuffix',
        timestamp: timestamp,
      ),
    ],
    _ => const [],
  };
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
    if (tokenBudget > 0 && totalTokens + tokens > tokenBudget) {
      // Summary entries squeeze in anyway when nearly full — they are
      // important context (omp parity).
      if ((entry is CompactionRecord || entry is BranchSummaryRecord) &&
          totalTokens < tokenBudget * 0.9) {
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
/// prepends the branch preamble plus the file-operation tags. Never throws:
/// failures surface as [BranchSummaryResult.error].
Future<BranchSummaryResult> generateBranchSummary(
  List<SessionRecord> entries, {
  required SummarizeFn summarize,
  int tokenBudget = 0,
  String? customInstructions,
  CancelToken? cancelToken,
}) async {
  final preparation = prepareBranchEntries(entries, tokenBudget: tokenBudget);
  if (preparation.messages.isEmpty) {
    return const BranchSummaryResult(summary: 'No content to summarize');
  }

  final instructions = customInstructions ?? branchSummaryPrompt;
  final prompt =
      '<conversation>\n'
      '${serializeConversation(preparation.messages)}\n'
      '</conversation>\n\n$instructions';

  SummarizationResult result;
  try {
    result = await summarize(
      SummarizationRequest(prompt: prompt, cancelToken: cancelToken),
    );
  } catch (error) {
    result = SummarizationResult.failure('Branch summarization failed: $error');
  }
  if (result.isAborted) return const BranchSummaryResult(aborted: true);
  final text = result.text;
  if (text == null) {
    return BranchSummaryResult(
      error: result.error ?? 'Branch summarization failed',
    );
  }

  final fileLists = computeFileLists(preparation.fileOps);
  final summary =
      '$branchSummaryPreamble\n$text'
      '${formatFileOperations(fileLists.readFiles, fileLists.modifiedFiles)}';
  return BranchSummaryResult(
    summary: summary.isEmpty ? 'No summary generated' : summary,
    readFiles: fileLists.readFiles,
    modifiedFiles: fileLists.modifiedFiles,
  );
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
