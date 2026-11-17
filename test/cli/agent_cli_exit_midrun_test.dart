// gh-2168 bounded-exit: `/exit` (every quit path) aborts the in-flight run
// — fires its cancel token, pi's shutdown semantics — then the normal
// teardown drains what settles and flushes + seals the session, all inside
// `cli.run()`. `bye` stays the observable farewell. Both waiters of the old
// unbounded `await _settled` are covered here: the TUI submit boundary
// (agent_cli_composer.dart) and the line-mode `_teardownAfterRepl`
// (agent_cli_lifecycle.dart). The wall assertions pin "bounded": the old
// behavior waited out the run's full configured patience (watchdog floor:
// 8 minutes) — or hung forever on a wedged provider.
library;

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

void main() {
  test(
    'line mode: /exit mid-run aborts the run and exits bounded',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final io = FakeCliIO();
      final stream = AbortableStreamFunction();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      await waitForIt(
        () async => (await repo.list(cwd: '/work')).isNotEmpty,
        reason: 'session persisted',
      );
      io.sendLine('start');
      await waitForIt(
        () => stream.started && cli.isBusy,
        reason: 'wedged run in flight',
      );

      final wall = Stopwatch()..start();
      io.sendLine('/exit');
      await io.out.waitUntilContains('bye');
      await run; // must return bounded — the stream never settles on its own
      wall.stop();

      expect(cli.isBusy, isFalse, reason: 'the run aborted on exit');
      expect(
        wall.elapsed,
        lessThan(const Duration(seconds: 20)),
        reason: 'exit settles bounded — the watchdog floor is 8 minutes',
      );
      final session = cli.sessionForTest;
      expect(session, isNotNull);
      expect(session!.isSealed, isTrue, reason: 'the quit seals the session');
      await io.close();
    },
  );

  test(
    'line mode: EOF mid-run aborts the run and exits bounded',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      // The other quit shape: input ends while a run wedges — the REPL
      // never passed `/exit`, so `_teardownAfterRepl` itself fires the
      // quit abort before the bounded drain (gh-2168).
      final env = MemoryExecutionEnv(cwd: '/work');
      final io = FakeCliIO();
      final stream = AbortableStreamFunction();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      await waitForIt(
        () async => (await repo.list(cwd: '/work')).isNotEmpty,
        reason: 'session persisted',
      );
      io.sendLine('start');
      await waitForIt(
        () => stream.started && cli.isBusy,
        reason: 'wedged run in flight',
      );

      final wall = Stopwatch()..start();
      await io.close(); // EOF: the line stream is done mid-run
      await run;
      wall.stop();

      expect(cli.isBusy, isFalse, reason: 'the run aborted on EOF');
      expect(
        wall.elapsed,
        lessThan(const Duration(seconds: 20)),
        reason: 'exit settles bounded — the watchdog floor is 8 minutes',
      );
      final session = cli.sessionForTest;
      expect(session, isNotNull);
      expect(session!.isSealed, isTrue, reason: 'the quit seals the session');
    },
  );

  test(
    'TUI mode: /exit submit boundary aborts the run and exits bounded',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      final env = MemoryExecutionEnv(cwd: '/work');
      final io = FakeCliIO();
      final stream = AbortableStreamFunction();
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
            width: 80,
            height: 24,
          ),
        ),
        io: io,
        useTui: true,
        streamFunction: stream.call,
      );
      final run = cli.run();
      try {
        await waitForIt(() => frames.text.contains('\x1b[?1049h'));
        // Start the wedged run through the composer submit boundary.
        // (The keystroke path detours through the fuzzy slash menu — UI
        // plumbing outside this ticket; the boundary is the waiter under
        // test and `tuiSubmitForTest` drives it directly, exactly as
        // gh-1787/steering suites do. NOT awaited: the boundary parks at
        // `_settled` while the run is wedged.)
        unawaited(cli.tuiSubmitForTest('start', const []));
        await waitForIt(
          () => stream.started && cli.isBusy,
          reason: 'wedged run in flight',
        );

        // The exit submit parks at the boundary's settle wait: it must
        // abort the run, drain, and schedule sendQuit instead of waiting
        // out the wedged stream.
        final wall = Stopwatch()..start();
        await cli.tuiSubmitForTest('/exit', const []);
        await waitForIt(() => frames.text.contains('bye'));
        await run; // must return bounded — sendQuit lands after the settle
        wall.stop();

        expect(cli.isBusy, isFalse, reason: 'the run aborted on exit');
        expect(
          wall.elapsed,
          lessThan(const Duration(seconds: 20)),
          reason: 'exit settles bounded — the watchdog floor is 8 minutes',
        );
        final session = cli.sessionForTest;
        expect(session, isNotNull);
        expect(session!.isSealed, isTrue, reason: 'the quit seals the session');
      } finally {
        await io.close();
        await keys.close();
      }
    },
  );
}
