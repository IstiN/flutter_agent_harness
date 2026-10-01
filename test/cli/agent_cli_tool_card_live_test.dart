/// Unit pin for the LIVE edge's feeding of the shared settled-card builder
/// (issue #916 round-2 review): the replay side is pinned against
/// [settledToolCardRows] by construction (the test oracle IS the builder),
/// so it can no longer catch a live-side feeding mistake — the live end
/// edge (`_onToolExecutionEnd`, approval_commands.dart) is the one seam
/// still verified only by the sharded PTY legs. This boots the real TUI
/// headlessly (the agent_cli_tui_sync_test harness: TuiProgramHooks in/out,
/// no real terminal), drives ONE real bash tool execution through the agent
/// loop, and pins the painted settled card against the builder fed with
/// exactly the live call's arguments: toolName, the START-event detail,
/// isError, `_rowWidth`, and `[elapsed]`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_chrome.dart';
import 'package:flutter_agent_harness/src/cli/tool_rows.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Collects rendered frame bytes (dart_tui wraps this into an IOSink).
class _FrameSink implements StreamConsumer<List<int>> {
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

/// SGR + cursor/control sequences out, then runs of spaces collapsed: the
/// alt-screen renderer may emit a row as diff spans, so the visible-cells
/// comparison rides normalized text.
String _normalize(String s) => s
    .replaceAll(RegExp('\x1b\\[[0-9;?]*[a-zA-Z]'), '')
    .replaceAll(RegExp(' +'), ' ');

void main() {
  test('live tool end paints the settled card fed exactly like the shared '
      'builder expects (start-event detail, success phase, elapsed meta)',
      () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    addTearDown(keys.close);
    final shell = FakeShell(stdout: 'hi');
    final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
    final io = FakeCliIO();
    final config = AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      approvalMode: ApprovalMode.yolo,
      skillsAccess: SkillsAccess.granted,
      tuiProgramHooks: TuiProgramHooks(
        input: keys.stream,
        output: frames,
        width: 80,
        height: 24,
      ),
    );
    final cli = AgentCli(
      config: config,
      io: io,
      useTui: true,
      streamFunction: FakeStreamFunction([
        toolTurn([
          const ToolCall(id: 't1', name: 'bash', arguments: {
            'command': 'echo hi',
          }),
        ]),
        textTurn('done'),
      ]).call,
    );
    final run = cli.run();
    try {
      await waitForIt(
        () => frames.text.contains('\x1b[?1049h'),
        reason: 'the TUI boot reached the frame renderer',
      );
      // Submit the prompt: the fake provider streams one bash tool turn,
      // then the final text turn.
      keys.add(utf8.encode('hi'));
      keys.add([0x0d]);
      // The final text turn proves the whole loop ran: the settled card
      // painted before it.
      await waitForIt(
        () => _normalize(frames.text).contains('done'),
        reason: 'the turn settled with the final text',
      );

      // The oracle: the builder fed with EXACTLY the live edge's call —
      // the start-event detail (toolRowDetail at tool START), success
      // phase, `_rowWidth` (the pinned TUI width), and the elapsed meta
      // (an in-process bash call always lands inside its first second).
      final startDetail = toolRowDetail(
        'bash',
        const {'command': 'echo hi'},
        cwd: '/work',
        home: config.homeDir,
      );
      final oracle = settledToolCardRows(
        toolName: 'bash',
        successDetail: startDetail,
        isError: false,
        width: 80,
        meta: const ['0s'],
      );
      expect(
        _normalize(frames.text),
        contains(_normalize(oracle.join('\n'))),
        reason: 'the live edge must feed the shared builder its exact '
            'segments (name, start detail, phase, width, [elapsed]) — '
            'frames=${frames.text}',
      );
      // The command really executed through the env (the card describes a
      // real run, not a synthetic event).
      expect(shell.commands, contains('echo hi'));
    } finally {
      keys.add([0x03]); // ctrl+c press 1: arms the double-press window
      keys.add([0x03]); // press 2: quits the TUI
      await run.timeout(const Duration(seconds: 10), onTimeout: () {});
      await io.close();
      await keys.close();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
