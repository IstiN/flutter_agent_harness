@TestOn('vm')
library;

/// gh-1947 — the `ShellJobRegistry` settle continuation must run in the
/// zone the registry was CONSTRUCTED in (host boot), never in the zone of
/// the `bash` call that started the job. A job started by a subagent used
/// to carry its settle — and the host's `onSettled` settle-wake that can
/// start a fresh MAIN run — into the child's subagent zone, so identity
/// consumers of the later run (`schedule_message`'s self-mailbox
/// resolution) attributed MAIN's work to the long-finished child.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A detached job the test settles manually.
final class _ManualJob implements ShellJob {
  _ManualJob({required this.id});

  @override
  final String id;
  @override
  final String command = 'sleep 1';
  @override
  final String logPath = '/jobs/log';
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

  void settle() {
    if (_stopped) return;
    _stopped = true;
    _settled.complete();
  }

  @override
  Future<void> stop() async => settle();
}

final class _ManualJobShell implements Shell, BackgroundShell {
  final jobs = <_ManualJob>[];

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
        'no foreground shell in this test',
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
    final job = _ManualJob(id: id);
    jobs.add(job);
    return Ok(job);
  }
}

void main() {
  test(
    'onSettled fires in the construction zone, not the starting call’s',
    () async {
      final bootMarkers = <Object?>[];
      const bootMarker = 'boot-zone';
      final shell = _ManualJobShell();
      late ShellJobRegistry registry;

      // The host constructs the registry at boot (its own zone value).
      runZoned(() {
        registry = ShellJobRegistry(
          env: MemoryExecutionEnv(cwd: '/work', shell: shell),
          onSettled: (job) {
            bootMarkers.add(Zone.current[#testZoneMarker]);
          },
        );
      }, zoneValues: {#testZoneMarker: bootMarker});

      // A subagent's bash call starts the job inside the CHILD's scope.
      await runZoned(
        () => registry.start('watch-release.sh'),
        zoneValues: {#testZoneMarker: 'child-zone', #fahSubagentId: 'child-1'},
      );
      expect(shell.jobs, hasLength(1));

      // The job settles long after the child's run ended.
      shell.jobs.single.settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bootMarkers, hasLength(1));
      expect(
        bootMarkers.single,
        bootMarker,
        reason:
            'gh-1947: the settle callback (and the host settle-wake it '
            'drives) must run in the registry construction zone — the '
            'starting call’s subagent zone must never leak into it',
      );
    },
  );

  test('settle bookkeeping (settledAt, GC) still runs on every exit', () async {
    final shell = _ManualJobShell();
    var settles = 0;
    final registry = ShellJobRegistry(
      env: MemoryExecutionEnv(cwd: '/work', shell: shell),
      onSettled: (_) => settles++,
    );
    final entry = await registry.start('job.sh');
    expect(entry.isRunning, isTrue);
    shell.jobs.single.settle();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(settles, 1);
    expect(entry.isRunning, isFalse);
    expect(entry.settledAt, isNotNull);
  });
}
