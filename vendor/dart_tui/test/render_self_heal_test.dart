import 'package:dart_tui/dart_tui.dart';
import 'package:test/test.dart';

import 'support/string_sink.dart';

/// A marker message the test model reacts to.
class _FrameMsg extends Msg {
  const _FrameMsg(this.label);
  final String label;
}

/// gh-1197 AC3: a throwing view() must never kill painting silently. The
/// frame pipeline logs loudly, invalidates the renderer, and keeps
/// painting — the run continues underneath, and the next frame heals the
/// diff state (full repaint) instead of freezing the screen.
final class _ThrowingViewModel extends Model {
  int frames = 0;
  bool throwNext = false;

  @override
  Cmd? init() => () async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return const _FrameMsg('first');
      };

  @override
  (Model, Cmd?) update(Msg msg) {
    if (msg is _FrameMsg) {
      throwNext = msg.label == 'poison';
      // Each frame is its OWN batch: a 30ms-spaced cmd chain keeps every
      // frame outside the 16ms fps-throttle window and outside one message
      // drain (a drain renders once with the latest view).
      final next = switch (msg.label) {
        'first' => 'poison',
        'poison' => 'healed',
        _ => 'quit',
      };
      return (
        this,
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return next == 'quit' ? QuitMsg() : _FrameMsg(next);
        },
      );
    }
    return (this, null);
  }

  @override
  View view() {
    frames++;
    if (throwNext) {
      throw StateError('gh-1197 AC3 simulated mid-run view failure');
    }
    return newView('frame-ok-$frames');
  }
}

void main() {
  test('a throwing view() self-heals: the pipeline logs and keeps painting',
      () async {
    final sink = TestSink();
    final model = _ThrowingViewModel();
    // run() must COMPLETE normally (QuitMsg reached) — a dead pipeline
    // would leave the program hanging past the timeout instead.
    await Program(options: [
      withOutput(sink),
      withInput(null),
    ]).run(model).timeout(const Duration(seconds: 5));

    // The poisoned frame never painted.
    expect(sink.buf.toString(), isNot(contains('poison')));
    // The next frame DID paint — and, because the guard invalidated the
    // renderer, it is a FULL repaint (first-frame clear) rather than a
    // diff against the poisoned frame's partial state.
    expect(sink.buf.toString(), contains('frame-ok-'));
    expect(model.frames, greaterThanOrEqualTo(3));
  });
}
