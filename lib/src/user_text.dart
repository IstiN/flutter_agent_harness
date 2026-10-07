/// The ONE synthetic-user-text predicate and the ONE user-content fold,
/// shared by every consumer that must distinguish the user's own words
/// from harness injections (issue #1380 review: three independent copies
/// had already drifted — this module is the single source; the cycle
/// constraint that bred the copies does not apply here, the module is a
/// leaf over `types.dart` only).
///
/// Consumers: the compaction summarizer's request-candidate scan and the
/// structured context ledger (`isSyntheticUserText` — a synthetic user
/// turn is machine content, never a pinned real-user turn), the
/// checkpoint auto-close (`_isRealUserTurn`), and the obligations
/// ledger's classifier (synthetic text never opens obligations).
library;

import 'types.dart';

/// Agent chat delivered as a user message (`from <id>: …`). Mail is data,
/// never a user instruction (the `[from <id>]` attach-view form IS the
/// user's own words and stays real); `\s+` tolerates attribution
/// whitespace variants.
final _agentMailPattern = RegExp(r'^from\s+\S+:\s');

/// Branch summaries projected as user messages (see `branchSummaryPrefix`).
final _branchSummaryPattern = RegExp(
  r'^The following is a summary of a branch',
);

/// Prefix-marked injections: widget interactions (`[widget <title>] …`,
/// the dynamic_message contract), extension follow-ups (`[ext:<name>] …`),
/// and TTSR system-interrupt rule injections.
final _syntheticPrefixPattern = RegExp(r'^\[(widget|ext:)|^<system-interrupt');

/// Harness `<system-notice>` envelopes (background-job completions,
/// steering receipts, inter-agent mail wakes, …) — matched anywhere in
/// the text: a quoted or trailing envelope is still machine content.
final _systemNoticePattern = RegExp('<system-notice>');

/// Whether a user-role text is synthetic harness content (system-notice
/// envelope, widget/extension/TTSR injection, agent mail, or a projected
/// branch summary) rather than the user's own words.
///
/// Canonical semantics (superset of the historical copies): the text is
/// trimmed first, `<system-notice>` matches anywhere, and the
/// widget/extension/system-interrupt prefixes and the whitespace-tolerant
/// agent-mail anchor apply on the trimmed text. Empty text is NOT
/// synthetic (callers skip it separately).
bool isSyntheticUserText(String text) {
  final trimmed = text.trim();
  return _systemNoticePattern.hasMatch(trimmed) ||
      _syntheticPrefixPattern.hasMatch(trimmed) ||
      _agentMailPattern.hasMatch(trimmed) ||
      _branchSummaryPattern.hasMatch(trimmed);
}

/// Flattens a user-message content (plain text or content blocks) to its
/// text — the same fold every projection and preview uses. Non-text
/// blocks collapse away; an empty list folds to the empty string.
String userMessageText(Object content) {
  if (content is String) return content;
  if (content is! List) return '';
  return [
    for (final block in content)
      if (block is TextContent) block.text,
  ].join(' ');
}
