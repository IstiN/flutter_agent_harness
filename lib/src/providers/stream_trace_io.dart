/// The dart:io half of StreamTrace — the file sink and the env-gated
/// installer. The pure contract (marks, line format, active-trace
/// lifecycle) lives in `stream_trace.dart` (barrel-exported); this file
/// is reachable exclusively through `lib/io.dart`, same pattern as
/// `stall_sentinel_io.dart`.
library;

import 'dart:async';
import 'dart:io';

import 'stream_trace.dart';

/// A buffered line sink over [file]: truncates whatever a previous run
/// left (ONE trace per file — each armed run replaces the last trail;
/// collect across runs by copying the file between runs), then appends
/// lines in batches. Concurrent armed runs share that one file: any
/// second armed `fa` boot — another terminal, or a detached child that
/// inherited `FA_STREAM_TRACE` (e.g. `fa dap start` spawning
/// `hub serve`) — truncates the live trail at its install. Copy the
/// file between runs when history matters. Batching keeps the per-mark
/// cost off the hot stream path (a sync fsync per SSE chunk would
/// perturb the very cadence being measured): lines flush on a
/// [flushInterval] timer, when the buffer crosses
/// [_kFlushThresholdBytes], or on [flush]/[dispose]. The trade is
/// explicit — up to one interval of buffered lines is lost on a hard
/// kill. Diagnostics contract: an IO failure degrades to silence, never
/// throws into the caller.
final class FileStreamTraceSink implements StreamTraceSink {
  /// Truncates [file] for a fresh trace and arms the flush timer.
  FileStreamTraceSink(
    this._file, {
    Duration flushInterval = const Duration(milliseconds: 250),
  }) {
    try {
      // Best-effort parent creation (pr-1727 review): bin/fah.dart arms
      // the trace before anything in the CLI boot has created
      // ~/.fah/logs/ — without this the armed trail is void on fresh
      // installs, fresh HOMEs, and ephemeral containers. Same pattern as
      // FileAgentTelemetrySink.record.
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync('', flush: true);
    } catch (_) {
      // A broken trace path never breaks the host.
    }
    _timer = Timer.periodic(flushInterval, (_) => flush());
  }

  /// Buffered lines flush when the buffer crosses this many bytes
  /// (bounded memory on a bursty endpoint between timer ticks).
  static const int _kFlushThresholdBytes = 64 * 1024;

  final File _file;
  late final Timer _timer;
  final StringBuffer _pending = StringBuffer();

  @override
  void writeLine(String line) {
    _pending
      ..write(DateTime.now().toIso8601String())
      ..write(' ')
      ..write(line)
      ..write('\n');
    if (_pending.length >= _kFlushThresholdBytes) flush();
  }

  /// Writes any buffered lines now (also driven by the flush timer).
  void flush() {
    if (_pending.isEmpty) return;
    final batch = _pending.toString();
    _pending.clear();
    try {
      _file.writeAsStringSync(batch, mode: FileMode.append, flush: true);
    } catch (_) {
      // A broken trace path never breaks the host.
    }
  }

  /// Cancels the timer and flushes the tail. The CLI never calls this
  /// (the trace is process-lifetime); tests and embedders may.
  void dispose() {
    _timer.cancel();
    flush();
  }
}

/// Starts a [StreamTrace] into [file] when the env knob is on:
/// `FA_STREAM_TRACE=1` (exactly `1`; any other value or an unset key
/// keeps the trace off). Returns the started trace, or null when the
/// knob is off. [envLookup] is a test seam; real hosts pass
/// `(key) => Platform.environment[key]`.
StreamTrace? maybeStartStreamTrace(
  File file, {
  required String? Function(String key) envLookup,
}) {
  if (envLookup('FA_STREAM_TRACE') != '1') return null;
  return StreamTrace.start(FileStreamTraceSink(file));
}
