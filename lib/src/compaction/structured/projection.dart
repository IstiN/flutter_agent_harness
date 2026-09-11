/// Context projection for the structured compaction engine (issue #148).
///
/// The structured state lives in [HiddenRangeRecord] and
/// [CompactCheckpointRecord] records on the branch. This library derives
/// the render-time view — which records are hidden, which ranges are
/// swallowed by which checkpoint — and walks the branch path into the
/// outgoing message list:
///
/// - hidden records render as one-line markers at their original position;
/// - a checkpoint's marker renders in place of the FIRST record it covers,
///   and everything it covers stops rendering individually;
/// - a checkpoint whose own record is covered by a later checkpoint is
///   skipped (nesting, D4);
/// - everything else projects exactly as the classic projection does.
///
/// All state is keyed by stable record ids. The short numeric ids shown to
/// the model are computed here from the append-only file order via
/// [RecordSeqIndex] and never persisted (AC3).
library;

import 'markers.dart';
import '../token_estimation.dart';
import '../../context.dart';
import '../../types.dart';
import '../../session/session_record.dart';

/// Numeric alias index over a session's stored records.
///
/// The id the model sees for a record is its 1-based JSONL line number
/// (the session header is line 1), so the zero-tool fallback —
/// `read $FAH_SESSION_FILE:<line>` — resolves to the same record. The file
/// is append-only, so a record's alias is stable for the session's
/// lifetime; branches share the numbering because they share the file.
final class RecordSeqIndex {
  /// Creates an index over [entries] in file order.
  RecordSeqIndex(this.entries)
    : _seqById = {
        for (var i = 0; i < entries.length; i++) entries[i].id: i + 2,
      };

  /// All records in file order.
  final List<SessionRecord> entries;

  final Map<String, int> _seqById;

  /// The numeric alias of [recordId], or `null` when unknown.
  int? seqOf(String recordId) => _seqById[recordId];

  /// The record at numeric alias [seq], or `null` when out of range.
  SessionRecord? recordAt(int seq) {
    final i = seq - 2;
    return i >= 0 && i < entries.length ? entries[i] : null;
  }
}

/// Derived, immutable view of the structured state on a branch path.
final class StructuredViewState {
  const StructuredViewState._({
    required this.hiddenRecordIds,
    required this.checkpoints,
    required this.coveredRecordIds,
  });

  /// Union of every [HiddenRangeRecord.recordIds] on the path.
  final Set<String> hiddenRecordIds;

  /// Checkpoints on the path, in path order.
  final List<CompactCheckpointRecord> checkpoints;

  /// Record id -> the checkpoint covering it (a later checkpoint wins over
  /// an earlier one for the same record, D4 nesting).
  final Map<String, CompactCheckpointRecord> coveredRecordIds;

  /// Whether no structured state exists on the path.
  bool get isEmpty =>
      hiddenRecordIds.isEmpty && checkpoints.isEmpty && coveredRecordIds.isEmpty;

  /// Whether [recordId] is swallowed by a checkpoint (hidden-and-covered
  /// counts as covered — the checkpoint's marker owns the position).
  bool isCovered(String recordId) => coveredRecordIds.containsKey(recordId);
}

/// Derives the structured view over a branch [path] (post-classic-transform).
StructuredViewState buildStructuredViewState(List<SessionRecord> path) {
  final hidden = <String>{};
  final checkpoints = <CompactCheckpointRecord>[];
  final covered = <String, CompactCheckpointRecord>{};
  for (final record in path) {
    switch (record) {
      case HiddenRangeRecord(:final recordIds):
        hidden.addAll(recordIds);
      case CompactCheckpointRecord():
        checkpoints.add(record);
        for (final id in record.coversRecordIds) {
          covered[id] = record;
        }
        // The range itself is swallowed even when covers is partial.
        covered[record.firstRecordId] = record;
        covered[record.lastRecordId] = record;
      default:
        break;
    }
  }
  return StructuredViewState._(
    hiddenRecordIds: hidden,
    checkpoints: checkpoints,
    coveredRecordIds: covered,
  );
}

