/// The compaction pipeline: decide, cut, summarize, and rewrite history.
///
/// Ported from pi-mono `packages/agent/src/harness/compaction/compaction.ts`
/// and `compaction/utils.ts`. The pipeline is token-based, never
/// message-count-based:
///
/// 1. [estimateContextTokens] (see `token_estimation.dart`) measures the
///    context; [shouldCompact] compares it against the model window minus a
///    16384-token reserve.
/// 2. [findCutPoint] walks the session branch backwards, keeping ~20k recent
///    tokens and cutting only on valid message boundaries.
/// 3. [generateSummary] asks an LLM for a structured checkpoint summary of
///    the compacted region using pi's fixed prompt.
/// 4. [CompactionManager.compactSession] appends a [CompactionRecord]; the
///    session's context projection then replaces the summarized region with
///    the summary. On any failure nothing is appended — compaction is
///    failure-safe and never loses history.
///
/// Deliberate divergences from the TypeScript original:
///
/// - The summary LLM call is an injected [SummarizeFn] instead of pi's
///   `models.completeSimple`, so tests can fake it and any provider adapter
///   can back it. [streamFunctionSummarizer] adapts a [StreamFunction].
/// - pi clamps the summary's `maxTokens` to `0.8 * reserveTokens`; our
///   [StreamFunction] has no options slot, so the clamp is the adapter's
///   responsibility.
/// - Failures surface as [CompactionException] (pi returns a `Result` and the
///   harness rethrows the error).
library;

import 'dart:convert';

import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../exceptions.dart';
import '../model.dart';
import '../session/session_record.dart';
import '../session/session_tree.dart';
import '../types.dart';
import 'token_estimation.dart';

// ---------------------------------------------------------------------------
// Prompts (ported verbatim from pi's compaction.ts)
// ---------------------------------------------------------------------------

/// System prompt for the summarization LLM. Ported verbatim from pi's
/// `SUMMARIZATION_SYSTEM_PROMPT`.
const summarizationSystemPrompt =
    'You are a context summarization assistant. Your task is to read a '
    'conversation between a user and an AI assistant, then produce a '
    'structured summary following the exact format specified.\n'
    '\n'
    'Do NOT continue the conversation. Do NOT respond to any questions in '
    'the conversation. ONLY output the structured summary.';

/// Structured checkpoint prompt for a first-time summary. Ported verbatim
/// from pi's `SUMMARIZATION_PROMPT`.
const summarizationPrompt =
    'The messages above are a conversation to summarize. Create a structured '
    'context checkpoint summary that another LLM will use to continue the '
    'work.\n'
    '\n'
    'Use this EXACT format:\n'
    '\n'
    '## Goal\n'
    '[What is the user trying to accomplish? Can be multiple items if the '
    'session covers different tasks.]\n'
    '\n'
    '## Constraints & Preferences\n'
    '- [Any constraints, preferences, or requirements mentioned by user]\n'
    '- [Or "(none)" if none were mentioned]\n'
    '\n'
    '## Progress\n'
    '### Done\n'
    '- [x] [Completed tasks/changes]\n'
    '\n'
    '### In Progress\n'
    '- [ ] [Current work]\n'
    '\n'
    '### Blocked\n'
    '- [Issues preventing progress, if any]\n'
    '\n'
    '## Key Decisions\n'
    '- **[Decision]**: [Brief rationale]\n'
    '\n'
    '## Next Steps\n'
    '1. [Ordered list of what should happen next]\n'
    '\n'
    '## Critical Context\n'
    '- [Any data, examples, or references needed to continue]\n'
    '- [Or "(none)" if not applicable]\n'
    '\n'
    'Keep each section concise. Preserve exact file paths, function names, '
    'and error messages.';

