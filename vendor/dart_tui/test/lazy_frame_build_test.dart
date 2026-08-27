import 'dart:async';

import 'package:dart_tui/dart_tui.dart';
import 'package:test/test.dart';

/// A dropped frame must not pay for the view either: the eager
/// `render(model.view())` built the whole screen string upstream even when
/// the fps throttle threw the frame away. With lazy building, view builds
/// happen ONLY for painted frames — one build per paint, none per drop.
void main() {
  test('dropped frames never build the view', () async {
    final model = _BuildCounter();
    final program = Program(
      options: [
        withoutRenderer(),
        withoutSignalHandler(),
        withFps(5), // 200 ms budget — forces plenty of drops below.
        withInput(const Stream.empty()),
      ],
    );

    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      for (var i = 0; i < 40; i++) {
        program.send(const _Ping());
        await Future<void>.delayed(const Duration(milliseconds: 4));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      program.send(QuitMsg());
    }());

    await program.run(model);

    expect(program.debugFramesDropped, greaterThanOrEqualTo(5));
    // Every PAINTED frame builds its view exactly once; DROPPED frames must
    // never reach the model's view builder (the old code paid the full
    // assembly for frames it then discarded).
    expect(model.buildCount, program.debugFramesPainted);
    expect(model.pingCount, 40);
  });
}

class _Ping extends Msg {
  const _Ping();
}

final class _BuildCounter extends Model {
  var pingCount = 0;
  var buildCount = 0;

  @override
  View view() {
    buildCount++;
    return View(content: 'x');
  }

  @override
  (Model, Cmd?) update(Msg msg) {
    if (msg is _Ping) pingCount++;
    return (this, null);
  }
}
