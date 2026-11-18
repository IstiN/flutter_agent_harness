// Seam-driven tests for the LocalShell.killTree walk-kill rounds (issue
// #2276): no real processes — the fake table stands in for `ps`, the
// signal seam records what would be sent. The real-process legs live in
// io_execution_env_test.dart (CI-Linux).
library;

import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() {
    LocalShell.descendantsOfOverride = null;
    LocalShell.signalPidOverride = null;
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

  test('a vanished tree stops at walk #1: no signals fired', () async {
    final signals = <ProcessSignal>[];
    LocalShell.descendantsOfOverride = (_) async => const <int>{};
    LocalShell.signalPidOverride = (_, signal) {
      signals.add(signal);
    };

    await LocalShell.killTree(100, ownGroup: false);

    expect(signals, isEmpty);
  });

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
