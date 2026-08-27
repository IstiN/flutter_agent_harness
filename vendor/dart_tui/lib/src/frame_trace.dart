import 'dart:async';
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

  /// dart:io forbids writes while a flush is in flight ("sink is bound to
  /// a stream"), so every write chains through this queue: write → flush →
  /// next. Ordering is preserved and a hard kill can only lose the row
  /// that is literally mid-write.
  Future<void> _queue = Future<void>.value();

  @override
  void event(Map<String, Object?> fields) {
    _queue = _queue.then((_) async {
      final sink = _sink ??= file.openWrite(mode: FileMode.append);
      sink.writeln(jsonEncode(fields));
      await sink.flush();
    }).catchError((Object _) {
      // A failing trace must never break the traced program.
    });
  }

  @override
  Future<void> close() => _queue.then((_) => _sink?.close());
}
