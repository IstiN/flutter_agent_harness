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
import '../summary_sanitizer.dart';
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
    this.pinnedRecordIds = const {},
    this.consolidatedRanges = const {},
  });

  /// Union of every [HiddenRangeRecord.recordIds] on the path.
  final Set<String> hiddenRecordIds;

  /// Checkpoints on the path, in path order.
  final List<CompactCheckpointRecord> checkpoints;

  /// Record id -> the checkpoint covering it (a later checkpoint wins over
  /// an earlier one for the same record, D4 nesting).
  final Map<String, CompactCheckpointRecord> coveredRecordIds;

  /// Record ids currently pinned (issue #1379 tier 2): never hidden by
  /// judge, fallback, LRU re-hide, or agent hide — never checkpoint-covered.
  final Set<String> pinnedRecordIds;

  /// GOAL #2394 (D5/AC9): every record a `consolidated` hidden range
  /// hides → that range. Such a range renders as ONE marker at its
  /// carrier instead of a marker per record (pre-#2394 ranges never
  /// appear here and render exactly as before).
  final Map<String, HiddenRangeRecord> consolidatedRanges;

  /// Whether no structured state exists on the path.
  bool get isEmpty =>
      hiddenRecordIds.length + checkpoints.length + coveredRecordIds.length ==
      0;

  /// Whether [recordId] is swallowed by a checkpoint (hidden-and-covered
  /// counts as covered — the checkpoint's marker owns the position).
  bool isCovered(String recordId) => coveredRecordIds.containsKey(recordId);
}

/// One fold record the replay dropped WHOLE (gh-1425 AC2): it carries NO
/// ids this build can read — the version-skew shape (an older writer put
/// the ids under keys this binary does not parse, so every id field is
/// empty). All-or-note resolution means none of its ids enter the derived
/// state (there are none) and its own marker/text never renders; a visible
/// note names the dropped generation instead.
final class DroppedFold {
  const DroppedFold({required this.record});

  /// The fold record itself (hidden range / compact checkpoint /
  /// segment pin).
  final SessionRecord record;
}

/// The [StructuredViewState] a fold-aware replay produced plus the folds
/// it had to drop whole.
final class ResolvedFolds {
  const ResolvedFolds({required this.state, required this.dropped});

  final StructuredViewState state;

  /// The dropped fold records, in path order — the renderer surfaces one
  /// visible resume note per entry.
  final List<DroppedFold> dropped;
}

/// Resolves the structured fold chain over a branch [path] with ALL-OR-NOTE
/// semantics (gh-1425 AC2): a fold record the replaying binary cannot
/// RESOLVE — it carries no ids at all (the record-shape skew a newer binary
/// can hit replaying an older build's folds: the ids live under keys this
/// build does not read) — is dropped WHOLE and reported, so its text never
/// renders as a valid checkpoint/hide and nothing half-applies silently.
///
/// References that merely point OFF the path are NOT skew and are applied
/// as before, unchanged: a checkpoint legitimately covers an off-branch
/// arc (it still renders its summary in place), and a hidden range may span
/// below a windowed resume's resident window (hiding those is moot — the
/// seq alias keeps the exempt classification quiet under a classic
/// boundary, issue #266 F1a). Both rendered identically before this
/// resolver existed (REG-1).
ResolvedFolds resolveStructuredFolds(List<SessionRecord> path) {
  final hidden = <String>{};
  final checkpoints = <CompactCheckpointRecord>[];
  final covered = <String, CompactCheckpointRecord>{};
  final pinnedIds = <String>{};
  final consolidated = <String, HiddenRangeRecord>{};
  final dropped = <DroppedFold>[];
  void apply(
    SessionRecord record,
    bool emptyShape,
    void Function() applyEffect,
  ) {
    if (emptyShape) {
      dropped.add(DroppedFold(record: record));
      return;
    }
    applyEffect();
  }

  for (final record in path) {
    switch (record) {
      case HiddenRangeRecord(:final recordIds):
        apply(record, recordIds.where((id) => id.isNotEmpty).isEmpty, () {
          hidden.addAll(recordIds);
          if (record.consolidated) {
            for (final id in recordIds) {
              consolidated[id] = record;
            }
          }
        });
      case SegmentPinRecord(:final recordIds, :final pinned):
        apply(record, recordIds.where((id) => id.isNotEmpty).isEmpty, () {
          pinned ? pinnedIds.addAll(recordIds) : pinnedIds.removeAll(recordIds);
        });
      case CompactCheckpointRecord checkpoint:
        apply(
          record,
          checkpoint.coversRecordIds.where((id) => id.isNotEmpty).isEmpty &&
              checkpoint.firstRecordId.isEmpty &&
              checkpoint.lastRecordId.isEmpty,
          () {
            checkpoints.add(checkpoint);
            for (final id in checkpoint.coversRecordIds) {
              covered[id] = checkpoint;
            }
            // The range itself is swallowed even when covers is partial.
            covered[checkpoint.firstRecordId] = checkpoint;
            covered[checkpoint.lastRecordId] = checkpoint;
          },
        );
      default:
        break;
    }
  }
  return ResolvedFolds(
    state: StructuredViewState._(
      hiddenRecordIds: hidden,
      checkpoints: checkpoints,
      coveredRecordIds: covered,
      pinnedRecordIds: pinnedIds,
      consolidatedRanges: consolidated,
    ),
    dropped: dropped,
  );
}

