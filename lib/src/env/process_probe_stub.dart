/// Web-safe stub for `process_probe_io.dart` (the OS process-table reads
/// the job-registry boot reconcile verifies entries against). The real
/// reads run `ps` — `dart:io` — so web builds of the root library import
/// this file conditionally:
///
/// ```dart
/// import 'process_probe_stub.dart' if (dart.library.io)
///   'process_probe_io.dart';
/// ```
///
/// On web there is no process table: null degrades per the registry
/// contract — entries the platform cannot verify are KEPT, never
/// destroyed on missing evidence.
library;

/// The raw `ps -ax -o pid=,lstart=` table, or null when the platform
/// cannot report one.
Future<String?> processTableSnapshot() async => null;

/// The raw `ps -ax -o pid=,pgid=` table, or null when the platform
/// cannot report one.
Future<String?> processGroupTableSnapshot() async => null;

/// The raw `ps -o lstart= -p <pid>` line, or null.
Future<String?> pidStartSnapshot(int pid) async => null;
