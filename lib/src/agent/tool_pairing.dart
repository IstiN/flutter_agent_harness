/// Tool-call pairing integrity for outbound model requests (issue #85).
///
/// Invariant: no outbound request ever contains a `tool_result` without its
/// `tool_use` (or vice versa), so a single corrupted context can never wedge
/// a session into permanent provider 400s.
///
/// Validation runs on the WIRE-equivalent message sequence — after
/// tool-result grouping (a run of consecutive `ToolResultMessage`s becomes
/// one user message of `tool_result` blocks) and same-role merging — because
/// that is what strict providers actually validate: each `tool_result` must
/// pair with a `tool_use` in the immediately preceding assistant message.
/// A user message interleaved between a call and its result (steering) or an
/// orphan result at any position (a non-leading one survived the old
/// leading-only trim guard) is a hard 400 on such endpoints.
///
/// [repairToolPairing] is the symmetric repairer applied at the request
/// boundary (request payload only — the transcript is never rewritten):
///
/// - a result without its call (at ANY position) → dropped, replaced by a
///   one-line user-role note appended to the context so the model is not
///   gaslit about missing work;
/// - a call without its result → synthetic interrupted result (the behavior
///   of the former `repairOrphanedToolCalls`, mirror direction);
/// - a result displaced from its call (steering interleave) → hoisted back
///   next to it;
/// - duplicate tool-call ids within the context → suffix-uniquified
///   consistently on BOTH sides (call and its result), preserving pairing.
///
/// Every non-empty repair is surfaced by the agent loop as a
/// `ToolPairingRepairEvent` — silent context surgery is how the wedge
/// happened in the first place.
library;

import '../compaction/structured/markers.dart'
    show isCompactionMarkerText, localTrimMarkerPrefix;
import '../context.dart';
import '../session/session_record.dart' show CustomRecord;
import '../session/session_tree.dart'
    show branchSummaryPrefix, compactionSummaryPrefix;
import '../types.dart';

/// What a [validateToolPairing] violation is, in provider terms.
enum ToolPairingViolationKind {
  /// A `tool_result` whose call is not in the immediately preceding
  /// assistant message (orphan at any position, leading included).
  orphanedResult,

  /// A `tool_use` with no `tool_result` in the following message.
  unansweredCall,

  /// The same tool-call id on two `tool_use` blocks.
  duplicateCallId,

  /// Two `tool_result` blocks answering the same id.
  duplicateResult,

  /// A `tool_result` after non-result content in its wire message
  /// (strict endpoints require results first).
  interleavedResult,
}

/// One wire-level pairing violation found by [validateToolPairing].
final class ToolPairingViolation {
  const ToolPairingViolation(this.kind, this.toolCallId, this.detail);

  final ToolPairingViolationKind kind;

  /// The affected tool-call id.
  final String toolCallId;

  /// Human-readable context for logs and test failures.
  final String detail;

  @override
  String toString() => '$kind($toolCallId): $detail';
}

/// What a [repairToolPairing] pass changed. Empty means nothing was touched.
final class ToolPairingRepairReport {
  const ToolPairingRepairReport({
    this.droppedResultIds = const [],
    this.synthesizedResultIds = const [],
    this.renamedIds = const [],
    this.notedOrphanKeys = const [],
  });

  /// Ids of orphaned results dropped from the payload (newly noted AND
  /// silently re-dropped already-reported ones).
  final List<String> droppedResultIds;

  /// Ids of calls that got a synthetic interrupted result.
  final List<String> synthesizedResultIds;

  /// Duplicate-id renames applied to a call AND its result.
  final List<({String from, String to})> renamedIds;

  /// gh-1449: stable keys of the orphans THIS pass reported for the first
  /// time (a subset of [droppedResultIds]). Callers merge them into the
  /// session's reported-orphan latch — [orphanReportRecordData] is the
  /// persisted shape — so the next request drops the same orphans
  /// silently instead of re-emitting the note.
  final List<String> notedOrphanKeys;

  bool get isNotEmpty =>
      droppedResultIds.isNotEmpty ||
      synthesizedResultIds.isNotEmpty ||
      renamedIds.isNotEmpty;

  @override
  String toString() =>
      'dropped=$droppedResultIds synthesized=$synthesizedResultIds '
      'renamed=$renamedIds noted=$notedOrphanKeys';
}

