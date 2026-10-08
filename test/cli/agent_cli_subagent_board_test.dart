// The subagent status board coordinator's wiring tests (gh-1415): the
// registry-event refresh, the 1 Hz repaint ticker's arm/disarm lifecycle,
// the timestamp-driven age re-render (E3), and session teardown. Full
// headless TUI boot (the agent_hub_overlay_guard_test pattern): the real
// AgentCli runs in TUI mode with scripted key bytes, captured frames, and
// a manual waiting clock — no terminal, no model. Assertions ride the
// coordinator's @visibleForTesting seams plus the rendered frame.
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

Future<void> _waitFor(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 6000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}

void main() {
  test(
    'the coordinator refreshes on registry events, arms the 1 Hz ticker '
    'while a row is live, and disarms + clears on teardown (gh-1415)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // The fake clock anchors at REAL now: a pinned past date pushes
      // every waiting/scheduled timer into the overdue path and starves
      // the REPL loop. Only the E3 tick below advances it.
      var now = DateTime.now();
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: MemoryExecutionEnv(cwd: '/work'),
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
        waitingClock: () => now,
        streamFunction: FakeStreamFunction(const []).call,
      );
      final run = cli.run();
      try {
        await _waitFor(
          () => frames.text.contains('\x1b[?1049h'),
          reason: 'the boot reached the frame renderer',
        );

        // SPAWN: the registry event drives the refresh — the row renders
        // from the handle and the ticker arms (a live row exists). The
        // clock anchor sits immediately before the register so the manual
        // advance below maps 1:1 onto the real `createdAt` stamp.
        now = DateTime.now();
        await cli.subagentManager.register(
          id: 'scout#1',
          name: 'scout',
          agentType: 'explore',
          task: 'scout the workspace',
        );
        await cli.subagentManager.update(
          'scout#1',
          status: SubagentStatus.running,
          tokens: 512,
        );
        await _waitFor(
          () => frames.plain.contains('run  scout'),
          reason: 'the spawn painted the one-line row',
        );
        expect(
          cli.subagentBoardTickerArmedForTest,
          isTrue,
          reason: 'a live row arms the 1 Hz ticker',
        );
        final pushed = cli.subagentBoardLastPushForTest;
        expect(
          pushed.join('\n'),
          contains('512'),
          reason: 'usage composes into the cost column',
        );

        // DEDUPE: a refresh with NO registry change re-renders identically
        // — the push is suppressed (an unchanged frame costs nothing).
        cli.subagentBoardRefreshForTest();
        expect(
          cli.subagentBoardLastPushForTest,
          pushed,
          reason: 'an unchanged registry renders the same frame',
        );

        // TICKING (E3): the age recomputes from the spawn timestamp when
        // the clock advances — the manual clock jumps 5s, one manual tick
        // re-renders the age column in place. The absolute value carries
        // the register call's real-event-loop latency (createdAt stamps a
        // moment after the anchor), so assert the RECOMPUTED band: a
        // tick-accumulator would still read ~1s; only a timestamp-derived
        // age lands in the 3-6s band after a +5s jump.
        now = now.add(const Duration(seconds: 5));
        cli.subagentBoardTickForTest();
        final rows = cli.subagentBoardRowsForTest();
        expect(rows, hasLength(1));
        expect(
          rows.single.text,
          contains(RegExp(r'\s[3-6]s\s')),
          reason: 'the age follows the clock, not accumulated ticks',
        );
        expect(rows.single.text, isNot(contains(' 1s ')));
        expect(rows.single.bright, isTrue, reason: 'a live row renders bright');

        // SETTLE: the terminal record flashes bright (still pushed) but is
        // no longer live — the ticker disarms.
        await cli.subagentManager.update(
          'scout#1',
          status: SubagentStatus.completed,
        );
        await _waitFor(
          () => frames.plain.contains('done scout'),
          reason: 'the settle collapsed the row to the done one-liner',
        );
        expect(
          cli.subagentBoardTickerArmedForTest,
          isFalse,
          reason: 'no live row — the ticker disarms',
        );

        keys.add([0x03]); // ctrl+c press 1: abort + armed window, stays
        keys.add([0x03]); // press 2 within the window quits
        await run;
        expect(
          cli.subagentBoardRegionForTest.isEmpty,
          isTrue,
          reason: 'teardown drops the region',
        );
        expect(
          cli.subagentBoardTickerArmedForTest,
          isFalse,
          reason: 'teardown cancels the ticker',
        );
      } finally {
        await io.close();
        await keys.close();
      }
    },
  );
}
