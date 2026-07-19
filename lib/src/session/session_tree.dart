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

import '../context.dart';
import '../exceptions.dart';
import '../types.dart';
import 'session_record.dart';
import 'session_storage.dart';

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
  /// or assistant message.
  final ({String provider, String modelId})? model;

  /// The active tool names in effect at the leaf, if ever set.
  final List<String>? activeToolNames;
}

/// A session: an append-only tree of records with an active leaf.
///
/// Ported from pi's `Session` class. All reads go through the storage's
/// in-memory index; all writes append to the underlying JSONL file.
final class Session {
  /// Creates a [Session] over [storage].
  const Session(this._storage);

  final SessionStorage _storage;

  /// The session metadata (from the file header).
  Future<SessionMetadata> getMetadata() => _storage.getMetadata();

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

  /// Appends a model change. Returns the new record id.
  Future<String> appendModelChange({
    required String provider,
    required String modelId,
  }) {
    return _append(
      (id, parentId) => ModelChangeRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.now(),
        provider: provider,
        modelId: modelId,
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
    return [
      for (final entry in _applyCompactionTransform(path))
        ..._entryToMessages(entry),
    ];
  }

  /// Rebuilds the full [SessionContext] (messages plus derived model state)
  /// for the active branch.
  Future<SessionContext> buildContext() async {
    final path = await getBranch();
    final state = _deriveState(path);
    return SessionContext(
      messages: [
        for (final entry in _applyCompactionTransform(path))
          ..._entryToMessages(entry),
      ],
      thinkingLevel: state.thinkingLevel,
      model: state.model,
      activeToolNames: state.activeToolNames,
    );
  }

  ({
    String thinkingLevel,
    ({String provider, String modelId})? model,
    List<String>? activeToolNames,
  })
  _deriveState(List<SessionRecord> path) {
    var thinkingLevel = 'off';
    ({String provider, String modelId})? model;
    List<String>? activeToolNames;
    for (final entry in path) {
      switch (entry) {
        case ThinkingLevelChangeRecord record:
          thinkingLevel = record.thinkingLevel;
        case ModelChangeRecord record:
          model = (provider: record.provider, modelId: record.modelId);
        case MessageRecord(message: AssistantMessage record):
          model = (provider: record.provider, modelId: record.model);
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

  List<SessionRecord> _applyCompactionTransform(List<SessionRecord> path) {
    CompactionRecord? compaction;
    for (final entry in path) {
      if (entry is CompactionRecord) compaction = entry;
    }
    if (compaction == null) return [...path];
    final entries = <SessionRecord>[compaction];
    final compactionIndex = path.indexOf(compaction);
    var foundFirstKept = false;
    for (var i = 0; i < compactionIndex; i++) {
      final entry = path[i];
      if (entry.id == compaction.firstKeptEntryId) foundFirstKept = true;
      if (foundFirstKept) entries.add(entry);
    }
    for (var i = compactionIndex + 1; i < path.length; i++) {
      entries.add(path[i]);
    }
    return entries;
  }

  List<Message> _entryToMessages(SessionRecord entry) {
    return switch (entry) {
      MessageRecord(:final message) => [message],
      CustomMessageRecord(:final content, :final timestamp) => [
        UserMessage(content: content, timestamp: timestamp),
      ],
      CompactionRecord(:final summary, :final timestamp) => [
        UserMessage.text(
          '$compactionSummaryPrefix$summary$compactionSummarySuffix',
          timestamp: timestamp,
        ),
      ],
      BranchSummaryRecord(:final summary, :final timestamp) =>
        summary.isEmpty
            ? const []
            : [
                UserMessage.text(
                  '$branchSummaryPrefix$summary$branchSummarySuffix',
                  timestamp: timestamp,
                ),
              ],
      _ => const [],
    };
  }
}