/// Canonical wire form of a tool-call id: the projection every provider
/// adapter applies before putting an id on the wire — characters outside
/// `[a-zA-Z0-9_-]` become `_` (Anthropic/Google/OpenAI `_normalizeToolCallId`)
/// and the result truncates to 40 chars (the strictest limit, OpenAI).
/// Pairing checks and the uniqueness stamp compare canonical forms, so two
/// raw ids that collapse into one provider-side id count as duplicates even
/// when their raw forms differ.
String canonicalToolCallId(String id) {
  final sanitized = id.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_');
  return sanitized.length <= 40 ? sanitized : sanitized.substring(0, 40);
}

/// Raw provider error substrings (matched case-insensitively) of the
/// tool-pairing error family across known gateways: Anthropic direct,
/// litellm/Bedrock, OpenAI-compatible, and Google Gemini's
/// function-response count mismatch. Detection is keyed on the error
/// SIGNATURE family, never on one provider's exact string (E5).
const _pairingErrorSignatures = [
  'unexpected tool_use_id',
  'corresponding tool_use block',
  'expected toolresult blocks',
  'tool_call_id is not found',
  'tool_call_ids did not have response messages',
  'number of function response parts',
];

/// Whether a provider [errorMessage] belongs to the tool-pairing error
/// family (the loop uses this to trigger the one-shot repair-and-retry).
bool isToolPairingProviderError(String? errorMessage) {
  if (errorMessage == null || errorMessage.isEmpty) return false;
  final normalized = errorMessage.toLowerCase();
  for (final signature in _pairingErrorSignatures) {
    if (normalized.contains(signature)) return true;
  }
  return false;
}

/// Validates the pairing invariant on the wire-equivalent sequence of
/// [messages]. An empty result means the context is safe to send.
List<ToolPairingViolation> validateToolPairing(List<Message> messages) {
  final violations = <ToolPairingViolation>[];
  final seenCalls = <String>{};
  final answered = <String>{};
  var pending = const <String>[];
  for (final item in _wireView(messages)) {
    switch (item) {
      case _WireAssistant(:final callIds):
        _flagUnanswered(pending, answered, violations);
        pending = callIds;
        for (final id in callIds) {
          if (!seenCalls.add(id)) {
            violations.add(
              ToolPairingViolation(
                ToolPairingViolationKind.duplicateCallId,
                id,
                'tool_use id appears in more than one assistant message',
              ),
            );
          }
        }
      case _WireUser(:final blocks):
        var sawText = false;
        for (final (:resultId) in blocks) {
          if (resultId == null) {
            sawText = true;
            continue;
          }
          if (answered.contains(resultId)) {
            violations.add(
              ToolPairingViolation(
                ToolPairingViolationKind.duplicateResult,
                resultId,
                'a second tool_result answers the same id',
              ),
            );
          } else if (pending.contains(resultId)) {
            answered.add(resultId);
            if (sawText) {
              violations.add(
                ToolPairingViolation(
                  ToolPairingViolationKind.interleavedResult,
                  resultId,
                  'tool_result appears after other content in its message',
                ),
              );
            }
          } else {
            violations.add(
              ToolPairingViolation(
                ToolPairingViolationKind.orphanedResult,
                resultId,
                'its tool_use is not in the immediately preceding assistant '
                'message',
              ),
            );
          }
        }
        _flagUnanswered(pending, answered, violations);
        pending = const [];
    }
  }
  _flagUnanswered(pending, answered, violations);
  return violations;
}

void _flagUnanswered(
  List<String> pending,
  Set<String> answered,
  List<ToolPairingViolation> violations,
) {
  for (final id in pending) {
    if (!answered.contains(id)) {
      violations.add(
        ToolPairingViolation(
          ToolPairingViolationKind.unansweredCall,
          id,
          'no tool_result follows this tool_use before the next message',
        ),
      );
    }
  }
}

/// The stable latch key of an orphaned result (gh-1449 E1): canonical call
/// id + tool name + the result's timestamp in epoch milliseconds. Ids reset
/// per run, so the timestamp is the position discriminator — a reused id is
/// a DIFFERENT orphan and is reported again; the same result rebuilds to
/// the same key across requests, compactions and session resumes (the
/// timestamp round-trips the session record).
String orphanReportKey(ToolResultMessage orphan) =>
    '${canonicalToolCallId(orphan.toolCallId)}|'
    '${canonicalToolCallId(orphan.toolName)}|'
    '${orphan.timestamp.millisecondsSinceEpoch}';

