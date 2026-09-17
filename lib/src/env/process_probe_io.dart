/// OS process-table reads for the job-registry boot reconcile (issue
/// #478). Platform glue only.
///
/// These probes are INFRASTRUCTURE evidence, not agent commands: they run
/// `ps` straight through `Process.run`, deliberately OUTSIDE
/// [Shell.exec] — no cwd/secret/session-var decoration, and no ride on
/// the shell command stream the `!` history (and the CLI tests) record.
/// A registry probe must never surface as a phantom command.
///
/// Never throws — every failure becomes null, and null means
/// "unverifiable": the reconcile keeps entries rather than destroying
/// them on missing evidence.
library;

import 'dart:io';

/// The raw `ps -ax -o pid=,lstart=` stdout, or null when ps fails.
Future<String?> processTableSnapshot() async {
  final ps = await Process.run('ps', ['-ax', '-o', 'pid=,lstart=']);
  final out = ps.stdout.toString();
  return ps.exitCode == 0 ? out : null;
}

/// The raw `ps -ax -o pid=,pgid=` stdout, or null when ps fails.
Future<String?> processGroupTableSnapshot() async {
  final ps = await Process.run('ps', ['-ax', '-o', 'pid=,pgid=']);
  final out = ps.stdout.toString();
  return ps.exitCode == 0 ? out : null;
}

/// The raw `ps -o lstart= -p <pid>` stdout, or null when ps fails.
Future<String?> pidStartSnapshot(int pid) async {
  final ps = await Process.run('ps', ['-o', 'lstart=', '-p', '$pid']);
  final out = ps.stdout.toString();
  return ps.exitCode == 0 && out.isNotEmpty ? out : null;
}
