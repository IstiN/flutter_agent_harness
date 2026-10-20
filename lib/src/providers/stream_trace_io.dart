/// The dart:io half of StreamTrace — the file sink and the env-gated
/// installer. The pure contract (marks, line format, active-trace
/// lifecycle) lives in `stream_trace.dart` (barrel-exported); this file
/// is reachable exclusively through `lib/io.dart`, same pattern as
/// `stall_sentinel_io.dart`.
library;

import 'dart:io';

import 'stream_trace.dart';

/// A synchronously-appending line sink over [file]: truncates whatever
/// a previous run left, then appends+flushes every line (the same
/// contract as the fa.log telemetry sink — no pending async writes a
/// crash or a same-second reader can lose). Diagnostics contract: an IO
/// failure degrades to silence, never throws into the caller.
final class FileStreamTraceSink implements StreamTraceSink {
  /// Truncates [file] for a fresh trace.
  FileStreamTraceSink(this._file) {
    try {
      _file.writeAsStringSync('', flush: true);
    } catch (_) {
      // A broken trace path never breaks the host.
    }
  }

  final File _file;

  @override
  void writeLine(String line) {
    try {
      _file.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // A broken trace path never breaks the host.
    }
  }
}

/// Starts a [StreamTrace] into [file] when the env knob is on:
/// `FA_STREAM_TRACE=1` (exactly `1`; any other value or an unset key
/// keeps the trace off). Returns the started trace, or null when the
/// knob is off. [envLookup] is a test seam; real hosts pass
/// `Platform.environment.lookup`.
StreamTrace? maybeStartStreamTrace(
  File file, {
  required String? Function(String key) envLookup,
}) {
  if (envLookup('FA_STREAM_TRACE') != '1') return null;
  return StreamTrace.start(FileStreamTraceSink(file));
}
