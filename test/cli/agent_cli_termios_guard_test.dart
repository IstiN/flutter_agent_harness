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
            'stty:-ixon -ixoff -icrnl -discard -ixany',
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
}
