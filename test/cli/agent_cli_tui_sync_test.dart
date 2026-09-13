// Issue #274: the `syncOutput` wire — AgentCliConfig.tuiSyncOutput must
// reach the FaTuiController constructor (agent_cli.dart `_createTuiController`)
// and from there the dart_tui program's BSU/ESU (DEC 2026) framing. Headless:
// the full AgentCli boots in-process, key bytes are scripted through
// TuiProgramHooks.input, rendered frames are captured through
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

/// Boots the real CLI into TUI mode headlessly and quits it via the TUI's
/// own ctrl+c path once the first alt-screen frame has rendered.
Future<void> _bootAndQuit({
  required bool? syncOutput,
  required _FrameSink frames,
  required StreamController<List<int>> keys,
}) async {
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
      tuiSyncOutput: syncOutput,
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
    await waitForIt(() => frames.text.contains('\x1b[?1049h'));
    keys.add([0x03]); // ctrl+c — the TUI's normal-mode quit key.
    await run;
  } finally {
    await io.close();
  }
}

void main() {
  test('tuiSyncOutput: true wires DEC 2026 BSU/ESU framing through the real '
      'AgentCli boot (#274)', () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    await _bootAndQuit(syncOutput: true, frames: frames, keys: keys);
    expect(
      frames.text,
      contains('\x1b[?2026h'),
      reason: 'tuiSyncOutput:true must force BSU on rendered frames',
    );
    expect(frames.text, contains('\x1b[?2026l'), reason: 'BSU must be closed');
  });

  test(
    'tuiSyncOutput: false keeps the same boot free of sync framing',
    () async {
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      await _bootAndQuit(syncOutput: false, frames: frames, keys: keys);
      expect(
        frames.text,
        isNot(contains('\x1b[?2026h')),
        reason: 'tuiSyncOutput:false must force legacy (unframed) writes',
      );
    },
  );
}
