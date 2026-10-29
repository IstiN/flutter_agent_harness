/// Host wiring helpers for the subagent lifecycle tools (issue #222):
/// reopening a child's JSONL session by path and reading its recent
/// messages. Hosts that retain real JSONL child sessions (the CLI/TUI)
/// wire these one-liners into `subagentMonitoringTools` and
/// `TaskToolConfig.childSessionOpener` so `task_send`/`task_observe`/
/// `task_resume` work instead of reporting "not available on this host".
library;

import '../context.dart';
import '../env/execution_env.dart';
import '../session/session_record.dart';
import '../session/session_storage.dart';
import '../session/session_repo.dart';
import '../session/session_tree.dart';
import '../session_io_retry.dart';
import '../types.dart';
import 'deliverables.dart' show deliverableArtifactRecordType;
import 'subagent_manager.dart' show subagentRegistryRecordType;
import 'subagent_tools.dart' show ChildMessageReader;

/// Opens a retained child session from its JSONL path (the value
/// [SubagentHandle.sessionId] carries after the executor attached the real
/// session). Used by the executor's resume path to continue a failed or
/// completed child in the SAME session file.
typedef ChildSessionOpener = Future<Session> Function(String sessionPath);

/// A [ChildSessionOpener] over plain JSONL session files.
///
/// [ioRetry] wires the transient-ENOENT retry of the reopen (issue #427):
/// the task-resume path rides a brief disappearance of the child's file
/// the same way every other session open does.
ChildSessionOpener jsonlChildSessionOpener(
  FileSystem fs, {
  SessionIoRetryConfig ioRetry = const SessionIoRetryConfig(),
}) {
  return (sessionPath) async => Session(
    await JsonlSessionStorage.open(fs, sessionPath, ioRetry: ioRetry),
  );
}

/// The subagent registry rows of a parent session (issue #488 AC2).
///
/// Two restart-time losses are healed here:
/// - the `subagent_registry` snapshot is a side-leaf custom record, so
///   the windowed boot open never materializes it into
///   `Session.getEntries` — the raw file scan still sees it. The LAST
///   snapshot wins (every write carries the full row list).
/// - a child whose snapshot row was lost (a kill between spawn and
///   persist) but whose transcript exists is ADOPTED: the sessions tree
///   is scanned for child headers (`agent: subagent`, `parent:` this
///   session) missing from the snapshot rows. An adopted row becomes a
///   `completed` handle on its real JSONL path, so `task_send` /
///   `task_resume` address it instead of reporting "no subagent with id".
Future<List<Map<String, dynamic>>> subagentRegistryRows({
  required JsonlSessionRepo repo,
  required SessionMetadata parent,
}) async {
  final records = await repo.readCustomRecordsOfType(parent, {
    subagentRegistryRecordType,
  });
  final rows = [
    for (final item
        in (records.isEmpty ? null : records.last.data as List?) ?? const [])
      if (item is Map<String, dynamic>) item,
  ];
  final known = {for (final row in rows) row['id'] as String?};
  for (final meta in await repo.list(cwd: parent.cwd)) {
    final header = meta.metadata;
    if (header == null || header['agent'] != 'subagent') continue;
    if (header['parent'] != parent.id) continue;
    final id = header['id'];
    if (id is! String ||
        id.isEmpty ||
        known.contains(id) ||
        meta.path == parent.path) {
      continue;
    }
    rows.add({
      'id': id,
      'sessionId': meta.path,
      'createdAt': meta.createdAt.toIso8601String(),
    });
  }
  return rows;
}

/// The durable deliverable artifact rows of a parent session (gh-1956,
/// AC6): every spilled artifact persisted one `deliverable_artifact`
/// custom record per row, read back by RAW file scan (the windowed boot
/// open drops side-leaf custom records out of `getEntries` — the same
/// restart-time loss the registry healed in issue #488). Rows restore in
/// order; the capture's first-write-wins rule keeps a live spill newer.
Future<List<Map<String, dynamic>>> deliverableArtifactRows({
  required JsonlSessionRepo repo,
  required SessionMetadata parent,
}) async {
  final records = await repo.readCustomRecordsOfType(parent, {
    deliverableArtifactRecordType,
  });
  return [
    for (final record in records)
      if (record.data is Map<String, dynamic>)
        record.data as Map<String, dynamic>,
  ];
}

/// A [ChildMessageReader] over plain JSONL session files: reads the active
/// branch's conversation messages and returns the last [tail] as
/// `(role, text)` pairs (`user` / `assistant` / `toolResult`).
///
/// [ioRetry] wires the transient-ENOENT retry of the open (issue #427):
/// observing a child's transcript rides the same brief file disappearance
/// every other session open does (gh-1948 reads run while the executor
/// appends to the same file).
ChildMessageReader jsonlChildMessageReader(
  FileSystem fs, {
  SessionIoRetryConfig ioRetry = const SessionIoRetryConfig(),
}) {
  return (sessionId, {tail = 10}) async {
    final session = Session(
      await JsonlSessionStorage.open(fs, sessionId, ioRetry: ioRetry),
    );
    final branch = await session.getBranch();
    final messages = <(String, String)>[
      for (final record in branch)
        if (record is MessageRecord)
          (record.message.role, childMessageText(record.message)),
    ];
    if (messages.length <= tail) return messages;
    return messages.sublist(messages.length - tail);
  };
}

/// Resolves a child's REAL session JSONL path from the sessions tree
/// (gh-1948): scans the parent's project directory for a child session
/// whose header carries `agent: subagent`, `parent: [parent.id]` and
/// `id: [childId]` — the same header contract [subagentRegistryRows]
/// adopts missing registry rows from at boot. Returns the newest match,
/// or null when the child has no transcript yet (a RUNNING child before
/// its first turn-boundary flush).
Future<String?> resolveChildSessionPath({
  required JsonlSessionRepo repo,
  required SessionMetadata parent,
  required String childId,
}) async {
  for (final meta in await repo.list(cwd: parent.cwd)) {
    final header = meta.metadata;
    if (header == null || header['agent'] != 'subagent') continue;
    if (header['parent'] != parent.id) continue;
    if (header['id'] != childId) continue;
    if (meta.path == parent.path) continue;
    return meta.path;
  }
  return null;
}

/// Plain-text projection of one conversation message for `task_observe`:
/// text blocks joined, tool calls named, everything else skipped.
String childMessageText(Message message) {
  final buffer = StringBuffer();
  void writeBlock(ContentBlock block) {
    if (block is TextContent) {
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(block.text);
    } else if (block is ToolCall) {
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write('[tool call: ${block.name}]');
    }
  }

  switch (message) {
    case UserMessage(content: final content):
      if (content is String) {
        buffer.write(content);
      } else if (content is List<ContentBlock>) {
        content.forEach(writeBlock);
      }
    case AssistantMessage(content: final content):
      content.forEach(writeBlock);
    case ToolResultMessage(content: final content):
      content.forEach(writeBlock);
  }
  return buffer.toString();
}
