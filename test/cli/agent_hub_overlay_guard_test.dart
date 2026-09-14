// Issue #382: the agents-hub overlay's event subscription used to push the
// tree on EVERY subagent event, and `pushHub` opens a closed overlay — so
// background child churn force-opened the hub over the user's chat. The fix
// makes event-driven pushes refresh-only: the model drops them while the
// overlay is closed. Headless full-boot: the real AgentCli runs in TUI mode
// with scripted key bytes and captured frames — no terminal, no model.
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

  /// The rendered text with control sequences stripped: the differential
  /// renderer redraws single cells, so content assertions must match on
  /// the decoded screen text, not the raw escape stream.
  String get plain =>
      text.replaceAll(RegExp('\x1b\\[[0-9;:?]*[ -/]*[@-~]'), '');
}

void main() {
  test(
    'child events never force the closed hub open; /agents still opens '
    'and live-refreshes it (#382)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
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
          tuiProgramHooks: TuiProgramHooks(
            input: keys.stream,
            output: frames,
            width: 100,
            height: 30,
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
          reason: 'the boot reached the frame renderer',
        );

        // Typing a bare slash command opens the completion menu, where
        // Enter only ACCEPTS — close the menu with esc before submitting.
        Future<void> type(String text) async {
          keys.add(utf8.encode(text));
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }

        Future<void> slash(String command) async {
          await type(command);
          keys.add([0x1b]); // close the slash menu
          await Future<void>.delayed(const Duration(milliseconds: 100));
          keys.add([0x0d]); // submit
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }

        // The user opens the hub — this also arms the event subscription.
        await slash('/agents');
        await waitForIt(
          () => frames.plain.contains('agents hub'),
          reason: '/agents opens the overlay',
        );

        // A child event while OPEN refreshes the tree in place (AC2).
        await cli.subagentManager.register(
          id: 'scout#1',
          name: 'scout#1',
          agentType: 'explore',
          task: 'scout',
        );
        await waitForIt(
          () => frames.plain.contains('scout#1'),
          reason: 'the open tree live-refreshes with the child row',
        );

        // Drilling into the child's transcript refreshes in place: the
        // transcript push is always refresh-only and arms the follow
        // timer over the OPEN overlay. ('j' moves the tree selection —
        // raw CSI arrow bytes are swallowed by the headless decoder.)
        await type('j');
        keys.add([0x0d]); // enter: transcript
        await waitForIt(
          () => frames.plain.contains('the child appends as it runs'),
          reason: 'enter opens the transcript in the open overlay',
        );

        // The user closes the overlay. From transcript mode esc first
        // steps back to the tree, then a second esc closes the hub.
        keys.add([0x1b]);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        keys.add([0x1b]);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final closedMark = frames.plain.length;
        // Child events fire with the hub CLOSED (AC1): the drops must not
        // open the overlay. A harmless keystroke forces a render after the
        // events so the observation window is provably flushed.
        await cli.subagentManager.update(
          'scout#1',
          status: SubagentStatus.running,
          tokens: 512,
        );
        await type('x');
        keys.add([0x7f]); // backspace: clear the probe before reopening
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await waitForIt(
          () => frames.plain.length > closedMark,
          reason: 'the closed-state window rendered',
        );
        expect(
          frames.plain.substring(closedMark),
          isNot(contains('agents hub')),
          reason: 'child events must not force the closed hub open',
        );
        expect(
          frames.plain.substring(closedMark),
          isNot(contains('scout#1')),
          reason: 'no overlay content leaked into the chat view',
        );

        // The user opens the hub again: bare /agents still opens (AC5) and
        // the tree carries the child the events created.
        final reopenedMark = frames.plain.length;
        await slash('/agents');
        await waitForIt(() {
          final window = frames.plain.substring(reopenedMark);
          return window.contains('agents hub') && window.contains('scout#1');
        }, reason: '/agents still opens the hub and the tree has the child');

        keys.add([0x03]); // ctrl+c quits (outranks the modal)
        await run;
      } finally {
        await io.close();
        await keys.close();
      }
    },
  );
}
