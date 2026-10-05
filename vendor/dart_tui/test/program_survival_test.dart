import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/dart_tui.dart';
import 'package:test/test.dart';

class _StringSink implements IOSink {
  final StringBuffer buf = StringBuffer();
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
  void add(List<int> data) => buf.write(utf8.decode(data));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Encoding get encoding => utf8;
  @override
  set encoding(Encoding value) {}
}

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
/// dap_wake_hang flake family). The view()-throw test pins the gh-1197
/// render-pipeline self-heal along the same ghost chain.
void main() {
  test('a throwing Cmd is logged and the program keeps running', () async {
    final sink = _StringSink();
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
    final sink = _StringSink();
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

  test('a throwing view() does not kill the loop; rendering recovers',
      () async {
    final sink = _StringSink();
    final program = Program(options: [
      withOutput(sink),
      withInput(null),
      withoutRenderer(),
      withoutSignalHandler(),
    ]);
    addTearDown(program.kill);
    final model = _ViewThrowerModel();
    await program.run(model);
    expect(model.viewsBuilt, greaterThan(0));
    expect(model.recovered, isTrue,
        reason: 'a failed frame must not end the program');
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

/// Throws in view() while armed, then recovers; the loop must survive both
/// phases and process the quit.
final class _ViewThrowerModel extends Model {
  var viewsBuilt = 0;
  var recovered = false;

  @override
  Cmd? init() => sequence([
        () => const _Survived('arm'),
        () => const _Survived('disarm'),
        () => QuitMsg(),
      ]);

  @override
  (Model, Cmd?) update(Msg msg) {
    if (msg is _Survived && msg.tag == 'arm') _throwUntilDisarm = true;
    if (msg is _Survived && msg.tag == 'disarm') _throwUntilDisarm = false;
    return (this, null);
  }

  var _throwUntilDisarm = false;

  @override
  View view() {
    viewsBuilt++;
    if (_throwUntilDisarm) throw StateError('poisoned view (gh-1248)');
    if (viewsBuilt > 1) recovered = true;
    return newView('view-thrower');
  }
}
