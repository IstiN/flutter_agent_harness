/// ConnTrace seam (issue #1392 bench round 3): the real implementation
/// reads `dart:io` (HttpClient.connectionInfo gives the local port and
/// socket errors give stale-keep-alive detection), so the root library
/// imports the web-safe stub conditionally:
///
/// ```dart
/// export 'conn_trace_stub.dart' if (dart.library.io) 'conn_trace_io.dart';
/// ```
library;

export 'conn_trace_stub.dart' if (dart.library.io) 'conn_trace_io.dart';
