import 'package:flutter_agent_harness/src/session/attach/session_presence.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/session/session_repair.dart';

/// The headless `fa session repair <sessionId|path> [--dry-run]` command
/// (gh-1073): rewrites a bloated session JSONL with the append-only
/// `custom` ledger records dropped or superseded (see
/// [repairSessionLedgers]) so a marathon session resumes instead of
/// exhausting the heap on open. The conversation — messages, tree, labels
/// — is copied verbatim; the original is preserved at `<file>.bak`.
///
/// A session owned by a LIVE process (fresh presence heartbeat) is
/// refused — repairing under a writer loses appends. [write]/[writeln]
/// are the host's output channel (a [CliIO] tear-off pair) so this file
/// stays a standalone library.
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
  if (target.endsWith('.jsonl')) {
    final exists = await env.exists(target);
    if (exists.isErr || !exists.valueOrNull!) {
      writeln('session repair: no such file: $target');
      return 1;
    }
    path = target;
  } else {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionRoot);
    final metadata = await resolveRepairableSession(repo, target);
    if (metadata == null) {
      writeln('session repair: session not found: $target');
      return 1;
    }
    path = metadata.path;
    // Live guard: a fresh heartbeat means a running process owns the
    // session — repairing under a writer loses appends (the same rule as
    // `delete`, minus the own-process pass: repair never runs in the
    // owning process).
    final row = (await presenceStore?.list())?[metadata.id];
    if (row != null) {
      writeln(
        'session repair: session ${metadata.id} is live (pid '
        '${row.pid ?? 'unknown'}, heartbeat ${row.touchedAt}) — stop the '
        'owning process first.',
      );
      return 1;
    }
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
