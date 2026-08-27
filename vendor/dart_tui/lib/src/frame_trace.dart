import 'dart:convert';
import 'dart:io';

/// Receives one structured row per traced event while a [Program] runs.
///
/// Attach one with [withTracer], or set the `FA_TUI_TRACE` environment
/// variable to a file path to get a default [FileFrameTracer]. Events are
/// plain maps serialized as JSONL; every row carries the program's
/// monotonically increasing `t` (microseconds since the run started), so
/// offline joins can order stdin arrivals against drained batches and
/// painted/dropped frames.
abstract interface class FrameTracer {
  /// Emits one event; called synchronously from the program's event loop,
  /// implementations must not block noticeably.
  void event(Map<String, Object?> fields);

  /// Releases underlying resources (file handles). Called by the program
  /// when the run ends.
  Future<void> close();
}

/// Writes trace rows as JSONL into a file (opened lazily, appended).
final class FileFrameTracer implements FrameTracer {
  FileFrameTracer(this.file);

  final File file;
  IOSink? _sink;

  @override
  void event(Map<String, Object?> fields) {
    _sink ??= file.openWrite(mode: FileMode.append);
    _sink!.writeln(jsonEncode(fields));
  }

  @override
  Future<void> close() =>
      _sink?.flush().then((_) => _sink?.close()) ?? Future<void>.value();
}
