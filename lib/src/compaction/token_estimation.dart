/// Token estimation for context compaction.
///
/// Ported from pi-mono `packages/agent/src/harness/compaction/compaction.ts`
/// (`estimateTokens`, `calculateContextTokens`, `estimateContextTokens`).
/// The heuristic is deliberately crude and provider-agnostic: **4 characters
/// per token** for transcript text, with images estimated at 4800 chars
/// (≈ 1200 tokens). The FIXED request overhead (system prompt + tool
/// schemas) is token-dense and prices at its own density
/// ([overheadCharsPerToken], gh-2411), corrected per session by
/// [OverheadCalibration]. When a provider has reported real usage on an
/// assistant message, that number is trusted for everything up to and
/// including that message, and only the trailing messages are estimated.
library;

import 'dart:convert';

import '../agent/image_registry.dart' show imageContentKey;
import '../context.dart';
import '../session/session_record.dart';
import '../types.dart';
import 'overhead_calibration.dart';
import 'record_tag.dart' show tagOverheadTokens, taggedRecordCount;

/// Estimated character cost of an image block (pi's `ESTIMATED_IMAGE_CHARS`:
/// 4800 chars ≈ 1200 tokens at 4 chars/token).
const estimatedImageChars = 4800;

/// Wire-replacement charge for an image the registry already rides
/// earlier in the request (an `[Image N]` label plus overhead).
const estimatedRepeatImageChars = 32;

/// The content key estimation dedups against — a public seam pinned to
/// [imageContentKey] so the estimator and the registry never drift.
String estimationImageKey(ImageContent image) => imageContentKey(image);

/// Characters per token in pi's conservative heuristic (transcript
/// text: prose, tool output).
const _charsPerToken = 4;

/// Characters per token for the FIXED REQUEST OVERHEAD — the system
/// prompt and the tool schemas (gh-2411).
///
/// JSON schemas and a Markdown system prompt are token-dense: quotes,
/// colons, braces, paths and ids tokenize far below prose's ~4
/// chars/token. Measured on the gh-2411 session (Copilot /
/// claude-haiku-5.5, 2026-11-25): the request carried 12,105 system
/// prompt chars + 34 tool schemas (317 name + 33,112 description +
/// 20,027 compact schema chars) = 65,561 chars and the provider charged
/// 24,126 input tokens — 2.72 chars/token. The chars/4 heuristic priced
/// the same overhead at 16,407 tokens (32% under), so the ctx meter read
/// 82% on a request the provider saw at 121%. 2.5 keeps a ~8% margin on
/// the over-reading side (a per-provider residual is what
/// [OverheadCalibration] corrects, upward only); the transcript heuristic
/// above stays at pi's 4 (parity with pi's estimator).
const double _overheadCharsPerToken = 2.5;

/// The overhead density [estimateRequestOverheadTokens] prices at.
double get overheadCharsPerToken => _overheadCharsPerToken;

/// Calculate total context tokens from provider usage.
///
/// Ported from pi's `calculateContextTokens`: prefers [Usage.totalTokens]
/// when the provider reported it, otherwise sums the components.
int calculateContextTokens(Usage usage) {
  return usage.totalTokens != 0
      ? usage.totalTokens
      : usage.input + usage.output + usage.cacheRead + usage.cacheWrite;
}

int _textAndImageChars(Object content) {
  if (content is String) return content.length;
  var chars = 0;
  for (final block in content as List<ContentBlock>) {
    switch (block) {
      case TextContent(:final text):
        chars += text.length;
      case ImageContent():
        chars += estimatedImageChars;
      case VideoContent(:final data):
        // gh-2007 thread 3: a video rides up to
        // images.maxBytesPerRequest (~8MB base64) and REPLAYS those bytes
        // every request (videos have no registry placeholder rewrite), so
        // the honest price is the payload itself, not a fixed constant.
        chars += data.length;
      default:
    }
  }
  return chars;
}

