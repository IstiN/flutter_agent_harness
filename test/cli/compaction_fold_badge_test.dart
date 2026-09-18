import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_attach_test.dart' show waitForTrue;
import 'agent_cli_test_support.dart';

/// A stream function that holds the call whose context matches [gateOn]
/// until [gate] completes: opens a deterministic mid-run observation
/// window (issue #653). Every other call replays the next scripted turn;
/// a spare summary turn keeps fold internals fed regardless of how many
/// passes an engine consumes.
class _GatedStream {
  _GatedStream(this.turns, {required this.gateOn, required this.gatedTurn});

  final List<List<AssistantMessageEvent>> turns;
  final bool Function(Context context) gateOn;
  final List<AssistantMessageEvent> gatedTurn;

  final gate = Completer<void>();
  final contexts = <Context>[];
  bool gated = false;

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    if (!gated && gateOn(context)) {
      gated = true;
      unawaited(
        gate.future.then((_) {
          for (final event in gatedTurn) {
            stream.push(event);
          }
          stream.end();
        }),
      );
      return stream;
    }
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// Issue #653 — the auto-compaction marker must leave the busy row the
/// moment the fold finishes: `Compacting context…` is set on compaction
/// start, the post-fold handback clears it, and every later label of the
/// still-running turn stays marker-free. The «[auto-compacted ·
/// continuing]» badge lives on the status row only (issue #438 AC3):
/// present while the run continues after the fold, gone at settle.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  test(
    'post-run fold: marker set on start, cleared on finish, never rides '
    'a busy label',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // Three ~10k-token answers in a 40k window cross the compaction
      // threshold on turn 3 (same arithmetic as the busy-gate test).
      final big = 'x' * 40000;
      const tiny = Model(
        id: 'tiny-window',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 40000,
        maxTokens: 4096,
      );
      final stream = _GatedStream(
        [
          textTurn(big),
          textTurn(big),
          textTurn(big),
          textTurn('summary of older context'),
          textTurn('summary of older context'),
        ],
        gateOn: (_) => false,
        gatedTurn: const [],
      );
      final cli = AgentCli(
        config: AgentCliConfig(
          model: tiny,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      await waitForTrue(() async {
        final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
        return (await repo.list(cwd: '/work')).isNotEmpty;
      });

      io.sendLine('one');
      await waitForIt(() => stream.calls >= 1 && !cli.isBusy);
      io.sendLine('two');
      await waitForIt(() => stream.calls >= 2 && !cli.isBusy);
      io.sendLine('three');
      await waitForIt(
        () => stream.calls >= 4 && !cli.isBusy,
        reason: 'post-run fold of run 3',
      );

      expect(
        io.out.toString(),
        contains('● auto-compacted'),
        reason: 'the fold really happened',
      );
      // Marker set on compaction start…
      expect(
        cli.busyPhasesForTest.any((p) => p.startsWith('Compacting context…')),
        isTrue,
      );
      // …and NO label ever carried the marker (pre-fix the handback pushed
      // «[auto-compacted · continuing]», which then led the row).
      expect(
        cli.busyPhasesForTest.where((p) => p.contains('auto-compacted')),
        isEmpty,
      );
      // The fold's last label hands the row back empty («Working…»).
      expect(cli.busyPhasesForTest.last, '');
      // Settle cleared the status-row badge.
      expect(cli.statusLineForTest(), isNot(contains('auto-compacted')));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'mid-run relief fold: busy row clears while the turn auto-continues, '
    'status row badges until settle',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // The guard refuses to send when the bash outputs balloon the
      // request past the window; the relief + post-run compaction free it
      // and the CLI auto-continues the SAME turn — the exact «compacted
      // and still working» shape of issue #653. Same arithmetic as the
      // over-window guard test.
      const window32k = Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 32768,
        maxTokens: 4096,
      );
      final stream = _GatedStream(
        [
          toolTurn([
            ToolCall(
              id: 'c1',
              name: 'bash',
              arguments: const {'command': 'cat a.log'},
            ),
            ToolCall(
              id: 'c2',
              name: 'bash',
              arguments: const {'command': 'cat b.log'},
            ),
            ToolCall(
              id: 'c3',
              name: 'bash',
              arguments: const {'command': 'cat c.log'},
            ),
          ]),
          textTurn('S'),
          textTurn('S'),
          textTurn('S'),
        ],
        gateOn: (context) =>
            jsonEncode(context.messages).contains('context-window guard'),
        gatedTurn: textTurn('continued after compaction'),
      );
      final shell = FakeShell(stdout: 'x' * 32800);
      final shellEnv = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: window32k,
          apiKey: 'test-key',
          env: shellEnv,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          compactionEngine: CompactionEngine.classic,
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      await waitForTrue(() async {
        final repo = JsonlSessionRepo(fs: shellEnv, sessionsRoot: '/sessions');
        return (await repo.list(cwd: '/work')).isNotEmpty;
      });

      io.sendLine('go');
      await waitForTrue(() async => stream.gated);
      expect(cli.isBusy, isTrue);

      // The fold announced itself (`Compacting context…`) and the tool
      // calls named themselves; the finished fold left NO marker on the
      // busy row — its handback handed the row back empty while the turn
      // continues.
      expect(
        cli.busyPhasesForTest.any((p) => p.startsWith('Compacting context…')),
        isTrue,
      );
      expect(
        cli.busyPhasesForTest.any((p) => p.startsWith('Running bash…')),
        isTrue,
      );
      expect(
        cli.busyPhasesForTest.where((p) => p.contains('auto-compacted')),
        isEmpty,
      );
      expect(cli.busyPhasesForTest.last, '');
      // AC3 kept: the STATUS row carries the continuing badge mid-run.
      expect(cli.statusLineForTest(), contains('[auto-compacted'));

      stream.gate.complete();
      await waitForIt(() => !cli.isBusy, reason: 'run settles');
      expect(cli.statusLineForTest(), isNot(contains('auto-compacted')));

      io.sendLine('/exit');
      await run;
    },
  );
}