/// Prompt for updating an existing summary with new messages. Ported
/// verbatim from pi's `UPDATE_SUMMARIZATION_PROMPT`.
const updateSummarizationPrompt =
    'The messages above are NEW conversation messages to incorporate into '
    'the existing summary provided in <previous-summary> tags.\n'
    '\n'
    'Update the existing structured summary with new information. RULES:\n'
    '- PRESERVE all existing information from the previous summary\n'
    '- ADD new progress, decisions, and context from the new messages\n'
    '- UPDATE the Progress section: move items from "In Progress" to "Done" '
    'when completed\n'
    '- UPDATE "Next Steps" based on what was accomplished\n'
    '- PRESERVE exact file paths, function names, and error messages\n'
    '- If something is no longer relevant, you may remove it\n'
    '\n'
    'Use this EXACT format:\n'
    '\n'
    '## Goal\n'
    '[Preserve existing goals, add new ones if the task expanded]\n'
    '\n'
    '## Constraints & Preferences\n'
    '- [Preserve existing, add new ones discovered]\n'
    '\n'
    '## Progress\n'
    '### Done\n'
    '- [x] [Include previously done items AND newly completed items]\n'
    '\n'
    '### In Progress\n'
    '- [ ] [Current work - update based on progress]\n'
    '\n'
    '### Blocked\n'
    '- [Current blockers - remove if resolved]\n'
    '\n'
    '## Key Decisions\n'
    '- **[Decision]**: [Brief rationale] (preserve all previous, add new)\n'
    '\n'
    '## Next Steps\n'
    '1. [Update based on current state]\n'
    '\n'
    '## Critical Context\n'
    '- [Preserve important context, add new if needed]\n'
    '\n'
    'Keep each section concise. Preserve exact file paths, function names, '
    'and error messages.';

/// Prompt for summarizing the prefix of a split turn. Ported verbatim from
/// pi's `TURN_PREFIX_SUMMARIZATION_PROMPT`.
const turnPrefixSummarizationPrompt =
    'This is the PREFIX of a turn that was too large to keep. The SUFFIX '
    '(recent work) is retained.\n'
    '\n'
    'Summarize the prefix to provide context for the retained suffix:\n'
    '\n'
    '## Original Request\n'
    '[What did the user ask for in this turn?]\n'
    '\n'
    '## Early Progress\n'
    '- [Key decisions and work done in the prefix]\n'
    '\n'
    '## Context for Suffix\n'
    '- [Information needed to understand the retained recent work]\n'
    '\n'
    "Be concise. Focus on what's needed to understand the kept suffix.";

// ---------------------------------------------------------------------------
// Conversation serialization (ported from pi's compaction/utils.ts)
// ---------------------------------------------------------------------------

const _toolResultMaxChars = 2000;

String _safeJsonEncode(Object? value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return '[unserializable]';
  }
}

String _truncateForSummary(String text, int maxChars) {
  if (text.length <= maxChars) return text;
  final truncatedChars = text.length - maxChars;
  return '${text.substring(0, maxChars)}\n\n'
      '[... $truncatedChars more characters truncated]';
}

