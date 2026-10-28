// Shared "manually settled shell job" fixture — the fake pair for tests
// that need a background shell job which settles ONLY when the test
// releases it (a job that outlives the run that started it).

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// A detached [ShellJob] that settles only when the test releases it via
/// [settle] — so a job started inside a run can outlive that run.
final class ManualSettleJob implements ShellJob {
  ManualSettleJob({
    required this.id,
    this.command = 'sleep 1',
    this.logPath = '/jobs/log',
  });

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;
  @override
  int? get pid => null;

  var _stopped = false;
  final _settled = Completer<void>();

  @override
  bool get isRunning => !_stopped;
  @override
  int? get exitCode => _stopped ? 0 : null;
  @override
  Future<void> get settled => _settled.future;
  @override
  String? get stopReason => _stopped ? 'finished' : null;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  bool writeStdin(String data) => false;

  /// Releases the job: it stops running and its `settled` future
  /// completes (firing the registry's settle bookkeeping / `onSettled`).
  void settle() {
    if (_stopped) return;
    _stopped = true;
    _settled.complete();
  }

  @override
  Future<void> stop() async => settle();
}

/// A [Shell] + [BackgroundShell] whose foreground `exec` is unavailable
/// (boot probes stay out of the way) and whose `startShellJob` hands out
/// [ManualSettleJob]s — the test settles them one by one.
final class ManualSettleJobShell implements Shell, BackgroundShell {
  final jobs = <ManualSettleJob>[];

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return const Err(
      ExecutionError(
        ExecutionErrorCode.shellUnavailable,
        'No foreground shell in this test',
      ),
    );
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = ManualSettleJob(id: id, command: command, logPath: logPath);
    jobs.add(job);
    return Ok(job);
  }
}