/// Derives the structured view over a branch [path] (post-classic-transform).
StructuredViewState buildStructuredViewState(List<SessionRecord> path) {
  final hidden = <String>{};
  final checkpoints = <CompactCheckpointRecord>[];
  final covered = <String, CompactCheckpointRecord>{};
  final pinnedRecordIds = <String>{};
  final consolidated = <String, HiddenRangeRecord>{};
  for (final record in path) {
    switch (record) {
      case HiddenRangeRecord(:final recordIds):
        hidden.addAll(recordIds);
        if (record.consolidated) {
          for (final id in recordIds) {
            consolidated[id] = record;
          }
        }
      case SegmentPinRecord(:final recordIds, :final pinned):
        pinned
            ? pinnedRecordIds.addAll(recordIds)
            : pinnedRecordIds.removeAll(recordIds);
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
    pinnedRecordIds: pinnedRecordIds,
    consolidatedRanges: consolidated,
  );
}

/// The model-visible projecting records over a transformed path — the
/// population both the judge ledger and the agent-hide validation work
/// over (issue #1379 tier 2: one convention, engine and tool alike).
List<SessionRecord> visibleStructuredPath(
  List<SessionRecord> path,
  StructuredViewState state,
) => [
  for (final record in path)
    if (!state.isCovered(record.id) &&
        record is! HiddenRangeRecord &&
        !state.hiddenRecordIds.contains(record.id) &&
        projectsStructured(record))
      record,
];

/// Whether [record] renders into the model context at all.
bool projectsStructured(SessionRecord record) =>
    record is MessageRecord ||
    record is CustomMessageRecord ||
    record is CompactionRecord ||
    record is BranchSummaryRecord ||
    record is CompactCheckpointRecord;

/// Renders [path] into the outgoing message list with markers.
///
/// [projectEntry] is the classic per-record projection (the session tree's
/// `_entryToMessages`); structured records never reach it. The result is
/// wire-safe by construction: hidden tool results stay tool results, and
/// hidden assistant carriers become plain user-role markers, so no tool
/// call is ever orphaned (issue #85).
///
/// The fold chain resolves with ALL-OR-NOTE semantics (gh-1425 AC2): a
/// fold record the replaying binary cannot resolve — it carries no ids at
/// all (an older build's shape: the ids live under keys this build does
/// not read) — is dropped whole and a visible `[resume]` note renders at
/// its position naming the dropped generation. References that merely
/// point off the path (off-branch checkpoint coverage, below-window
/// ranges) are not skew and apply unchanged.
List<Message> renderStructuredMessages({
  required List<SessionRecord> path,
  required RecordSeqIndex seqs,
  required List<Message> Function(SessionRecord record) projectEntry,
  void Function(SessionRecord? source, Message message)? onMessage,
}) {
  final resolution = resolveStructuredFolds(path);
  final state = resolution.state;
  final droppedById = {
    for (final drop in resolution.dropped) drop.record.id: drop,
  };
  final byId = {for (final record in path) record.id: record};
  // Tool calls whose assistant carrier is itself hidden: hiding the
  // carrier downgrades its results to user-role markers too, or the wire
  // would carry tool_results whose tool_use no longer exists (the #85
  // orphan bug wearing a marker).
  final hiddenCallIds = _hiddenToolCallIds(path, state);
  final messages = <Message>[];
  final emitted = <String>{};
  // The single emission point: every wire message reports the record it
  // projects FROM (its own, or the covering checkpoint whose text rides
  // its position) — the record_tag alignment the session transcript and
  // the tag epoch share (GOAL #2394). `null` = a message that projects
  // from NO record (the #2394 fold pointer, deliberately untagged).
  void emit(SessionRecord? source, Message message) {
    messages.add(message);
    onMessage?.call(source, message);
  }

  for (final record in path) {
    final drop = droppedById[record.id];
    if (drop != null) {
      // The dropped fold's own marker/text never renders — the note
      // replaces it and the span it named renders unfolded.
      emit(record, _droppedFoldNote(drop, seqs));
      continue;
    }
    _projectRecord(
      record,
      state: state,
      byId: byId,
      seqs: seqs,
      emitted: emitted,
      hiddenCallIds: hiddenCallIds,
      projectEntry: projectEntry,
      emit: emit,
    );
  }
  return messages;
}

/// The visible resume note for a dropped fold (gh-1425 AC2): names the
/// dropped generation — fold kind, file position, why it dropped — so a
/// version-skewed fold can never vanish silently. Plain text, one wire
/// message at the fold's position.
Message _droppedFoldNote(DroppedFold drop, RecordSeqIndex seqs) {
  final record = drop.record;
  final seq = seqs.seqOf(record.id);
  final kind = switch (record) {
    HiddenRangeRecord() => 'hidden_range',
    CompactCheckpointRecord() => 'compact_checkpoint',
    SegmentPinRecord() => 'segment_pin',
    _ => record.type,
  };
  return UserMessage.text(
    '[resume] structured fold #${seq ?? '?'} ($kind) dropped: it carries '
    'no record ids (a shape an older build wrote — the fields this build '
    'reads are empty) — its span renders unfolded and no part of the fold '
    'was applied. The session file keeps every record.',
    timestamp: record.timestamp,
  );
}

/// Tool-call ids on hidden (or checkpoint-covered) assistant carriers —
/// their results are orphaned the moment the carrier leaves the wire.
Set<String> _hiddenToolCallIds(
  List<SessionRecord> path,
  StructuredViewState state,
) {
  final callIds = <String>{};
  for (final record in path) {
    final message = record is MessageRecord ? record.message : null;
    if (message is AssistantMessage &&
        (state.hiddenRecordIds.contains(record.id) ||
            state.isCovered(record.id))) {
      for (final block in message.content) {
        if (block is ToolCall) callIds.add(block.id);
      }
    }
  }
  return callIds;
}

/// One path record to its wire messages, reported through [emit] with
/// the record each message projects from.
void _projectRecord(
  SessionRecord record, {
  required StructuredViewState state,
  required Map<String, SessionRecord> byId,
  required RecordSeqIndex seqs,
  required Set<String> emitted,
  required Set<String> hiddenCallIds,
  required List<Message> Function(SessionRecord record) projectEntry,
  required void Function(SessionRecord? source, Message message) emit,
}) {
  // A covering checkpoint renders at the position of its first visible
  // path record (D2: markers sit where the content sat); null when the
  // record is not covered (or its checkpoint was itself hidden — then
  // the range renders as if uncovered).
  if (_coverAt(
    record,
    state: state,
    byId: byId,
    seqs: seqs,
    emitted: emitted,
    emit: emit,
  )) {
    return;
  }
  // GOAL #2394 (D5/AC9): a consolidated hidden range renders as ONE
  // marker at its carrier — the other members emit nothing here.
  if (_consolidatedAt(
    record,
    state: state,
    byId: byId,
    seqs: seqs,
    hiddenCallIds: hiddenCallIds,
    emit: emit,
  )) {
    return;
  }
  switch (record) {
    case HiddenRangeRecord():
      return;
    case CompactCheckpointRecord():
      _projectCheckpointRecord(
        record,
        state: state,
        byId: byId,
        seqs: seqs,
        emitted: emitted,
        emit: emit,
      );
    case MessageRecord():
      emit(
        record,
        _messageAt(
          record,
          state: state,
          seqs: seqs,
          hiddenCallIds: hiddenCallIds,
        ),
      );
    case CompactionRecord() || BranchSummaryRecord():
      for (final message in _legacyAt(
        record,
        state: state,
        seqs: seqs,
        projectEntry: projectEntry,
      )) {
        emit(record, message);
      }
    case CustomMessageRecord():
      for (final message in _customAt(
        record,
        state: state,
        seqs: seqs,
        projectEntry: projectEntry,
      )) {
        emit(record, message);
      }
    default:
      return;
  }
}

/// A checkpoint record at its own position: only when its range sits
/// fully off-branch (nothing visible triggered the in-place emission
/// through `_coverAt`); a hide targeting the checkpoint itself leaves no
/// marker, no swallow. A tail-layout checkpoint (GOAL #2394 D5) renders
/// ITS text here with the tagged hidden index — the range start carries
/// only the `[expand a-b]` pointer.
void _projectCheckpointRecord(
  CompactCheckpointRecord record, {
  required StructuredViewState state,
  required Map<String, SessionRecord> byId,
  required RecordSeqIndex seqs,
  required Set<String> emitted,
  required void Function(SessionRecord? source, Message message) emit,
}) {
  if (state.hiddenRecordIds.contains(record.id)) return;
  if (!emitted.add(record.id)) return;
  final tail = record.layout == compactCheckpointLayoutTail;
  emit(
    record,
    _checkpointMessage(
      record,
      byId: byId,
      seqs: seqs,
      state: state,
      taggedIndex: tail,
    ),
  );
}

/// Whether [record] is covered and its covering checkpoint rendered here
/// (through [emit]); `false` when it does not apply (not covered, the
/// covering checkpoint is itself hidden, or it was already emitted).
bool _coverAt(
  SessionRecord record, {
  required StructuredViewState state,
  required Map<String, SessionRecord> byId,
  required RecordSeqIndex seqs,
  required Set<String> emitted,
  required void Function(SessionRecord? source, Message message) emit,
}) {
  final cover = state.coveredRecordIds[record.id];
  if (cover == null || state.hiddenRecordIds.contains(cover.id)) {
    return false;
  }
  if (cover.layout == compactCheckpointLayoutTail) {
    // GOAL #2394 (D5): the text rides the checkpoint's OWN record (the
    // tail at run time); the range's first record carries only the
    // fold pointer — untagged, and emitted even when the checkpoint is
    // itself covered by a later one (a covered range stays folded; the
    // later checkpoint owns its own text).
    if (state.isCovered(cover.id)) return true;
    if (emitted.add('fold:${cover.id}')) {
      final startSeq = seqs.seqOf(cover.firstRecordId);
      final endSeq = seqs.seqOf(cover.lastRecordId);
      emit(
        null,
        UserMessage.text(
          expandMarker(from: startSeq ?? 0, to: endSeq ?? startSeq ?? 0),
          timestamp: record.timestamp,
        ),
      );
    }
    return true;
  }
  if (!emitted.add(cover.id) || state.isCovered(cover.id)) return true;
  emit(cover, _checkpointMessage(cover, byId: byId, seqs: seqs, state: state));
  return true;
}

/// GOAL #2394 (D5/AC9): whether [record] belongs to a consolidated
/// hidden range and was rendered by that fact — ONE `[expand a-b]`
/// marker at the range's carrier (its first member the path still
/// renders), nothing at the other members. A tool result whose carrier
/// stays visible keeps its own tool_result marker: the pair must stay
/// on the wire (#85). `false` when the range does not apply.
bool _consolidatedAt(
  SessionRecord record, {
  required StructuredViewState state,
  required Map<String, SessionRecord> byId,
  required RecordSeqIndex seqs,
  required Set<String> hiddenCallIds,
  required void Function(SessionRecord? source, Message message) emit,
}) {
  final range = state.consolidatedRanges[record.id];
  if (range == null) return false;
  final members = range.recordIds.toList()
    ..sort((a, b) => (seqs.seqOf(a) ?? 0).compareTo(seqs.seqOf(b) ?? 0));
  // The carrier: the first member the path still renders (a member a
  // later checkpoint swallowed cannot carry the marker).
  SessionRecord? carrier;
  for (final id in members) {
    final member = byId[id];
    if (member == null || state.isCovered(id)) continue;
    carrier = member;
    break;
  }
  if (carrier != null && carrier.id == record.id) {
    final seqs_ = [
      for (final id in members)
        if (byId.containsKey(id)) ?seqs.seqOf(id),
    ]..sort();
    emit(
      record,
      UserMessage(
        content: consolidatedHideMarker(
          from: seqs_.firstOrNull ?? 0,
          to: seqs_.lastOrNull,
          label: range.labels[record.id],
        ),
        timestamp: record.timestamp,
      ),
    );
    return true;
  }
  final message = record is MessageRecord ? record.message : null;
  if (message is ToolResultMessage &&
      record is MessageRecord &&
      !hiddenCallIds.contains(message.toolCallId)) {
    emit(
      record,
      _messageAt(
        record,
        state: state,
        seqs: seqs,
        hiddenCallIds: hiddenCallIds,
      ),
    );
  }
  return true;
}

/// A [CustomMessageRecord] to its wire message: host-injected context
/// must never silently vanish on a structured branch — hidden customs
/// render as notice markers, visible ones project through the classic
/// per-record projection.
List<Message> _customAt(
  CustomMessageRecord record, {
  required StructuredViewState state,
  required RecordSeqIndex seqs,
  required List<Message> Function(SessionRecord record) projectEntry,
}) {
  if (!state.hiddenRecordIds.contains(record.id)) return projectEntry(record);
  return [
    UserMessage(
      content: hiddenMarker(
        seq: seqs.seqOf(record.id) ?? 0,
        kind: markerKinds.notice,
        tokens: recordTokens(record),
      ),
      timestamp: record.timestamp,
    ),
  ];
}

/// A [MessageRecord] to its wire message: hidden and orphaned records
/// become markers, everything else passes through untouched.
Message _messageAt(
  MessageRecord record, {
  required StructuredViewState state,
  required RecordSeqIndex seqs,
  required Set<String> hiddenCallIds,
}) {
  final message = record.message;
  final seq = seqs.seqOf(record.id);
  final hidden = state.hiddenRecordIds.contains(record.id) && seq != null;
  // A visible result whose call was hidden or swallowed by a
  // checkpoint cannot stay a tool_result on the wire — it renders
  // as a user-role marker (its content stays expandable).
  final orphaned =
      message is ToolResultMessage &&
      hiddenCallIds.contains(message.toolCallId);
  return hidden || orphaned
      ? _hiddenMessage(
          record,
          message,
          seq ?? 0,
          orphaned: orphaned,
          pinned: state.pinnedRecordIds.contains(record.id),
        )
      : message;
}

/// A classic compaction or branch-summary record: hidden → marker,
/// visible → the classic projection.
List<Message> _legacyAt(
  SessionRecord record, {
  required StructuredViewState state,
  required RecordSeqIndex seqs,
  required List<Message> Function(SessionRecord record) projectEntry,
}) {
  final seq = seqs.seqOf(record.id);
  if (state.hiddenRecordIds.contains(record.id) && seq != null) {
    return [
      UserMessage.text(
        hiddenMarker(
          seq: seq,
          kind: markerKindFor(record),
          tokens: recordTokens(record),
          preview: markerPreview(recordPreviewSource(record)),
        ),
        timestamp: record.timestamp,
      ),
    ];
  }
  return projectEntry(record);
}

Message _checkpointMessage(
  CompactCheckpointRecord record, {
  required StructuredViewState state,
  required Map<String, SessionRecord> byId,
  required RecordSeqIndex seqs,
  bool taggedIndex = false,
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
    if (covered != null) coveredTokens += recordTokens(covered);
  }
  // Issue #1131: sanitize once — the header's token estimate must describe
  // the text actually rendered, not the raw (possibly poisoned) record.
  final text = sanitizeSummary(record.text).text;
  final header = checkpointMarkerHeader(
    startSeq: startSeq,
    endSeq: endSeq,
    coveredTokens: coveredTokens,
    textTokens: estimateTokens(UserMessage.text(text)),
    coversRanges: idsToRanges(covers),
  );
  final index = hiddenIndexSection(
    [
      // Consolidated markers (issue #387) are not re-listed: a checkpoint
      // over a marker run would otherwise reproduce every marker line
      // inside itself and never shrink. The header's covers ranges keep
      // every id expandable.
      for (final id in record.coversRecordIds)
        if (!state.hiddenRecordIds.contains(id)) ?byId[id],
    ],
    seqs,
    tagged: taggedIndex,
  );
  return UserMessage.text('$header\n$text$index', timestamp: record.timestamp);
}

/// Builds the marker replacement for a hidden [MessageRecord].
Message _hiddenMessage(
  MessageRecord record,
  Message message,
  int seq, {
  required bool orphaned,
  required bool pinned,
}) {
  final preview = markerPreview(recordPreviewSource(record));
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
              preview: preview,
              pinned: pinned,
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
          preview: preview,
          pinned: pinned,
        ),
        timestamp: message.timestamp,
      );
    case AssistantMessage():
      return UserMessage.text(
        hiddenMarker(
          seq: seq,
          kind: markerKinds.assistant,
          tokens: estimateTokens(message),
          preview: preview,
          pinned: pinned,
        ),
        timestamp: message.timestamp,
      );
    default:
      return UserMessage.text(
        hiddenMarker(
          seq: seq,
          kind: markerKinds.user,
          tokens: estimateTokens(message),
          preview: preview,
          pinned: pinned,
        ),
        timestamp: message.timestamp,
      );
  }
}

