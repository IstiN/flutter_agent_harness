/// The session tree: navigation, labels, and context rebuild on top of
/// [SessionStorage].
///
/// Ported from pi-mono `packages/agent/src/harness/session/session.ts`
/// (`Session`, `buildSessionContext`, `defaultContextEntryTransform`) and
/// `harness/messages.ts` (the summary prefixes). A session is an append-only
/// tree of records: messages chain through `parentId`, `leaf` records move
/// the active branch, and the model context is rebuilt by walking the active
/// branch from leaf to root.
library;

import '../compaction/structured/projection.dart';
import '../compaction/summary_sanitizer.dart';
import '../context.dart';
import '../exceptions.dart';
import '../types.dart';
import 'obligations_ledger.dart';
import 'session_record.dart';
import 'session_storage.dart';
import 'windowed_session_storage.dart';

/// Prefix wrapping a compaction summary when it is projected into the model
/// context. Ported from pi's `COMPACTION_SUMMARY_PREFIX`.
const compactionSummaryPrefix =
    'The conversation history before this point was compacted into the '
    'following summary:\n\n<summary>\n';

/// Suffix closing [compactionSummaryPrefix]. Ported from pi's
/// `COMPACTION_SUMMARY_SUFFIX`.
const compactionSummarySuffix = '\n</summary>';

/// Prefix wrapping a branch summary when it is projected into the model
/// context. Ported from pi's `BRANCH_SUMMARY_PREFIX`.
const branchSummaryPrefix =
    'The following is a summary of a branch that this conversation came '
    'back from:\n\n<summary>\n';

/// Suffix closing [branchSummaryPrefix]. Ported from pi's
/// `BRANCH_SUMMARY_SUFFIX`.
const branchSummarySuffix = '\n</summary>';

/// The model binding a session's active branch was recorded with: the
/// provider kind and model id, plus — when the leaf record was a
/// gh-1000 `model_change` — the serving endpoint and the saved
/// custom-provider ENTRY NAME that pinned the key. Public so consumers
/// of [SessionContext.model] (the CLI restore, the Flutter app) share
/// one shape instead of re-spelling the record type.
typedef SessionModelPin = ({
  String provider,
  String modelId,
  String? baseUrl,
  String? customProvider,
});

/// The model-derived state of a session along the active branch.
///
/// Ported from pi's `SessionContext`.
final class SessionContext {
  /// Creates a [SessionContext].
  const SessionContext({
    required this.messages,
    required this.thinkingLevel,
    required this.model,
    required this.activeToolNames,
  });

  /// The rebuilt conversation context, oldest first.
  final List<Message> messages;

  /// The thinking level in effect at the leaf (`off` by default).
  final String thinkingLevel;

  /// The model in effect at the leaf, from the last `model_change` record
  /// or assistant message. [baseUrl]/[customProvider] carry the serving
  /// endpoint and saved custom-provider entry when the last record was a
  /// gh-1000 model_change (a restore re-resolves onto that entry);
  /// assistant-message-derived models carry neither.
  final SessionModelPin? model;

  /// The active tool names in effect at the leaf, if ever set.
  final List<String>? activeToolNames;
}

/// A session: an append-only tree of records with an active leaf.
///
/// Ported from pi's `Session` class. All reads go through the storage's
/// in-memory index; all writes append to the underlying JSONL file.
final class Session {
  /// Creates a [Session] over [storage]. [customRecordScan], when given
  /// (the JSONL repo injects itself), lets the session read `custom`
  /// records RESIDENCY can hide — the windowed tail drops side-leaf and
  /// below-tail records from `getEntries()` (issue #488 class), while the
  /// raw scan streams the whole file chain. The obligations ledger's
  /// projection fallback is the consumer.
  Session(this._storage, {this.customRecordScan});

  final SessionStorage _storage;

  /// Raw `custom`-record scan over the full session file chain, keyed by
  /// record type. Null when the session was built without a repo behind
  /// it (direct constructions in tools/tests) — consumers then degrade to
  /// the resident view only.
  final Future<List<CustomRecord>> Function(Set<String> types)?
      customRecordScan;

