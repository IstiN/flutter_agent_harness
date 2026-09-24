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
Future<String?> processTableSnapshot() =>
    _psOutput(['-ax', '-o', 'pid=,lstart=']);

/// The raw `ps -ax -o pid=,pgid=` stdout, or null when ps fails.
Future<String?> processGroupTableSnapshot() =>
    _psOutput(['-ax', '-o', 'pid=,pgid=']);

/// The raw `ps -o lstart= -p <pid>` stdout, or null when ps fails or
/// prints nothing.
Future<String?> pidStartSnapshot(int pid) async {
  final out = await _psOutput(['-o', 'lstart=', '-p', '$pid']);
  if (out == null || out.isEmpty) return null;
  return out;
}

/// One `ps` probe, never throwing: a spawn denial (hardened runtime,
/// sandboxed runner) degrades to the same null a failing exit produces.
Future<String?> _psOutput(List<String> args) async {
  try {
    return await _checkedPs(args);
  } on ProcessException {
    return null;
  }
}

Future<String?> _checkedPs(List<String> args) async {
  final ps = await Process.run('ps', args);
  return ps.exitCode == 0 ? ps.stdout.toString() : null;
}
