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
import '../session/session_tree.dart';
import '../session_io_retry.dart';
import '../types.dart';
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

/// A [ChildMessageReader] over plain JSONL session files: reads the active
/// branch's conversation messages and returns the last [tail] as
/// `(role, text)` pairs (`user` / `assistant` / `toolResult`).
ChildMessageReader jsonlChildMessageReader(FileSystem fs) {
  return (sessionId, {tail = 10}) async {
    final session = Session(await JsonlSessionStorage.open(fs, sessionId));
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
