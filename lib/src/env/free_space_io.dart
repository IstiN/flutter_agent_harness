/// `dart:io` free-disk-space probe behind the [DiskFreeProbe] seam
/// (issue #919). Exported only from `lib/io.dart`.
///
/// POSIX only (`df -k -P`); on platforms without `df` (Windows) — or on any
/// probe failure — it returns null, which leaves the low-disk guard
/// inactive. Never throws.
library;

import 'dart:io';

import 'job_log_ceiling.dart';

// ponytail: `df -k -P` parse, null on anything unusual — a per-job probe
// runs at most once per produced MB, and a wrong null just disables the
// guard.
/// Free bytes on the filesystem holding [directory], or null when unknown.
///
/// `-P` forces the POSIX single-line format: without it a filesystem name
/// longer than the header (macOS network mounts, `map auto_home`) wraps
/// onto a second line and the "Available" column would be read from the
/// wrong row.
Future<int?> diskFreeBytes(String directory) async {
  try {
    final result = await Process.run('df', ['-k', '-P', directory]);
    if (result.exitCode != 0) return null;
    final lines = result.stdout.toString().trim().split('\n');
    if (lines.length < 2) return null;
    final fields = lines[1].split(RegExp(r'\s+'));
    if (fields.length < 4) return null;
    final kb = int.tryParse(fields[3]);
    if (kb == null || kb < 0) return null;
    return kb * 1024;
  } on Object {
    return null;
  }
}