  /// Cached result of the one-time obligations scan fallback (null =
  /// not scanned yet; a scanned-empty result is cached too). Resident
  /// appends always win over it, so no invalidation is needed.
  ObligationsLedger? _obligationsFromScan;

  /// The obligations ledger from the raw scan fallback, or null when no
  /// scan hook exists / was already consulted and found nothing new.
  /// Runs at most once per session instance.
  Future<ObligationsLedger?> _scanObligationsLedger() async {
    if (_obligationsFromScan != null) return _obligationsFromScan;
    final scan = customRecordScan;
    if (scan == null) return null;
    final records = await scan({obligationsLedgerRecordType});
    return _obligationsFromScan = records.isEmpty
        ? const ObligationsLedger([])
        : ObligationsLedger.fromPayload(records.last.data);
  }

  /// The session metadata (from the file header).
  Future<SessionMetadata> getMetadata() => _storage.getMetadata();

  /// The session id when the storage caches the header synchronously
  /// ([SessionHeaderCache] — the full [JsonlSessionStorage] and the
  /// windowed [WindowedSessionStorage] always do); `null` otherwise. Used
  /// as the prompt-cache affinity key, where a synchronous read lets
  /// provider stream functions resolve it per call without an async hop.
  String? get cachedId {
    final storage = _storage;
    if (storage case final SessionHeaderCache cached) {
      return cached.cachedMetadata.id;
    }
    return null;
  }

  /// The session metadata when the storage caches the header synchronously
  /// ([SessionHeaderCache]) — used for the session-scoped
  /// `.tools/<sessionId>.yaml` path, which is derived from the session
  /// file's location; `null` otherwise.
  SessionMetadata? get cachedMetadata {
    final storage = _storage;
    if (storage case final SessionHeaderCache cached) {
      return cached.cachedMetadata;
    }
    return null;
  }

  /// The underlying storage.
  SessionStorage getStorage() => _storage;

  /// The id of the active leaf record, or `null` at the tree root.
  Future<String?> getLeafId() => _storage.getLeafId();

  /// Looks up a record by id.
  Future<SessionRecord?> getEntry(String id) => _storage.getEntry(id);

  /// All records in file order.
  Future<List<SessionRecord>> getEntries() => _storage.getEntries();

  /// The records of the active branch (or of the branch ending at
  /// [fromId]), root-first.
  Future<List<SessionRecord>> getBranch({String? fromId}) async {
    final leafId = fromId ?? await _storage.getLeafId();
    return _storage.getPathToRoot(leafId);
  }

  /// The direct children of [parentId] (roots when `null`), in file order.
  Future<List<SessionRecord>> getChildren(String? parentId) async {
    return [
      for (final entry in await _storage.getEntries())
        if (entry.parentId == parentId) entry,
    ];
  }

  /// The current label attached to record [id], if any.
  Future<String?> getLabel(String id) => _storage.getLabel(id);

  /// The session's display name (last `session_info` record wins).
  Future<String?> getSessionName() async {
    final entries = await _storage.findEntries('session_info');
    if (entries.isEmpty) return null;
    final name = (entries.last as SessionInfoRecord).name?.trim();
    return name != null && name.isNotEmpty ? name : null;
  }

  /// The session's display name, paging older chunks when the last
  /// `session_info` record sits outside a windowed storage's resident
  /// tail (a name written long before the newest records). [maxPages]
  /// bounds the scan for pathological files.
  Future<String?> resolveSessionName({int maxPages = 64}) async {
    var name = await getSessionName();
    final storage = _storage;
    var pages = 0;
    while (name == null && pages < maxPages) {
      if (storage is! WindowedSessionStorage) break;
      if (!storage.hasOlder) break;
      pages++;
      await storage.loadOlder();
      name = await getSessionName();
    }
    return name;
  }

