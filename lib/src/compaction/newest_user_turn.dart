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
import '../user_text.dart' show isSyntheticUserText, userMessageText;

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
