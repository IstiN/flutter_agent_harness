import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/headless_config.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

class _RoutingStream {
  _RoutingStream();
  final contexts = <Context>[];
  AssistantMessageEventStream call(Model model, Context context, {CancelToken? cancelToken}) {
    contexts.add(context);
    final stream = AssistantMessageEventStream();
    for (final event in textTurn('watching')) { stream.push(event); }
    stream.end();
    return stream;
  }
}

class _DrainShell implements Shell, BackgroundShell {
  final jobs = <_DrainJob>[];
  @override
  bool get backgroundJobsSupported => true;
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(String command, {ShellExecOptions? options}) async =>
      const Err(ExecutionError(ExecutionErrorCode.shellUnavailable, 'no'));
  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(String command, {required String id, required String logPath, ShellExecOptions? options}) async {
    final job = _DrainJob(id: id, command: command, logPath: logPath);
    jobs.add(job);
    return Ok(job);
  }
}

final class _DrainJob implements ShellJob {
  _DrainJob({required this.id, required this.command, required this.logPath});
  @override final String id;
  @override final String command;
  @override final String logPath;
  @override int? get pid => null;
  int? _exitCode;
  final _settled = Completer<void>();
  @override bool get isRunning => !_settled.isCompleted;
  @override int? get exitCode => _exitCode;
  @override Future<void> get settled => _settled.future;
  @override String? get stopReason => null;
  @override Stream<String> get output => const Stream.empty();
  @override bool writeStdin(String data) => false;
  void finish(int code) { if (!_settled.isCompleted) { _exitCode = code; _settled.complete(); } }
  @override Future<void> stop() async => finish(9);
}

void main() {
  test('debug: ceiling 60ms — where does the drain exit?', timeout: const Timeout(Duration(seconds: 60)), () async {
    final io = FakeCliIO();
    final shell = _DrainShell();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: MemoryExecutionEnv(cwd: '/work', shell: shell),
        sessionRoot: '/sessions',
        approvalMode: ApprovalMode.yolo,
        headless: const HeadlessConfig(shellJobDrainMs: 60),
      ),
      io: io,
      streamFunction: _RoutingStream().call,
    );
    // Start the job BEFORE the run so the registry has it at drain time.
    await cli.shellJobsRegistryForTest.start('gh run watch 42');
    final code = await cli.runHeadless('watch');
    // ignore: avoid_print
    print('=== exit code: $code');
    // ignore: avoid_print
    print('=== out:\n${io.out.toString()}');
    io.close();
  });
}