  /// Pages older chunks into a windowed storage until the newest
  /// compaction record is resident — the "open from the end, up to the
  /// compaction" resume (owner directive): a marathon session opens in
  /// O(tail-after-compaction) instead of parsing gigabytes. Stops when
  /// the active branch carries a [CompactionRecord], when [tokenBudget]
  /// is already covered by the resident tail, or when the file start is
  /// reached (sessions without compaction page everything, as before).
  /// A no-op for full storages. [maxPages] bounds pathological files.
  ///
  /// The walk keeps the TAIL ANCHORED (WindowedSessionStorage.
  /// growOlderUntil suspends the residency eviction): the previous
  /// loadOlder-based loop slid the newest side out on the first chunk —
  /// the branch read empty and every deep-boundary resume fell back to
  /// a full open (10s+ on a 1.4 GB live session). Returns false only on
  /// [maxPages] exhaustion — the caller's documented full-open fallback;
  /// a genuinely empty session reports `true`.
  ///
  /// [tokenBudget] (issue #503) stops the walk as soon as the resident
  /// tail's estimated context tokens cover the model's window — a resume
  /// needs only what fits the context, and older history pages in lazily
  /// through the scrollback's loadOlder path. `null` walks to the
  /// boundary/file head as before.
  Future<bool> ensureCompactionBoundaryResident({
    int maxPages = 512,
    int? tokenBudget,
  }) async {
    final storage = _storage;
    if (storage is! WindowedSessionStorage) return true;
    return storage.growOlderUntil(
      (r) => r is CompactionRecord,
      maxPages: maxPages,
      tokenBudget: tokenBudget,
    );
  }

  Future<String> _append(
    SessionRecord Function(String id, String? parentId) build,
  ) async {
    final record = build(
      await _storage.createEntryId(),
      await _storage.getLeafId(),
    );
    await _storage.appendEntry(record);
    return record.id;
  }

