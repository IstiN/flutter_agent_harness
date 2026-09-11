/// The context ledger for the structured compaction engine (issue #148).
///
/// The judge model never sees raw history — it sees one line per visible
/// projecting record:
///
/// ```
/// [2] user·exempt ~68tok · fix the login crash
/// [3] assistant-TOOLCALL(read) ~40tok
/// [4] toolResult(read) ~4.0k · x.dart contents…
/// [5] ckpt 2-4 ~38k → covers:3,4 · summary text…
/// ```
///
/// Real user turns are tagged `·exempt` and can never be hidden (F8/F9):
/// user steering must survive every pass. Tool-call carriers carry their
/// tool names so the judge can reason about pairs (F3), and every entry
/// knows the pair group it belongs to — groups hide atomically (D6).
library;

import '../compaction.dart' show isSyntheticUserText;
import '../token_estimation.dart' show estimateTokens;
import '../../context.dart';
import '../../types.dart';
import '../../session/session_record.dart';
import 'projection.dart';
import '../compaction.dart';

/// One visible line of the ledger.
final class LedgerEntry {
  const LedgerEntry._({
    required this.seq,
    required this.recordId,
    required this.record,
    required this.kind,
    required this.tokens,
    required this.preview,
    required this.toolNames,
  });

  /// The record's numeric alias (JSONL line number).
  final int seq;

  /// The record's stable id.
  final String recordId;

  /// The underlying record.
  final SessionRecord record;

  /// The kind label (`user`, `notice`, `assistant-TEXT`,
  /// `assistant-TOOLCALL(read,bash)`, `toolResult(read)`, `ckpt`,
  /// `legacy-ckpt`, `branch-summary`).
  final String kind;

  /// Estimated tokens of the record's projection.
  final int tokens;

  /// Flattened first line of content (~110 chars).
  final String preview;

  /// Comma-joined tool names for call/result entries.
  final String toolNames;

  /// Real user turns can never be hidden.
  bool get exempt => kind == 'user';
}

/// The judge-facing index of visible records.
final class ContextLedger {
  const ContextLedger._(this.entries, this._groupByRecordId);

  /// Visible projecting records, oldest first.
  final List<LedgerEntry> entries;

  final Map<String, Set<String>> _groupByRecordId;

  /// The pair-atomic group of [recordId]: an assistant tool-call carrier
  /// plus every result answering its calls (D6 — all or none).
  Set<String> groupOf(String recordId) =>
      _groupByRecordId[recordId] ?? {recordId};

  /// The entry with numeric alias [seq], or `null`.
  LedgerEntry? entryAtSeq(int seq) {
    for (final entry in entries) {
      if (entry.seq == seq) return entry;
    }
    return null;
  }

  /// Renders the ledger as the judge's input block.
  String render() => [for (final entry in entries) _line(entry)].join('\n');

  String _line(LedgerEntry entry) {
    final kind = entry.toolNames.isEmpty ? entry.kind : entry.kind;
    final exempt = entry.exempt ? '·exempt' : '';
    final detail = entry.preview.isEmpty ? '' : ' · ${entry.preview}';
    return '[${entry.seq}] $kind$exempt ~${entry.tokens}tok$detail';
  }
}

/// Builds the ledger over the VISIBLE branch path (post-projection-walk:
/// hidden and checkpoint-covered records already removed).
ContextLedger buildContextLedger({
  required List<SessionRecord> visiblePath,
  required RecordSeqIndex seqs,
}) {
  final entries = <LedgerEntry>[];
  for (final record in visiblePath) {
    final entry = _entryFor(record, seqs);
    if (entry != null) entries.add(entry);
  }
  return ContextLedger._(entries, _pairGroups(visiblePath));
}

