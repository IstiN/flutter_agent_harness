// Issue #510: a selection-only picker must hide the PHYSICAL cursor on the
// wire. The view says `cursor: null`, but the visibility signal has to reach
// the terminal: the cell renderer parses frame content into an SGR-only
// cell grid, so a DECTCEM (?25l/?25h) escape smuggled inside the content
// never lands on the wire — the cursor stayed visible, stranded on the last
// painted cell (settings/provider/wizard screens). Headless: the full
// AgentCli boots in-process, key bytes are scripted through
// TuiProgramHooks.input, rendered frame bytes are captured through
// TuiProgramHooks.output — no real terminal involved.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Collects rendered frame bytes (dart_tui wraps this into an IOSink).
class _FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);

  // Plain members: IOSink invokes them through the runtime instance, but
  // they are not part of the StreamConsumer interface.
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

Future<void> _run() async {
  final frames = _FrameSink();
  final keys = StreamController<List<int>>();
  final env = MemoryExecutionEnv(cwd: '/work');
  final io = FakeCliIO();
  final cli = AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      // No terminal answers DECRQM in headless mode — force legacy writes
      // (the FA_TUI_SYNC=0 path); cursor visibility is orthogonal to
      // BSU/ESU framing.
      tuiSyncOutput: false,
      tuiProgramHooks: TuiProgramHooks(
        input: keys.stream,
        output: frames,
        width: 80,
        height: 24,
      ),
    ),
    io: io,
    useTui: true,
    streamFunction: FakeStreamFunction(const []).call,
  );
  final run = cli.run();
  try {
    // The first frame renders before the capability queries; the alt-screen
    // enter proves the boot reached the frame renderer.
    await waitForIt(
      () => frames.text.contains('\x1b[?1049h'),
      reason: 'alt-screen boot frame',
    );

    // Open the settings hub: /settings + Enter.
    keys.add(utf8.encode('/settings'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    keys.add([0x0d]); // Enter runs the command.
    await waitForIt(
      () => frames.text.contains('[Settings]'),
      reason: 'settings hub picker to open',
    );
    final settingsAt = frames.text.indexOf('[Settings]');

    // THE RULE: a selection-only picker carries cursor: null, and that must
    // surface as a real DECTCEM hide on the wire — emitted OUT-OF-BAND at
    // the head of the picker's first frame (mode apply precedes painting),
    // never an escape riding the diffed frame content (which the cell
    // renderer's SGR-only grid silently drops — the #510 bug).
    final hideAt = frames.text.indexOf('\x1b[?25l');
    expect(hideAt, isNonNegative, reason: 'the wire must carry a DECTCEM '
        'hide when the selection-only picker opens (#510)');
    expect(
      hideAt,
      lessThan(settingsAt),
      reason: 'the hide precedes the picker title paint in the same frame',
    );

    // Closing the picker hands focus back to the composer: the caret must
    // come back (DECTCEM show) after the hide.
    keys.add([0x1b]); // Esc closes the picker.
    await waitForIt(
      () => frames.text.indexOf('\x1b[?25h', hideAt + 1) > 0,
      reason: 'cursor to come back after the picker closes',
    );

    keys.add([0x03]); // ctrl+c — the TUI's normal-mode quit key.
    await run;
  } finally {
    await io.close();
  }
}

void main() {
  test(
    'a settings picker hides the physical cursor on the wire (#510)',
    _run,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