/// The persisted shape of a reported-orphan batch: the `data` payload of
/// the hidden `orphan_report` custom record (see
/// [orphanReportRecordType]). A plain key list — every write carries only
/// ITS batch, reads union all records.
Map<String, Object?> orphanReportRecordData(Set<String> keys) => {
  'keys': keys.toList()..sort(),
};

/// Unions the reported-orphan keys out of a scanned record list (records of
/// any other type are skipped). Tolerant of corrupt payloads — a broken
/// record must never fail a session boot.
Set<String> orphanReportKeysFromRecords(Iterable<CustomRecord> records) => {
  for (final record in records)
    if (record.customType == orphanReportRecordType)
      ...switch (record.data) {
        {'keys': final List<Object?> keys} => [
          for (final key in keys)
            if (key is String && key.isNotEmpty) key,
        ],
        _ => const <String>[],
      },
};

/// The hidden custom-record type hosts persist reported orphan batches
/// under (gh-1449 AC6: a resumed session must not re-report).
const String orphanReportRecordType = 'orphan_report';

/// Symmetric pairing repair at the request boundary. Returns [messages]
/// untouched (same instance, empty report) when the context already
/// satisfies [validateToolPairing]; otherwise returns a rebuilt payload
/// whose wire view is valid — the transcript itself is never modified.
///
/// gh-1449: dropped orphan results are reported ONCE — [reportedOrphanKeys]
/// is the session's latch of already-reported [orphanReportKey]s; latched
/// orphans are dropped silently. The note is never a stand-alone user-role
/// message (it would cost the model a turn): it rides the payload's last
/// existing user message as an extra text block. Only when the payload has
/// NO user message at all does the repair degrade to the legacy standalone
/// note (the carrier cannot be honored; the emitted
/// `ToolPairingRepairEvent` reports the batch).
({List<Message> messages, ToolPairingRepairReport report}) repairToolPairing(
  List<Message> messages, {
  Set<String> reportedOrphanKeys = const {},
}) {
  if (validateToolPairing(messages).isEmpty) {
    return (messages: messages, report: const ToolPairingRepairReport());
  }

  final index = _indexCalls(messages);
  final renames = _renameDuplicates(index, messages);
  final attached = _attachResults(index, messages, renames.slotNewIds);
  return _rebuild(messages, index, renames, attached, reportedOrphanKeys);
}

final class _CallIndex {
  /// Call slots in encounter order: (message index, ToolCall).
  final slots = <({int messageIndex, ToolCall call, int blockIndex})>[];

  /// Tool-call id → slot indexes (ascending).
  final byId = <String, List<int>>{};

  /// Message index → slot indexes (in content-block order).
  final byMessage = <int, List<int>>{};

  void add(int messageIndex, int blockIndex, ToolCall call) {
    byId.putIfAbsent(call.id, () => <int>[]).add(slots.length);
    byMessage.putIfAbsent(messageIndex, () => <int>[]).add(slots.length);
    slots.add((messageIndex: messageIndex, call: call, blockIndex: blockIndex));
  }
}

_CallIndex _indexCalls(List<Message> messages) {
  final index = _CallIndex();
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message is! AssistantMessage) continue;
    for (var b = 0; b < message.content.length; b++) {
      final block = message.content[b];
      if (block is ToolCall) index.add(i, b, block);
    }
  }
  return index;
}

final class _Renames {
  /// Slot index → new id for duplicate occurrences.
  final slotNewIds = <int, String>{};

  /// Report entries (original id → new id), in order.
  final entries = <({String from, String to})>[];
}

/// Uniquifies later occurrences of duplicate tool-call ids, keyed on
/// canonical wire form: raw ids that collapse into one provider-side id are
/// wire duplicates even when their raw forms differ. Fresh ids are generated
/// from the canonical base so the rename cannot re-collide after the
/// adapter's own sanitize/truncate pass.
_Renames _renameDuplicates(_CallIndex index, List<Message> messages) {
  final used = <String>{
    for (final slot in index.slots) canonicalToolCallId(slot.call.id),
    for (final message in messages)
      if (message is ToolResultMessage) canonicalToolCallId(message.toolCallId),
  };
  final renames = _Renames();
  final byCanonical = <String, List<int>>{};
  for (var slot = 0; slot < index.slots.length; slot++) {
    byCanonical
        .putIfAbsent(canonicalToolCallId(index.slots[slot].call.id), () => [])
        .add(slot);
  }
  for (final group in byCanonical.entries) {
    for (var k = 1; k < group.value.length; k++) {
      final slot = group.value[k];
      final fresh = _freshId(group.key, used);
      used.add(fresh);
      renames.slotNewIds[slot] = fresh;
      renames.entries.add((from: index.slots[slot].call.id, to: fresh));
    }
  }
  return renames;
}

