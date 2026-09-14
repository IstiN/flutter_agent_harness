// Issue #278 AC4: `/mouse off` must actually DISARM the terminal. The
// mouse mode is view-driven per frame (no boot-static option, no vendor
// clamp), so turning capture off emits the full disable sequence through
// the real program output. Headless: the full AgentCli boots in-process,
// key bytes are scripted through TuiProgramHooks.input, the emitted
// escapes are captured through TuiProgramHooks.output — no real terminal
// involved.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _mouseDisable = '\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l';
const _cellMotionEnable = '\x1b[?1002h\x1b[?1006h';

/// Collects emitted terminal bytes (dart_tui wraps this into an IOSink).
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

/// Boots the real CLI into TUI mode headlessly and quits via ctrl+c once
/// [probe] sees its byte pattern in the emitted stream.
Future<void> _bootAndDrive({
  required _FrameSink frames,
  required StreamController<List<int>> keys,
  required bool Function() probe,
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
      tuiMouseCapture: true,
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
    await waitForIt(probe);
    keys.add([0x03]); // ctrl+c — the TUI's normal-mode quit key.
    await run;
  } finally {
    await io.close();
  }
}

void main() {
  test('/mouse off emits the terminal disable sequence (AC4)', () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    var offSent = false;
    await _bootAndDrive(
      frames: frames,
      keys: keys,
      probe: () {
        // Boot: view-driven cell motion arms the terminal (1002h+1006h).
        if (!frames.text.contains(_cellMotionEnable)) return false;
        if (!offSent) {
          offSent = true;
          keys.add(utf8.encode('/mouse off'));
          keys.add([0x0d]); // enter
        }
        return frames.text.contains(_mouseDisable);
      },
    );
    expect(
      frames.text,
      contains(_mouseDisable),
      reason: '/mouse off must write the full ?1000l ?1002l ?1003l ?1006l '
          'teardown to the terminal',
    );
  });

  test('/mouse on re-arms cell motion after off (AC4)', () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    var onSent = false;
    await _bootAndDrive(
      frames: frames,
      keys: keys,
      probe: () {
        if (!frames.text.contains(_mouseDisable)) return false;
        if (!onSent) {
          onSent = true;
          keys.add(utf8.encode('/mouse on'));
          keys.add([0x0d]); // enter
        }
        // A SECOND enable: the boot's first one precedes the off; a fresh
        // ?1002h after the off proves the transition re-armed the terminal.
        final afterOff = frames.text.indexOf(_mouseDisable);
        return frames.text
            .substring(afterOff)
            .contains(_cellMotionEnable);
      },
    );
    final afterOff = frames.text.indexOf(_mouseDisable);
    expect(
      frames.text.substring(afterOff),
      contains(_cellMotionEnable),
      reason: '/mouse on after off must re-emit the cell-motion sequence',
    );
  });
}
