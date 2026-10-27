import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/session/attach/session_presence.dart';
import 'package:flutter_agent_harness/src/session_retention.dart';

/// The headless `fa session clean [--dry-run]` command (gh-1746 AC6):
/// runs one [SessionRetentionSweeper.sweep] pass over [sessionRoot] with
/// the parsed `sessions.retention` policy and prints the report lines —
/// the exact plan on a dry run, the applied outcome otherwise. Without a
/// cap the sweeper's no-op report renders the config hint instead (the
/// manual verb is the `sweep: off` escape hatch, so it must work even
/// when boot never sweeps — E5). [write]/[writeln] are the host's output
/// channel (a [CliIO] tear-off pair) so this file stays a standalone
/// library, like session_repair_command.dart. [presenceStore] keeps a
/// live session undeletable mid-apply (the same fail-closed guard as the
/// boot sweep).
Future<int> runSessionCleanCliCommand({
  required void Function(String text) write,
  required void Function(String text) writeln,
  required FileSystem env,
  required String sessionRoot,
  SessionRetentionConfig retention = const SessionRetentionConfig(),
  bool dryRun = false,
  SessionPresenceStore? presenceStore,
  DateTime Function()? now,
}) async {
  final sweeper = SessionRetentionSweeper(
    fs: env,
    sessionsRoot: sessionRoot,
    retention: retention,
    presenceStore: presenceStore,
    now: now,
  );
  try {
    final report = await sweeper.sweep(dryRun: dryRun);
    if (!retention.hasCap) {
      // The verb is explicit — unlike boot it must answer even with no
      // cap: point at the keys instead of printing nothing (the shared
      // renderer stays silent here by design; boot may never note, AC1).
      writeln('no sessions.retention cap configured — nothing to clean.');
      writeln(
        'set sessions.retention.maxTotalBytes in ~/.fah/config.yaml '
        'to enable the boot sweep',
      );
    }
    for (final line in sessionSweepReportLines(report)) {
      writeln(line);
    }
    if (dryRun && report.deletions.isNotEmpty) {
      writeln('dry run: nothing deleted. Re-run without --dry-run to apply.');
    }
    return 0;
  } on Object catch (error) {
    writeln('session clean failed: $error');
    return 1;
  }
}