/// Serialize messages to plain text for summarization prompts.
///
/// Ported from pi's `serializeConversation`: `[User]:`, `[Assistant]:`,
/// `[Assistant thinking]:`, `[Assistant tool calls]:`, and truncated
/// `[Tool result]:` lines, joined by blank lines. Image blocks are skipped.
String serializeConversation(List<Message> messages) {
  final parts = <String>[];

  for (final msg in messages) {
    switch (msg) {
      case UserMessage(:final content):
        final text = content is String
            ? content
            : (content as List<ContentBlock>)
                  .whereType<TextContent>()
                  .map((block) => block.text)
                  .join();
        if (text.isNotEmpty) parts.add('[User]: $text');
      case AssistantMessage(:final content):
        final textParts = <String>[];
        final thinkingParts = <String>[];
        final toolCalls = <String>[];
        for (final block in content) {
          switch (block) {
            case TextContent(:final text):
              textParts.add(text);
            case ThinkingContent(:final thinking):
              thinkingParts.add(thinking);
            case ToolCall(:final name, :final arguments):
              final args = arguments.entries
                  .map(
                    (entry) => '${entry.key}=${_safeJsonEncode(entry.value)}',
                  )
                  .join(', ');
              toolCalls.add('$name($args)');
            default:
          }
        }
        if (thinkingParts.isNotEmpty) {
          parts.add('[Assistant thinking]: ${thinkingParts.join('\n')}');
        }
        if (textParts.isNotEmpty) {
          parts.add('[Assistant]: ${textParts.join('\n')}');
        }
        if (toolCalls.isNotEmpty) {
          parts.add('[Assistant tool calls]: ${toolCalls.join('; ')}');
        }
      case ToolResultMessage(:final content):
        final text = content
            .whereType<TextContent>()
            .map((block) => block.text)
            .join();
        if (text.isNotEmpty) {
          parts.add(
            '[Tool result]: ${_truncateForSummary(text, _toolResultMaxChars)}',
          );
        }
      default:
    }
  }

  return parts.join('\n\n');
}

// ---------------------------------------------------------------------------
// File operations (ported from pi's compaction/utils.ts)
// ---------------------------------------------------------------------------

/// File paths touched by a compaction range.
///
/// Ported from pi's `FileOperations`.
final class FileOperations {
  /// Creates an empty [FileOperations] accumulator.
  FileOperations();

  /// Files read but not necessarily modified.
  final read = <String>{};

  /// Files written by full-file write operations.
  final written = <String>{};

  /// Files modified by edit operations.
  final edited = <String>{};
}

/// Create an empty file-operation accumulator. Ported from pi's
/// `createFileOps`.
FileOperations createFileOps() => FileOperations();

/// Add file operations from assistant `read`/`write`/`edit` tool calls to
/// [fileOps]. Ported from pi's `extractFileOpsFromMessage`.
void extractFileOpsFromMessage(Message message, FileOperations fileOps) {
  if (message is! AssistantMessage) return;
  for (final block in message.content) {
    if (block is! ToolCall) continue;
    final path = block.arguments['path'];
    if (path is! String) continue;
    switch (block.name) {
      case 'read':
        fileOps.read.add(path);
      case 'write':
        fileOps.written.add(path);
      case 'edit':
        fileOps.edited.add(path);
    }
  }
}

/// Compute sorted read-only and modified file lists from accumulated
/// operations. Ported from pi's `computeFileLists`.
({List<String> readFiles, List<String> modifiedFiles}) computeFileLists(
  FileOperations fileOps,
) {
  final modified = {...fileOps.edited, ...fileOps.written};
  final readOnly = fileOps.read.where((f) => !modified.contains(f)).toList()
    ..sort();
  final modifiedFiles = modified.toList()..sort();
  return (readFiles: readOnly, modifiedFiles: modifiedFiles);
}

/// Format file lists as summary metadata tags. Ported from pi's
/// `formatFileOperations`.
String formatFileOperations(
  List<String> readFiles,
  List<String> modifiedFiles,
) {
  final sections = <String>[];
  if (readFiles.isNotEmpty) {
    sections.add('<read-files>\n${readFiles.join('\n')}\n</read-files>');
  }
  if (modifiedFiles.isNotEmpty) {
    sections.add(
      '<modified-files>\n${modifiedFiles.join('\n')}\n</modified-files>',
    );
  }
  if (sections.isEmpty) return '';
  return '\n\n${sections.join('\n\n')}';
}

// ---------------------------------------------------------------------------
// Settings and the compaction decision
// ---------------------------------------------------------------------------

/// Compaction thresholds and retention settings.
///
/// Ported from pi's `CompactionSettings`.
final class CompactionSettings {
  /// Creates a [CompactionSettings].
  const CompactionSettings({
    required this.enabled,
    required this.reserveTokens,
    required this.keepRecentTokens,
  });

  /// Enable automatic compaction decisions.
  final bool enabled;

