import 'dart:async';

import 'package:dart_tui/dart_tui.dart';
import 'package:test/test.dart';

/// Input-driven frames must bypass the fps throttle: a key press inside
/// the min-frame window paints IMMEDIATELY (echo latency is the
/// user-perceived typing speed), while non-input frames keep collapsing
/// to the budget rate. Port of the kitty `input_delay`/`repaint_delay`
/// split (docs: adaptive frame pacing, the input lane wins).
void main() {
  test('a key press inside the throttle window still paints', () async {
    final model = _Recorder();
    final program = Program(
      options: [
        withoutRenderer(),
        withoutSignalHandler(),
        withFps(2), // 500 ms frame budget.
        withInput(const Stream.empty()),
      ],
    );

    var paintedAtKeyCheck = -1;
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      program.send(const _Ping());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Key lands WELL inside the 500 ms window of the last paint.
      program.send(KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'a')));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      paintedAtKeyCheck = program.debugFramesPainted;
      program.send(QuitMsg());
    }());

    await program.run(model);

    expect(model.keyCount, 1);
    expect(
      paintedAtKeyCheck,
      greaterThanOrEqualTo(2),
      reason: 'input frames must not be dropped by the fps throttle',
    );
  });

  test('a mouse wheel inside the window still paints', () async {
    final model = _Recorder();
    final program = Program(
      options: [
        withoutRenderer(),
        withoutSignalHandler(),
        withFps(2),
        withInput(const Stream.empty()),
      ],
    );

    var paintedAtWheelCheck = -1;
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      program.send(const _Ping());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      program.send(
        MouseWheelMsg(const Mouse(x: 1, y: 1, button: MouseButton.wheelUp)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      paintedAtWheelCheck = program.debugFramesPainted;
      program.send(QuitMsg());
    }());

    await program.run(model);

    expect(model.mouseCount, 1);
    expect(paintedAtWheelCheck, greaterThanOrEqualTo(2));
  });

  test('non-input frames inside the window still drop', () async {
    final model = _Recorder();
    final program = Program(
      options: [
        withoutRenderer(),
        withoutSignalHandler(),
        withFps(2),
        withInput(const Stream.empty()),
      ],
    );

    var paintedAtPingCheck = -1;
    var droppedAtPingCheck = -1;
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      program.send(const _Ping());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      program.send(const _Ping());
      await Future<void>.delayed(const Duration(milliseconds: 120));
      paintedAtPingCheck = program.debugFramesPainted;
      droppedAtPingCheck = program.debugFramesDropped;
      program.send(QuitMsg());
    }());

    await program.run(model);

    expect(model.pingCount, 2);
    expect(paintedAtPingCheck, 1);
    expect(droppedAtPingCheck, greaterThanOrEqualTo(1));
  });
}

class _Ping extends Msg {
  const _Ping();
}

class _Recorder extends Model {
  var pingCount = 0;
  var keyCount = 0;
  var mouseCount = 0;

  @override
  View view() => View(content: 'x');

  @override
  (Model, Cmd?) update(Msg msg) {
    switch (msg) {
      case _Ping():
        pingCount++;
      case KeyMsg():
        keyCount++;
      case MouseMsg():
        mouseCount++;
    }
    return (this, null);
  }
}