/// A fresh canonical wire-form id derived from canonical [base] that is not
/// in [used] (`base_2`, `base_3`, …). Ids are opaque to tools and providers
/// echo them back verbatim. The stem stays inside the 40-char wire cap so
/// the suffix survives the adapters' own cap and the candidate sequence
/// strictly grows — renaming terminates even when many long ids truncate to
/// one form.
String _freshId(String base, Set<String> used) {
  final stem = base.length > 36 ? base.substring(0, 36) : base;
  var k = 2;
  var candidate = '${stem}_$k';
  while (used.contains(candidate)) {
    k++;
    candidate = '${stem}_$k';
  }
  return candidate;
}

final class _Attachment {
  /// Slot index → original message index of its result.
  final resultForSlot = <int, int>{};

  /// Orphaned results (no call occurrence left to answer them), in
  /// encounter order with their original message index (the cut-boundary
  /// probe anchors on the position).
  final orphans = <({int messageIndex, ToolResultMessage message})>[];
}

/// Pairs each result with its call occurrence (k-th result of an id answers
/// the k-th call of that id); anything left over is an orphan.
_Attachment _attachResults(
  _CallIndex index,
  List<Message> messages,
  Map<int, String> slotNewIds,
) {
  final attachment = _Attachment();
  final occurrence = <String, int>{};
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message is! ToolResultMessage) continue;
    final slots = index.byId[message.toolCallId];
    if (slots == null) {
      attachment.orphans.add((messageIndex: i, message: message));
      continue;
    }
    final n = occurrence.putIfAbsent(message.toolCallId, () => 0);
    occurrence[message.toolCallId] = n + 1;
    if (n < slots.length) {
      attachment.resultForSlot[slots[n]] = i;
    } else {
      attachment.orphans.add((messageIndex: i, message: message));
    }
  }
  return attachment;
}

({List<Message> messages, ToolPairingRepairReport report}) _rebuild(
  List<Message> messages,
  _CallIndex index,
  _Renames renames,
  _Attachment attachment,
  Set<String> reportedOrphanKeys,
) {
  final rebuilt = <Message>[];
  final emittedResults = <int>{};
  final synthesized = <String>[];

  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    final slots = index.byMessage[i];
    if (slots == null) {
      // User message, tool result (emitted with its call below or dropped as
      // an orphan), or assistant message without tool calls.
      if (message is ToolResultMessage) continue;
      rebuilt.add(message);
      continue;
    }
    rebuilt.add(
      _rewriteAssistantCallIds(messages, i, slots, index, renames),
    );
    _emitSlotResults(
      messages,
      slots,
      index,
      renames,
      attachment,
      rebuilt,
      emittedResults,
      synthesized,
    );
  }

  // gh-1449: dropped orphans are reported ONCE per session, as a note that
  // never costs the model a turn. The note rides the payload's last
  // existing user message as an appended text block (in the rebuilt payload
  // every user message sits outside or AFTER its wire group's results, so
  // the annotation can never re-break the strict results-first ordering the
  // repair just fixed); the degenerate no-user-message payload degrades to
  // the legacy standalone note — there is nothing else to carry it.
  final freshOrphans = [
    for (final orphan in attachment.orphans)
      if (!reportedOrphanKeys.contains(orphanReportKey(orphan.message)))
        orphan,
  ];
  if (freshOrphans.isNotEmpty) {
    final note = _dropNote(freshOrphans, messages);
    final carrierIndex = _lastUserMessageIndex(rebuilt);
    if (carrierIndex == null) {
      rebuilt.add(UserMessage.text(note));
    } else {
      rebuilt[carrierIndex] = _withAppendedNote(
        rebuilt[carrierIndex] as UserMessage,
        note,
      );
    }
  }

  return (
    messages: rebuilt,
    report: ToolPairingRepairReport(
      droppedResultIds: [
        for (final orphan in attachment.orphans) orphan.message.toolCallId,
      ],
      synthesizedResultIds: synthesized,
      renamedIds: renames.entries,
      notedOrphanKeys: [
        for (final orphan in freshOrphans) orphanReportKey(orphan.message),
      ],
    ),
  );
}

/// The last user message in [messages], or null when the payload has none.
int? _lastUserMessageIndex(List<Message> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i] is UserMessage) return i;
  }
  return null;
}

