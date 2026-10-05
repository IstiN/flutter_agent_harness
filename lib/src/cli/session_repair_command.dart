import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_storage.dart'
    show SessionMetadata;
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/session/attach/session_presence.dart';
import 'package:flutter_agent_harness/src/session_repair.dart';

/// The headless `fa session repair <sessionId|path> [--dry-run]` command
/// (gh-1073): rewrites a bloated session JSONL with the append-only
/// `custom` ledger records dropped or superseded (see
/// [repairSessionLedgers]) so a marathon session resumes instead of
/// exhausting the heap on open. The conversation — messages, tree, labels
/// — is copied verbatim; the original is preserved at `<file>.bak`.
///
/// A session owned by a LIVE process (fresh presence heartbeat) is
/// refused — repairing under a writer loses appends. The guard covers
/// both target shapes: by-id lookups check the id directly; a direct
/// `.jsonl` path resolves to its session id through the listing under
/// [sessionRoot] (presence is keyed by id, so a file that is not a
/// session under that root has no heartbeat to check and is repaired
/// as an offline file). [write]/[writeln] are the host's output channel
/// (a [CliIO] tear-off pair) so this file stays a standalone library.
Future<int> runSessionRepairCliCommand({
  required void Function(String text) write,
  required void Function(String text) writeln,
  required FileSystem env,
  required String sessionRoot,
  String? sessionId,
  bool dryRun = false,
  SessionPresenceStore? presenceStore,
}) async {
  final target = sessionId?.trim() ?? '';
  if (target.isEmpty) {
    writeln('usage: fa session repair <sessionId|path> [--dry-run]');
    return 1;
  }
  String? path;
  SessionPresence? liveRow;
  if (target.endsWith('.jsonl')) {
    final exists = await env.exists(target);
    if (exists.isErr || !exists.valueOrNull!) {
      writeln('session repair: no such file: $target');
      return 1;
    }
    path = target;
    // Live guard for the path branch too: resolve the file to its
    // session id through the repo listing (ids are the presence key).
    // A file that is not a session under [sessionRoot] matches no
    // presence row; there is no writer heartbeat to check against (see
    // the doc comment).
    liveRow = await _liveRowForPath(env, sessionRoot, path, presenceStore);
  } else {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionRoot);
    final metadata = await resolveRepairableSession(repo, target);
    if (metadata == null) {
      writeln('session repair: session not found: $target');
      return 1;
    }
    path = metadata.path;
    liveRow = (await presenceStore?.list())?[metadata.id];
  }
  // Live guard: a fresh heartbeat means a running process owns the
  // session — repairing under a writer loses appends (the same rule as
  // `delete`, minus the own-process pass: repair never runs in the
  // owning process).
  if (liveRow != null) {
    writeln(
      'session repair: session ${liveRow.sessionId} is live (pid '
      '${liveRow.pid ?? 'unknown'}, heartbeat ${liveRow.touchedAt}) — '
      'stop the owning process first.',
    );
    return 1;
  }
  try {
    final report = await repairSessionLedgers(env, path, dryRun: dryRun);
    for (final line in report.summaryLines()) {
      writeln(line);
    }
    if (dryRun) {
      writeln('dry run: nothing written. Re-run without --dry-run to apply.');
    }
    return 0;
  } on SessionRepairException catch (error) {
    writeln('session repair: ${error.message}');
    return 1;
  } on Object catch (error) {
    writeln('session repair failed: $error');
    return 1;
  }
}

/// Resolves a repair target WITHOUT opening the session (a full open is
/// exactly what repair exists to avoid): exact id, then session-name
/// match — the `/session` lookup rule. Null when nothing matches.
Future<SessionMetadata?> resolveRepairableSession(
  JsonlSessionRepo repo,
  String wanted,
) async {
  final sessions = await repo.list();
  for (final metadata in sessions) {
    if (metadata.id == wanted) return metadata;
  }
  for (final metadata in sessions) {
    final name = await repo.sessionNameQuick(metadata);
    if (name != null && name.trim() == wanted) return metadata;
  }
  return null;
}

/// The fresh presence row (if any) that names [path]: the file is
/// resolved to its session id via the repo listing, then the id is
/// looked up in [presenceStore]. Null when the file is not a listed
/// session under [sessionRoot] or no live process owns it — presence is
/// keyed by session id, and only sessions under the root can be mapped
/// back to one.
Future<SessionPresence?> _liveRowForPath(
  FileSystem env,
  String sessionRoot,
  String path,
  SessionPresenceStore? presenceStore,
) async {
  if (presenceStore == null) return null;
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionRoot);
  final sessions = await repo.list();
  final absolute = (await env.absolutePath(path)).valueOrNull ?? path;
  for (final metadata in sessions) {
    if (metadata.path == path || metadata.path == absolute) {
      return (await presenceStore.list())[metadata.id];
    }
  }
  return null;
}
