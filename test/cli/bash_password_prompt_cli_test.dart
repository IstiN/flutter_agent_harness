import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Fake background shell that mimics sudo: the job prints a password ask
/// (no trailing newline), blocks on a stdin line, then finishes.
final class _SudoAskShell implements Shell, BackgroundShell {
  _SudoAskJob? lastJob;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async => Ok(const ShellExecResult(stdout: '', stderr: '', exitCode: 0));

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = _SudoAskJob(id: id, command: command, logPath: logPath);
    lastJob = job;
    // Bind the live stdin pipe the bash tool created, exactly like a real
    // process-backed environment would.
    options?.liveStdin?.bind(job.writeStdin);
    // The ask arrives right away; no trailing newline, so the detector's
    // quiet window has to fire to open the prompt. Broadcast streams do
    // not buffer, so give the tool's listener a beat to attach first.
    unawaited(
      Future<void>(() async {
        for (var i = 0; i < 200 && !job.hasListener; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        job.emitAsk('[sudo] password for tester: ');
      }),
    );
    return Ok(job);
  }
}

final class _SudoAskJob implements ShellJob {
  _SudoAskJob({required this.id, required this.command, required this.logPath});

  @override
  final String id;

  @override
  final String command;

  @override
  final String logPath;

  final _controller = StreamController<String>.broadcast();
  final _settled = Completer<void>();
  final receivedStdin = <String>[];
  int? _exitCode;

  @override
  late final Stream<String> output = _controller.stream;

  @override
  late final Future<void> settled = _settled.future;

  @override
  bool get isRunning => _exitCode == null;

  @override
  int? get exitCode => _exitCode;

  @override
  String? get stopReason => null;

  bool get hasListener => _controller.hasListener;

  void emitAsk(String text) {
    if (!_controller.isClosed) _controller.add(text);
  }

  @override
  bool writeStdin(String data) {
    if (!isRunning) return false;
    receivedStdin.add(data);
    if (data.contains('\n')) {
      _controller.add('FED-OK\n');
      _exitCode = 0;
      _settled.complete();
      unawaited(_controller.close());
    }
    return true;
  }

  @override
  Future<void> stop() async {
    if (!isRunning) return;
    _exitCode = 130;
  }
}

AgentCli cliFor(
  StreamFunction streamFunction, {
  required ExecutionEnv env,
  required CliIO io,
}) {
  return AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
    ),
    io: io,
    streamFunction: streamFunction,
  );
}

void main() {
  late MemoryExecutionEnv env;
  late _SudoAskShell shell;
  late FakeCliIO io;

  setUp(() {
    shell = _SudoAskShell();
    env = MemoryExecutionEnv(cwd: '/work', shell: shell);
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  Future<void> runTurn(FakeStreamFunction fake, {String answer = ''}) async {
    final cli = cliFor(fake.call, env: env, io: io);
    final run = cli.run();
    io.sendLine('install the thing');
    await waitForIt(() => io.out.toString().contains('[password]'));
    io.sendLine(answer);
    await waitForIt(() => fake.calls == 2);
    io.sendLine('/exit');
    await run;
  }

  test('typed answer reaches the job stdin, transcript stays clean', () async {
    final fake = FakeStreamFunction([
      toolTurn([
        ToolCall(
          id: 'call_1',
          name: 'bash',
          arguments: const {'command': 'sudo apt install fah'},
        ),
      ]),
      textTurn('fed'),
    ]);

    await runTurn(fake, answer: 'hunter2');

    expect(shell.lastJob!.receivedStdin, contains('hunter2\n'));
    expect(io.out.toString(), contains('[password]'));
    // The answer never echoes into the session transcript.
    expect(io.out.toString(), isNot(contains('hunter2')));
  });

  test(
    'empty answer writes a bare newline (decline) and the job settles',
    () async {
      final fake = FakeStreamFunction([
        toolTurn([
          ToolCall(
            id: 'call_1',
            name: 'bash',
            arguments: const {'command': 'sudo apt install fah'},
          ),
        ]),
        textTurn('moved on'),
      ]);

      await runTurn(fake);

      expect(shell.lastJob!.receivedStdin, contains('\n'));
      expect(shell.lastJob!.isRunning, isFalse);
      expect(io.out.toString(), isNot(contains('[secret]')));
    },
  );
}
