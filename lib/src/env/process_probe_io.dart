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
import 'process_lstart.dart';

// gh-2413: the lstart parser moved to the pure `process_lstart.dart` (the
// boot reconcile compares start times without dart:io); re-exported here
// so the existing io-side importers are unchanged.
export 'process_lstart.dart';

/// The raw `ps -ax -o pid=,lstart=` stdout, or null when ps fails.
Future<String?> processTableSnapshot() =>
    _psOutput(['-ax', '-o', 'pid=,lstart=']);

/// The raw `ps -ax -o pid=,pgid=` stdout, or null when ps fails.
Future<String?> processGroupTableSnapshot() =>
    _psOutput(['-ax', '-o', 'pid=,pgid=']);

/// The raw `ps -o lstart= -p <pid>` stdout, or null when ps fails or
/// prints nothing. TRIMMED (issue #2260 review): ps right-aligns the
/// single-pid column, so the raw value carries leading whitespace —
/// every consumer compares/parses start tags against trimmed values
/// (`tryParseLstart`, the reconcile, the liveness table), and an
/// untrimmed tag made every recorded entry read as recycled.
Future<String?> pidStartSnapshot(int pid) async {
  final out = (await _psOutput(['-o', 'lstart=', '-p', '$pid']))?.trim();
  if (out == null || out.isEmpty) return null;
  return out;
}

// ---------------------------------------------------------------------------
// Survivor detection (issue #2201). Row type + parser + the one
// classification over it; the IO layer only runs `ps`.
// ---------------------------------------------------------------------------

final _psWhitespace = RegExp(r'\s+');

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
    final cols = line.trim().split(_psWhitespace);
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
/// The per-exec script dir prefix (gh-1763): every bash tool / job command
/// runs as `sh -c '. "$1"' sh <dir>/cmd.sh` with `<dir>` a private temp
/// dir under this prefix.
const shellCommandTempPrefix = 'fa_sh_cmd_';

/// This harness's positive owner marker for survivor classification
/// (gh-2413): `fa_sh_cmd_<pid>_` — the [shellCommandTempPrefix] dir name
/// carrying the owning harness pid. `_writeGuardedScript` creates the dir
/// under exactly this prefix, so a backgrounded SUBSHELL keeps the wrapper
/// argv (and the marker) while a detached program's own argv never does.
String shellCommandOwnerMarker(int pid) => '$shellCommandTempPrefix${pid}_';

/// [shellCommandOwnerMarker] for THIS harness process — the one form the
/// io layer's job class can name (its own `pid` member shadows dart:io's).
String currentProcessOwnerMarker() => shellCommandOwnerMarker(pid);

/// The survivor candidates of one completed call (issue #2201),
/// classified over one POST-EXIT process table. Two disjoint strategies:
///
/// - **ownGroup hosts** (setsid — Linux/CI): authoritative group scan.
///   The direct child led its own group; descendants inherit the pgid and
///   keep it after the leader's death (reparented, group unchanged), so
///   `pgid == childPid` catches every child regardless of when the script
///   forked it.
/// - **non-ownGroup hosts** (macOS has no setsid): the orphan window,
///   bounded on BOTH ends (gh-2413) and gated on a positive OWNER proof.
///   The child ran in OUR group — which every process of a peer session
///   this harness (or a job-control-less parent) spawned shares — so
///   "in our group, started within this call's lifetime" only NAMES
///   candidates; ownership needs proof from the same snapshot: the row's
///   own command, or some ANCESTOR's (the `ppid` chain walked inside the
///   table), still carries this harness's wrapper tag
///   ([shellCommandOwnerMarker] — `fa_sh_cmd_<pid>_…`, the per-exec script
///   dir every backgrounded subshell inherits in its argv). A survivor is
///   a child like `sleep 300` whose own argv carries nothing: it is OURS
///   when the subshell that launched it still wears the tag, a peer's
///   when the chain hits `fa_sh_cmd_<other>_` or init. A detached program
///   whose launcher already exited (`nohup prog &`, chain → pid 1) cannot
///   be proven ours on these hosts: it is left alone — never adopted,
///   never a cross-session "left by" misattribution (gh-2413). The upper
///   bound (`startedMs <= execEndMs`) stops an hours-long call from
///   adopting every later orphan in the group.
///
/// The direct child itself is never a survivor. Pure.
List<ShellSurvivor> classifyShellSurvivors({
  required int childPid,
  required bool ownGroup,
  required int? ourPgid,
  required DateTime? execStart,
  DateTime? execEnd,
  String? ownerMarker,
  required List<ProcessDetailRow>? table,
}) {
  if (table == null) return const [];
  // ps lstart has whole-second resolution — compare the spawn time on the
  // same grain, or a same-second fork would be rejected.
  final windowStartMs = execStart == null
      ? null
      : execStart.millisecondsSinceEpoch -
            execStart.millisecondsSinceEpoch % 1000;
  final marker = ownerMarker;
  // The ancestry lookup for the ownership proof; empty when no marker was
  // given (nothing can then be proven ours).
  final byPid = marker == null
      ? const <int, ProcessDetailRow>{}
      : {for (final row in table) row.pid: row};
  final out = <ShellSurvivor>[];
  for (final row in table) {
    if (row.pid == childPid) continue;
    final matches = ownGroup
        // ownGroup hosts: the authoritative group scan.
        ? row.pgid == childPid
        : _isOwnedOrphan(
            row,
            childPid: childPid,
            windowStartMs: windowStartMs,
            windowEndMs: execEnd?.millisecondsSinceEpoch,
            ourPgid: ourPgid,
            marker: marker,
            byPid: byPid,
          );
    if (!matches) continue;
    out.add(
      ShellSurvivor(pid: row.pid, startTag: row.lstart, command: row.command),
    );
  }
  return out;
}

