import 'dart:async';

import 'package:dart_tui/dart_tui.dart';
import 'package:test/test.dart';

/// The fps throttle must DROP early frames instead of blocking the event
/// loop: messages keep flowing (none lost), paints collapse to the budget
/// rate, and the deferred repaint never blocks message pickup.
void main() {
  test('fps throttle drops frames, never messages', () async {
    final model = _Recorder();
    final program = Program(
      options: [
        withoutRenderer(),
        withoutSignalHandler(),
        withFps(5), // 200 ms frame budget — exaggerates the old sleeps.
        withInput(const Stream.empty()),
      ],
    );

    final watch = Stopwatch()..start();
    unawaited(() async {
      // Stream messages DURING the run so every wakeup races the throttle.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      for (var i = 0; i < 40; i++) {
        program.send(const _Ping());
        await Future<void>.delayed(const Duration(milliseconds: 4));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      program.send(QuitMsg());
    }());

    await program.run(model);
    watch.stop();

    // Every message reached the model exactly once — drops only affect
    // frames.
    expect(
      model.pingCount,
      40,
      reason: 'frame drops must never lose or duplicate messages',
    );

    // The old inline-sleep throttle serialized wakeups behind the frame
    // budget (~200 ms each at fps=5); dropping finishes fast instead.
    expect(watch.elapsedMilliseconds, lessThan(2000));

    // Both instrumentation counters moved: frames painted AND dropped.
    expect(program.debugFramesPainted, greaterThanOrEqualTo(1));
    expect(program.debugFramesDropped, greaterThanOrEqualTo(5));
  });
}

class _Ping extends Msg {
  const _Ping();
}

class _Recorder extends Model {
  var pingCount = 0;

  @override
  View view() => View(content: 'x');

  @override
  (Model, Cmd?) update(Msg msg) {
    if (msg is _Ping) {
      pingCount++;
    }
    return (this, null);
  }
}