  /// Tokens reserved for the summary prompt and output.
  final int reserveTokens;

  /// Approximate recent-context tokens to keep after compaction.
  final int keepRecentTokens;
}

/// Default compaction settings (pi's `DEFAULT_COMPACTION_SETTINGS`):
/// reserve 16384 tokens, keep ~20000 recent tokens.
const defaultCompactionSettings = CompactionSettings(
  enabled: true,
  reserveTokens: 16384,
  keepRecentTokens: 20000,
);

/// Whether context usage exceeds the compaction threshold.
///
/// Ported from pi's `shouldCompact`: compacts when
/// `contextTokens > contextWindow - reserveTokens`.
bool shouldCompact(
  int contextTokens,
  int contextWindow,
  CompactionSettings settings,
) {
  if (!settings.enabled) return false;
  return contextTokens > contextWindow - settings.reserveTokens;
}

// ---------------------------------------------------------------------------
// Cut point selection
// ---------------------------------------------------------------------------

/// Cut point selected for compaction.
///
/// Ported from pi's `CutPointResult`.
final class CutPointResult {
  /// Creates a [CutPointResult].
  const CutPointResult({
    required this.firstKeptEntryIndex,
    required this.turnStartIndex,
    required this.isSplitTurn,
  });

  /// Index of the first entry retained after compaction.
  final int firstKeptEntryIndex;

  /// Index of the turn-start entry when the cut splits a turn, otherwise -1.
  final int turnStartIndex;

  /// Whether the selected cut point splits an in-progress turn.
  final bool isSplitTurn;
}

List<int> _findValidCutPoints(
  List<SessionRecord> entries,
  int startIndex,
  int endIndex,
) {
  final cutPoints = <int>[];
  for (var i = startIndex; i < endIndex; i++) {
    final entry = entries[i];
    if (entry is MessageRecord) {
      // Any message role except tool results may start the kept region.
      if (entry.message.role != 'toolResult') cutPoints.add(i);
    } else if (entry is BranchSummaryRecord || entry is CustomMessageRecord) {
      cutPoints.add(i);
    }
  }
  return cutPoints;
}

/// Find the user-visible message that starts the turn containing an entry.
///
/// Ported from pi's `findTurnStartIndex`.
int findTurnStartIndex(
  List<SessionRecord> entries,
  int entryIndex,
  int startIndex,
) {
  for (var i = entryIndex; i >= startIndex; i--) {
    final entry = entries[i];
    if (entry is BranchSummaryRecord || entry is CustomMessageRecord) {
      return i;
    }
    if (entry is MessageRecord && entry.message.role == 'user') return i;
  }
  return -1;
}

/// Find the compaction cut point that keeps approximately [keepRecentTokens]
/// recent tokens.
///
/// Ported from pi's `findCutPoint`: walks entries backwards accumulating
/// estimated tokens until the budget is exhausted, then snaps the cut forward
/// to the next valid cut point (never a tool result) and backwards over
/// non-message records so configuration entries stay with the kept region.
CutPointResult findCutPoint(
  List<SessionRecord> entries,
  int startIndex,
  int endIndex,
  int keepRecentTokens,
) {
  final cutPoints = _findValidCutPoints(entries, startIndex, endIndex);

  if (cutPoints.isEmpty) {
    return CutPointResult(
      firstKeptEntryIndex: startIndex,
      turnStartIndex: -1,
      isSplitTurn: false,
    );
  }
  var accumulatedTokens = 0;
  var cutIndex = cutPoints.first;

  for (var i = endIndex - 1; i >= startIndex; i--) {
    final entry = entries[i];
    if (entry is! MessageRecord) continue;
    accumulatedTokens += estimateTokens(entry.message);
    if (accumulatedTokens >= keepRecentTokens) {
      for (final cutPoint in cutPoints) {
        if (cutPoint >= i) {
          cutIndex = cutPoint;
          break;
        }
      }
      break;
    }
  }
  while (cutIndex > startIndex) {
    final prevEntry = entries[cutIndex - 1];
    if (prevEntry is CompactionRecord || prevEntry is MessageRecord) break;
    cutIndex--;
  }
  final cutEntry = entries[cutIndex];
  final isUserMessage =
      cutEntry is MessageRecord && cutEntry.message.role == 'user';
  final turnStartIndex = isUserMessage
      ? -1
      : findTurnStartIndex(entries, cutIndex, startIndex);

  return CutPointResult(
    firstKeptEntryIndex: cutIndex,
    turnStartIndex: turnStartIndex,
    isSplitTurn: !isUserMessage && turnStartIndex != -1,
  );
}