/// Renders [path] into the outgoing message list with markers.
///
/// [projectEntry] is the classic per-record projection (the session tree's
/// `_entryToMessages`); structured records never reach it. The result is
/// wire-safe by construction: hidden tool results stay tool results, and
/// hidden assistant carriers become plain user-role markers, so no tool
/// call is ever orphaned (issue #85).
List<Message> renderStructuredMessages({
  required List<SessionRecord> path,
  required RecordSeqIndex seqs,
  required List<Message> Function(SessionRecord record) projectEntry,
}) {
  final state = buildStructuredViewState(path);
  final byId = {for (final record in path) record.id: record};
  final messages = <Message>[];
  final emitted = <String>{};
  // Tool calls whose assistant carrier is itself hidden: hiding the
  // carrier downgrades its results to user-role markers too, or the wire
  // would carry tool_results whose tool_use no longer exists (the #85
  // orphan bug wearing a marker).
  final hiddenCallIds = <String>{};
  for (final record in path) {
    final message = record is MessageRecord ? record.message : null;
    if (message is AssistantMessage &&
        (state.hiddenRecordIds.contains(record.id) ||
            state.isCovered(record.id))) {
      for (final block in message.content) {
        if (block is ToolCall) hiddenCallIds.add(block.id);
      }
    }
  }

  for (final record in path) {
    // A covering checkpoint renders at the position of its first visible
    // path record (D2: markers sit where the content sat).
    final cover = state.coveredRecordIds[record.id];
    if (cover != null) {
      if (emitted.add(cover.id) && !state.isCovered(cover.id)) {
        messages.add(_checkpointMessage(cover, byId: byId, seqs: seqs));
      }
      continue; // Swallowed by the checkpoint.
    }
    switch (record) {
      case HiddenRangeRecord():
        continue;
      case CompactCheckpointRecord():
        // Renders in place only when its range sits fully off-branch
        // (nothing visible triggered the in-place emission above).
        if (emitted.add(record.id)) {
          messages.add(_checkpointMessage(record, byId: byId, seqs: seqs));
        }
      case MessageRecord(:final message, :final id):
        final seq = seqs.seqOf(id);
        final hidden = state.hiddenRecordIds.contains(id) && seq != null;
        // A visible result whose call was hidden or swallowed by a
        // checkpoint cannot stay a tool_result on the wire — it renders
        // as a user-role marker (its content stays expandable).
        final orphaned = message is ToolResultMessage &&
            hiddenCallIds.contains(message.toolCallId);
        messages.add(
          hidden || orphaned
              ? _hiddenMessage(record, message, seq ?? 0, orphaned: orphaned)
              : message,
        );
      case CompactionRecord() || BranchSummaryRecord():
        final seq = seqs.seqOf(record.id);
        if (state.hiddenRecordIds.contains(record.id) && seq != null) {
          final kind = record is CompactionRecord
              ? markerKinds.legacyCheckpoint
              : markerKinds.branchSummary;
          messages.add(
            UserMessage.text(
              hiddenMarker(
                seq: seq,
                kind: kind,
                tokens: _recordTokens(record),
              ),
              timestamp: record.timestamp,
            ),
          );
        } else {
          messages.addAll(projectEntry(record));
        }
      default:
        break;
    }
  }
  return messages;
}

Message _checkpointMessage(
  CompactCheckpointRecord record, {
  required Map<String, SessionRecord> byId,
  required RecordSeqIndex seqs,
}) {
  final startSeq = seqs.seqOf(record.firstRecordId) ?? 0;
  final endSeq = seqs.seqOf(record.lastRecordId) ?? startSeq;
  final covers = <int>[];
  for (final id in record.coversRecordIds) {
    final seq = seqs.seqOf(id);
    if (seq != null) covers.add(seq);
  }
  var coveredTokens = 0;
  for (final id in record.coversRecordIds) {
    final covered = byId[id];
    if (covered != null) coveredTokens += _recordTokens(covered);
  }
  final header = checkpointMarkerHeader(
    startSeq: startSeq,
    endSeq: endSeq,
    coveredTokens: coveredTokens,
    textTokens: estimateTokens(UserMessage.text(record.text)),
    coversRanges: idsToRanges(covers),
  );
  return UserMessage.text(
    '$header\n${record.text}',
    timestamp: record.timestamp,
  );
}
/// Builds the marker replacement for a hidden [MessageRecord].
Message _hiddenMessage(
  MessageRecord record,
  Message message,
  int seq, {
  required bool orphaned,
}) {
  switch (message) {
    case ToolResultMessage() when !orphaned:
      // Keep the pair on the wire: same call id, same tool name, marker
      // as the only content.
      return ToolResultMessage(
        toolCallId: message.toolCallId,
        toolName: message.toolName,
        content: [
          TextContent(
            text: hiddenMarker(
              seq: seq,
              kind: markerKinds.toolResult,
              tokens: estimateTokens(message),
            ),
          ),
        ],
        isError: message.isError,
        timestamp: message.timestamp,
      );
    case ToolResultMessage():
      // Carrier hidden too: a tool_result without its tool_use is an
      // invalid request — downgrade to a plain user-role marker.
      return UserMessage.text(
        hiddenMarker(
          seq: seq,
          kind: markerKinds.toolResult,
          tokens: estimateTokens(message),
        ),
        timestamp: message.timestamp,
      );
    case AssistantMessage():
      return UserMessage.text(
        hiddenMarker(
          seq: seq,
          kind: markerKinds.assistant,
          tokens: estimateTokens(message),
        ),
        timestamp: message.timestamp,
      );
    default:
      return UserMessage.text(
        hiddenMarker(
          seq: seq,
          kind: markerKinds.user,
          tokens: estimateTokens(message),
        ),
        timestamp: message.timestamp,
      );
  }
}

int _recordTokens(SessionRecord record) {
  switch (record) {
    case MessageRecord(:final message):
      return estimateTokens(message);
    case CustomMessageRecord(:final content):
      return estimateTokens(UserMessage(content: content, timestamp: DateTime.fromMillisecondsSinceEpoch(0)));
    case CompactCheckpointRecord(:final text):
      return estimateTokens(UserMessage.text(text));
    case CompactionRecord(:final summary):
      return estimateTokens(UserMessage.text(summary));
    case BranchSummaryRecord(:final summary):
      return estimateTokens(UserMessage.text(summary));
    default:
      return 0;
  }
}
