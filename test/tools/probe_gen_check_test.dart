@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final class _FakeJob implements ShellJob {
  _FakeJob({required this.id, required this.logPath});
  @override
  final String id;
  @override
  final String logPath;
  @override
  String get command => 'fake';
  @override
  int? get pid => null;
  final _settled = Completer<void>();
  @override
  bool get isRunning => !_settled.isCompleted;
  @override
  int? get exitCode => null;
  @override
  Future<void> get settled => _settled.future;
  @override
  String? get stopReason => null;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  bool writeStdin(String data) => false;
  @override
  Future<void> stop() async {}
}

final class _FakeBgEnv implements Shell, BackgroundShell {
  final jobs = <_FakeJob>[];
  @override
  bool get backgroundJobsSupported => true;
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(String command, {ShellExecOptions? options}) async =>
      const Err(ExecutionError(ExecutionErrorCode.shellUnavailable, 'none'));
  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(String command, {required String id, required String logPath, ShellExecOptions? options}) async {
    final j = _FakeJob(id: id, logPath: logPath);
    jobs.add(j);
    return Ok(j);
  }
}

void main() {
  test('bash_job status bumps probeGeneration', () async {
    final env = MemoryExecutionEnv(cwd: '/work', shell: _FakeBgEnv());
    final registry = ShellJobRegistry(env: env);
    final tool = bashJobTool(registry);
    final entry = await registry.start('sleep 10');
    expect(entry.probeGeneration, 0);
    await tool.execute({'action': 'status', 'id': entry.id}, null, null);
    expect(entry.probeGeneration, 1);
    await tool.execute({'action': 'output', 'id': entry.id}, null, null);
    expect(entry.probeGeneration, 2);
  });
}
