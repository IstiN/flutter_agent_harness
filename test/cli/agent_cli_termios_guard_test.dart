// Issue #735 IT: the TermiosGuard wire — a scripted TUI session with an
// injected stty runner. Boot sanitize runs through the same runner; a
// foreground bash tool phase "corrupts" the simulated tty (a child ran
// `stty ixon ixany`); the guard must re-assert the input flags at the
// after-tool boundary — BEFORE the next keystrokes are read — so the
// Ctrl+S (0x13) steer still reaches the running agent. Headless: no real
// tty anywhere, the fake runner models it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Captures rendered frame bytes (dart_tui wraps this into an IOSink).
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

/// The simulated tty + a global event log shared with the scripted shell,
/// so the test can assert the guard re-asserted BEFORE the steer keys.
class _SimTty {
  final events = <String>[];
  final calls = <List<String>>[];
  var enabled = <String>{};

  Future<ProcessResult> runner(List<String> args) async {
    calls.add(List.of(args));
    events.add('stty:${args.skip(2).join(" ")}');
    if (args.contains('-a')) {
      final toggles = ['icrnl', 'ixon', 'ixoff', 'ixany'];
      final flags = [
        for (final f in toggles) enabled.contains(f) ? f : '-$f',
      ].join(' ');
      return ProcessResult(
        0,
        0,
        'speed 9600 baud; rows 24; columns 80;\ndiscard = ^O\n$flags\n',
        '',
      );
    }
    if (args.contains('-g')) return ProcessResult(0, 0, 'saved\n', '');
    for (final arg in args) {
      if (arg.startsWith('-')) {
        enabled.remove(arg.substring(1));
      }
    }
    return ProcessResult(0, 0, '', '');
  }

  /// The corrupting child: `stty ixon ixany < /dev/tty` mid-tool-phase.
  void childCorrupts() {
    enabled = {...enabled, 'ixon', 'ixany'};
    events.add('child:stty-ixon-ixany');
  }
}

/// Bash tool shell: the FIRST exec runs the corrupting child, the SECOND
/// blocks until released (holds the turn open for the mid-run steer).
class _CorruptingGatedShell implements Shell {
  _CorruptingGatedShell(this._tty);

  final _SimTty _tty;
  final _gate = Completer<void>();
  var calls = 0;

  void release() => _gate.complete();

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    calls++;
    if (calls == 1) {
      // The child holds the tty open and leaves IXON re-enabled on exit.
      _tty.childCorrupts();
      return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
    }
    await _gate.future;
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }
}

