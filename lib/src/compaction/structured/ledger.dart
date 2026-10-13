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
  ContextLedger._(this.entries, this._groupByRecordId)
    : _entryBySeq = {for (final entry in entries) entry.seq: entry};

  /// Visible projecting records, oldest first.
  final List<LedgerEntry> entries;

  final Map<String, Set<String>> _groupByRecordId;

  final Map<int, LedgerEntry> _entryBySeq;

  /// The pair-atomic group of [recordId]: an assistant tool-call carrier
  /// plus every result answering its calls (D6 — all or none).
  Set<String> groupOf(String recordId) =>
      _groupByRecordId[recordId] ?? {recordId};

  /// The entry with numeric alias [seq], or `null` (issue #1499: a map
  /// lookup — the linear scan over all entries showed up on judge-pick
  /// validation over marathon sessions).
  LedgerEntry? entryAtSeq(int seq) => _entryBySeq[seq];

  /// The judge input cap (issue #541): the newest [judgePreviewEntries]
  /// entries render. The judge prompt stays O(bounded) regardless of
  /// session size, so the per-call budget (issue #515) stays winnable on
  /// marathon sessions instead of growing into a guaranteed timeout.
  static const int judgePreviewEntries = 512;

  /// Renders the ledger as the judge's input block: at most
  /// [maxEntries] NEWEST entries, preceded by one summary line for the
  /// omitted older prefix (issue #541 — the judge decides on a bounded
  /// preview, not the whole chronicle).
  String render({int maxEntries = judgePreviewEntries}) {
    if (entries.length <= maxEntries) {
      return [for (final entry in entries) _line(entry)].join('\n');
    }
    final omitted = entries.length - maxEntries;
    var omittedTokens = 0;
    for (final entry in entries.take(omitted)) {
      omittedTokens += entry.tokens;
    }
    final head =
        '[…] $omitted older records (seqs ${entries.first.seq}-'
        '${entries[omitted - 1].seq}, ~$omittedTokens tok) are omitted '
        'from this preview — decide on the newest records below';
    return [
      head,
      for (final entry in entries.skip(omitted)) _line(entry),
    ].join('\n');
  }

  String _line(LedgerEntry entry) {
    final kind = entry.toolNames.isEmpty ? entry.kind : entry.kind;
    final exempt = entry.exempt ? '·exempt' : '';
    final detail = entry.preview.isEmpty ? '' : ' · ${entry.preview}';
    return '[${entry.seq}] $kind$exempt ~${entry.tokens}tok$detail';
  }
}

/// Memoizes the derived ledger scalars of records across
/// [buildContextLedger] rebuilds (issue #1499).
///
/// Every compaction pass rebuilds the ledger over the whole visible path,
/// and the expensive part of each entry — token estimation, preview
/// flattening, the synthetic-user scan — scales with the record's CONTENT.
/// On a marathon session that is history re-processed from scratch on
/// every pass (the 2.0s mean / 58.8s max profile). The session file is
/// append-only and record ids are stable, so those scalars never change
/// for a given id: computing them once per record turns every later
/// rebuild into O(changed records) plus cheap map hits.
///
/// OWNERSHIP: one cache per ledger-rebuilding chain, scoped to ONE
/// session — a [StructuredCompactor] instance (one compaction run), a
/// [CompactExpandController] instance (one agent; cleared when the live
/// session object changes). Never share a cache across sessions and never
/// make it global: ids are only unique within a session.
final class LedgerEntryCache {
  final Map<String, _CachedEntry> _byId = {};

  /// Forgets every memoized record (session switch).
  void clear() => _byId.clear();
}

/// The id-keyed scalars a rebuilt [LedgerEntry] needs; the rebuilt entry
/// carries the CURRENT record instance so identity stays honest.
final class _CachedEntry {
  const _CachedEntry({
    required this.seq,
    required this.kind,
    required this.tokens,
    required this.preview,
    required this.toolNames,
  });

  final int seq;
  final String kind;
  final int tokens;
  final String preview;
  final String toolNames;
}