/// [message] with the note appended as one more text block (a plain-string
/// content is promoted to blocks). Payload-only — the transcript keeps the
/// original instance.
UserMessage _withAppendedNote(UserMessage message, String note) {
  final content = message.content;
  final blocks = [
    if (content is String)
      TextContent(text: content)
    else if (content is List<ContentBlock>)
      ...content
    else
      ...const <ContentBlock>[],
    TextContent(text: note),
  ];
  return UserMessage(content: blocks, timestamp: message.timestamp);
}

/// The assistant message at [i] with its tool-call ids renamed per
/// [renames] (identity-copied when nothing changed).
AssistantMessage _rewriteAssistantCallIds(
  List<Message> messages,
  int i,
  List<int> slots,
  _CallIndex index,
  _Renames renames,
) {
  var assistant = messages[i] as AssistantMessage;
  var changed = false;
  final content = <ContentBlock>[];
  for (final block in assistant.content) {
    var call = switch (block) {
      ToolCall() => block,
      _ => null,
    };
    if (call == null) {
      content.add(block);
      continue;
    }
    // Find this block's slot (byMessage order matches content order).
    final slot = slots.firstWhere(
      (s) => identical(index.slots[s].call, call),
    );
    final newId = renames.slotNewIds[slot];
    if (newId != null) {
      call = call.copyWith(id: newId);
      changed = true;
    }
    content.add(call);
  }
  if (changed) assistant = assistant.copyWith(content: content);
  return assistant;
}

/// Emits each slot's tool result DIRECTLY after its assistant message —
/// results first, before any interleaved user text. A slot with no result
/// gets ONE synthetic interrupted note; its index lands in [emitted] /
/// [synthesized] for the report.
void _emitSlotResults(
  List<Message> messages,
  List<int> slots,
  _CallIndex index,
  _Renames renames,
  _Attachment attachment,
  List<Message> rebuilt,
  Set<int> emitted,
  List<String> synthesized,
) {
  for (final slot in slots) {
    final call = index.slots[slot].call;
    final id = renames.slotNewIds[slot] ?? call.id;
    final resultIndex = attachment.resultForSlot[slot];
    if (resultIndex != null) {
      final result = messages[resultIndex] as ToolResultMessage;
      rebuilt.add(
        id == result.toolCallId
            ? result
            : ToolResultMessage(
                toolCallId: id,
                toolName: result.toolName,
                content: result.content,
                isError: result.isError,
                timestamp: result.timestamp,
              ),
      );
      emitted.add(resultIndex);
    } else {
      rebuilt.add(
        ToolResultMessage(
          toolCallId: id,
          toolName: call.name,
          content: [
            TextContent(
              text:
                  'Tool call "${call.name}" did not produce a result: '
                  'the run was interrupted before the tool finished. '
                  'Re-issue the tool call if it is still needed.',
            ),
          ],
          isError: true,
          timestamp: DateTime.now(),
        ),
      );
      synthesized.add(id);
    }
  }
}

/// The one-shot drop note (gh-1449 invariant 3): names each orphan's tool
/// and call id, the cut that removed its call, and whether the call's trace
/// survives the summary — and says no reply is needed, so the annotation
/// never costs a turn even when it rides the pending user message.
///
/// [messages] is the ORIGINAL payload: the cut reference is the nearest
/// renumbering boundary (compaction summary / branch summary / local trim /
/// structured marker) BEFORE the orphan's position. The kept-in-summary
/// probe is a substring scan of that boundary's text for the canonical call
/// id — the one stable trace a summarizer plausibly carries.
String _dropNote(
  List<({int messageIndex, ToolResultMessage message})> orphans,
  List<Message> messages,
) {
  final lines = [
    for (final orphan in orphans)
      '"${orphan.message.toolName}" (id: ${orphan.message.toolCallId}): '
          '${_orphanNoteClause(orphan.message, orphan.messageIndex, messages)}',
  ];
  if (orphans.length == 1) {
    return '[context note: a tool result for "${orphans.first.message
        .toolName}" (id: ${orphans.first.message.toolCallId}) was dropped — '
        '${lines.single}. No reply needed.]';
  }
  return [
    '[context note: ${orphans.length} tool results were dropped — their '
    'originating tool calls are no longer in context. No reply needed.',
    ...lines.map((line) => '- $line'),
    'end context note]',
  ].join('\n');
}

