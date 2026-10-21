/// StreamTrace: the per-chunk timing trail (diagnostic).
///
/// Three marks, one line each:
///
/// - `net` — raw bytes arrived from the provider socket
///   (the [createSseIterator] read leg);
/// - `emit` — a provider adapter pushed a delta event into the
///   [AssistantMessageEventStream];
/// - `render` — the host wrote the delta to its live surface
///   (the CLI's `_TuiCliIO.write` in TUI mode, `_TerminalCliIO.write`
///   in headless and line-mode runs).
///
/// Every line carries `t=<elapsed>ms +<delta>ms #<seq> <mark> <detail>`:
/// elapsed ms since the trace started, the gap since the PREVIOUS mark,
/// a global sequence number (cross-marker ordering), and a short detail
/// (byte/char counts). Comparing a `net` line with the `emit`/`render`
/// lines that follow answers "streamed x ms, rendered y ms" from the log
/// alone — the per-chunk cadence of a bursty endpoint vs the render
/// pipeline's own lag.
///
/// OFF by default: the static [mark] is a single null-check until a host
/// calls [start] (the CLI wires that behind `FA_STREAM_TRACE=1`, see
/// `stream_trace_io.dart`). Pure Dart — sinks are injected, so web hosts
/// stay clean.
library;

/// The pipeline stage one trace line names.
enum StreamTraceMark {
  /// Raw provider bytes arrived from the socket.
  net,

  /// A delta event left the provider adapter.
  emit,

  /// The host rendered the delta on its live surface.
  render,
}

/// Where trace lines go. Implementations must not throw — diagnostics
/// never break the host. Sinks must also tolerate being ABANDONED:
/// [StreamTrace.start] replaces the active trace and [StreamTrace.stop]
/// clears it WITHOUT releasing the sink (this interface has no
/// dispose/close hook), so a sink holding resources —
/// `FileStreamTraceSink`'s flush timer, a file handle — must clean up
/// on its own (process exit, or an owner calling its `dispose`).
abstract interface class StreamTraceSink {
  /// Receives one formatted trace body (no trailing newline).
  void writeLine(String line);
}

/// One active trace per process: a stopwatch, a sequence counter, and
/// the last-mark timestamp so each line can name its own gap.
final class StreamTrace {
  StreamTrace._(this._sink) : _sw = Stopwatch()..start();

  final StreamTraceSink _sink;
  final Stopwatch _sw;
  var _lastMs = 0;
  var _seq = 0;
  var _closed = false;

  static StreamTrace? _active;

  /// The currently active trace, if a host started one.
  static StreamTrace? get active => _active;

  /// Starts tracing into [sink], replacing any previous trace, and
  /// returns it.
  static StreamTrace start(StreamTraceSink sink) =>
      _active = StreamTrace._(sink);

  /// Stops and clears the active trace. Marks after this are dropped.
  static void stop() {
    _active?._closed = true;
    _active = null;
  }

  /// Records one mark on the active trace — a no-op when none is active.
  static void mark(StreamTraceMark m, [String detail = '']) =>
      _active?.record(m, detail);

  /// Records one mark: elapsed ms, the gap since the previous mark, the
  /// sequence number, and [detail]. Dropped after [stop].
  void record(StreamTraceMark m, [String detail = '']) {
    if (_closed) return;
    final now = _sw.elapsedMilliseconds;
    final delta = now - _lastMs;
    _lastMs = now;
    _seq++;
    final suffix = detail.isEmpty ? '' : ' $detail';
    _sink.writeLine('t=${now}ms +${delta}ms #$_seq ${m.name}$suffix');
  }
}
