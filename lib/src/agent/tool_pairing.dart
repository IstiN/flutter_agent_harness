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

import '../context.dart';
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
  });

  /// Ids of orphaned results dropped from the payload.
  final List<String> droppedResultIds;

  /// Ids of calls that got a synthetic interrupted result.
  final List<String> synthesizedResultIds;

  /// Duplicate-id renames applied to a call AND its result.
  final List<({String from, String to})> renamedIds;

  bool get isNotEmpty =>
      droppedResultIds.isNotEmpty ||
      synthesizedResultIds.isNotEmpty ||
      renamedIds.isNotEmpty;

  @override
  String toString() =>
      'dropped=$droppedResultIds synthesized=$synthesizedResultIds '
      'renamed=$renamedIds';
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
/// litellm/Bedrock, and OpenAI-compatible. Detection is keyed on the error
/// SIGNATURE family, never on one provider's exact string (E5).
const _pairingErrorSignatures = [
  'unexpected tool_use_id',
  'corresponding tool_use block',
  'expected toolresult blocks',
  'tool_call_id is not found',
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

/// Symmetric pairing repair at the request boundary. Returns [messages]
/// untouched (same instance, empty report) when the context already
/// satisfies [validateToolPairing]; otherwise returns a rebuilt payload
/// whose wire view is valid — the transcript itself is never modified.
({List<Message> messages, ToolPairingRepairReport report}) repairToolPairing(
  List<Message> messages,
) {
  if (validateToolPairing(messages).isEmpty) {
    return (messages: messages, report: const ToolPairingRepairReport());
  }

  final index = _indexCalls(messages);
  final renames = _renameDuplicates(index, messages);
  final attached = _attachResults(index, messages, renames.slotNewIds);
  return _rebuild(messages, index, renames, attached);
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

  /// Orphaned results (no call occurrence left to answer them).
  final orphans = <ToolResultMessage>[];
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
      attachment.orphans.add(message);
      continue;
    }
    final n = occurrence.putIfAbsent(message.toolCallId, () => 0);
    occurrence[message.toolCallId] = n + 1;
    if (n < slots.length) {
      attachment.resultForSlot[slots[n]] = i;
    } else {
      attachment.orphans.add(message);
    }
  }
  return attachment;
}

({List<Message> messages, ToolPairingRepairReport report}) _rebuild(
  List<Message> messages,
  _CallIndex index,
  _Renames renames,
  _Attachment attachment,
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
    var assistant = message as AssistantMessage;
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
    rebuilt.add(assistant);

    // Results (and synthetic interrupted ones) sit DIRECTLY after their
    // assistant message — results first, before any interleaved user text.
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
        emittedResults.add(resultIndex);
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

  // Dropped orphans are replaced by ONE visible note so the model knows the
  // work happened but is no longer in context. Appended at the end: strict
  // endpoints require tool_result blocks to come before text in a message,
  // so a note mid-context could re-break the very grouping we just fixed.
  if (attachment.orphans.isNotEmpty) {
    rebuilt.add(UserMessage.text(_dropNote(attachment.orphans)));
  }

  return (
    messages: rebuilt,
    report: ToolPairingRepairReport(
      droppedResultIds: [
        for (final orphan in attachment.orphans) orphan.toolCallId,
      ],
      synthesizedResultIds: synthesized,
      renamedIds: renames.entries,
    ),
  );
}

String _dropNote(List<ToolResultMessage> orphans) {
  final dropped = orphans
      .map((orphan) => '"${orphan.toolName}" (id: ${orphan.toolCallId})')
      .join(', ');
  return orphans.length == 1
      ? '[context note: a tool result for $dropped was dropped — its '
            'originating call is no longer in context]'
      : '[context note: ${orphans.length} tool results ($dropped) were '
            'dropped — their originating calls are no longer in context]';
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
