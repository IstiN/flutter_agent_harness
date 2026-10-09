import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart'
    show TuiProgramHooks, stripAnsi;

class FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);
  void add(List<int> data) => _bytes.add(data);
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

Future<void> main() async {
  final frames = FrameSink();
  final keys = StreamController<List<int>>();
  final controller = FaTuiController(
    callbacks: FaTuiCallbacks(
      onSubmit: (_, {images = const []}) async {},
      onModelSelected: (_) async {},
      buildSlashMenu: (_) => const [],
      buildModelMenu: (_, _) => const [],
      statusLine: () => 'test',
      prompt: 'fa> ',
    ),
    isExited: () => false,
    programHooks: TuiProgramHooks(
      input: keys.stream,
      output: frames,
      width: 80,
      height: 24,
    ),
  );
  const banner = [
    '◆ v1.0.494',
    'esc interrupt · ctrl+c clear · double ctrl+c exit · / commands · ! bash',
    'Press /help to show full commands and resources.',
    '',
    '[Context]',
    '  /tmp/fa_tui_503_x/proj',
    '',
    '[Model]',
    '  mock-model (test-api)',
    '  endpoint: https://example.test',
    '',
    '[Session]',
    '  pty446',
  ];
  const summary = '✗ 1 background task lost on restart '
      '(process gone, no exit reported): sh-1-stale503';
  for (final line in banner) {
    controller.sendOutput(line, newline: true);
  }
  controller.markReplayAnchor();
  controller.sendOutput(summary, newline: true);
  final run = controller.run();
  await Future<void>.delayed(const Duration(seconds: 2));
  final screen = stripAnsi(frames.text);
  var i = 0;
  for (final row in screen.split('\n')) {
    // ignore: avoid_print
    print('$i: [$row]');
    i++;
  }
  keys.add([0x03]);
  keys.add([0x03]);
  await run;
  await keys.close();
}