void main() {
  test(
    'guard re-asserts after a corrupting tool phase; Ctrl+S still steers '
    '(issue #735)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final tty = _SimTty();
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      final shell = _CorruptingGatedShell(tty);

      // Turn 1: two bash calls (corrupt + hold). Turn 2: proof the steer
      // reached the model.
      final fake = FakeStreamFunction([
        toolTurn(const [
          ToolCall(
            id: 'c1',
            name: 'bash',
            arguments: {'command': 'stty ixon ixany < /dev/tty'},
          ),
          ToolCall(id: 'c2', name: 'bash', arguments: {'command': 'sleep 30'}),
        ]),
        textTurn('STEERED-OK'),
      ]);

      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          sttyRunner: tty.runner,
          tuiProgramHooks: TuiProgramHooks(
            input: keys.stream,
            output: frames,
            width: 100,
            height: 30,
          ),
        ),
        io: io,
        useTui: true,
        streamFunction: fake.call,
      );

      final run = cli.run();
      addTearDown(() async {
        await io.close();
      });
      try {
        // Boot: the TUI's own sanitize ran through the injected runner.
        await waitForIt(
          () => frames.text.contains('\x1b[?1049h'),
          reason: 'TUI alt-screen boot',
        );
        await waitForIt(
          () => tty.calls.any((c) => c.contains('-ixon')),
          reason: 'boot sanitize cleared the input flags via the runner',
        );

        // Submit the run; the first bash call corrupts the tty, then the
        // guard re-asserts at the after-tool boundary, then the second
        // call blocks on the gate (turn stays busy for the steer).
        keys.add(utf8.encode('run the tool\r'));
        await waitForIt(
          () => shell.calls >= 2,
          reason: 'the second (gated) bash call started',
        );

        // The re-assert already ran: the clear call arrived AFTER the
        // child corrupted and the drift note hit the transcript.
        expect(
          tty.events,
          containsAllInOrder([
            'child:stty-ixon-ixany',
            'stty:-ixon -ixoff -icrnl discard ^- -ixany',
          ]),
        );
        await waitForIt(
          () => frames.text.contains('re-enabled by a child'),
          reason: 'the drift note names the corrupting child',
        );

        // Mid-run steer: Ctrl+S (0x13) after the guard re-asserted.
        keys.add(utf8.encode('steer me'));
        keys.add([0x13]);
        await waitForIt(
          () => frames.text.contains('steering from you'),
          reason: 'the steer was accepted while the run was busy',
        );

        // Release the held tool call: the step boundary delivers the
        // steer and the second model turn proves it.
        shell.release();
        await waitForIt(
          () => fake.calls >= 2 && !cli.isBusy,
          reason: 'the turn settles after the boundary',
        );
        final secondCall = fake.contexts.last.messages;
        expect(
          secondCall.any(
            (m) =>
                m is UserMessage &&
                m.content == '[steering from user] steer me',
          ),
          isTrue,
          reason: '0x13 reached the agent as a steered user message',
        );

        keys.add([0x03]); // ctrl+c quits the TUI.
        await run;
      } finally {
        await keys.close();
      }
    },
  );

  test(
    'hidden /termios command degrades to a hint without a tty (issue #735)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // Line mode + FakeCliIO: the guard's default terminal gate is false
      // (headless host), so the dump is null and the command prints the
      // explanatory fallback — the /termios dispatch arm and its output
      // path stay covered on every shard.
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      addTearDown(io.close);
      // The editor-flow seam (providers_queue_editor_test pattern): drive
      // the command directly, no REPL loop.
      await cli.handleLineForTest('/termios');
      expect(
        io.out.toString(),
        contains('no tty available'),
        reason: 'headless hosts get the fallback hint, not a crash',
      );
    },
  );

  test(
    'TUI queue drain runs queued follow-ups as separate turns (kimi-cli '
    'semantics — the _drainTuiQueue leg of the #735 extraction)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // Busy run (gated bash) + two queued submits while busy; releasing
      // the gate settles the turn and the drain loop runs each queued
      // message as its own model turn — covering the moved
      // _drainTuiQueue body (drain + runRound wiring).
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      final shell = _GateShell();
      final fake = FakeStreamFunction([
        toolTurn(const [
          ToolCall(id: 'q1', name: 'bash', arguments: {'command': 'hold'}),
        ]),
        textTurn('first-ack'),
        // One ack per queued follow-up — the drain loop runs each as its
        // own model turn.
        textTurn('ack-one'),
        textTurn('ack-two'),
      ]);
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
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
        streamFunction: fake.call,
      );
      final run = cli.run();
      addTearDown(() async {
        await io.close();
      });
      try {
        await waitForIt(
          () => frames.text.contains('\x1b[?1049h'),
          reason: 'TUI alt-screen boot',
        );
        keys.add(utf8.encode('start\r'));
        await waitForIt(
          () => shell.calls >= 1,
          reason: 'the gated bash call started (run busy)',
        );
        // Two submits while busy queue as follow-ups (Enter mid-run).
        keys.add(utf8.encode('queued one\r'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        keys.add(utf8.encode('queued two\r'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        shell.release();
        await waitForIt(
          () => fake.calls >= 4 && !cli.isBusy,
          reason: 'the turn settles and both queued messages ran as turns',
        );
        // Call 2 is turn 1's post-tool continuation ('first-ack'); the
        // drain loop then runs each queued message as its own turn.
        expect(
          fake.contexts[2].messages.any(
            (m) =>
                m is UserMessage && m.content.toString().contains('queued one'),
          ),
          isTrue,
        );
        expect(
          fake.contexts[3].messages.any(
            (m) =>
                m is UserMessage && m.content.toString().contains('queued two'),
          ),
          isTrue,
        );
        keys.add([0x03]);
        await run;
      } finally {
        await keys.close();
      }
    },
  );

  test(
    'line mode never touches the tty — zero guard probes/clears even '
    'with an injected runner (PR review PRRT_kwDOTXdlLc6kMBZH)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // The interactive line REPL runs COOKED: icrnl/ixon are SUPPOSED to
      // be on, and clearing them would kill Enter (no CR→NL translation
      // in canonical mode) with no restore path. The guard is TUI-only —
      // line mode must not probe the tty even when a stty runner seam is
      // injected.
      final tty = _SimTty();
      final shell = _CorruptingGatedShell(tty);
      final fake = FakeStreamFunction([
        toolTurn(const [
          ToolCall(
            id: 'c1',
            name: 'bash',
            arguments: {'command': 'stty ixon ixany < /dev/tty'},
          ),
        ]),
        textTurn('LINE-MODE-OK'),
      ]);

      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          sttyRunner: tty.runner,
        ),
        io: io,
        useTui: false,
        streamFunction: fake.call,
      );

      final run = cli.run();
      addTearDown(io.close);
      io.sendLine('run the tool');
      await waitForIt(
        () => fake.calls >= 2 && !cli.isBusy,
        reason: 'the tool turn ran and settled',
      );
      // The tool phase DID run (the corrupting child fired)…
      expect(tty.events, contains('child:stty-ixon-ixany'));
      // …but line mode must show ZERO guard probes/clears: the runner
      // only ever served the tool's child, never an stty probe or clear.
      expect(tty.events.where((e) => e.startsWith('stty:')), isEmpty);
      io.sendLine('/exit');
      await run;
    },
  );
}

/// One-gate shell: every exec blocks until [release] (the busy holder for
/// the queue-drain leg).
class _GateShell implements Shell {
  final _gate = Completer<void>();
  var released = false;

  void release() {
    if (!released) {
      released = true;
      _gate.complete();
    }
  }

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    calls++;
    await _gate.future;
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }

  var calls = 0;
}
