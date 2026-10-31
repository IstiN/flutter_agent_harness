/// Unit pin for the LIVE edge's feeding of the shared settled-card
/// derivation (issue #916 round-2 review, gh-1933 v2): the replay side is
/// pinned against [settledCallCardRows] by construction (the test oracle
/// IS the derivation), so it can no longer catch a live-side feeding
/// mistake — the live end edge (`_onToolExecutionEnd`,
/// approval_commands.dart) is the one seam still verified only by the
/// sharded PTY legs. This boots the real TUI headlessly (the
/// agent_cli_tui_sync_test harness: TuiProgramHooks in/out, no real
/// terminal), drives ONE real bash tool execution through the agent loop,
/// and pins the painted settled card against the derivation fed with
/// exactly the live call's material: toolName, the persisted args, the
/// result content, isError, `_rowWidth`, and the elapsed zone.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tool_row_content.dart';
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
  test(
    'live tool end paints the settled card fed exactly like the shared '
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
            const ToolCall(
              id: 't1',
              name: 'bash',
              arguments: {'command': 'echo hi'},
            ),
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
        // the gh-1933 v2 derivation (`settledCallCardRows`: bash intent
        // label, output-lines count, right-aligned elapsed zone, dim
        // command preview) at `_rowWidth` (the pinned TUI width). An
        // in-process bash call always lands inside its first second.
        final oracle = settledCallCardRows(
          toolName: 'bash',
          args: const {'command': 'echo hi'},
          resultContent: const [TextContent(text: 'hi')],
          isError: false,
          width: 80,
          elapsed: '0s',
          cwd: '/work',
          home: config.homeDir,
        );
        final oracleHeader = oracle.first;
        final oraclePreview = oracle.last;
        expect(
          _normalize(frames.text),
          contains(_normalize(oracleHeader)),
          reason:
              'the live edge must feed the shared derivation its exact '
              'material (name, args, result, phase, width, elapsed) — '
              'frames=${frames.text}',
        );
        // The dim command preview renders as its own row (the frame
        // renderer separates rows with cursor moves, so rows assert one by
        // one).
        expect(
          _normalize(frames.text),
          contains(_normalize(oraclePreview)),
          reason: 'frames=${frames.text}',
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
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('live thinking collapses to ONE `> Thought for Ns` row in the TUI '
      '(gh-1933 AC4) — the per-delta stream is gone; expand all renders '
      'the persisted text', () async {
    // A thinking turn that streams reasoning deltas, then answers.
    List<AssistantMessageEvent> thinkingTurn(String think, String answer) {
      final empty = testAssistant();
      final thought = testAssistant(
        content: [ThinkingContent(thinking: think)],
      );
      final partial = testAssistant(
        content: [
          ThinkingContent(thinking: think),
          TextContent(text: answer),
        ],
      );
      return [
        StartEvent(partial: empty),
        ThinkingStartEvent(contentIndex: 0, partial: empty),
        ThinkingDeltaEvent(contentIndex: 0, delta: think, partial: thought),
        TextStartEvent(contentIndex: 1, partial: thought),
        TextDeltaEvent(contentIndex: 1, delta: answer, partial: partial),
        DoneEvent(reason: StopReason.stop, message: partial),
      ];
    }

    Future<String> runTurn({required bool expanded}) async {
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      addTearDown(keys.close);
      transcriptExpandDetails = expanded;
      addTearDown(() => transcriptExpandDetails = false);
      final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
      final io = FakeCliIO();
      final config = AgentCliConfig(
        model: testModel,
        apiKey: 'k',
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
          thinkingTurn('reasoning deeply about the problem', 'the answer'),
        ]).call,
      );
      final run = cli.run();
      try {
        await waitForIt(
          () => frames.text.contains('\x1b[?1049h'),
          reason: 'the TUI boot reached the frame renderer',
        );
        keys.add(utf8.encode('hi'));
        keys.add([0x0d]);
        await waitForIt(
          () => _normalize(frames.text).contains('the answer'),
          reason: 'the turn settled with the final text',
        );
        return _normalize(frames.text);
      } finally {
        keys.add([0x03]);
        keys.add([0x03]);
        await run.timeout(const Duration(seconds: 10), onTimeout: () {});
        await io.close();
        await keys.close();
      }
    }

    final collapsed = await runTurn(expanded: false);
    expect(collapsed, contains('Thought for'), reason: collapsed);
    expect(collapsed, contains('0s'), reason: 'the streamed window duration');
    // The raw thinking text stays OUT of the collapsed transcript.
    expect(collapsed, isNot(contains('reasoning deeply')), reason: collapsed);

    // `/transcript expand all`: the persisted thinking text renders dim
    // under the label row (AC5 — nothing is lost, only folded).
    final expanded = await runTurn(expanded: true);
    expect(expanded, contains('Thought for'));
    expect(expanded, contains('reasoning deeply'), reason: expanded);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
