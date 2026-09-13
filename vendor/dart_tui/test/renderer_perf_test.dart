import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/src/renderer.dart';
import 'package:dart_tui/src/view.dart';
import 'package:test/test.dart';

/// PERF — issue #274 AC3: byte-budget of the differential renderer on a
/// 2000-line screen.
///
/// - a static 2000-line screen repaints ZERO bytes
/// - a one-line spinner tick repaints exactly one line (one CUP)
/// - a page scroll is one scroll op + at most one page of fresh rows
void main() {
  late StringBuffer buf;
  late CellRenderer renderer;

  setUp(() {
    buf = StringBuffer();
    renderer = CellRenderer(
      output: _StringSink(buf),
      logSink: null,
      defaultAltScreen: false,
      defaultHideCursor: false,
    );
  });

  final history = List.generate(2000, (i) => 'history line $i — payload');

  test('static 2000-line screen: an idle frame emits zero bytes', () {
    renderer.render(newView(history.join('\n')));
    buf.clear();
    renderer.render(newView(history.join('\n')));
    expect(buf.toString(), '');
  });

  test('spinner tick repaints exactly one line', () {
    var tick = 0;
    String frame() =>
        [...history.take(1999), '⠋ working ${tick++}s'].join('\n');
    renderer.render(newView(frame()));
    buf.clear();
    renderer.render(newView(frame()));
    final out = buf.toString();
    // One cursor-home = one line touched; byte budget stays tiny (CUP +
    // spinner glyph + digits).
    final cups = RegExp(r'\x1b\[\d+;\d+H').allMatches(out).length;
    expect(cups, 1);
    expect(out.length, lessThan(80));
    // And the tick after that is again a single line.
    buf.clear();
    renderer.render(newView(frame()));
    expect(RegExp(r'\x1b\[\d+;\d+H').allMatches(buf.toString()).length, 1);
  });

  test('scroll-by-page is one scroll op + at most one page of rows', () {
    const page = 40;
    renderer.render(newView(history.join('\n')));
    buf.clear();
    final scrolled = [...history.skip(page), ...List.generate(
      page,
      (i) => 'history line ${history.length + i} — payload',
    )];
    renderer.render(newView(scrolled.join('\n')));
    final out = buf.toString();
    expect(out, startsWith('\x1b[$page S'.replaceAll(' ', '')));
    final cups = RegExp(r'\x1b\[\d+;\d+H').allMatches(out).length;
    expect(cups, lessThanOrEqualTo(page));
    // No row outside the fresh page was touched.
    expect(cups, page);
  });

  test('wheel scroll (3 rows) is one scroll op + 3 rows', () {
    renderer.render(newView(history.join('\n')));
    buf.clear();
    final scrolled = [
      ...history.skip(3),
      'history line 2000 — payload',
      'history line 2001 — payload',
      'history line 2002 — payload',
    ];
    renderer.render(newView(scrolled.join('\n')));
    final out = buf.toString();
    expect(out, startsWith('\x1b[3S'));
    expect(RegExp(r'\x1b\[\d+;\d+H').allMatches(out).length, 3);
  });
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