/// Estimate token count for one message using pi's character heuristic.
///
/// - `user` / `toolResult`: text chars + [estimatedImageChars] per image.
/// - `assistant`: text + thinking chars, plus tool call name and JSON-encoded
///   arguments.
int estimateTokens(Message message) {
  final chars = switch (message) {
    UserMessage(:final content) => _textAndImageChars(content),
    AssistantMessage(:final content) => _assistantChars(content),
    ToolResultMessage(:final content) => _textAndImageChars(content),
    _ => 0,
  };
  return (chars + _charsPerToken - 1) ~/ _charsPerToken;
}

/// [estimateTokens] for a bare string — the same chars/4 heuristic, no
/// per-block structure. The ONE estimator for a system prompt: the boot
/// banner's pi-mode initial-context line and the parity gate
/// (`pi_hello_parity_test.dart`) both price a prompt with it, so the
/// printed and gated numbers agree by construction.
int estimateStringTokens(String text) =>
    (text.length + _charsPerToken - 1) ~/ _charsPerToken;
int _assistantChars(List<ContentBlock> content) {
  var chars = 0;
  for (final block in content) {
    switch (block) {
      case TextContent(:final text):
        chars += text.length;
      case ThinkingContent(:final thinking):
        chars += thinking.length;
      case ToolCall(:final name, :final arguments):
        chars += name.length + _safeJsonEncode(arguments).length;
      default:
    }
  }
  return chars;
}

String _safeJsonEncode(Object? value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return '[unserializable]';
  }
}

/// Estimated context tokens for a walked session branch (root-first
/// records), counting ONLY what [Session.buildContextMessages] would
/// project into the model context: messages, custom messages, compaction
/// and branch summaries. Ledger-only records (custom payloads like
/// `model_request_summary`, model/label markers, …) never reach the
/// context and count zero — a marathon tail full of giant
/// `model_request_summary` snapshots does not inflate the estimate.
///
/// Backs the token-budgeted resume walk (issue #503): the CLI pages a
/// windowed open back from the tail only until the resident records cover
/// the model's context window, instead of always walking to the newest
/// compaction boundary (or the whole file). Older history stays on disk
/// and pages in lazily via the scrollback's loadOlder path.
int estimateSessionBranchTokens(List<SessionRecord> branch) {
  var tokens = 0;
  for (final record in branch) {
    tokens += switch (record) {
      MessageRecord(:final message) => estimateTokens(message),
      CustomMessageRecord(:final content) =>
        (_textAndImageChars(content) + _charsPerToken - 1) ~/ _charsPerToken,
      CompactionRecord(:final summary) => estimateStringTokens(summary),
      BranchSummaryRecord(:final summary) => estimateStringTokens(summary),
      _ => 0,
    };
  }
  return tokens;
}

/// Estimated token cost of the one-line marker a hidden record renders as
/// in the structured projection (`[3:hidden·tool_result·4.2k]` ≈ 30–40
/// chars).
const hiddenRecordMarkerTokens = 10;
const _hiddenMarkerTokens = hiddenRecordMarkerTokens;

/// Token budget for the windowed resume walk (gh-968, AC-R3): the
/// transcript tally the walk may stop at, derived from the SAME basis as
/// the ctx meter, `_maybeAutoCompact` and the loop's over-window guard.
///
/// `effectiveContextWindow − system-prompt/tool-schema overhead −
/// reserveTokens`, floored at 0. The old budget priced the transcript
/// alone against the window, so a resume filled the resident records to
/// ~the whole window and the meter — which adds the unanchored
/// system+tools overhead on top — read past 100% (the reported
/// `127%/200k` resume). With the parity budget, meter = transcript +
/// overhead ≤ window − reserve: below the compaction trigger, below the
/// guard, on every fresh resume.
///
/// [overheadCalibration] (gh-241 follow-up #5, R2): a MEASURED session
/// prices the overhead by the provider's own report — the budget is the
/// same parity formula with the calibrated overhead. `null` callers skip
/// the budget altogether (R1): an unmeasured estimate never truncates a
/// resumed transcript.
int resumeParityBudget({
  required int effectiveContextWindow,
  required int reserveTokens,
  String? systemPrompt,
  List<Tool> tools = const [],
  OverheadCalibration overheadCalibration = OverheadCalibration.uncalibrated,
}) {
  final budget =
      effectiveContextWindow -
      overheadCalibration.apply(
        estimateRequestOverheadTokens(systemPrompt, tools),
      ) -
      reserveTokens;
  return budget > 0 ? budget : 0;
}

