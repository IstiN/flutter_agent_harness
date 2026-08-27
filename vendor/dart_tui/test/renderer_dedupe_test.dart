import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/src/renderer.dart';
import 'package:dart_tui/src/terminal_control.dart' show windowTitleSequence;
import 'package:dart_tui/src/view.dart';
import 'package:test/test.dart';

class _StringSink implements IOSink {
  _StringSink(this._buf);
  final StringBuffer _buf;
  @override
  void write(Object? obj) => _buf.write(obj);
  @override
  void writeln([Object? obj = '']) => _buf.writeln(obj);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
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

View _view(String content, {String title = '', Cursor? cursor}) =>
    View(content: content, windowTitle: title, cursor: cursor);

/// Idle-frame output hygiene: an unchanged title must not re-emit its OSC
/// sequence every frame, and an unmoved cursor must not re-emit CUP. Both
/// used to be written unconditionally per render — pure escape churn the
/// terminal has to parse.
void main() {
  test('window title is emitted once, not on every frame', () {
    final buf = StringBuffer();
    final renderer = AnsiRenderer(
      output: _StringSink(buf),
      defaultAltScreen: false,
      defaultHideCursor: false,
    );
    renderer.render(_view('a', title: 'fa'));
    final afterFirst = buf.length;
    // Same title, changed content → row diff only, no OSC title repeat.
    renderer.render(_view('b', title: 'fa'));
    expect(buf.toString().indexOf(windowTitleSequence('fa')),
        lessThan(afterFirst));
    expect(
        windowTitleSequence('fa')
            .allMatches(buf.toString().substring(afterFirst)),
        isEmpty);
    // Title change still emits.
    renderer.render(_view('c', title: 'other'));
    expect(buf.toString().contains(windowTitleSequence('other')), isTrue);
  });

  test('unmoved cursor emits CUP once; moving it re-homes', () {
    final buf = StringBuffer();
    final renderer = AnsiRenderer(
      output: _StringSink(buf),
      defaultAltScreen: false,
      defaultHideCursor: false,
    );
    const cursor = Cursor(x: 3, y: 4, shape: CursorShape.bar);
    renderer.render(_view('a', cursor: cursor));
    renderer.render(_view('a', cursor: cursor)); // identical frame + cursor
    final firstFrameCups = '\x1b[5;4H'.allMatches(buf.toString()).length;
    expect(firstFrameCups, 1,
        reason: 'identical repaint must not re-home the cursor');
    renderer.render(_view('b', cursor: const Cursor(x: 7, y: 2)));
    expect(buf.toString().contains('\x1b[3;8H'), isTrue);
  });

  test('a repaint still re-homes the SAME-position cursor', () {
    final buf = StringBuffer();
    final renderer = AnsiRenderer(
      output: _StringSink(buf),
      defaultAltScreen: false,
      defaultHideCursor: false,
    );
    const cursor = Cursor(x: 3, y: 4, shape: CursorShape.bar);
    renderer.render(_view('one\ntwo', cursor: cursor));
    // A changed row repaint physically moves the terminal cursor away from
    // home; even an unchanged logical position must be re-emitted.
    renderer.render(_view('ONE\ntwo', cursor: cursor));
    expect('\x1b[5;4H'.allMatches(buf.toString()).length, 2);
    // But a NO-OP frame writes nothing at all (no CUP churn).
    final before = buf.length;
    renderer.render(_view('ONE\ntwo', cursor: cursor));
    expect(buf.length, before);
  });

  test('clearScreen invalidates the cursor dedupe cache', () {
    final buf = StringBuffer();
    final renderer = AnsiRenderer(
      output: _StringSink(buf),
      defaultAltScreen: false,
      defaultHideCursor: false,
    );
    const cursor = Cursor(x: 0, y: 0, shape: CursorShape.bar);
    renderer.render(_view('a', cursor: cursor));
    buf.clear();
    renderer.clearScreen();
    renderer.render(_view('a', cursor: cursor));
    // clearScreen homes the terminal cursor to 1;1 behind our back — the
    // same logical position must be RE-emitted.
    expect(buf.toString().contains('\x1b[1;1H'), isTrue);
  });
}