LedgerEntry? _entryFor(SessionRecord record, RecordSeqIndex seqs) {
  final seq = seqs.seqOf(record.id);
  if (seq == null) return null;
  switch (record) {
    case MessageRecord(:final message):
      switch (message) {
        case AssistantMessage assistant:
          final calls = assistant.content.whereType<ToolCall>().toList();
          return LedgerEntry._(
            seq: seq,
            recordId: record.id,
            record: record,
            kind: calls.isEmpty
                ? 'assistant-TEXT'
                : 'assistant-TOOLCALL(${calls.map((c) => c.name).join(',')})',
            tokens: estimateTokens(message),
            preview: _flattenAssistant(assistant),
            toolNames: calls.map((c) => c.name).join(','),
          );
        case ToolResultMessage result:
          return LedgerEntry._(
            seq: seq,
            recordId: record.id,
            record: record,
            kind: 'toolResult(${result.toolName})',
            tokens: estimateTokens(message),
            preview: _flattenBlocks(result.content),
            toolNames: result.toolName,
          );
        case UserMessage user:
          final text = _flattenUser(user.content);
          final synthetic = isSyntheticUserText(text);
          return LedgerEntry._(
            seq: seq,
            recordId: record.id,
            record: record,
            kind: synthetic ? 'notice' : 'user',
            tokens: estimateTokens(message),
            preview: _clip(text),
            toolNames: '',
          );
        default:
          return null;
      }
    case CustomMessageRecord():
      return LedgerEntry._(
        seq: seq,
        recordId: record.id,
        record: record,
        kind: 'notice',
        tokens: estimateTokens(
          UserMessage(content: record.content, timestamp: record.timestamp),
        ),
        preview: _clip(_flattenUser(record.content)),
        toolNames: '',
      );
    case CompactCheckpointRecord ckpt:
      return LedgerEntry._(
        seq: seq,
        recordId: record.id,
        record: record,
        kind: 'ckpt',
        tokens: estimateTokens(UserMessage.text(ckpt.text)),
        preview: _clip(ckpt.text),
        toolNames: '',
      );
    case CompactionRecord legacy:
      return LedgerEntry._(
        seq: seq,
        recordId: record.id,
        record: record,
        kind: 'legacy-ckpt',
        tokens: estimateTokens(UserMessage.text(legacy.summary)),
        preview: _clip(legacy.summary),
        toolNames: '',
      );
    case BranchSummaryRecord branch:
      return LedgerEntry._(
        seq: seq,
        recordId: record.id,
        record: record,
        kind: 'branch-summary',
        tokens: branch.summary.isEmpty
            ? 0
            : estimateTokens(UserMessage.text(branch.summary)),
        preview: _clip(branch.summary),
        toolNames: '',
      );
    default:
      return null; // Non-projecting records have no ledger line.
  }
}

/// Pair-atomic groups over the visible path (D6): each assistant
/// tool-call carrier groups with the results answering its calls.
Map<String, Set<String>> _pairGroups(List<SessionRecord> path) {
  final groups = <String, Set<String>>{};
  final pendingCalls = <String, String>{}; // toolCallId -> carrier record id
  for (final record in path) {
    final message = record is MessageRecord ? record.message : null;
    if (message is AssistantMessage) {
      final calls = message.content.whereType<ToolCall>().toList();
      if (calls.isEmpty) continue;
      final group = {record.id};
      groups[record.id] = group;
      for (final call in calls) {
        pendingCalls[call.id] = record.id;
      }
    } else if (message is ToolResultMessage) {
      final carrierId = pendingCalls[message.toolCallId];
      if (carrierId != null) {
        groups[carrierId]?.add(record.id);
        groups[record.id] = groups[carrierId]!;
      } else {
        // A result whose carrier is off-ledger (older than the visible
        // window): it hides alone, or stays — never blocks its neighbors.
        groups[record.id] = {record.id};
      }
    }
  }
  return groups;
}

String _flattenAssistant(AssistantMessage message) {
  final text = message.content
      .whereType<TextContent>()
      .map((block) => block.text)
      .join(' ');
  return _clip(text);
}

String _flattenUser(Object content) {
  if (content is String) return content;
  return (content as List<Object>)
      .whereType<TextContent>()
      .map((block) => block.text)
      .join(' ');
}

String _flattenBlocks(List<ContentBlock> blocks) {
  return _clip(blocks.whereType<TextContent>().map((b) => b.text).join(' '));
}

String _clip(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= 110) return flat;
  return '${flat.substring(0, 107)}…';
}
