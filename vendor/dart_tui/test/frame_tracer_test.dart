import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/dart_tui.dart';
import 'package:test/test.dart';

/// The keypress→paint tracer: with a [FrameTracer] attached (or the
/// FA_TUI_TRACE env path), the program emits an ordered JSONL timeline of
/// stdin arrivals, drained batches, painted frames and drops — enough to
/// join input latency offline without touching application code.
void main() {
  test('program traces stdin → batch → paint in order', () async {
    final tracer = _ListTracer();
    final sink = _StringSink();
    final controller = StreamController<List<int>>();
    final program = Program(
      options: [
        withoutSignalHandler(),
        withoutCatchPanics(),
        withInput(controller.stream),
        withOutput(sink),
        withTracer(tracer),
      ],
    );
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.add(utf8.encode('hi'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      program.send(QuitMsg());
      await controller.close();
    }());
    await program.run(_Echo());

    final events = tracer.rows.map((r) => r['ev'] as String).toList();
    expect(events.contains('stdin'), isTrue, reason: 'rows: $tracer');
    expect(events.contains('batch'), isTrue);
    expect(events.where((e) => e == 'paint'), isNotEmpty);
    // Timeline is ordered: a paint FOLLOWS the input arrival (the initial
    // frame legitimately paints before any stdin).
    final stdinIdx = events.indexOf('stdin');
    final paintAfter = [
      for (var i = stdinIdx + 1; i < events.length; i++)
        if (events[i] == 'paint') i
    ];
    expect(paintAfter, isNotEmpty,
        reason: 'an input must be followed by a repaint');
    // Timestamps never regress.
    for (var i = 1; i < tracer.rows.length; i++) {
      expect(
        (tracer.rows[i]['t'] as int) >= (tracer.rows[i - 1]['t'] as int),
        isTrue,
        reason: 'row $i regressed: ${tracer.rows}',
      );
    }
  });

  test('FileFrameTracer writes JSONL rows to disk', () async {
    final dir = await Directory.systemTemp.createTemp('fah_trace');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/trace.jsonl');
    final tracer = FileFrameTracer(file);
    tracer.event({'ev': 'stdin', 'bytes': 3});
    tracer.event({'ev': 'paint', 'build_us': 12, 'render_us': 34});
    await tracer.close();
    final lines = file.readAsStringSync().trim().split('\n');
    expect(lines, hasLength(2));
    final first = jsonDecode(lines.first) as Map<String, dynamic>;
    expect(first['ev'], 'stdin');
    expect(first['bytes'], 3);
  });
}

class _Echo extends Model {
  @override
  View view() => View(content: 'ready');

  @override
  (Model, Cmd?) update(Msg msg) => (this, null);
}

final class _ListTracer implements FrameTracer {
  final rows = <Map<String, Object?>>[];
  @override
  void event(Map<String, Object?> fields) => rows.add(fields);
  @override
  Future<void> close() async {}
  @override
  String toString() => rows.toString();
}

class _StringSink implements IOSink {
  final buf = StringBuffer();
  @override
  void write(Object? obj) => buf.write(obj);
  @override
  void writeln([Object? obj = '']) => buf.writeln(obj);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      buf.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => buf.writeCharCode(charCode);
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
