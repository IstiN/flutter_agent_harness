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

import 'execution_env.dart' show ShellSurvivor;

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

// ---------------------------------------------------------------------------
// Survivor detection (issue #2201). Row type + parser + the one
// classification over it; the IO layer only runs `ps`.
// ---------------------------------------------------------------------------

/// One `ps -ax -o pid=,ppid=,pgid=,lstart=,command=` row: the full
/// identity a survivor classification and liveness sample read.
typedef ProcessDetailRow = ({
  int pid,
  int ppid,
  int? pgid,
  String lstart,
  String? command,
});

/// The parsed full-identity table, or null when the platform cannot
/// report one.
Future<List<ProcessDetailRow>?> processDetailTableSnapshot() async {
  final raw = await _psOutput([
    '-ax',
    '-o',
    'pid=,ppid=,pgid=,lstart=,command=',
  ]);
  if (raw == null) return null;
  final rows = <ProcessDetailRow>[];
  for (final line in raw.split('\n')) {
    final cols = line.trim().split(RegExp(r'\s+'));
    // Identity columns: pid ppid pgid + 5 lstart words = 8. Rows whose
    // command ps cannot print stay identified (command: null -> the
    // <unknown cmd> surface downstream).
    if (cols.length < 8) continue;
    final pid = int.tryParse(cols[0]);
    final ppid = int.tryParse(cols[1]);
    final pgid = int.tryParse(cols[2]);
    if (pid == null || ppid == null || pgid == null) continue;
    rows.add((
      pid: pid,
      ppid: ppid,
      pgid: pgid,
      lstart: cols.sublist(3, 8).join(' '),
      command: cols.length > 8 ? cols.sublist(8).join(' ') : null,
    ));
  }
  return rows;
}

/// Parses one `ps -o lstart=` value ("Mon Nov 16 10:00:00 2026", LOCAL
/// time); null when the shape does not match. Second resolution only —
/// ps never reports sub-second starts.
DateTime? tryParseLstart(String value) {
  final m = RegExp(
    r'^(\w{3}) (\w{3})\s+(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})$',
  ).firstMatch(value.trim());
  if (m == null) return null;
  const months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };
  final month = months[m.group(2)!];
  if (month == null) return null;
  return DateTime(
    int.parse(m.group(7)!),
    month,
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
}

/// The survivor candidates of one completed call (issue #2201),
/// classified over one POST-EXIT process table. Two disjoint strategies:
///
/// - **ownGroup hosts** (setsid — Linux/CI): authoritative group scan.
///   The direct child led its own group; descendants inherit the pgid and
///   keep it after the leader's death (reparented, group unchanged), so
///   `pgid == childPid` catches every child regardless of when the script
///   forked it.
/// - **non-ownGroup hosts** (macOS has no setsid): the orphan-window
///   heuristic. The child ran in OUR group, so its survivors are processes
///   that are (a) orphans now (`ppid == 1` — the shell that spawned them
///   is gone), (b) still in our group, and (c) started no earlier than
///   this call's spawn second. Race-free where a parent-chain snapshot
///   was not: an instant `nohup x &` script exits before any pre-exit
///   sample could run, but its orphaned child stays visible in the
///   post-exit table. Best-effort by design — the documented detection
///   heuristic, not a guarantee (a process that escaped our group via its
///   own `setsid` is invisible here).
///
/// The direct child itself is never a survivor. Pure.
List<ShellSurvivor> classifyShellSurvivors({
  required int childPid,
  required bool ownGroup,
  required int? ourPgid,
  required DateTime? execStart,
  required List<ProcessDetailRow>? table,
}) {
  if (table == null) return const [];
  // ps lstart has whole-second resolution — compare the spawn time on the
  // same grain, or a same-second fork would be rejected.
  final windowStartMs = execStart == null
      ? null
      : execStart.millisecondsSinceEpoch -
            execStart.millisecondsSinceEpoch % 1000;
  final out = <ShellSurvivor>[];
  for (final row in table) {
    if (row.pid == childPid) continue;
    final bool matches;
    if (ownGroup) {
      matches = row.pgid == childPid;
    } else {
      final startedMs = tryParseLstart(row.lstart)?.millisecondsSinceEpoch;
      matches =
          windowStartMs != null &&
          ourPgid != null &&
          row.pgid == ourPgid &&
          row.ppid == 1 &&
          startedMs != null &&
          startedMs >= windowStartMs;
    }
    if (!matches) continue;
    out.add(
      ShellSurvivor(pid: row.pid, startTag: row.lstart, command: row.command),
    );
  }
  return out;
}

/// Best-effort TERM-then-KILL of a detached foreign process (issue
/// #2201: `bash_job stop` on an adopted job — we hold only the pid, no
/// process handle). Never throws; true when a signal round ran.
Future<bool> stopDetachedProcess(int pid) async {
  try {
    final ok = Process.killPid(pid, ProcessSignal.sigterm);
    if (ok != true) return false;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    Process.killPid(pid, ProcessSignal.sigkill);
    return true;
  } on Object {
    return false;
  }
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
