import 'package:dart_tui/dart_tui.dart';
import 'package:test/test.dart';

import 'support/string_sink.dart';

/// A marker message a [Model] can watch for.
final class _Survived extends Msg {
  const _Survived(this.tag);
  final String tag;
}

/// gh-1248 regression: an exception inside a Cmd or update() must NEVER
/// stop the program. The guards used to enqueue InterruptMsg, which set
/// `_running = false` — the program died while the embedding CLI kept
/// running, and `Program.send` then silently dropped every later message:
/// the agent kept answering into a screen that never painted again (the
/// dap_wake_hang flake family). The render pipeline's own self-heal is
/// pinned separately by render_self_heal_test.dart (gh-1197).
void main() {
  test('a throwing Cmd is logged and the program keeps running', () async {
    final sink = TestSink();
    var survived = false;
    final program = Program(options: [
      withOutput(sink),
      withInput(null),
      withoutRenderer(),
      withoutSignalHandler(),
    ]);
    addTearDown(program.kill);
    await program.run(_CmdThrowerModel(() => survived = true));
    expect(survived, isTrue, reason: 'msgs after the throwing Cmd must land');
  });

  test('a throwing update() is logged and the program keeps running',
      () async {
    final sink = TestSink();
    var survived = false;
    final program = Program(options: [
      withOutput(sink),
      withInput(null),
      withoutRenderer(),
      withoutSignalHandler(),
    ]);
    addTearDown(program.kill);
    await program.run(_UpdateThrowerModel(() => survived = true));
    expect(survived, isTrue, reason: 'msgs after the throwing update must land');
  });
}

/// Drives: poison Cmd → survivor marker → quit.
final class _CmdThrowerModel extends Model {
  _CmdThrowerModel(this.onSurvived);
  final void Function() onSurvived;

  @override
  Cmd? init() => sequence([
        () => throw StateError('poisoned cmd (gh-1248)'),
        () => const _Survived('cmd'),
        () => QuitMsg(),
      ]);

  @override
  (Model, Cmd?) update(Msg msg) {
    if (msg is _Survived) onSurvived();
    return (this, null);
  }

  @override
  View view() => newView('cmd-thrower');
}

/// Drives: poison update → survivor marker → quit.
final class _UpdateThrowerModel extends Model {
  _UpdateThrowerModel(this.onSurvived);
  final void Function() onSurvived;
  var _threw = false;

  @override
  Cmd? init() => sequence([
        () => const _Survived('poison'),
        () => const _Survived('update'),
        () => QuitMsg(),
      ]);

  @override
  (Model, Cmd?) update(Msg msg) {
    if (msg is _Survived && msg.tag == 'poison' && !_threw) {
      _threw = true;
      throw StateError('poisoned update (gh-1248)');
    }
    if (msg is _Survived && msg.tag == 'update') onSurvived();
    return (this, null);
  }

  @override
  View view() => newView('update-thrower');
}