/// gh-241 follow-up #5 (F3): an in-memory cut must never hand the
/// provider a context that OPENS on an assistant or tool fragment — its
/// user turn is gone, several APIs refuse the shape, and the model reads
/// the missing turns as lost history. Returns the messages from the first
/// [UserMessage] on (the list itself when it already opens on one or
/// holds no user message at all — nothing is invented). The caller logs
/// [leading] through [onDropped].
List<Message> cutAtUserTurnBoundary(
  List<Message> messages, {
  required String reason,
  void Function(int leading, String reason)? onDropped,
}) {
  if (messages.isEmpty || messages.first is UserMessage) return messages;
  final first = messages.indexWhere((m) => m is UserMessage);
  if (first <= 0) return messages;
  onDropped?.call(first, reason);
  return messages.sublist(first);
}

/// The projected token cost of ONE record that actually renders — the
/// single switch both projection estimators ([projectedBranchBudgetCut],
/// [estimateProjectedBranchTokens]) price records with.
int _projectedRecordTokens(SessionRecord record) => switch (record) {
  MessageRecord(:final message) => estimateTokens(message),
  CustomMessageRecord(:final content, :final timestamp) => estimateTokens(
    UserMessage(content: content, timestamp: timestamp),
  ),
  CompactionRecord(:final summary) => estimateStringTokens(summary),
  BranchSummaryRecord(:final summary) => estimateStringTokens(summary),
  CompactCheckpointRecord(:final text) => estimateStringTokens(text),
  _ => 0,
};

/// The backward walk's marker absorption (mirror: the forward estimator
/// collects markers over the KEPT region only). Returns `true` when
/// [record] is the branch's last (newest) compaction record — the caller
/// engages the classic transform, pricing everything OLDER zero.
bool _absorbProjectionMarkers(
  SessionRecord record,
  Set<String> hidden,
  Set<String> covered,
) {
  switch (record) {
    case HiddenRangeRecord(:final recordIds):
      hidden.addAll(recordIds);
    case CompactCheckpointRecord(
      :final coversRecordIds,
      :final firstRecordId,
      :final lastRecordId,
    ):
      // Hidden-checkpoint parity (the goal_builder resume class): a
      // checkpoint the judge itself hid swallows NOTHING and renders
      // nothing (projection.dart `_coverAt` / the checkpoint case) —
      // its span prices FULL. The hiding range is always NEWER than the
      // checkpoint (folds reference older records), so the backward walk
      // has already collected it here.
      if (!hidden.contains(record.id)) {
        covered
          ..addAll(coversRecordIds)
          ..add(firstRecordId)
          ..add(lastRecordId);
      }
    case CompactionRecord():
      return true;
    default:
      break;
  }
  return false;
}

/// The index of the OLDEST record of [branch] (root-first) to keep so the
/// projected estimate of the kept suffix stays within [budget] — walking
/// from the newest end backward, the record that would push the tally
/// PAST the budget is dropped together with everything older — or `null`
/// when the whole branch already fits. The newest record is always kept
/// (a `0` budget floors at keeping the tail: never an empty window).
///
/// Record-granular budget stop for the resume walk (gh-968, AC-R4): the
/// old stop fired after a whole doubling block was paged, so one giant
/// record in the last block read the tally tens of thousands of tokens
/// past the budget. Exact mirror of [estimateProjectedBranchTokens]
/// walked in reverse: hidden-range/checkpoint markers sit NEWER than the
/// records they hide, so the backward pass already knows every record's
/// hidden/covered state when it reaches it, and the classic compaction
/// transform makes everything below the last compaction record's kept id
/// price zero — those records are never the crossing.
int? projectedBranchBudgetCut(List<SessionRecord> branch, int budget) {
  final hidden = <String>{};
  final covered = <String>{};
  var belowTransform = false; // passed the last compaction record
  var tally = 0;
  for (var i = branch.length - 1; i >= 0; i--) {
    final record = branch[i];
    if (belowTransform) continue; // dropped by the classic transform
    final contribution = covered.contains(record.id)
        ? 0
        : hidden.contains(record.id)
        ? (record is CompactCheckpointRecord ? 0 : _hiddenMarkerTokens)
        : _projectedRecordTokens(record);
    if (tally + contribution > budget && i < branch.length - 1) {
      // stop BEFORE the crossing record
      return _openOnUserTurn(branch, i + 1);
    }
    tally += contribution;
    if (_absorbProjectionMarkers(record, hidden, covered)) {
      belowTransform = true;
    }
  }
  return null; // whole branch fits
}