/// The kind label a record shows in markers and the hidden-segment index.
String markerKindFor(SessionRecord record) => switch (record) {
  MessageRecord(:final message) => switch (message) {
    UserMessage() => markerKinds.user,
    AssistantMessage() => markerKinds.assistant,
    ToolResultMessage() => markerKinds.toolResult,
    _ => message.role,
  },
  CustomMessageRecord() => markerKinds.notice,
  CompactCheckpointRecord() => markerKinds.checkpoint,
  CompactionRecord() => markerKinds.legacyCheckpoint,
  BranchSummaryRecord() => markerKinds.branchSummary,
  _ => 'system',
};

/// The flat text a record's preview draws from — the record's own
/// content, wrapper stripped. Image blocks collapse to their kind-named
/// placeholder (E3), so a preview never carries base64.
String recordPreviewSource(SessionRecord record) => switch (record) {
  MessageRecord(:final message) => switch (message) {
    UserMessage(:final content) => _previewUserText(content),
    ToolResultMessage(:final content) => _previewBlocks(content),
    AssistantMessage(:final content) => _previewBlocks(content),
    _ => message.role,
  },
  CustomMessageRecord(:final content) => _previewUserText(content),
  CompactCheckpointRecord(:final text) => text,
  CompactionRecord(:final summary) => summary,
  BranchSummaryRecord(:final summary) => summary,
  _ => '',
};

