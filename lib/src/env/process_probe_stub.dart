/// Web-safe stub for `process_probe_io.dart` (the OS process-table reads
/// the job-registry boot reconcile verifies entries against, plus the
/// issue #2201 survivor scan). The real reads run `ps` — `dart:io` — so
/// web builds of the root library import this file conditionally:
///
/// ```dart
/// import 'process_probe_stub.dart' if (dart.library.io)
///   'process_probe_io.dart';
/// ```
///
/// On web there is no process table: null degrades per the registry
/// contract — entries the platform cannot verify are KEPT, never
/// destroyed on missing evidence, and no survivors are ever detected.
library;

/// The raw `ps -ax -o pid=,lstart=` table, or null when the platform
/// cannot report one.
Future<String?> processTableSnapshot() async => null;

/// The raw `ps -ax -o pid=,pgid=` table, or null when the platform
/// cannot report one.
Future<String?> processGroupTableSnapshot() async => null;

/// The raw `ps -o lstart= -p <pid>` line, or null.
Future<String?> pidStartSnapshot(int pid) async => null;

/// One `ps -ax -o pid=,ppid=,pgid=,lstart=,command=` row (issue #2201).
typedef ProcessDetailRow = ({
  int pid,
  int ppid,
  int? pgid,
  String lstart,
  String? command,
});

/// The parsed full-identity table, or null — web has no process table.
Future<List<ProcessDetailRow>?> processDetailTableSnapshot() async => null;

/// No-op on web: there is no process to signal.
Future<bool> stopDetachedProcess(int pid) async => false;