// ---------------------------------------------------------------------------
// Summary generation
// ---------------------------------------------------------------------------

/// A single summarization request handed to a [SummarizeFn].
final class SummarizationRequest {
  /// Creates a [SummarizationRequest].
  const SummarizationRequest({required this.prompt, this.cancelToken});

  /// The full user prompt (serialized conversation + instructions).
  final String prompt;

  /// Cancellation for the underlying LLM call, if any.
  final CancelToken? cancelToken;
}

/// Result of a [SummarizeFn] call. Success carries [text]; failure carries
/// [error] and optionally marks the call as [isAborted].
final class SummarizationResult {
  const SummarizationResult._({this.text, this.error, this.isAborted = false});

  /// A successful summary.
  factory SummarizationResult.success(String text) {
    return SummarizationResult._(text: text);
  }

  /// A failed (or aborted, when [aborted] is true) summarization.
  factory SummarizationResult.failure(String error, {bool aborted = false}) {
    return SummarizationResult._(error: error, isAborted: aborted);
  }

  /// The summary text on success, `null` on failure.
  final String? text;

  /// The failure description on failure, `null` on success.
  final String? error;

  /// Whether the call was aborted rather than failed.
  final bool isAborted;

  /// Whether the call produced a summary.
  bool get isSuccess => text != null;
}

/// The injectable summary LLM call.
///
/// Implementations must never throw — return [SummarizationResult.failure]
/// instead, mirroring the providers-never-throw contract. The compaction
/// pipeline is defensive anyway: a throw is converted into a failure.
typedef SummarizeFn =
    Future<SummarizationResult> Function(SummarizationRequest request);

/// Adapts a provider [StreamFunction] into a [SummarizeFn].
///
/// Sends pi's [summarizationSystemPrompt] plus the request prompt as a single
/// user message and joins the response's text blocks. Error and aborted stop
/// reasons map to failure results (errors-as-events contract); a throwing
/// [StreamFunction] is defensive-converted into a failure.
SummarizeFn streamFunctionSummarizer(
  StreamFunction streamFunction,
  Model model,
) {
  return (SummarizationRequest request) async {
    try {
      final stream = streamFunction(
        model,
        Context(
          systemPrompt: summarizationSystemPrompt,
          messages: [UserMessage.text(request.prompt)],
        ),
        cancelToken: request.cancelToken,
      );
      final response = await stream.result;
      return switch (response.stopReason) {
        StopReason.aborted => SummarizationResult.failure(
          response.errorMessage ?? 'Summarization aborted',
          aborted: true,
        ),
        StopReason.error => SummarizationResult.failure(
          'Summarization failed: ${response.errorMessage ?? 'Unknown error'}',
        ),
        _ => SummarizationResult.success(
          response.content
              .whereType<TextContent>()
              .map((block) => block.text)
              .join('\n'),
        ),
      };
    } catch (error) {
      return SummarizationResult.failure('Summarization failed: $error');
    }
  };
}