/// gh-2411 follow-up #5c (C3 — owner live test round 4): the kept tail
/// must never OPEN on an assistant reply or a tool result — their user
/// turn is gone (several APIs refuse the shape; the owner's spills 22/24
/// opened on a 1092/1167-char reply). The same invariant as every
/// in-memory cut ([cutAtUserTurnBoundary]): leading non-user messages
/// are dropped with the crossing record. Any other record (a boundary,
/// a custom message) opens a context legitimately; the newest record is
/// always kept.
int _openOnUserTurn(List<SessionRecord> branch, int cut) {
  for (var i = cut; i < branch.length - 1; i++) {
    final record = branch[i];
    if (record is! MessageRecord || record.message is UserMessage) break;
    cut = i + 1;
  }
  return cut;
}

/// The classic-transform KEPT region of [branch]: the last compaction
/// record replaces its dropped prefix (mirrors
/// `SessionTree._applyCompactionTransform`: kept = [compaction] +
/// path[firstKept..compactionIndex) + path(compactionIndex..]). The
/// summary record itself survives and REPLACES the dropped span.
List<SessionRecord> _keptAfterClassicTransform(List<SessionRecord> branch) {
  for (var i = branch.length - 1; i >= 0; i--) {
    final record = branch[i];
    if (record is CompactionRecord) {
      final cut = branch.indexWhere((r) => r.id == record.firstKeptEntryId);
      final foundKept = cut >= 0 && cut < i;
      return [
        record,
        if (foundKept) ...branch.sublist(cut, i),
        ...branch.sublist(i + 1),
      ];
    }
  }
  return branch;
}

/// Ids any [HiddenRangeRecord] on [kept] renders as one-line markers
/// (mirrors `buildStructuredViewState`; re-implemented here because
/// projection.dart already imports this library — importing back would be
/// circular).
Set<String> _collectHiddenIds(Iterable<SessionRecord> kept) {
  final hidden = <String>{};
  for (final record in kept) {
    if (record is HiddenRangeRecord) hidden.addAll(record.recordIds);
  }
  return hidden;
}

/// Ids swallowed by a healthy (non-hidden) checkpoint on [kept].
///
/// Hidden-checkpoint parity (the goal_builder resume class): a checkpoint
/// the judge itself hid swallows NOTHING and renders nothing
/// (projection.dart `_coverAt` — "its checkpoint was itself hidden — then
/// the range renders as if uncovered"). Collecting its covers anyway
/// undercounts the real projection by the whole covered span — a resume
/// walk priced 175k while the request actually carried ~298k, so the
/// budget trim never fired and the session booted over-window.
Set<String> _collectCoveredIds(
  Iterable<SessionRecord> kept,
  Set<String> hidden,
) {
  final covered = <String>{};
  for (final record in kept) {
    if (record is CompactCheckpointRecord && !hidden.contains(record.id)) {
      covered
        ..addAll(record.coversRecordIds)
        ..add(record.firstRecordId)
        ..add(record.lastRecordId);
    }
  }
  return covered;
}

