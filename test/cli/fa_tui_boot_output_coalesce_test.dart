// Issue #503 boot-cost regression: pre-run output (the banner plus the
// restored-session replay — thousands of writeln calls on a marathon
// resume) used to flush one OutputMsg PER CALL into the controller's
// pending queue. The drain at run() then ran a markdown+wrap sync per
// message — measured 5.7s for 1913 lines on a 434MB session, all of it
// inside the drain, invisible to the user as a blank terminal.
//
// The fix coalesces pre-run output in the controller's text buffer (the
// same coalescer the streaming path uses) and flushes it as one
// OutputMsg at the run() drain — one markdown pass over the whole boot
// transcript instead of one per line. Ordering is preserved: _send
// still flushes the buffer ahead of any non-output message.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
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
  test('pre-run sendOutput coalesces into one markdown pass (#503)', () async {
    TranscriptMarkdown.resetDebugCounters();
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

    // The boot storm shape: hundreds of individual writes before run().
    for (var i = 0; i < 500; i++) {
      controller.sendOutput('boot line $i', newline: true);
    }
    final run = controller.run();

    try {
      await waitForIt(() => frames.text.contains('boot line 499'));
      // The whole point: ONE markdown+wrap pass over the boot transcript,
      // not one per writeln. Per-line passes were the 5.7s boot drain on
      // a marathon session (1913 lines).
      final passes =
          TranscriptMarkdown.debugResumedPasses +
          TranscriptMarkdown.debugFullRebuilds;
      expect(
        passes,
        lessThan(10),
        reason:
            'pre-run output must coalesce into a handful of markdown '
            'passes (got $passes — per-line OutputMsgs are back)',
      );
    } finally {
      keys.add([0x03]); // ctrl+c quits the TUI.
      await run;
      await keys.close();
    }
  });

  test(
    'pre-run output interleaved with a non-output message keeps order',
    () async {
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

      controller.sendOutput('before-marker', newline: true);
      controller.sendInputText('x'); // a non-output message
      controller.sendOutput('after-marker', newline: true);
      final run = controller.run();

      try {
        await waitForIt(() => frames.text.contains('after-marker'));
        expect(
          frames.text.indexOf('before-marker'),
          lessThan(frames.text.indexOf('after-marker')),
          reason:
              'a non-output message flushes the buffer first, so the '
              'trailing write must render after the earlier one',
        );
      } finally {
        keys.add([0x03]); // ctrl+c quits the TUI.
        await run;
        await keys.close();
      }
    },
  );
}
