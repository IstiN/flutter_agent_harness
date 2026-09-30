// Repro: detached follow (scroll up mid-run) + resize taller than the
// transcript while the sticky echo is armed -> paintedTop < 0 ->
// scrollOffset.clamp(0, negative) throws ArgumentError in _framePlanFor.
import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:test/test.dart';

void main() {
  test('detached + huge resize does not crash the frame plan (#917 edge)', () {
    FaTuiCallbacks callbacks() => FaTuiCallbacks(
      onSubmit: (_, {images = const []}) async {},
      onModelSelected: (_) async {},
      buildSlashMenu: (_) => const [],
      buildModelMenu: (_, _) => const [],
      statusLine: () => '',
      prompt: '',
    );
    FaTuiModel send(FaTuiModel model, Msg msg) =>
        model.update(msg).$1 as FaTuiModel;

    var model = FaTuiModel(
      callbacks: callbacks(),
      isExited: () => false,
      termWidth: 80,
      termHeight: 24,
    );
    model = model.copyWith(inputText: 'the pinned prompt echo');
    model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    model = send(model, const BusyMsg(true, source: 'run'));
    for (var i = 0; i < 40; i++) {
      model = send(model, OutputMsg('answer line $i', newline: true));
    }
    // Detach: wheel up mid-run.
    model = send(
      model,
      const MouseWheelMsg(Mouse(wheel: 0, button: MouseButton.wheelUp)),
    );
    expect(model.followTail, isFalse, reason: 'wheel up must detach follow');
    // Resize the terminal far taller than the transcript.
    model = send(model, const WindowSizeMsg(width: 80, height: 200));
    // Pre-fix #917 this frame crashed with ArgumentError (clamp 0..negative).
    final view = model.view(); // <-- must not throw
    expect(view.content, isNotEmpty);
  });
}