Future<String> _runSummarization({
  required String prompt,
  required SummarizeFn summarize,
  required CancelToken? cancelToken,
  required String failureLabel,
}) async {
  SummarizationResult result;
  try {
    result = await summarize(
      SummarizationRequest(prompt: prompt, cancelToken: cancelToken),
    );
  } catch (error) {
    result = SummarizationResult.failure('$failureLabel: $error');
  }
  if (result.isAborted) {
    throw CompactionException(
      result.error ?? '$failureLabel aborted',
      code: CompactionErrorCode.aborted,
    );
  }
  final text = result.text;
  if (text == null) {
    throw CompactionException(
      result.error ?? failureLabel,
      code: CompactionErrorCode.summarizationFailed,
    );
  }
  return text;
}

/// Generate (or update) a conversation summary for compaction.
///
/// Ported from pi's `generateSummary`: serializes [messages] into
/// `<conversation>` tags, optionally appends `<previous-summary>` for
/// iterative updates, and ends with the fixed structured prompt (plus
/// `Additional focus:` when [customInstructions] is given). Throws
/// [CompactionException] on failure — callers must treat compaction as
/// failure-safe and leave history untouched.
Future<String> generateSummary(
  List<Message> messages, {
  required SummarizeFn summarize,
  String? customInstructions,
  String? previousSummary,
  CancelToken? cancelToken,
}) {
  var basePrompt = previousSummary != null
      ? updateSummarizationPrompt
      : summarizationPrompt;
  if (customInstructions != null) {
    basePrompt = '$basePrompt\n\nAdditional focus: $customInstructions';
  }
  final prompt = StringBuffer()
    ..write('<conversation>\n')
    ..write(serializeConversation(messages))
    ..write('\n</conversation>\n\n');
  if (previousSummary != null) {
    prompt.write(
      '<previous-summary>\n$previousSummary\n</previous-summary>\n\n',
    );
  }
  prompt.write(basePrompt);

  return _runSummarization(
    prompt: prompt.toString(),
    summarize: summarize,
    cancelToken: cancelToken,
    failureLabel: 'Summarization failed',
  );
}

Future<String> _generateTurnPrefixSummary(
  List<Message> messages, {
  required SummarizeFn summarize,
  CancelToken? cancelToken,
}) {
  final prompt =
      '<conversation>\n${serializeConversation(messages)}\n</conversation>\n\n'
      '$turnPrefixSummarizationPrompt';
  return _runSummarization(
    prompt: prompt,
    summarize: summarize,
    cancelToken: cancelToken,
    failureLabel: 'Turn prefix summarization failed',
  );
}

// ---------------------------------------------------------------------------
// Pipeline orchestration
// ---------------------------------------------------------------------------

/// Prepared inputs for a compaction run.
///
/// Ported from pi's `CompactionPreparation`.
final class CompactionPreparation {
  /// Creates a [CompactionPreparation].
  const CompactionPreparation({
    required this.firstKeptEntryId,
    required this.messagesToSummarize,
    required this.turnPrefixMessages,
    required this.isSplitTurn,
    required this.tokensBefore,
    this.previousSummary,
    this.readFiles = const [],
    this.modifiedFiles = const [],
    this.settings = defaultCompactionSettings,
  });

  /// Entry id where retained history starts.
  final String firstKeptEntryId;

  /// Messages summarized into the history summary.
  final List<Message> messagesToSummarize;

  /// Prefix messages summarized separately when compaction splits a turn.
  final List<Message> turnPrefixMessages;

  /// Whether compaction splits a turn.
  final bool isSplitTurn;

  /// Estimated context tokens before compaction.
  final int tokensBefore;

  /// Previous compaction summary used for iterative updates.
  final String? previousSummary;

  /// Files read in the compacted history (accumulated across compactions).
  final List<String> readFiles;

  /// Files modified in the compacted history (accumulated across
  /// compactions).
  final List<String> modifiedFiles;

  /// Settings used to prepare compaction.
  final CompactionSettings settings;
}

/// Generated compaction data ready to persist as a [CompactionRecord].
///
/// Ported from pi's `CompactionResult`.
final class CompactionResult {
  /// Creates a [CompactionResult].
  const CompactionResult({
    required this.summary,
    required this.firstKeptEntryId,
    required this.tokensBefore,
    this.details,
  });

