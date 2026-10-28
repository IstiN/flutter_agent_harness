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

import '../support/manual_settle_job.dart';

void main() {
  test(
    'onSettled fires in the construction zone, not the starting call’s',
    () async {
      final bootMarkers = <Object?>[];
      const bootMarker = 'boot-zone';
      final shell = ManualSettleJobShell();
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
    final shell = ManualSettleJobShell();
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
