import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/src/renderer.dart';
import 'package:dart_tui/src/view.dart';
import 'package:test/test.dart';

void main() {
  test('AnsiRenderer wraps frame with sync markers when syncUpdates enabled',
      () {
    final buf = StringBuffer();
    final sink = _StringSink(buf);
    final renderer = AnsiRenderer(
      output: sink,
      logSink: null,
      defaultAltScreen: false,
      defaultHideCursor: false,
    );
    renderer.setSyncUpdates(true);
    renderer.render(newView('hello'));
    final output = buf.toString();
    expect(output, contains('\x1b[?2026h'));
    expect(output, contains('\x1b[?2026l'));
    // Sync start must come before sync end
    expect(
        output.indexOf('\x1b[?2026h'), lessThan(output.indexOf('\x1b[?2026l')));
  });

  test('AnsiRenderer does NOT wrap frame when syncUpdates disabled', () {
    final buf = StringBuffer();
    final sink = _StringSink(buf);
    final renderer = AnsiRenderer(
      output: sink,
      logSink: null,
      defaultAltScreen: false,
      defaultHideCursor: false,
    );
    renderer.render(newView('hello'));
    final output = buf.toString();
    expect(output, isNot(contains('\x1b[?2026h')));
    expect(output, isNot(contains('\x1b[?2026l')));
  });

  // ── CellRenderer synchronized output — issue #274 (AC2) ───────────────────

  test('CellRenderer wraps painted frames in BSU…ESU when enabled', () {
    final buf = StringBuffer();
    final sink = _StringSink(buf);
    final renderer = CellRenderer(
      output: sink,
      logSink: null,
      defaultAltScreen: false,
      defaultHideCursor: false,
    );
    renderer.setSyncUpdates(true);
    renderer.render(newView('hello'));
    final output = buf.toString();
    expect(output, endsWith('\x1b[?2026l'));
    // One-time mode setup may precede the frame; the paint itself sits
    // inside the atomic region.
    expect(
      output.indexOf('\x1b[?2026h'),
      lessThan(output.indexOf('\x1b[1;1H\x1b[K')),
    );
    expect(
      output.lastIndexOf('\x1b[?2026l'),
      greaterThan(output.lastIndexOf('hello')),
    );
    // Exactly one pair per frame.
    expect('?2026h'.allMatches(output).length, 1);
    expect('?2026l'.allMatches(output).length, 1);
  });

  test('CellRenderer scroll frames are wrapped atomically too', () {
    final buf = StringBuffer();
    final sink = _StringSink(buf);
    final renderer = CellRenderer(
      output: sink,
      logSink: null,
      defaultAltScreen: false,
      defaultHideCursor: false,
    );
    renderer.setSyncUpdates(true);
    final prev = [for (var i = 0; i < 10; i++) 'row-$i'].join('\n');
    final next = [for (var i = 1; i <= 10; i++) 'row-$i'].join('\n');
    renderer.render(newView(prev));
    buf.clear();
    renderer.render(newView(next));
    final output = buf.toString();
    expect(output, startsWith('\x1b[?2026h\x1b[1S'));
    expect(output, endsWith('\x1b[?2026l'));
  });

  test('CellRenderer idle frames emit zero bytes even with sync enabled', () {
    final buf = StringBuffer();
    final sink = _StringSink(buf);
    final renderer = CellRenderer(
      output: sink,
      logSink: null,
      defaultAltScreen: false,
      defaultHideCursor: false,
    );
    renderer.setSyncUpdates(true);
    renderer.render(newView('hello'));
    buf.clear();
    renderer.render(newView('hello'));
    expect(buf.toString(), '');
  });

  test('CellRenderer sync OFF is byte-identical to the legacy writes', () {
    // The same two frames as the ON case: with capability off the stream
    // carries no 2026 bytes and the painted bytes are unchanged.
    final offBuf = StringBuffer();
    final off = CellRenderer(
      output: _StringSink(offBuf),
      logSink: null,
      defaultAltScreen: false,
      defaultHideCursor: false,
    );
    off.render(newView('hello'));
    offBuf.clear();
    off.render(newView('hellX'));
    final legacy = offBuf.toString();
    expect(legacy, '\x1b[1;5HX');
    expect(legacy, isNot(contains('?2026')));
  });
}

extension on String {
  int allMatches(String s) => RegExp(escape(this)).allMatches(s).length;
}

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
