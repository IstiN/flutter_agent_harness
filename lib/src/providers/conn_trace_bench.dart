/// Bench ConnTrace seam (issue #1392 bench round 3) — the round's
/// structured FA_CONN forensics (trace file, payload snapshots,
/// origin-aware stale attribution), coexisting with the gh-1395 pure
/// core in conn_trace.dart: the real implementation
/// reads `dart:io` (HttpClient.connectionInfo gives the local port and
/// socket errors give stale-keep-alive detection), so the root library
/// imports the web-safe stub conditionally:
///
/// ```dart
/// export 'conn_trace_bench_stub.dart' if (dart.library.io) 'conn_trace_bench_io.dart';
/// ```
library;

export 'conn_trace_bench_stub.dart'
    if (dart.library.io) 'conn_trace_bench_io.dart';