String _previewUserText(Object content) =>
    content is String ? content : _previewBlocks(content as List<ContentBlock>);

String _previewBlocks(List<ContentBlock> blocks) => [
  for (final block in blocks)
    switch (block) {
      TextContent(:final text) => text,
      ImageContent(:final mimeType) => imagePreview(mimeType),
      _ => '[${block.runtimeType}]',
    },
].join('\n');

/// The hidden-segments index heading the agent consults (issue #266 F1a).
const hiddenIndexHeading = 'hidden segments (compact_expand reopens any id):';

/// One marker line per [records] — id, kind, size, preview — appended
/// under a summary so history folded away stays consultable and
/// expandable. Empty string when nothing survives resolution.
String hiddenIndexSection(
  Iterable<SessionRecord> records,
  RecordSeqIndex seqs, {
  bool tagged = false,
}) {
  final lines = <String>[];
  for (final record in records) {
    final seq = seqs.seqOf(record.id);
    if (seq == null) continue;
    final preview = markerPreview(recordPreviewSource(record));
    lines.add(
      tagged
          // GOAL #2394: the tail-layout transfer record indexes its
          // range with the SAME `m<seq>` aliases the model reads the
          // tagged transcript by (the record_tag protocol) — kind, size
          // and preview unchanged.
          ? 'm$seq ${markerKindFor(record)}·${formatMarkerTokens(recordTokens(record))}'
                '${preview.isEmpty ? '' : '·"$preview"'}'
          : hiddenMarker(
              seq: seq,
              kind: markerKindFor(record),
              tokens: recordTokens(record),
              preview: preview,
            ),
    );
  }
  return lines.isEmpty ? '' : '\n\n$hiddenIndexHeading\n${lines.join('\n')}';
}

int recordTokens(SessionRecord record) {
  switch (record) {
    case MessageRecord(:final message):
      return estimateTokens(message);
    case CustomMessageRecord(:final content):
      return estimateTokens(
        UserMessage(
          content: content,
          timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );
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

/// The projected wire cost of one hidden record (issue #387): its
/// one-line marker message — the marker is what rides the wire after a
/// hide pass, so checkpoint selection weighs hidden records at the
/// marker size, not the original payload size.
int hiddenMarkerTokens(SessionRecord record, int seq) => estimateTokens(
  UserMessage.text(
    hiddenMarker(
      seq: seq,
      kind: markerKindFor(record),
      tokens: recordTokens(record),
      preview: markerPreview(recordPreviewSource(record)),
    ),
  ),
);
