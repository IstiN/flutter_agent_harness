// Issue #2172 regression: a fresh TUI boot whose banner alone overflows
// the transcript viewport must still paint the banner's HEAD — the
// '[Model]' block waitForBoot anchors on.
//
// The trigger shape: a workspace cwd long enough that the [Context] row
// and the derived [Session] path wrap the boot banner past the viewport
// height (macOS temp-space paths: /var/folders/…/T/fa_…_ws_XXXXXX wraps
// where CI's short /tmp paths do not). Pre-fix the live-edge follow
// pinned the first window to the bottom (and the boot anchor's trailing
// phantom slot then parked it past the banner entirely) — the banner's
// head was born above the fold, '[Model]' never reached the wire, and
// every PTY waitForBoot timed out at 90 s on a chrome-only frame.
//
// Headless (issue #735 injected runner): the full AgentCli boots in-process,
// frames are captured through TuiProgramHooks.output — no terminal involved.
// 80x24 is the PTY harness default geometry.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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

void main() {
  test('boot banner overflow: [Model] paints even when the banner wraps '
      'past the viewport (#2172)', () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    // A deep fake workspace path: the [Context] row wraps to several
    // rows and the derived [Session] path wraps past it — together the
    // banner exceeds the 80x24 transcript viewport (the #2172 shape).
    final deepCwd =
        '/${List.generate(10, (i) => 'segment-$i-longname').join('/')}';
    final env = MemoryExecutionEnv(cwd: deepCwd);
    final io = FakeCliIO();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        agentMode: 'code',
        approvalMode: ApprovalMode.yolo,
        skillsAccess: SkillsAccess.granted,
        tuiClassic: true,
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
      await waitForIt(
        () => frames.text.contains('\x1b[?1049h'),
        reason: 'alt-screen enter',
      );
      await waitForIt(
        () => frames.text.contains('[Model]'),
        reason:
            'the boot banner [Model] block (issue #2172: a wrapped '
            'boot banner must keep its head on the glass)',
      );
      expect(frames.text, contains('[Context]'));
      // Quit via the TUI's own ctrl+c path (double press, #830).
      keys.add([0x03]);
      keys.add([0x03]);
      await run;
    } finally {
      await io.close();
      await keys.close();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
