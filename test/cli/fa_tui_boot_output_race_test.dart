// Issue #538 regression: output written through the TUI io BEFORE the
// dart_tui program starts (the whole boot window: plugins register in the
// AgentCli constructor and their connects complete asynchronously — e.g.
// the hub plugin's `[hub] connected as …`) must park in the controller's
// `_pending` queue and render once `run()` starts, never route through
// `Program.send` (which DROPS pre-start messages).
//
// In the wild the loss needed a real `stty` subprocess (~20ms on Linux)
// inside `run()`'s termios sanitize: the output flush fired while the
// controller's `_running` gate was already open but the program had not
// started — the line vanished on slow hosts (the dap PTY integration legs
// timed out on CI, green on fast dev machines). The controller now opens
// the gate only immediately before `_program.run` (zero awaits between)
// and re-drains `_pending` there; everything earlier parks. The full
// end-to-end window is guarded by the dap PTY integration legs; this unit
// test pins the park-and-drain contract at the controller seam.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

class _FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);

  void add(List<int> data) => _bytes.add(data);

  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  String get text => utf8.decode(_bytes.toBytes(), allowMalformed: true);
}

FaTuiCallbacks _callbacks() {
  return FaTuiCallbacks(
    onSubmit: (line, {images = const []}) async {},
    onSteer: (messages) async {},
    onModelSelected: (_) async {},
    buildSlashMenu: (_) => const [],
    buildModelMenu: (_, _) => const [],
    statusLine: () => 'test',
    prompt: 'fa> ',
  );
}

void main() {
  test('output sent before run() and inside run()\'s pre-program window both '
      'render (no dropped boot output, #538)', () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    final controller = FaTuiController(
      callbacks: _callbacks(),
      isExited: () => false,
      programHooks: TuiProgramHooks(
        input: keys.stream,
        output: frames,
        width: 100,
        height: 30,
      ),
    );

    // 1) Before run() entirely: parks in _pending.
    controller.sendOutput('boot-line-parked');
    final run = controller.run();

    // 2) Immediately after run() is entered: run() is suspended at its
    // first await (the termios sanitize). Under the pre-#538 code the
    // gate was already open here and a flush landing in this window
    // went to Program.send — which drops pre-start messages. It must
    // park alongside (1) and drain with it.
    controller.sendOutput('sanitize-window-line');

    try {
      await waitForIt(() => frames.text.contains('boot-line-parked'));
      expect(
        frames.text,
        contains('sanitize-window-line'),
        reason:
            'output flushed during run()\'s pre-program window must '
            'park in _pending and render, not drop via Program.send '
            '(#538)',
      );
      keys.add([0x03]); // ctrl+c quits the TUI.
    } finally {
      await run;
      await keys.close();
    }
  });
}