  /// Summary text that replaces compacted history in future context.
  final String summary;

  /// Entry id where retained history starts.
  final String firstKeptEntryId;

  /// Estimated context tokens before compaction.
  final int tokensBefore;

  /// Structured details stored with the compaction entry: a
  /// `{'readFiles': [...], 'modifiedFiles': [...]}` map.
  final Object? details;
}

List<Message> _entryToSummarizableMessages(SessionRecord entry) {
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
    // Compaction records themselves never enter a summary.
    _ => const [],
  };
}

/// The compaction pipeline over a [Session], mirroring pi's harness-level
/// `compact()`.
///
/// Usage mirrors pi: callers check [shouldCompact] with
/// [estimateContextTokens] against the model's context window, then call
/// [compactSession] explicitly (pi compacts on demand while the harness is
/// idle, never inside the run loop).
final class CompactionManager {
  /// Creates a [CompactionManager] with an injected summary LLM call.
  const CompactionManager({
    required this.summarize,
    this.settings = defaultCompactionSettings,
  });

  /// The summary LLM call used for every summarization.
  final SummarizeFn summarize;

  /// Thresholds and retention settings for [compactSession].
  final CompactionSettings settings;

  /// Prepare session branch records for compaction, or return `null` when
  /// compaction is not applicable (empty branch, or the last entry is already
  /// a compaction).
  ///
  /// Ported from pi's `prepareCompaction`: the summarized region starts at
  /// the previous compaction's kept boundary (with its summary threaded in
  /// for iterative updates), and file operations accumulate across
  /// compactions.
  CompactionPreparation? prepareCompaction(
    List<SessionRecord> pathEntries, {
    required int tokensBefore,
    CompactionSettings? settings,
  }) {
    final effectiveSettings = settings ?? this.settings;
    if (pathEntries.isEmpty || pathEntries.last is CompactionRecord) {
      return null;
    }

    var prevCompactionIndex = -1;
    for (var i = pathEntries.length - 1; i >= 0; i--) {
      if (pathEntries[i] is CompactionRecord) {
        prevCompactionIndex = i;
        break;
      }
    }

    final fileOps = createFileOps();
    String? previousSummary;
    var boundaryStart = 0;
    if (prevCompactionIndex >= 0) {
      final prevCompaction =
          pathEntries[prevCompactionIndex] as CompactionRecord;
      previousSummary = prevCompaction.summary;
      final firstKeptEntryIndex = pathEntries.indexWhere(
        (entry) => entry.id == prevCompaction.firstKeptEntryId,
      );
      boundaryStart = firstKeptEntryIndex >= 0
          ? firstKeptEntryIndex
          : prevCompactionIndex + 1;
      if (prevCompaction.fromHook != true) {
        final details = prevCompaction.details;
        if (details is Map) {
          final readFiles = details['readFiles'];
          if (readFiles is List) {
            fileOps.read.addAll(readFiles.whereType<String>());
          }
          final modifiedFiles = details['modifiedFiles'];
          if (modifiedFiles is List) {
            fileOps.edited.addAll(modifiedFiles.whereType<String>());
          }
        }
      }
    }

    final cutPoint = findCutPoint(
      pathEntries,
      boundaryStart,
      pathEntries.length,
      effectiveSettings.keepRecentTokens,
    );
    final firstKeptEntryId = pathEntries[cutPoint.firstKeptEntryIndex].id;

    final historyEnd = cutPoint.isSplitTurn
        ? cutPoint.turnStartIndex
        : cutPoint.firstKeptEntryIndex;
    final messagesToSummarize = <Message>[];
    for (var i = boundaryStart; i < historyEnd; i++) {
      messagesToSummarize.addAll(_entryToSummarizableMessages(pathEntries[i]));
    }
    final turnPrefixMessages = <Message>[];
    if (cutPoint.isSplitTurn) {
      for (
        var i = cutPoint.turnStartIndex;
        i < cutPoint.firstKeptEntryIndex;
        i++
      ) {
        turnPrefixMessages.addAll(_entryToSummarizableMessages(pathEntries[i]));
      }
    }
    for (final message in messagesToSummarize) {
      extractFileOpsFromMessage(message, fileOps);
    }
    for (final message in turnPrefixMessages) {
      extractFileOpsFromMessage(message, fileOps);
    }
    final fileLists = computeFileLists(fileOps);

    return CompactionPreparation(
      firstKeptEntryId: firstKeptEntryId,
      messagesToSummarize: messagesToSummarize,
      turnPrefixMessages: turnPrefixMessages,
      isSplitTurn: cutPoint.isSplitTurn,
      tokensBefore: tokensBefore,
      previousSummary: previousSummary,
      readFiles: fileLists.readFiles,
      modifiedFiles: fileLists.modifiedFiles,
      settings: effectiveSettings,
    );
  }

