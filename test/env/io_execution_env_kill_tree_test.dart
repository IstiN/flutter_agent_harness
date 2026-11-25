// Seam-driven tests for the LocalShell.killTree walk-kill rounds (issue
// #2276): no real processes — the fake table stands in for `ps`, the
// signal seam records what would be sent. The real-process legs live in
// io_execution_env_test.dart (CI-Linux).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/env/process_probe_io.dart';
import 'package:test/test.dart';

void main() async {
  final psAvailable = Platform.isWindows
      ? false
      : await Process.run('ps', [
          '-ax',
          '-o',
          'pid=',
        ]).then((p) => p.exitCode == 0).catchError((Object _) => false);

  tearDown(() {
    LocalShell.ownProcessGroupOverride = null;
    LocalShell.ourPgidOverride = null;
    LocalShell.descendantsOfOverride = null;
    LocalShell.signalPidOverride = null;
    LocalShell.processDetailTableSnapshotOverride = null;
  });

  test('KILL round keeps the pre-reap root set: a TERM-trapping grandchild is '
      'killed after the leader is reaped (issue #2276 AC2)', () async {
    // Fake tree pid→ppid: leader(100) → shell(200) → sleeper(300); 300
    // traps TERM. The leader answers TERM and is reaped by the VM
    // between the rounds — `ps` then hides the reparented survivor from
    // any walk rooted at the bare leader pid.
    var table = <int, int>{100: 1, 200: 100, 300: 200};
    final walks = <Set<int>>[];
    final signals = <(int, ProcessSignal)>[];
    LocalShell.descendantsOfOverride = (roots) async {
      walks.add(Set.of(roots));
      // The real walk's semantics over the CURRENT table: roots still
      // observable, plus their descendants.
      final out = <int>{};
      final queue = roots.where(table.containsKey).toList();
      out.addAll(queue);
      while (queue.isNotEmpty) {
        final parent = queue.removeAt(0);
        for (final row in table.entries) {
          if (row.value == parent && out.add(row.key)) queue.add(row.key);
        }
      }
      return out;
    };
    LocalShell.signalPidOverride = (pid, signal) {
      signals.add((pid, signal));
      if (signal == ProcessSignal.sigterm) {
        table.remove(100);
        table.remove(200);
        table[300] = 1; // reparented to init
      }
    };

    await LocalShell.killTree(100, ownGroup: false);

    expect(walks, hasLength(2), reason: 'one walk per round');
    expect(walks[0], {100}, reason: 'walk #1 roots at the job pid');
    expect([
      for (final s in signals)
        if (s.$2 == ProcessSignal.sigterm) s.$1,
    ], unorderedEquals([100, 200, 300]));
    expect(
      walks[1],
      {100, 200, 300},
      reason:
          'the KILL round re-roots at walk #1’s own victim set — '
          're-rooting at the bare pid yields {} once the leader is '
          'reaped, and nothing is ever SIGKILLed',
    );
    expect(
      [
        for (final s in signals)
          if (s.$2 == ProcessSignal.sigkill) s.$1,
      ],
      {300},
      reason:
          'the TERM-trapping grandchild must reach the KILL round — '
          'today it survives while the stop answers "Stopped"',
    );
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('ownGroup group-kill path unchanged: never walks, never walk-signals '
      '(issue #2276 AC3 — the gh-1053 contract)', () async {
    var walks = 0;
    var signals = 0;
    LocalShell.descendantsOfOverride = (roots) async {
      walks++;
      return roots;
    };
    LocalShell.signalPidOverride = (_, _) {
      signals++;
    };

    await LocalShell.killTree(100, ownGroup: true);

    expect(walks, 0, reason: 'the group signal owns the whole tree');
    expect(
      signals,
      0,
      reason: 'the ps-walk signal rounds never fire on an ownGroup stop',
    );
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
    'a vanished tree stops at walk #1 and resumes the leader probe',
    () async {
      final signals = <ProcessSignal>[];
      LocalShell.descendantsOfOverride = (_) async => const <int>{};
      LocalShell.signalPidOverride = (_, signal) {
        signals.add(signal);
      };

      await LocalShell.killTree(100, ownGroup: false);

      expect(signals, [
        ProcessSignal.sigstop,
        ProcessSignal.sigcont,
      ], reason: 'the pre-walk freeze is always paired; no TERM/KILL is sent');
    },
  );

  test('a failed walk resumes the frozen leader', () async {
    final signals = <ProcessSignal>[];
    LocalShell.descendantsOfOverride = (_) async =>
        throw StateError('ps unavailable');
    LocalShell.signalPidOverride = (_, signal) {
      signals.add(signal);
    };

    await LocalShell.killTree(100, ownGroup: false);

    expect(signals, [ProcessSignal.sigstop, ProcessSignal.sigcont]);
  });

  test(
    'a stopped non-ownGroup registry job buffers and adopts its survivors',
    skip: Platform.isWindows ? 'POSIX process semantics only' : false,
    () async {
      final workspace = await Directory.systemTemp.createTemp('fah2276-stop-');
      addTearDown(() => workspace.delete(recursive: true));
      LocalShell.ownProcessGroupOverride = false;
      LocalShell.ourPgidOverride = 700;
      LocalShell.descendantsOfOverride = (roots) async => Set.of(roots);
      // Let stop()'s direct-child backstop reap the shell; the fake table
      // supplies the reparented survivor without requiring real `ps`.
      LocalShell.signalPidOverride = (_, _) {};
      LocalShell.processDetailTableSnapshotOverride = () async =>
          _survivorRows(990000);

      final adoptedBatch = Completer<List<ShellJobEntry>>();
      final registry = ShellJobRegistry(
        env: LocalExecutionEnv(cwd: workspace.path),
        onAdopt: (adopted, {required source}) {
          if (!adoptedBatch.isCompleted) adoptedBatch.complete(adopted);
        },
        livenessTableOverride: () async => null,
        stopAdoptedOverride: (_) async => const [],
      );
      final entry = await registry.start('while :; do :; done');
      await entry.stop();
      await entry.settled;

      final adopted = await adoptedBatch.future.timeout(
        const Duration(seconds: 5),
      );
      expect(entry.stopReason, 'stopped');
      // Both the tagged subshell and the work under it are re-tracked.
      expect(adopted.map((e) => e.pid).toSet(), {990000, 990001});
      final work = adopted.firstWhere((e) => e.pid == 990001);
      expect(work.isAdopted, isTrue);
      expect(work.command, 'sleep 606.2276');
      final shell = adopted.firstWhere((e) => e.pid == 990000);
      expect(shell.command, contains(currentProcessOwnerMarker()));
      for (final entry in adopted) {
        expect(registry.jobs, contains(entry));
        await entry.stop();
      }
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'a timed-out non-ownGroup exec carries survivors on its error result',
    skip: Platform.isWindows ? 'POSIX process semantics only' : false,
    () async {
      LocalShell.ownProcessGroupOverride = false;
      LocalShell.ourPgidOverride = 700;
      LocalShell.descendantsOfOverride = (roots) async => Set.of(roots);
      LocalShell.signalPidOverride = (_, _) {};
      LocalShell.processDetailTableSnapshotOverride = () async =>
          _survivorRows(990002);

      final result = await const LocalShell().exec(
        'while :; do :; done',
        options: const ShellExecOptions(timeout: Duration(milliseconds: 100)),
      );

      expect(result.isErr, isTrue);
      final error = result.errorOrNull!;
      expect(error.code, ExecutionErrorCode.timeout);
      expect(error.survivors.map((s) => s.pid).toSet(), {990002, 990003});
      expect(
        error.survivors.map((s) => s.command),
        containsAll([contains(currentProcessOwnerMarker()), 'sleep 606.2276']),
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'gh-2413: a detached program (own argv, no owner marker) is never a '
    'survivor on non-ownGroup hosts',
    skip: Platform.isWindows ? 'POSIX process semantics only' : false,
    () async {
      LocalShell.ownProcessGroupOverride = false;
      LocalShell.ourPgidOverride = 700;
      LocalShell.descendantsOfOverride = (roots) async => Set.of(roots);
      LocalShell.signalPidOverride = (_, _) {};
      LocalShell.processDetailTableSnapshotOverride = () async => [
        _detachedRow(990003),
        ..._peerRows(990004),
      ];
      final result = await const LocalShell().exec(
        'echo hi',
        options: const ShellExecOptions(timeout: Duration(seconds: 5)),
      );
      expect(result.isOk, isTrue);
      expect(
        result.valueOrNull!.survivors,
        isEmpty,
        reason:
            'a detached program and a peer session\'s subtree are '
            'never adopted on marker-gated hosts',
      );
    },
  );

  test(
    'AC1 real walk: stop kills a TERM-trapping grandchild after the leader '
    'is reaped',
    skip: Platform.isWindows || !psAvailable
        ? 'needs POSIX with ps access'
        : false,
    () async {
      const marker = 'sleep 606.2276';
      addTearDown(() => Process.run('pkill', ['-f', marker]));
      final workspace = await Directory.systemTemp.createTemp('fah2276-ac1-');
      addTearDown(() => workspace.delete(recursive: true));
      LocalShell.ownProcessGroupOverride = false;
      final registry = ShellJobRegistry(
        env: LocalExecutionEnv(cwd: workspace.path),
      );

      // PR#2301 review: the trap must live in a SUBSHELL around the
      // grandchild only. With the old shape `trap "" TERM; $marker &
      // wait` the trap was set before the background fork, so TERM was
      // SIG_IGN in BOTH the job shell and the sleep — the leader
      // survived the TERM round and was still observable at walk #2,
      // making the old bare-leader re-root and the new pre-reap re-root
      // return the same KILL set (this leg could not red-fail a
      // regression). Now the leader keeps default TERM handling and is
      // reaped by the TERM round, while the grandchild execs with TERM
      // ignored — exactly the shape only the pre-reap victim set kills.
      final entry = await registry.start('(trap "" TERM; exec $marker) & wait');
      await entry.stop();
      await entry.settled;

      var survivors = <String>{};
      for (var i = 0; i < 20; i++) {
        survivors = await _liveMarkerProcesses(marker);
        if (survivors.isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        survivors,
        isEmpty,
        reason: 'the pre-reap KILL round must reach the trapped grandchild',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  group('shouldScanSurvivors — the #2201 scan gate on stop exits (issue '
      '#2276: gate on group leadership truthfully)', () {
    test('a normal exit always scans', () {
      expect(
        LocalShell.shouldScanSurvivors(stopped: false, ownGroup: true),
        isTrue,
      );
      expect(
        LocalShell.shouldScanSurvivors(stopped: false, ownGroup: false),
        isTrue,
      );
    });

    test('a stop scans only where the group kill did not own the tree', () {
      expect(
        LocalShell.shouldScanSurvivors(stopped: true, ownGroup: true),
        isFalse,
        reason:
            'gh-1053: the group kill reaped every descendant — REG '
            'unchanged',
      );
      expect(
        LocalShell.shouldScanSurvivors(stopped: true, ownGroup: false),
        isTrue,
        reason:
            'the ps walk can miss reparented TERM-trapping '
            'grandchildren — adoption must re-track them instead of '
            '"Stopped" lying',
      );
    });
  });
}

/// The survivor fixture (gh-2413): OUR leftover subtree after the job's
/// wrapper exited — a backgrounded SUBSHELL still wearing this harness's
/// wrapper argv (`fa_sh_cmd_<pid>_…`, the owner marker) and, under it, the
/// child that does the work (`sleep` — its own argv carries nothing; it is
/// ours because the `ppid` chain reaches the tagged subshell). [wrapperPid]
/// is the subshell, [wrapperPid] + 1 the sleep.
List<ProcessDetailRow> _survivorRows(int wrapperPid) => [
  (
    pid: wrapperPid,
    ppid: 1,
    pgid: 700,
    lstart: _lstartOf(DateTime.now()),
    command: 'sh -c . \$1 sh /T/${currentProcessOwnerMarker()}AbC/cmd.sh',
  ),
  (
    pid: wrapperPid + 1,
    ppid: wrapperPid,
    pgid: 700,
    lstart: _lstartOf(DateTime.now()),
    command: 'sleep 606.2276',
  ),
];

/// A PEER session's leftover: the same shape, tagged with another
/// harness's marker (gh-2413 cross-talk shape) — never ours.
List<ProcessDetailRow> _peerRows(int wrapperPid) => [
  (
    pid: wrapperPid,
    ppid: 1,
    pgid: 700,
    lstart: _lstartOf(DateTime.now()),
    command: 'sh -c . \$1 sh /T/fa_sh_cmd_${pid + 1}_Zz/cmd.sh',
  ),
  (
    pid: wrapperPid + 1,
    ppid: wrapperPid,
    pgid: 700,
    lstart: _lstartOf(DateTime.now()),
    command: 'sleep 606.2276',
  ),
];

/// A detached program's row: own argv, chain → init (gh-2413 negative).
ProcessDetailRow _detachedRow(int pid) => (
  pid: pid,
  ppid: 1,
  pgid: 700,
  lstart: _lstartOf(DateTime.now()),
  command: 'sleep 606.2276',
);

Future<Set<String>> _liveMarkerProcesses(String marker) async {
  final ps = await Process.run('ps', ['-ax', '-o', 'command=']);
  return (ps.stdout as String)
      .split('\n')
      .where((line) => line.contains(marker))
      .toSet();
}

String _lstartOf(DateTime at) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  String two(int value) => value.toString().padLeft(2, '0');
  return '${days[at.weekday - 1]} ${months[at.month - 1]} ${at.day} '
      '${two(at.hour)}:${two(at.minute)}:${two(at.second)} ${at.year}';
}