/// Projection-aware variant of [estimateProjectedBranchTokens] (issue #503
/// round 3b): counts what `Session.buildContextMessages` would ACTUALLY
/// project, not the raw branch. Three adjustments over the raw tally:
///
/// 1. **Classic transform** — everything before the last
///    [CompactionRecord.firstKeptEntryId] is dropped (the summary replaces
///    it).
/// 2. **Structured hiding** — a record id in any [HiddenRangeRecord] on
///    the branch renders as a one-line marker, not its full content.
/// 3. **Checkpoints** — records covered by a [CompactCheckpointRecord]
///    (including flattened inner checkpoints, D4) count zero; the
///    checkpoint's own text counts once.
///
/// On a structured-compaction marathon the raw estimate overshoots the
/// real projected context by an order of magnitude (hundreds of hidden
/// tool results), which tripped the resume walk's token budget far too
/// early and resumed with a badly under-filled window.
int estimateProjectedBranchTokens(List<SessionRecord> branch) {
  final kept = _keptAfterClassicTransform(branch);
  final hidden = _collectHiddenIds(kept);
  final covered = _collectCoveredIds(kept, hidden);
  var tokens = 0;
  for (final record in kept) {
    if (covered.contains(record.id)) continue;
    if (hidden.contains(record.id)) {
      // A hidden checkpoint renders NOTHING (projection.dart's checkpoint
      // case: "no marker, no swallow"); every other hidden record renders
      // a one-line marker.
      if (record is CompactCheckpointRecord) continue;
      tokens += _hiddenMarkerTokens;
      continue;
    }
    tokens += _projectedRecordTokens(record);
  }
  return tokens;
}

/// Estimated context-token usage for a message list.
///
/// Ported from pi's `ContextUsageEstimate`.
final class ContextUsageEstimate {
  /// Creates a [ContextUsageEstimate].
  const ContextUsageEstimate({
    required this.tokens,
    required this.usageTokens,
    required this.trailingTokens,
    required this.lastUsageIndex,
  });

  /// An empty estimate (no messages, no anchor).
  static const empty = ContextUsageEstimate(
    tokens: 0,
    usageTokens: 0,
    trailingTokens: 0,
    lastUsageIndex: null,
  );

  /// Estimated total context tokens.
  final int tokens;

  /// Tokens reported by the most recent assistant usage block.
  final int usageTokens;

  /// Estimated tokens after the most recent assistant usage block.
  final int trailingTokens;

  /// Index of the message that provided usage, or `null` when none exists.
  final int? lastUsageIndex;
}

Usage? _assistantUsage(Message message) {
  if (message case AssistantMessage(:final stopReason, :final usage)) {
    if (stopReason != StopReason.aborted &&
        stopReason != StopReason.error &&
        calculateContextTokens(usage) > 0) {
      return usage;
    }
  }
  return null;
}

/// Estimate context tokens for [messages] using provider usage when
/// available.
///
/// Ported from pi's `estimateContextTokens`: the last assistant message with
/// valid usage (not errored/aborted, non-zero tokens) anchors the estimate;
/// everything after it is estimated heuristically. Without any usage, the
/// whole list is estimated.
ContextUsageEstimate estimateContextTokens(List<Message> messages) {
  ({Usage usage, int index})? usageInfo;
  for (var i = messages.length - 1; i >= 0; i--) {
    final usage = _assistantUsage(messages[i]);
    if (usage != null) {
      usageInfo = (usage: usage, index: i);
      break;
    }
  }

  // F5: the registry dedups repeated images on the wire to short
  // `[Image N]` labels — mirror that here, or the transcript-side
  // estimate diverges from the request the provider actually prices.
  final seenImages = <String>{};
  int charged(Message message) => _estimateTokensDedup(message, seenImages);
  if (usageInfo == null) {
    var estimated = 0;
    for (final message in messages) {
      estimated += charged(message);
    }
    return ContextUsageEstimate(
      tokens: estimated,
      usageTokens: 0,
      trailingTokens: estimated,
      lastUsageIndex: null,
    );
  }

  // The anchor era still seeds the seen-set so trailing repeats stay
  // cheap even when their first occurrence predates the anchor.
  for (var i = 0; i <= usageInfo.index; i++) {
    charged(messages[i]);
  }
  var trailingTokens = 0;
  for (var i = usageInfo.index + 1; i < messages.length; i++) {
    trailingTokens += charged(messages[i]);
  }

  final usageTokens = calculateContextTokens(usageInfo.usage);
  return ContextUsageEstimate(
    tokens: usageTokens + trailingTokens,
    usageTokens: usageTokens,
    trailingTokens: trailingTokens,
    lastUsageIndex: usageInfo.index,
  );
}

