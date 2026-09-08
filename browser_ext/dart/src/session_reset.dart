// `session_new` storage half: the archive-before-reset step, pure over the
// harness [FileSystem] so the VM tests pin it (the AgentHost itself is
// web-only). The reset refuses to lose data silently: the live transcript
// is copied to a sibling `/session-<id>.jsonl` before `/session.jsonl` is
// re-created — and an archive failure is reported, never swallowed, so the
// caller can decide whether to proceed.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The archive path for [sessionId] — a sibling of the live session file.
String sessionArchivePath(String sessionId) => '/session-$sessionId.jsonl';

/// Copies the live session file to [sessionArchivePath]. Returns the
/// archive path on success, `null` when there is nothing to archive
/// (no id, or the live file does not exist yet — a never-materialised
/// session), and throws when the copy itself fails: overwriting the live
/// path after a failed archive would destroy the only copy.
Future<String> archiveLiveSession({
  required FileSystem fs,
  required String sessionPath,
  required String sessionId,
}) async {
  if (sessionId.isEmpty) {
    throw StateError('session_new: no live session id to archive');
  }
  if ((await fs.exists(sessionPath)).valueOrNull != true) {
    // Nothing on disk (the file materialises lazily on the first persist):
    // the reset starts from zero, nothing to lose.
    return sessionArchivePath(sessionId);
  }
  final text = (await fs.readTextFile(sessionPath)).valueOrNull;
  if (text == null) {
    throw StateError('session_new: live session file unreadable');
  }
  final archivePath = sessionArchivePath(sessionId);
  final written = await fs.writeFile(archivePath, text);
  if (written.isErr) {
    throw StateError('session_new: archive write failed');
  }
  return archivePath;
}