  /// Generate compaction summary data from a [preparation].
  ///
  /// Ported from pi's `compact`: split turns summarize history and turn
  /// prefix separately; the file-operation metadata tags are appended to the
  /// summary. Throws [CompactionException] on any summarization failure.
  Future<CompactionResult> compact(
    CompactionPreparation preparation, {
    String? customInstructions,
    CancelToken? cancelToken,
  }) async {
    String summary;

    if (preparation.isSplitTurn && preparation.turnPrefixMessages.isNotEmpty) {
      final history = preparation.messagesToSummarize.isNotEmpty
          ? await generateSummary(
              preparation.messagesToSummarize,
              summarize: summarize,
              customInstructions: customInstructions,
              previousSummary: preparation.previousSummary,
              cancelToken: cancelToken,
            )
          : 'No prior history.';
      final turnPrefix = await _generateTurnPrefixSummary(
        preparation.turnPrefixMessages,
        summarize: summarize,
        cancelToken: cancelToken,
      );
      summary =
          '$history\n\n---\n\n**Turn Context (split turn):**\n\n$turnPrefix';
    } else {
      summary = await generateSummary(
        preparation.messagesToSummarize,
        summarize: summarize,
        customInstructions: customInstructions,
        previousSummary: preparation.previousSummary,
        cancelToken: cancelToken,
      );
    }

    summary += formatFileOperations(
      preparation.readFiles,
      preparation.modifiedFiles,
    );

    return CompactionResult(
      summary: summary,
      firstKeptEntryId: preparation.firstKeptEntryId,
      tokensBefore: preparation.tokensBefore,
      details: {
        'readFiles': preparation.readFiles,
        'modifiedFiles': preparation.modifiedFiles,
      },
    );
  }

  /// Compact the active branch of [session] and append a [CompactionRecord].
  ///
  /// Returns the appended record, or `null` when there is nothing to compact.
  /// Failure-safe: when summarization throws, no record is appended and the
  /// session history is fully preserved. The session's
  /// [Session.buildContextMessages] then projects the summary in place of the
  /// compacted region.
  Future<CompactionRecord?> compactSession(
    Session session, {
    String? customInstructions,
    CancelToken? cancelToken,
  }) async {
    final path = await session.getBranch();
    final tokensBefore = estimateContextTokens(
      await session.buildContextMessages(),
    ).tokens;
    final preparation = prepareCompaction(path, tokensBefore: tokensBefore);
    if (preparation == null) return null;
    final result = await compact(
      preparation,
      customInstructions: customInstructions,
      cancelToken: cancelToken,
    );
    final recordId = await session.appendCompaction(
      summary: result.summary,
      firstKeptEntryId: result.firstKeptEntryId,
      tokensBefore: result.tokensBefore,
      details: result.details,
    );
    final record = await session.getEntry(recordId);
    return record is CompactionRecord ? record : null;
  }
}