/// Estimated token cost of the request parts that are NOT transcript
/// messages: the system prompt and the tool schemas (name + description +
/// JSON-encoded parameters), at the overhead density
/// ([overheadCharsPerToken], gh-2411 — NOT the transcript's chars/4: a
/// schema-dense overhead under-counted by a third on the incident
/// session).
///
/// Every wire request carries these, but [estimateContextTokens] never
/// counts them — they only enter an ANCHORED estimate implicitly, through
/// the provider-reported usage. An unanchored estimate (fresh or resumed
/// session, provider without usage reporting) silently drops them: a
/// 30 KB system prompt plus ~30 tool schemas is tens of thousands of
/// tokens the ctx meter and the over-window guard then ignore.
int estimateRequestOverheadTokens(String? systemPrompt, List<Tool> tools) {
  var chars = systemPrompt?.length ?? 0;
  for (final tool in tools) {
    chars +=
        tool.name.length +
        tool.description.length +
        _safeJsonEncode(tool.parameters).length;
  }
  return (chars / _overheadCharsPerToken).ceil();
}

/// Full next-request estimate — the ONE basis the ctx meter, the loop's
/// over-window guard, and the compaction threshold all enforce.
///
/// [estimateContextTokens] over [messages], plus
/// [estimateRequestOverheadTokens] when no provider-usage anchor prices
/// the system prompt and tool schemas in. An anchored estimate already
/// includes them (the reported usage is the whole previous request), so
/// adding the overhead there would double-count.
///
/// [calibration] (gh-2411) scales the UNANCHORED estimate — transcript
/// plus overhead — by the multiplier the provider's first valid usage
/// earned for it (see [deriveOverheadCalibration]); an anchored estimate
/// is the provider's own number and is never scaled.
int estimateRequestTokens(
  List<Message> messages, {
  String? systemPrompt,
  List<Tool> tools = const [],
  List<int?>? recordSeqs,
  OverheadCalibration calibration = OverheadCalibration.uncalibrated,
}) {
  final estimate = estimateContextTokens(messages);
  // GOAL #2394 (E23): the wire copy carries an `m<seq> ` tag on every
  // record the transcript does not — the estimate must price what the
  // request really carries, or the trigger fires late by the tag
  // overhead. A usage anchor already priced the tags up to it; only the
  // records after the anchor add their share.
  final overhead = recordSeqs == null
      ? 0
      : tagOverheadTokens(
          taggedRecordCount(recordSeqs, after: estimate.lastUsageIndex),
        );
  if (estimate.lastUsageIndex != null) return estimate.tokens + overhead;
  return calibration.apply(
        estimate.tokens + estimateRequestOverheadTokens(systemPrompt, tools),
      ) +
      overhead;
}

/// The session's [OverheadCalibration]: the ratio the FIRST valid
/// provider usage anchor in [messages] earned for the unanchored estimate
/// of the request that produced it (`prompt tokens / (transcript prefix
/// + overhead)`), or `null` when no message carries a valid anchor.
///
/// The first anchor on purpose (gh-2411): its request is the smallest,
/// so the overhead dominates both sides of the ratio. A late anchor —
/// the transcript a hundred times the overhead — would dilute the
/// measured overhead error toward 1.0 and hand the next unanchored
/// estimate (the turn after a compaction zeroed the anchors) the same
/// under-count the calibration exists to fix.
/// The provider usage [estimateContextTokens] would anchor on for
/// [message] — a finished (not aborted/errored) assistant reply with a
/// non-zero report; `null` otherwise. The public seam of the estimator's
/// own validity rule (gh-2411 follow-up #5c: the resume calibration
/// scan looks for the very report the anchor is).
Usage? assistantUsageOf(Message message) => _assistantUsage(message);

OverheadCalibration? deriveOverheadCalibration(
  List<Message> messages, {
  String? systemPrompt,
  List<Tool> tools = const [],
}) {
  for (var i = 0; i < messages.length; i++) {
    final usage = _assistantUsage(messages[i]);
    if (usage == null) continue;
    // The provider's price for the REQUEST: its total minus the reply.
    // Copilot splits a cache hit into `input` (uncached) + `cacheRead`,
    // so the raw `input` field under-counts; the total carries both.
    final promptTokens = calculateContextTokens(usage) - usage.output;
    return OverheadCalibration.fromUsage(
      promptTokens: promptTokens,
      unanchoredRequestTokens:
          estimateContextTokens(messages.sublist(0, i)).tokens +
          estimateRequestOverheadTokens(systemPrompt, tools),
    );
  }
  return null;
}

