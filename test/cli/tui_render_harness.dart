// Shared harness for the TUI frame tests (fa_tui_sticky_scroll_test.dart,
// fa_tui_viewport_fold_test.dart): a minimal IOSink over a StringBuffer
// capturing what the renderer would write to the tty. One copy — the next
// IOSink interface change breaks one file, not every clone.
library;

import 'dart:convert';
import 'dart:io';

/// Minimal [IOSink] over a [StringBuffer] capturing what the renderer would
/// write to the tty.
final class StringSinkIOSink implements IOSink {
  StringSinkIOSink(this._buf);
  final StringBuffer _buf;

  @override
  void write(Object? obj) => _buf.write(obj);
  @override
  void writeln([Object? obj = '']) => _buf.writeln(obj);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buf.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _buf.writeCharCode(charCode);
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Encoding get encoding => utf8;
  @override
  set encoding(Encoding value) {}
}
