// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Unanswered inbound inter-agent mail — the records every
/// context-bounding tier must keep until a reply exists (PR #2435
/// addendum).
///
/// Delivered mail is user-ROLE data: the DM shape (`from <id>: …`), the
/// channel shape (`from <id> in #<channel>: …`) or any text carrying the
/// channel reply anchor ([isAgentMailText] is the ONE text predicate).
/// Two belts existed before this module, and neither was mechanical:
///
/// - the prompt-level `## Open User Requests` section (issue #81 v2)
///   instructs the judge to carry open asks into the summary — but the
///   judge decides openness ("the summarizer LLM judges openness",
///   issue #81 AC9), and a judge that under-summarizes loses the ask;
/// - the ledger's exempt tag folds DM-shaped mail out of hide picks via
///   [isSyntheticUserText] — but channel-delivered mail (the DAP shape
///   every multi-agent session carries) matches neither the exempt tag
///   nor any other protection, so the relief's keep-N hide, the judge's
///   picks and the local trim valve all folded it like noise.
///
/// The live clip that pinned the invariant: a peer's mail delivered
/// into a busy agent's session, the autonomous chain paused on its
/// budget with one message queued — while any of those tiers could have
/// folded earlier delivered-but-unanswered mail away.
///
/// The invariant here: an inbound mail record with NO later assistant
/// record is an OPEN request — never a judge hide pick, never a relief
/// hide candidate, never dropped by the local trim valve. Once a later
/// assistant record exists the mail folds like any other data.
///
/// Mirrors [newestUserTurnRecordIds] consumers: the structured engine's
/// foldable filter and `validateHidePicks` pins, the emergency relief's
/// keep-N veto, and `localTrimValve`'s carried region. Pure functions
/// over records and messages; no policy lives here. The reply test is
/// deliberately conservative — ANY later assistant record counts as a
/// reply (a precise per-channel match would parse delivery envelopes;
/// the conservative view only over-protects by a turn, never loses).
library;

import '../context.dart' show UserMessage;
import '../session/session_record.dart';
import '../types.dart' show AssistantMessage, Message, ToolCall;
import '../user_text.dart' show isAgentMailText, userMessageText;

/// Whether a session [record] is delivered inbound inter-agent mail: a
/// user-role message whose text carries a mail delivery shape.
bool isInboundAgentMailRecord(SessionRecord record) {
  if (record is! MessageRecord) return false;
  final message = record.message;
  return message is UserMessage &&
      isAgentMailText(userMessageText(message.content));
}

/// Conservative reply evidence: a later assistant record that speaks
/// BACK — carries an `agent_message` tool call (how inter-agent replies
/// travel) or is pure prose with no tool calls at all. An assistant
/// carrier with ordinary tool calls (`read`, `bash`, …) is the agent
/// WORKING after the mail, not answering it — in an agentic session
/// such records follow every delivery, and counting them as replies
/// would make the invariant dead code (the exact first draft's bug: a
/// read carrier closed every mail, so the relief folded it anyway).
bool _isReplyRecord(SessionRecord record) {
  if (record is! MessageRecord) return false;
  final message = record.message;
  if (message is! AssistantMessage) return false;
  final calls = message.content.whereType<ToolCall>().toList();
  return calls.isEmpty || calls.any((call) => call.name == 'agent_message');
}

/// The record ids of unanswered inbound inter-agent mail on a session
/// [path]: every mail record with NO later assistant record. Callers
/// treat the ids like pins — the records never fold into a checkpoint,
/// never enter a judge hide pick and never join a relief hide
/// candidate; the trim valve carries them across its cut.
Set<String> unansweredInboundMailRecordIds(List<SessionRecord> path) {
  final open = <String>{};
  var seenReply = false;
  for (var i = path.length - 1; i >= 0; i--) {
    final record = path[i];
    if (seenReply) continue;
    if (_isReplyRecord(record)) {
      seenReply = true;
    } else if (isInboundAgentMailRecord(record)) {
      open.add(record.id);
    }
  }
  return open;
}

bool _hasReplyCall(AssistantMessage message) => message.content
    .whereType<ToolCall>()
    .any((call) => call.name == 'agent_message');

/// The message-level view of the same invariant for `localTrimValve`
/// (which sees live [Message]s, not records): the indices of unanswered
/// inbound mail, ascending.
List<int> unansweredAgentMailMessageIndices(List<Message> messages) {
  final indices = <int>[];
  var seenReply = false;
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (seenReply) continue;
    if (message is AssistantMessage &&
        (_hasReplyCall(message) ||
            message.content.whereType<ToolCall>().isEmpty)) {
      seenReply = true;
    } else if (message is UserMessage &&
        isAgentMailText(userMessageText(message.content))) {
      indices.add(i);
    }
  }
  return indices.reversed.toList();
}
