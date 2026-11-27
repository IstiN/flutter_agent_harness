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

/// Channel-delivered inter-agent mail (`from <id> in #<channel>: …`) —
/// the DAP/network delivery shape the multi-agent sessions actually
/// carry.
final _agentChannelMailPattern = RegExp(r'^from\s+\S+\s+in\s+#\S+:\s');

/// The channel-mail reply instruction the delivery envelope appends
/// (matched anywhere: the anchor closes a multi-line body).
final _replyAnchorPattern = RegExp(
  r'\[reply into this channel with agent_message to:',
);

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

/// Projection markers the structured engine writes as user-ROLE
/// messages (gh-241 follow-up #5d, D4): hidden-record and checkpoint
/// markers (`[175:hidden·tool_result·13k·…]`), fold pointers (`[expand
/// 3-140]`, bare or closing a labelled consolidated hide), and the local
/// trim valve's own marker. Each is machine content — a hidden-record
/// marker that followed the owner's prompt was taken for the newest
/// "real" user turn, and the prompt itself was trimmed away.
final _projectionMarkerPattern = RegExp(
  r'^(?:m\d+ )?\[\d+(?:-\d+)?:(?:hidden|ckpt)·'
  r'|^(?:m\d+ )?\[expand \d+(?:-\d+)?\]'
  r'|^\[context trimmed locally:',
);

/// gh-241 follow-up #5e (E4/E6): the checkpoint projection header —
/// `[a-b:ckpt·…]`, optionally behind its record tag.
final _checkpointMarkerPattern = RegExp(r'^(?:m\d+ )?\[\d+(?:-\d+)?:ckpt·');

/// A consolidated hide marker is a label closed by its pointer
/// (`old session list [expand 142-143]`): the pointer ends the text.
final _labeledExpandPointerPattern = RegExp(r'\[expand \d+(?:-\d+)?\]$');

/// Whether a user-role text is synthetic harness content (system-notice
/// envelope, widget/extension/TTSR injection, agent mail, a projected
/// branch summary, or a projection marker) rather than the user's own
/// words.
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
      _branchSummaryPattern.hasMatch(trimmed) ||
      _projectionMarkerPattern.hasMatch(trimmed) ||
      _labeledExpandPointerPattern.hasMatch(trimmed);
}

/// gh-241 follow-up #5e (E4/E6): whether a user-role text is a rendered
/// checkpoint summary — the `[a-b:ckpt·…]` header a checkpoint projects
/// as, followed by the summary text and its hidden index.
bool isCheckpointSummaryText(String text) =>
    _checkpointMarkerPattern.hasMatch(text.trim());

/// Whether a user-role text is inter-agent mail: the DM delivery shape
/// (`from <id>: …` — the [isSyntheticUserText] anchor) or the channel
/// delivery shape (`from <id> in #<channel>: …`, optionally closing with
/// the `[reply into this channel…]` anchor). Mail is data, never the
/// user's own words.
///
/// Deliberately broader than [isSyntheticUserText]: the synthetic
/// classification is pinned by gh-241 semantics (channel mail still
/// counts as a real user turn there — flipping it is a behavior change
/// far beyond the compaction belt), while the unanswered-mail
/// protection needs the wider view of what is mail.
bool isAgentMailText(String text) {
  final trimmed = text.trim();
  return _agentMailPattern.hasMatch(trimmed) ||
      _agentChannelMailPattern.hasMatch(trimmed) ||
      _replyAnchorPattern.hasMatch(trimmed);
}

/// gh-241 follow-up #5e (E1/E6): whether a user-role text opens with a
/// projection marker — a hidden-range or checkpoint marker, a fold
/// pointer or the local trim marker. A resume walk that stops at the
/// newest durable boundary OPENS the context with that boundary's
/// markers.
bool opensWithProjectionMarker(String text) =>
    _projectionMarkerPattern.hasMatch(text.trim());

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