/// Builds the ledger over the VISIBLE branch path (post-projection-walk:
/// hidden and checkpoint-covered records already removed).
///
/// [cache] memoizes per-record entry scalars across calls (issue #1499):
/// pass one cache instance to every rebuild of the same session's ledger.
/// Omitted — as by every direct caller and test — the build computes each
/// entry from scratch, byte-identical to the pre-cache shape.
ContextLedger buildContextLedger({
  required List<SessionRecord> visiblePath,
  required RecordSeqIndex seqs,
  LedgerEntryCache? cache,
}) {
  final entries = <LedgerEntry>[];
  for (final record in visiblePath) {
    final entry = _entryFor(record, seqs, cache);
    if (entry != null) entries.add(entry);
  }
  return ContextLedger._(entries, _pairGroups(visiblePath));
}

LedgerEntry? _entryFor(
  SessionRecord record,
  RecordSeqIndex seqs,
  LedgerEntryCache? cache,
) {
  final seq = seqs.seqOf(record.id);
  if (seq == null) return null;
  final cached = cache?._byId[record.id];
  if (cached != null && cached.seq == seq) {
    // Cache hit: scalars reuse, identity fresh. The seq guard makes the
    // cache self-correcting should an id ever move in file order.
    return LedgerEntry._(
      seq: seq,
      recordId: record.id,
      record: record,
      kind: cached.kind,
      tokens: cached.tokens,
      preview: cached.preview,
      toolNames: cached.toolNames,
    );
  }
  final entry = switch (record) {
    MessageRecord(:final message) => _messageEntry(record, message, seq),
    CustomMessageRecord() => LedgerEntry._(
      seq: seq,
      recordId: record.id,
      record: record,
      kind: 'notice',
      tokens: estimateTokens(
        UserMessage(content: record.content, timestamp: record.timestamp),
      ),
      preview: _clip(_flattenUser(record.content)),
      toolNames: '',
    ),
    CompactCheckpointRecord ckpt => LedgerEntry._(
      seq: seq,
      recordId: record.id,
      record: record,
      kind: 'ckpt',
      tokens: estimateTokens(UserMessage.text(ckpt.text)),
      preview: _clip(ckpt.text),
      toolNames: '',
    ),
    CompactionRecord legacy => LedgerEntry._(
      seq: seq,
      recordId: record.id,
      record: record,
      kind: 'legacy-ckpt',
      tokens: estimateTokens(UserMessage.text(legacy.summary)),
      preview: _clip(legacy.summary),
      toolNames: '',
    ),
    BranchSummaryRecord branch => LedgerEntry._(
      seq: seq,
      recordId: record.id,
      record: record,
      kind: 'branch-summary',
      tokens: branch.summary.isEmpty
          ? 0
          : estimateTokens(UserMessage.text(branch.summary)),
      preview: _clip(branch.summary),
      toolNames: '',
    ),
    _ => null, // Non-projecting records have no ledger line.
  };
  if (entry == null) return null;
  cache?._byId[record.id] = _CachedEntry(
    seq: seq,
    kind: entry.kind,
    tokens: entry.tokens,
    preview: entry.preview,
    toolNames: entry.toolNames,
  );
  return entry;
}

/// A message-carrying record to its ledger line, or null when the
/// message kind never projects (the ledger lists only model-visible
/// content).
LedgerEntry? _messageEntry(MessageRecord record, Message message, int seq) {
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

/// The live-edge floor shared by every hide path (issue #1379 tier 2):
/// the ids of the newest [protectLastN] ledger entries — the working set
/// no hide may fold, whoever asks (judge picks, deterministic fallback,
/// LRU re-hide, agent hide). The ONE computation; every consumer calls
/// this so the invariant cannot drift between copies.
Set<String> protectedTailIds(ContextLedger ledger, int protectLastN) {
  final start = ledger.entries.length - protectLastN;
  return {
    for (final entry in ledger.entries.skip(start < 0 ? 0 : start))
      entry.recordId,
  };
}