  /// Appends a conversation message at the active leaf. Returns the new
  /// record id.
  Future<String> appendMessage(Message message) {
    return _append(
      (id, parentId) => MessageRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        message: message,
      ),
    );
  }

  /// Appends a structured-compaction hide event (issue #148 pass 1): the
  /// records in [recordIds] keep living in the file but project as
  /// one-line markers. Ids must be stable record ids of records already on
  /// the append path — never positions.
  Future<String> appendHiddenRange({required List<String> recordIds}) {
    return _append(
      (id, parentId) => HiddenRangeRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        recordIds: recordIds,
      ),
    );
  }

  /// Appends a structured-compaction checkpoint (issue #148 pass 2): the
  /// range [firstRecordId, lastRecordId] stops rendering individually and
  /// is replaced by [text]; [coversRecordIds] names every hidden segment
  /// the checkpoint subsumes, [flattenedRecordIds] the inner checkpoints
  /// folded in by the depth cap.
  Future<String> appendCompactCheckpoint({
    required String firstRecordId,
    required String lastRecordId,
    required String text,
    required List<String> coversRecordIds,
    required List<String> flattenedRecordIds,
  }) {
    return _append(
      (id, parentId) => CompactCheckpointRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        firstRecordId: firstRecordId,
        lastRecordId: lastRecordId,
        text: text,
        coversRecordIds: coversRecordIds,
        flattenedRecordIds: flattenedRecordIds,
      ),
    );
  }

  /// Appends a segment pin event (issue #1379 tier 2): the records in
  /// [recordIds] become immune to every hide/compact path until an unpin
  /// event names them again. Recorded over stable record ids — replay
  /// applies pin records in file order, last one wins.
  Future<String> appendSegmentPin({
    required List<String> recordIds,
    required bool pinned,
  }) {
    return _append(
      (id, parentId) => SegmentPinRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        recordIds: recordIds,
        pinned: pinned,
      ),
    );
  }

  /// Appends a thinking-level change. Returns the new record id.
  Future<String> appendThinkingLevelChange(String thinkingLevel) {
    return _append(
      (id, parentId) => ThinkingLevelChangeRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        thinkingLevel: thinkingLevel,
      ),
    );
  }

  /// Appends a model change. Returns the new record id. [baseUrl] and
  /// [customProvider] pin the serving endpoint and the saved custom
  /// provider entry (gh-1000) so a restore re-resolves onto the same
  /// provider+key binding; leave both null for catalog-default switches.
  Future<String> appendModelChange({
    required String provider,
    required String modelId,
    String? baseUrl,
    String? customProvider,
  }) {
    return _append(
      (id, parentId) => ModelChangeRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        provider: provider,
        modelId: modelId,
        baseUrl: baseUrl,
        customProvider: customProvider,
      ),
    );
  }

  /// Appends an active-tools change. Returns the new record id.
  Future<String> appendActiveToolsChange(List<String> activeToolNames) {
    return _append(
      (id, parentId) => ActiveToolsChangeRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        activeToolNames: [...activeToolNames],
      ),
    );
  }

  /// Appends a compaction record. Returns the new record id.
  ///
  /// Written by the compaction pipeline; see [CompactionRecord].
  Future<String> appendCompaction({
    required String summary,
    required String firstKeptEntryId,
    required int tokensBefore,
    Object? details,
    bool? fromHook,
  }) {
    return _append(
      (id, parentId) => CompactionRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        summary: summary,
        firstKeptEntryId: firstKeptEntryId,
        tokensBefore: tokensBefore,
        details: details,
        fromHook: fromHook,
      ),
    );
  }

  /// Appends an application-defined record that stays out of model context.
  /// Returns the new record id.
  Future<String> appendCustomEntry({required String customType, Object? data}) {
    return _append(
      (id, parentId) => CustomRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        customType: customType,
        data: data,
      ),
    );
  }

  /// Appends a checkpoint mark for the `checkpoint`/`rewind` tools. Returns
  /// the new record id — the rewind uses it as the session-tree branch anchor.
  /// See [CheckpointRecord].
  Future<String> appendCheckpoint({required int messageCount, String? goal}) {
    return _append(
      (id, parentId) => CheckpointRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        messageCount: messageCount,
        goal: goal,
      ),
    );
  }

  /// Appends an application-defined record that projects into model context
  /// as a user message. [content] is a [String] or a `List<ContentBlock>`.
  /// Returns the new record id.
  Future<String> appendCustomMessageEntry({
    required String customType,
    required Object content,
    required bool display,
    Object? details,
  }) {
    return _append(
      (id, parentId) => CustomMessageRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        customType: customType,
        content: content,
        display: display,
        details: details,
      ),
    );
  }

  /// Attaches (or removes, when [label] is null) a label to [targetId].
  /// Returns the new record id.
  Future<String> appendLabel(String targetId, String? label) async {
    if (await _storage.getEntry(targetId) == null) {
      throw SessionException(
        'Entry $targetId not found',
        code: SessionErrorCode.notFound,
      );
    }
    return _append(
      (id, parentId) => LabelRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        targetId: targetId,
        label: label,
      ),
    );
  }

  /// Sets the session display name (newlines are sanitized away).
  Future<String> appendSessionName(String name) {
    final sanitized = name.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    return _append(
      (id, parentId) => SessionInfoRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        name: sanitized,
      ),
    );
  }

  /// Moves the active leaf to [entryId] (or the tree root when `null`),
  /// appending a `leaf` record. When [summary] is provided, also appends a
  /// `branch_summary` record and returns its id; otherwise returns `null`.
  ///
  /// Ported from pi's `Session.moveTo`.
  Future<String?> moveTo(
    String? entryId, {
    String? summary,
    Object? details,
    bool? fromHook,
  }) async {
    if (entryId != null && await _storage.getEntry(entryId) == null) {
      throw SessionException(
        'Entry $entryId not found',
        code: SessionErrorCode.notFound,
      );
    }
    await _storage.setLeafId(entryId);
    if (summary == null) return null;
    final record = BranchSummaryRecord(
      id: await _storage.createEntryId(),
      parentId: entryId,
      timestamp: DateTime.now(),
      fromId: entryId ?? 'root',
      summary: summary,
      details: details,
      fromHook: fromHook,
    );
    await _storage.appendEntry(record);
    return record.id;
  }

  /// Rebuilds the model context from the active branch: messages in branch
  /// order, with compaction, branch-summary, and custom-message records
  /// projected per pi's `buildSessionContext` + `convertToLlm`.
  Future<List<Message>> buildContextMessages() async {
    final path = await getBranch();
    final (kept, dropped) = _applyCompactionTransform(path);
    return _projectMessages(kept, classicHidden: dropped);
  }

  /// Projects an explicit record path (root-first) into messages — the
  /// same fold [buildContext] applies to the storage-walked branch. The
  /// windowed host keeps its own accumulated view path (storage residency
  /// is tail-anchored and drops old records), so the transcript renders
  /// through this instead of a second storage walk.
  List<Message> projectPath(List<SessionRecord> path) {
    final (kept, _) = _applyCompactionTransform(path);
    return [for (final entry in kept) ..._entryToMessages(entry)];
  }

  /// Rebuilds the full [SessionContext] (messages plus derived model state)
  /// for the active branch.
  Future<SessionContext> buildContext() async {
    final path = await getBranch();
    final state = _deriveState(path);
    final (kept, dropped) = _applyCompactionTransform(path);
    return SessionContext(
      messages: await _projectMessages(kept, classicHidden: dropped),
      thinkingLevel: state.thinkingLevel,
      model: state.model,
      activeToolNames: state.activeToolNames,
    );
  }

  /// Projects a classic-transformed path into messages. Branches carrying
  /// structured-compaction records render through the structured
  /// projection (hidden markers + checkpoints); everything else keeps the
  /// classic shape byte-for-byte.
  ///
  /// A structured record dropped by a later classic fallback compaction
  /// (records before `firstKeptEntryId`) loses its effect on the kept
  /// region — benign: the covered records simply render fully again, and
  /// the next structured pass re-derives hides from scratch.
  ///
  /// [classicHidden] are the records a classic summary folded away; they
  /// ride the summary as a hidden-segments index (issue #266 F1a) so the
  /// agent can consult and reopen what it can no longer see.
  Future<List<Message>> _projectMessages(
    List<SessionRecord> path, {
    List<SessionRecord> classicHidden = const [],
  }) async {
    final hasStructured = path.any(
      (entry) => entry is HiddenRangeRecord || entry is CompactCheckpointRecord,
    );
    if (!hasStructured) {
      if (classicHidden.isEmpty) {
        return _withObligationsBlock([
          for (final entry in path) ..._entryToMessages(entry),
        ]);
      }
      final seqs = RecordSeqIndex(await getEntries());
      return _withObligationsBlock([
        for (final entry in path)
          ..._entryToMessages(entry, classicHidden: classicHidden, seqs: seqs),
      ]);
    }
    final entries = await getEntries();
    final seqs = RecordSeqIndex(entries);
    return _withObligationsBlock(
      renderStructuredMessages(
        path: path,
        seqs: seqs,
        projectEntry: (record) =>
            _entryToMessages(record, classicHidden: classicHidden, seqs: seqs),
      ),
      entries: entries,
    );
  }

  /// Appends the obligations ledger block (issue #1380 A1) at level 0 —
  /// after every projected message, outside any hidden range or checkpoint
  /// span, so compaction at any depth can never sink it. Presence-gated on
  /// the session's latest `obligations_ledger` snapshot: a session without
  /// one (classic engine, E3) projects exactly as before.
  ///
  /// The resident lookup first; when residency shows NO snapshot and the
  /// storage is windowed, the raw-scan fallback runs once (cached) — the
  /// latest snapshot routinely lies below a windowed tail, and dropping
  /// the block there would sink every obligation under it (#488 class).
  /// A full-open storage's resident view is the whole file — no scan.
  Future<List<Message>> _withObligationsBlock(
    List<Message> messages, {
    List<SessionRecord>? entries,
  }) async {
    var ledger = latestObligationsLedgerIn(entries ?? await getEntries());
    if (ledger == null && _storage is WindowedSessionStorage) {
      ledger = await _scanObligationsLedger();
    }
    if (ledger == null || ledger.isEmpty) return messages;
    final block = renderObligationsBlock(ledger);
    if (block.isEmpty) return messages;
    return [...messages, UserMessage.text(block)];
  }

  ({
    String thinkingLevel,
    SessionModelPin? model,
    List<String>? activeToolNames,
  })
  _deriveState(List<SessionRecord> path) {
    var thinkingLevel = 'off';
    SessionModelPin? model;
    List<String>? activeToolNames;
    for (final entry in path) {
      switch (entry) {
        case ThinkingLevelChangeRecord record:
          thinkingLevel = record.thinkingLevel;
        case ModelChangeRecord record:
          model = (
            provider: record.provider,
            modelId: record.modelId,
            baseUrl: record.baseUrl,
            customProvider: record.customProvider,
          );
        case MessageRecord(message: AssistantMessage record):
          // gh-1226: a turn answers with the serving endpoint/entry the
          // last model_change recorded — wiping the pin here made a
          // session restored after several turns fall back to the
          // launch-default provider on the mail-wake turn. The message
          // carries provider/modelId only; baseUrl/customProvider carry
          // forward from the pin in effect — but ONLY when this turn was
          // actually served by the pinned provider: the provider queue's
          // sticky-cursor failover and roles-mode per-turn rotation swap
          // the serving model with NO model_change record in between,
          // and carrying the pin then would fuse the old provider's
          // endpoint/entry onto the new one (the same cross-provider
          // fusion class gh-1226 AC2 fixes — review thread).
          final carriesForward = record.provider == model?.provider;
          model = (
            provider: record.provider,
            modelId: record.model,
            baseUrl: carriesForward ? model?.baseUrl : null,
            customProvider: carriesForward ? model?.customProvider : null,
          );
        case ActiveToolsChangeRecord record:
          activeToolNames = [...record.activeToolNames];
        default:
      }
    }
    return (
      thinkingLevel: thinkingLevel,
      model: model,
      activeToolNames: activeToolNames,
    );
  }

  /// The classic compaction cut: everything before the LAST
  /// [CompactionRecord]'s first-kept entry drops away; returns
  /// `(kept, dropped)` — dropped is what the summary folded away
  /// (issue #266 F1a). A path with no classic compaction passes through
  /// unchanged.
  (List<SessionRecord>, List<SessionRecord>) _applyCompactionTransform(
    List<SessionRecord> path,
  ) {
    CompactionRecord? compaction;
    var compactionIndex = -1;
    for (var i = 0; i < path.length; i++) {
      if (path[i] is CompactionRecord) {
        compaction = path[i] as CompactionRecord;
        compactionIndex = i;
      }
    }
    if (compaction == null) return (path, const []);
    final kept = <SessionRecord>[compaction];
    final dropped = <SessionRecord>[];
    var foundFirstKept = false;
    for (var i = 0; i < compactionIndex; i++) {
      if (path[i].id == compaction.firstKeptEntryId) foundFirstKept = true;
      if (foundFirstKept) {
        kept.add(path[i]);
      } else {
        dropped.add(path[i]);
      }
    }
    for (var i = compactionIndex + 1; i < path.length; i++) {
      kept.add(path[i]);
    }
    return (kept, dropped);
  }

  List<Message> _entryToMessages(
    SessionRecord entry, {
    List<SessionRecord> classicHidden = const [],
    RecordSeqIndex? seqs,
  }) {
    return switch (entry) {
      MessageRecord(:final message) => [message],
      CustomMessageRecord(:final content, :final timestamp) => [
        UserMessage(content: content, timestamp: timestamp),
      ],
      CompactionRecord(:final summary, :final timestamp) => [
        UserMessage.text(
          '$compactionSummaryPrefix'
          '${sanitizeSummary(summary).text}'
          '$compactionSummarySuffix'
          '${_classicHiddenIndex(classicHidden, seqs)}',
          timestamp: timestamp,
        ),
      ],
      BranchSummaryRecord(:final summary, :final timestamp) =>
        summary.isEmpty
            ? const []
            : [
                UserMessage.text(
                  '$branchSummaryPrefix'
                  '${sanitizeSummary(summary).text}'
                  '$branchSummarySuffix',
                  timestamp: timestamp,
                ),
              ],
      _ => const [],
    };
  }

  /// The hidden-segments index a classic summary carries (issue #266
  /// F1a) — empty unless the cut actually folded records away.
  String _classicHiddenIndex(
    List<SessionRecord> hidden,
    RecordSeqIndex? seqs,
  ) => seqs == null || hidden.isEmpty ? '' : hiddenIndexSection(hidden, seqs);
}
