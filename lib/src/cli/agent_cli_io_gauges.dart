/// The `/stats` + boot fa.log IO gauges (issue #2248 AC6).
///
/// The incident container held 77GB (one 3.7GB session + ~50 subagent
/// mailboxes) under standing fd/IO pressure from sweeps — invisible to
/// the operator because nothing measured it. Three gauges close that:
///
/// - open-fd count (`/proc/self/fd` on Linux, `/dev/fd` on macOS/BSD —
///   the EMFILE candidate);
/// - per-minute fs-op failures ([SessionIoHealth.failuresInLastMinute],
///   lives with the health tracker);
/// - sessions-container size (recursive metadata-only walk below).
///
/// Pure Dart over the injected [ExecutionEnv] — no `dart:io` in the
/// core; hosts without either fd dir render the gauge as `-`.
library;

import '../env/execution_env.dart';
import '../session/session_io_health.dart';

export '../session/session_io_health.dart' show SessionIoHealth;

/// The sessions-container size snapshot behind the AC6 gauge.
final class ContainerSizeStats {
  /// Creates the snapshot.
  const ContainerSizeStats({
    required this.bytes,
    required this.files,
    required this.dirs,
    required this.elapsed,
    required this.truncated,
  });

  /// Total bytes across regular files.
  final int bytes;

  /// Regular files walked.
  final int files;

  /// Directories descended into.
  final int dirs;

  /// Walk duration.
  final Duration elapsed;

  /// True when the entry cap stopped the walk early.
  final bool truncated;

  /// Human-readable size (GB/MB granularity — the card speaks in GB).
  String get sizeLabel {
    const gib = 1 << 30;
    const mib = 1 << 20;
    if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GiB';
    if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MiB';
    return '$bytes B';
  }
}

/// Entry cap of the container walk: metadata stats only, but a runaway
/// tree must not pin the loop forever. ponytail: flat cap, per-subtree
/// budgets if a real container ever trips it.
const int containerWalkMaxEntries = 250000;

/// The open-fd gauge: entry count of `/proc/self/fd` (Linux) or
/// `/dev/fd` (macOS/BSD); null when the host exposes neither.
Future<int?> openFdCount(ExecutionEnv env) async {
  for (final dir in const <String>['/proc/self/fd', '/dev/fd']) {
    final entries = (await env.listDir(dir)).valueOrNull;
    if (entries != null) return entries.length;
  }
  return null;
}

/// Recursive size of the sessions container at [root] (AC6): every
/// regular file's bytes, the directory count, one elapsed reading.
/// Metadata-only (listDir stats, no content reads) — O(entries), which
/// the boot/listing sweeps already pay; the size SUM is the new part.
/// Returns null when [root] cannot be listed at all.
Future<ContainerSizeStats?> sessionsContainerSize(
  ExecutionEnv env,
  String root,
) async {
  final sw = Stopwatch()..start();
  var bytes = 0;
  var files = 0;
  var dirs = 0;
  var entries = 0;
  var truncated = false;
  final pending = <String>[root];
  while (pending.isNotEmpty) {
    final entriesHere = (await env.listDir(pending.removeLast())).valueOrNull;
    if (entriesHere == null) continue;
    for (final entry in entriesHere) {
      if (++entries > containerWalkMaxEntries) {
        truncated = true;
        return ContainerSizeStats(
          bytes: bytes,
          files: files,
          dirs: dirs,
          elapsed: sw.elapsed,
          truncated: truncated,
        );
      }
      switch (entry.kind) {
        case FileKind.directory:
          dirs++;
          pending.add(entry.path);
        case FileKind.file:
          files++;
          bytes += entry.size;
        case FileKind.symlink:
          break; // counted nowhere: never followed, never sized.
      }
    }
  }
  return ContainerSizeStats(
    bytes: bytes,
    files: files,
    dirs: dirs,
    elapsed: sw.elapsed,
    truncated: false,
  );
}

/// Renders the boot-line `/stats` fd gauge value: the count, or `-` when
/// the host exposes neither fd directory.
String fdGaugeLabel(int? fds) => fds == null ? '-' : '$fds';