/// [estimateTokens] against a first-seen set: repeated images charge the
/// wire replacement, not a second payload. Per-message [estimateTokens]
/// keeps charging every occurrence (no cross-message context there).
int _estimateTokensDedup(Message message, Set<String> seenImages) {
  List<ContentBlock>? blocks;
  if (message is UserMessage && message.content is List<ContentBlock>) {
    blocks = message.content as List<ContentBlock>;
  } else if (message is ToolResultMessage) {
    blocks = message.content;
  }
  if (blocks == null) return estimateTokens(message);
  var chars = 0;
  for (final block in blocks) {
    switch (block) {
      case TextContent(:final text):
        chars += text.length;
      case ImageContent():
        chars += seenImages.add(estimationImageKey(block))
            ? estimatedImageChars
            : estimatedRepeatImageChars;
      case VideoContent(:final data):
        // gh-2007 thread 3: videos replay their bytes every request (no
        // registry placeholder rewrite) — every occurrence charges full
        // payload, no dedup discount.
        chars += data.length;
      default:
    }
  }
  return (chars / _charsPerToken).ceil();
}

/// Memoized context estimate for the SETTLED part of a transcript.
///
/// The status line renders on every frame — including every keystroke while
/// the user types over a run. Keying the memo on the message list LENGTH
/// and the LAST message's identity (never on in-flight stream content)
/// makes each streamed delta cost one O(stream) `estimateTokens` instead
/// of a full O(context) re-scan: on a 200k-token transcript that is the
/// difference between ~50 whole-transcript scans per second and none.
///
/// The key deliberately survives list COPIES: `AgentState.messages`
/// hands out a fresh `List.unmodifiable` wrapper on every read, so a
/// whole-list identity key would miss on every single frame. Settled
/// messages are immutable once appended, so (length, last-instance)
/// changes exactly when the settled estimate can change: appends grow
/// the length, compaction/session switches replace the last instance.
final class SettledContextEstimate {
  /// Creates a memo; [estimator] is injectable for tests.
  SettledContextEstimate({
    ContextUsageEstimate Function(List<Message>)? estimator,
  }) : _estimator = estimator ?? estimateContextTokens;

  final ContextUsageEstimate Function(List<Message>) _estimator;
  Object? _cachedKey;
  ContextUsageEstimate _cachedValue = ContextUsageEstimate.empty;

  /// How many times the underlying estimator actually ran (test seam).
  int get estimatorCalls => _estimatorCalls;
  int _estimatorCalls = 0;

  /// Estimate for the settled [messages], recomputed only when the list
  /// length or the last message instance changed (appends, compaction,
  /// session switches). An in-place mutation that keeps both is
  /// deliberately NOT tracked — settled messages are immutable once
  /// appended.
  ContextUsageEstimate settledEstimate(List<Message> messages) {
    final key = (
      messages.length,
      messages.isEmpty ? null : identityHashCode(messages.last),
    );
    if (key != _cachedKey) {
      _estimatorCalls++;
      _cachedValue = _estimator(messages);
      _cachedKey = key;
    }
    return _cachedValue;
  }

  /// The token total of [settledEstimate].
  int settled(List<Message> messages) => settledEstimate(messages).tokens;
}

/// Drops generation-time [AssistantMessage.usage] anchors from messages
/// loaded off disk.
///
/// A usage anchor reflects the context the message was GENERATED in — after
/// a compaction, the projected branch is far smaller than those anchors
/// (a 27k projection whose last assistant message still reports 183k). Left
/// in place, the estimate anchors at the phantom size: every resume fired a
/// no-op compaction pass and the context gauge lied. Zeroing re-anchors the
/// estimate at the chars/4 heuristic over the REAL projected context; the
/// first live turn stamps fresh usage again.
///
/// Non-assistant messages and zero-anchored assistants pass through as the
/// same instances (no copy churn on the hot load path).
List<Message> resetLoadedUsageAnchors(List<Message> messages) => [
  for (final message in messages)
    if (message is AssistantMessage && message.usage.totalTokens != 0)
      message.copyWith(usage: Usage.zero)
    else
      message,
];