/// One orphan's named clause: `removed by the [cut] cut; kept in summary:
/// yes|no`.
String _orphanNoteClause(
  ToolResultMessage orphan,
  int messageIndex,
  List<Message> messages,
) {
  final boundary = _nearestCutBoundary(messages, messageIndex);
  final id = canonicalToolCallId(orphan.toolCallId);
  final kept = boundary != null && _boundaryText(messages[boundary.index])
      .contains(id);
  return 'removed by the ${boundary?.label ?? 'context'} cut; '
      'kept in summary: ${kept ? 'yes' : 'no'}';
}

final class _CutBoundary {
  const _CutBoundary(this.index, this.label);

  final int index;
  final String label;
}

/// The nearest cut boundary (gh-1449 invariant 3's "compaction/cut that
/// removed the call") at or before [fromIndex] in the payload, or null.
_CutBoundary? _nearestCutBoundary(List<Message> messages, int fromIndex) {
  for (var i = fromIndex; i >= 0; i--) {
    final message = messages[i];
    if (message is! UserMessage) continue;
    final content = message.content;
    if (content is! String) continue;
    if (content.startsWith(compactionSummaryPrefix)) {
      return _CutBoundary(i, 'compaction summary');
    }
    if (content.startsWith(branchSummaryPrefix)) {
      return _CutBoundary(i, 'branch summary');
    }
    if (content.startsWith(localTrimMarkerPrefix)) {
      return _CutBoundary(i, 'local trim');
    }
    if (isCompactionMarkerText(content)) {
      return _CutBoundary(i, 'context marker');
    }
  }
  return null;
}

/// The plain text of a boundary message (summary bodies are plain strings;
/// marker projections can ride other roles).
String _boundaryText(Message message) {
  switch (message) {
    case UserMessage(:final content):
      if (content is String) return content;
      if (content is! List) return '';
      return [
        for (final block in content)
          if (block is TextContent) block.text,
      ].join();
    case ToolResultMessage(:final content):
      return [
        for (final block in content)
          if (block is TextContent) block.text,
      ].join();
    case AssistantMessage(:final content):
      return [
        for (final block in content)
          if (block is TextContent) block.text,
      ].join();
  }
  // `Message` is an interface: unknown implementations have no text.
  return '';
}

/// The wire-equivalent projection of harness messages: a run of consecutive
/// tool results merges into one user message of result blocks, adjacent
/// user-role items (text and result groups) merge into one wire message,
/// messages the provider adapters would skip (whitespace user text,
/// assistant messages with no visible blocks) are dropped, and every
/// tool-call/result id is projected through [canonicalToolCallId] — what
/// the adapter puts on the wire is what pairs here.
List<_WireMessage> _wireView(List<Message> messages) {
  final wire = <_WireMessage>[];
  final userBlocks = <({String? resultId})>[];
  void flushUser() {
    if (userBlocks.isNotEmpty) {
      wire.add(_WireUser(List.of(userBlocks)));
      userBlocks.clear();
    }
  }

  for (final message in messages) {
    switch (message) {
      case ToolResultMessage():
        userBlocks.add((resultId: canonicalToolCallId(message.toolCallId)));
      case UserMessage():
        if (_userVisible(message)) userBlocks.add((resultId: null));
      case AssistantMessage():
        flushUser();
        _collectAssistant(wire, message);
    }
  }
  flushUser();
  return wire;
}

/// The wire view of one assistant message: its canonical call ids, dropped
/// entirely when it has no visible content.
void _collectAssistant(List<_WireMessage> wire, AssistantMessage message) {
  final callIds = [
    for (final block in message.content)
      if (block is ToolCall) canonicalToolCallId(block.id),
  ];
  final hasText = message.content.any(
    (block) => block is TextContent && block.text.trim().isNotEmpty,
  );
  if (callIds.isNotEmpty || hasText) {
    wire.add(_WireAssistant(callIds));
  }
}

/// Whether a user message survives the provider adapters' empty-content
/// filtering (see e.g. `_convertUserMessage` in the Anthropic adapter).
bool _userVisible(UserMessage message) {
  final content = message.content;
  if (content is String) return content.trim().isNotEmpty;
  return (content as List<ContentBlock>).any(
    (block) =>
        block is ImageContent ||
        (block is TextContent && block.text.trim().isNotEmpty),
  );
}

sealed class _WireMessage {
  const _WireMessage();
}

final class _WireAssistant extends _WireMessage {
  const _WireAssistant(this.callIds);
  final List<String> callIds;
}

final class _WireUser extends _WireMessage {
  const _WireUser(this.blocks);
  final List<({String? resultId})> blocks;
}
