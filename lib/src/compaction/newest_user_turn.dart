/// The newest REAL user turn — the one record every context-bounding
/// tier must keep (gh-2411).
///
/// The fixed request overhead (system prompt + tool schemas) plus one
/// large tool result can push a transcript over a small window while the
/// user's question is still the newest turn. Every tier that bounds the
/// live context used to protect only the protected tail and
/// `messages.last`: the emergency trim valve kept the tool RESULT and
/// dropped the question two records back, the quality checkpoint folded
/// the range including it, and the record tag (`m19`) was the only trace
/// the model saw of what the user asked.
///
/// This module is the ONE definition of "the newest real user turn"
/// shared by those tiers: a user-role message whose text is NOT
/// synthetic harness content ([isSyntheticUserText] — the same predicate
/// the context ledger's `·exempt` tag and `validateHidePicks` use), so a
/// system notice, a steering injection or an agent-mail line is never
/// mistaken for the user's own words. Pure functions over messages and
/// session records; no policy lives here.
library;

import '../context.dart';
import '../session/session_record.dart';
import '../types.dart';
import '../user_text.dart'
    show
        isCheckpointSummaryText,
        isSyntheticUserText,
        opensWithProjectionMarker,
        userMessageText;

/// Whether [message] is the user's own turn: a user-role message whose
/// flattened text is not synthetic harness content.
bool isRealUserTurn(Message message) =>
    message is UserMessage &&
    !isSyntheticUserText(userMessageText(message.content));

/// The index of the newest real user turn in [messages], or `-1` when
/// the list carries none (a tool-result-only tail, a transcript of
/// notices).
int newestRealUserTurnIndex(List<Message> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    if (isRealUserTurn(messages[i])) return i;
  }
  return -1;
}

/// The record ids the invariant protects on a session [path]: the newest
/// real user turn's record (its ledger pair group is the record itself —
/// only an assistant carrier and its results group). Empty when the path
/// carries no real user turn. Callers treat the ids like pins: the
/// record never folds into a checkpoint, never hides and bounds the trim
/// valve's kept region from below.
int newestRealUserTurnRecordIndex(List<SessionRecord> path) {
  for (var i = path.length - 1; i >= 0; i--) {
    final record = path[i];
    if (record is MessageRecord && isRealUserTurn(record.message)) return i;
  }
  return -1;
}

Set<String> newestUserTurnRecordIds(List<SessionRecord> path) {
  final index = newestRealUserTurnRecordIndex(path);
  return index < 0 ? const {} : {path[index].id};
}

/// gh-241 follow-up #5e (E4/E6): whether [message] is a rendered
/// boundary summary — the user-ROLE text a checkpoint projects as.
bool isBoundarySummary(Message message) =>
    message is UserMessage &&
    isCheckpointSummaryText(userMessageText(message.content));

/// gh-241 follow-up #5e (E1/E6): the leading run of projection markers
/// at the head of [messages] — hidden-range markers, checkpoint
/// summaries and fold pointers, oldest first. A resume walk that stops
/// at the newest durable boundary opens the context with exactly that
/// run (the boundary cluster's rendering); an empty run means the
/// context opens on conversation.
List<Message> leadingBoundaryCluster(List<Message> messages) {
  var end = 0;
  while (end < messages.length) {
    final message = messages[end];
    if (message is! UserMessage) break;
    if (!opensWithProjectionMarker(userMessageText(message.content))) break;
    end++;
  }
  return messages.sublist(0, end);
}

/// The boundary summaries the context-bounding tiers pin like the
/// newest real user turn (gh-241 follow-up #5e, E4): every checkpoint
/// summary of the leading boundary cluster plus the newest checkpoint
/// summary anywhere in [messages] — after a compaction pass the newest
/// summary rides its own tail record. Indices ascend; older summaries
/// beyond these stay droppable.
List<int> pinnedBoundarySummaryIndices(List<Message> messages) {
  final cluster = leadingBoundaryCluster(messages).length;
  var newest = -1;
  for (var i = 0; i < messages.length; i++) {
    if (isBoundarySummary(messages[i])) newest = i;
  }
  return [
    for (var i = 0; i < messages.length; i++)
      if (isBoundarySummary(messages[i]) && (i < cluster || i == newest)) i,
  ];
}

/// gh-241 follow-up #5e (E1/E6): the NEWEST durable boundary's checkpoint
/// summaries — the run of consecutive projection markers that ends at
/// the newest checkpoint summary in [messages], reduced to the summaries
/// themselves, oldest first. A window that opens at its boundary holds
/// the run at the head; a checkpoint appended after the tail it
/// summarizes (tail layout) holds it at the end — the caller decides
/// where the request opens. Empty when the projection carries no
/// checkpoint summary.
List<Message> newestBoundarySummaries(List<Message> messages) {
  var last = -1;
  for (var i = 0; i < messages.length; i++) {
    if (isBoundarySummary(messages[i])) last = i;
  }
  if (last < 0) return const [];
  var first = last;
  while (first > 0 && _isProjectionMarker(messages[first - 1])) {
    first--;
  }
  return [
    for (var i = first; i <= last; i++)
      if (isBoundarySummary(messages[i])) messages[i],
  ];
}

bool _isProjectionMarker(Message message) =>
    message is UserMessage &&
    opensWithProjectionMarker(userMessageText(message.content));
