// Issue #827 × #503 × #446: a RESUMED session's first glass must keep the
// boot chrome (banner, the #503 lost-tasks reconciliation summary) AND the
// replayed tail on screen. The resume replay therefore never anchors the
// window at the replayed last-prompt echo — that pin is a LIVE-submit
// semantic and would fold the pre-echo boot notices away (the SM-CI
// regression this pins: resume_tail_grid lost `got 0` at both geometries).
// The resumed window rides the same global bottom the session rode at
// close (#446 1:1); the user's first LIVE submit re-arms the turn
// boundary.
//
// Real controller + real program loop over an in-memory frame sink — no
// PTY, no IO (the PTY suites need a host tty).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart'
    show TuiProgramHooks, stripAnsi;
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

FaTuiCallbacks _callbacks() => FaTuiCallbacks(
  onSubmit: (_, {images = const []}) async {},
  onModelSelected: (_) async {},
  buildSlashMenu: (_) => const [],
  buildModelMenu: (_, _) => const [],
  statusLine: () => 'test',
  prompt: 'fa> ',
);

/// The resumed boot's io sequence (agent_cli_repl_boot.dart): banner rows,
/// the #503 reconciliation summary (dim), then the replayed transcript
/// (restored-session header + the last prompt echo + its reply).
const _summary = '✗ 10 background tasks lost on restart '
    '(process gone, no exit reported): sh-1-stale503 · sh-2-stale503';

List<String> _bootLines() => const [
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
  '  key: env secret',
  '',
  '[Session]',
  '  resume-tail-503',
  '  /tmp/fa_tui_503_x/.fah/sessions/resume-tail-503.jsonl',
  _summary,
  '─── restored session: resume-tail-503 (2 messages)',
  '╭─',
  '│ produce the anchor reply',
  '╰─',
  '',
  '>_Fa FINAL-TAIL-MARKER-503 the resumed answer tail',
  '────────────────────',
];

Future<String> _resumedScreen(int width, int height) async {
  final frames = _FrameSink();
  final keys = StreamController<List<int>>();
  final controller = FaTuiController(
    callbacks: _callbacks(),
    isExited: () => false,
    programHooks: TuiProgramHooks(
      input: keys.stream,
      output: frames,
      width: width,
      height: height,
    ),
  );
  for (final line in _bootLines()) {
    controller.sendOutput(line, newline: true);
  }
  final run = controller.run();
  await waitForIt(() => frames.text.contains('FINAL-TAIL-MARKER'));
  final screen = stripAnsi(frames.text);
  keys.add([0x03]); // press 1 arms the double-press window (#830)
  keys.add([0x03]); // press 2 quits the TUI
  await run;
  await keys.close();
  return screen;
}

void main() {
  for (final (width, height) in [(80, 24), (100, 40)]) {
    test('resumed boot glass at $width x $height keeps the reconciliation '
        'summary and the replayed tail', () async {
      final screen = await _resumedScreen(width, height);
      expect(screen, contains('lost on restart'),
          reason: 'the #503 summary must stay on the first resumed glass');
      expect(screen, contains('produce the anchor reply'),
          reason: 'the replayed last prompt stays on the glass');
      expect(screen, contains('FINAL-TAIL-MARKER-503'),
          reason: 'the replayed tail is the final paint');
    }, timeout: const Timeout(Duration(seconds: 60)));
  }

  test('the first LIVE submit after a resume re-arms the turn boundary',
      () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    final controller = FaTuiController(
      callbacks: _callbacks(),
      isExited: () => false,
      programHooks: TuiProgramHooks(
        input: keys.stream,
        output: frames,
        width: 80,
        height: 24,
      ),
    );
    for (var i = 0; i < 40; i++) {
      controller.sendOutput('old row $i', newline: true);
    }
    final run = controller.run();
    await waitForIt(() => frames.text.contains('old row 39'));
    keys.add('next turn'.codeUnits);
    keys.add([0x0d]); // enter — the live submit pins the window at ITS echo
    await waitForIt(() => frames.text.contains('next turn'));
    final screen = stripAnsi(frames.text);
    expect(screen, contains('next turn'),
        reason: 'the new echo is the window top after a live submit');
    expect(screen, isNot(contains('old row 1 ')),
        reason: 'pre-turn rows fold once the turn boundary re-arms');
    keys.add([0x03]);
    keys.add([0x03]);
    await run;
    await keys.close();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