/// The non-ownGroup candidate test (gh-2413), every clause explicit:
/// in OUR group, started inside the call's window (both ends, whole-second
/// grain), and PROVABLY a leftover of THIS call — its `ppid` chain leads
/// into the completed call's subtree through this harness's [marker]
/// ([ownedByCall]). No marker, no window, no start string or a failed
/// proof each answer false on their own. Pure.
bool _isOwnedOrphan(
  ProcessDetailRow row, {
  required int childPid,
  required int? windowStartMs,
  required int? windowEndMs,
  required int? ourPgid,
  required String? marker,
  required Map<int, ProcessDetailRow> byPid,
}) {
  if (windowStartMs == null || ourPgid == null || marker == null) {
    return false;
  }
  if (row.pgid != ourPgid) return false;
  final startedMs = tryParseLstart(row.lstart)?.millisecondsSinceEpoch;
  if (startedMs == null || startedMs < windowStartMs) return false;
  if (windowEndMs != null && startedMs > windowEndMs) return false;
  return ownedByCall(row, byPid, childPid, marker);
}

/// The gh-2413 ownership proof for one non-ownGroup candidate of the
/// COMPLETED call ([childPid]): the `ppid` chain, walked inside the same
/// snapshot ([byPid]), must lead into THAT call's leftover subtree —
/// through [childPid] itself (a child the snapshot still shows under the
/// dead wrapper) or through an ORPHANED subshell (`ppid == 1`) that still
/// wears this harness's [marker] (`fa_sh_cmd_<pid>_…`: forked from our
/// wrapper, re-parented to init because its parent — the completed call —
/// is gone). A process under a LIVE wrapper is NOT a survivor of this
/// call even when that wrapper wears the same marker — it is another job
/// of this very harness (the marker names the harness, not the call; a
/// settled job once adopted its running sibling's `sleep` as a duplicate
/// and doubled the waiting row, gh-2413 regression). A chain that reaches
/// init without the tag (a peer's wrapper, a detached program whose
/// launcher exited) is NOT ours either. Bounded depth guards against a
/// table with a cycle (a recycled pid mid-walk); pure.
bool ownedByCall(
  ProcessDetailRow row,
  Map<int, ProcessDetailRow> byPid,
  int childPid,
  String marker,
) {
  var current = row;
  for (var depth = 0; depth < 128; depth++) {
    // A child the snapshot still shows under the completed call's pid:
    // the dead wrapper itself is already reaped and absent from the table,
    // so the `ppid` hit is the only trace of that subtree.
    if (current.pid == childPid || current.ppid == childPid) return true;
    if (current.ppid <= 1) {
      // An orphan: ours only as a tagged subshell of this harness.
      return current.command?.contains(marker) ?? false;
    }
    final parent = byPid[current.ppid];
    if (parent == null || parent.pid == current.pid) return false;
    current = parent;
  }
  return false;
}

/// Grace between the TERM and KILL rounds of [stopDetachedProcess].
const _stopKillGrace = Duration(milliseconds: 400);

/// Settle time after the KILL round before the survivor scan — orphans
/// are reparented to init and reaped within moments; zombies (the
/// already-dead, not-yet-reaped) must not count as survivors.
const _stopSurvivorScanDelay = Duration(milliseconds: 250);

/// Best-effort TERM-then-KILL of a detached foreign process (issue
/// #2201: `bash_job stop` on an adopted job — we hold only the pid, no
/// process handle), GROUP-AWARE (issue #2260): when the process table
/// shows the pid leading its own process group (`pgid == pid` — the
/// setsid contract), the whole GROUP is signaled `kill(-pid)` — a
/// single-pid kill strands the group's members, which inherit the group
/// and survive the leader burning CPU forever. Leadership evidence comes
/// from the same table row that identifies the process, so a process
/// that never led a group (non-ownGroup hosts) keeps the single-pid
/// kill, and a stale/wrong pid degrades to it too.
///
/// Returns the group members verified STILL ALIVE after the kill rounds
/// (empty = the whole group is gone, verified by a fresh table scan), or
/// null when the group could not be verified: no group leadership ran,
/// the leader refused the TERM (already gone), or the verification scan
/// failed. Never throws.
Future<List<ShellSurvivor>?> stopDetachedProcess(int pid) async {
  try {
    final detail = await processDetailTableSnapshot();
    ProcessDetailRow? row;
    if (detail != null) {
      for (final candidate in detail) {
        if (candidate.pid == pid) row = candidate;
      }
    }
    if (row == null || row.pgid != pid) {
      // No group leadership on this host (or no readable row): the
      // single-pid kill, as before. The group is unverifiable — on
      // orphan-window hosts its members sit in OUR group,
      // indistinguishable from the harness's own processes.
      final ok = Process.killPid(pid, ProcessSignal.sigterm);
      if (ok != true) return null;
      await Future<void>.delayed(_stopKillGrace);
      Process.killPid(pid, ProcessSignal.sigkill);
      return null;
    }
    Process.killPid(-pid, ProcessSignal.sigterm);
    await Future<void>.delayed(_stopKillGrace);
    Process.killPid(-pid, ProcessSignal.sigkill);
    await Future<void>.delayed(_stopSurvivorScanDelay);
    final after = await processDetailTableSnapshot();
    if (after == null) return null;
    return [
      for (final member in after)
        if (member.pgid == pid &&
            !(member.command?.contains('defunct') ?? false))
          ShellSurvivor(
            pid: member.pid,
            startTag: member.lstart,
            command: member.command,
          ),
    ];
  } on Object {
    return null;
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
