import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/dart_tui.dart';
import 'package:test/test.dart';

void main() {
  test('program emits terminal request sequences', () async {
    final chunks = <String>[];
    final controller = StreamController<List<int>>();
    controller.stream.listen((data) => chunks.add(utf8.decode(data)));
    final sink = IOSink(controller.sink);

    final program = Program(
      options: [
        withInput(const Stream<List<int>>.empty()),
        withOutput(sink),
      ],
    );

    await program.run(_RequestModel());
    await sink.flush();
    final out = chunks.join();
    expect(out, contains('\x1b]10;?\x07'));
    expect(out, contains('\x1b[6n'));
    expect(out, contains('\x1b[?2026\$p'));
    expect(out, contains('\x1b[?2027\$p'));

    await sink.close();
    await controller.close();
  });

  test('withSyncUpdates forces BSU/ESU without a DECRQM answer', () async {
    final chunks = <String>[];
    final controller = StreamController<List<int>>();
    controller.stream.listen((data) => chunks.add(utf8.decode(data)));
    final sink = IOSink(controller.sink);

    final program = Program(
      options: [
        withInput(const Stream<List<int>>.empty()),
        withOutput(sink),
        withSyncUpdates(),
      ],
    );

    await program.run(_SyncProbeModel());
    await sink.flush();
    final out = chunks.join();
    // No ModeReportMsg(2026) was ever fed — the option forces the framing.
    expect(out, contains('\x1b[?2026h'));
    expect(out, contains('\x1b[?2026l'));
    expect(out.indexOf('\x1b[?2026h'), lessThan(out.indexOf('painted')));
    expect(out.lastIndexOf('\x1b[?2026l'), greaterThan(out.lastIndexOf('painted')));

    await sink.close();
    await controller.close();
  });

  test('withoutSyncUpdates blocks framing even when the terminal reports 2026',
      () async {
    final chunks = <String>[];
    final controller = StreamController<List<int>>();
    controller.stream.listen((data) => chunks.add(utf8.decode(data)));
    final sink = IOSink(controller.sink);

    final program = Program(
      options: [
        withInput(const Stream<List<int>>.empty()),
        withOutput(sink),
        withoutSyncUpdates(),
      ],
    );

    final model = _SyncProbeModel();
    await program.run(model);
    await sink.flush();
    final out = chunks.join();
    expect(out, contains('painted'));
    expect(out, isNot(contains('?2026h')));
    expect(out, isNot(contains('?2026l')));
    // The blocked report did reach the program (the model recorded it).
    expect(model.sawSyncReport, isTrue);

    await sink.close();
    await controller.close();
  });

  test('program with tickInterval exits cleanly after quit', () async {
    final program = Program(
      options: [
        withInput(null),
        withTickInterval(const Duration(milliseconds: 10)),
      ],
    );

    await program.run(_ImmediateQuitModel());
  });
}

final class _RequestModel extends Model {
  @override
  Cmd? init() {
    return sequence([
      () => requestForegroundColor(),
      () => requestCursorPosition(),
      () => quit(),
    ]);
  }

  @override
  (Model, Cmd?) update(Msg msg) => (this, null);

  @override
  View view() => newView('');
}

final class _ImmediateQuitModel extends Model {
  @override
  Cmd? init() => () => quit();

  @override
  (Model, Cmd?) update(Msg msg) => (this, null);

  @override
  View view() => newView('');
}
/// Paints one visible frame and feeds a synthetic DECRQM(2026)=1 report.
final class _SyncProbeModel extends Model {
  var _frame = 0;
  var sawSyncReport = false;

  @override
  Cmd? init() => sequence([
        () => ModeReportMsg(mode: 2026, value: 1),
        () => TickMsg(DateTime.now()),
      ]);

  @override
  (Model, Cmd?) update(Msg msg) {
    if (msg is ModeReportMsg && msg.mode == 2026) sawSyncReport = true;
    if (msg is TickMsg) _frame++;
    return (this, _frame == 1 ? () => quit() : null);
  }

  @override
  View view() => newView('painted');
}
