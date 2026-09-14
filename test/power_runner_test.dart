@TestOn('vm')
library;

/// PowerAssertionController lifecycle tests (issue #326 rework): the
/// assertion is held PER RUN by default — acquired when a run goes in
/// flight, released when it settles — and only the explicit
/// `power.hold: session` opt-in holds from session open to close. The
/// gated fake runner is the clock: an acquire left pending models a run
/// that settles while the helper is still spawning (the in-flight
/// branch), and the test opens the gate to advance it.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A handle that counts releases and can report itself dead.
class _FakeHandle implements PowerAssertionHandle {
  @override
  final String description;

  _FakeHandle(this.description);

  var released = 0;

  @override
  bool get held => released == 0;

  @override
  Future<void> release() async => released++;
}

/// A runner whose `acquire` stays in flight until the test opens
/// [gate] — the controllable "clock" for the in-flight lifecycle branch.
/// With [gated] false (the default) the gate starts open: acquires
/// finish on the next microtask, like a fast spawn.
class _GatedRunner implements PowerAssertionRunner {
  _GatedRunner({bool gated = false}) {
    if (!gated) _gate.complete();
  }

  final _gate = Completer<void>();

  /// Lets every pending (and future) acquire finish — the clock tick.
  void tick() {
    if (!_gate.isCompleted) _gate.complete();
  }

  var acquireCalls = 0;
  final handles = <_FakeHandle>[];
  Object? error;

  @override
  Future<PowerAssertionHandle> acquire(PowerAssertionOptions options) async {
    acquireCalls++;
    if (error != null) throw error!;
    await _gate.future;
    final handle = _FakeHandle('fake-caffeinate ${options.idle ? '-i' : ''}');
    handles.add(handle);
    return handle;
  }
}

void main() {
  group('per-run hold (the default)', () {
    test('onRunStarted acquires, onRunSettled releases', () async {
      final runner = _GatedRunner();
      final controller = PowerAssertionController(
        runner: runner,
        level: PowerAssertionLevel.idle,
      );

      await controller.onSessionOpened();
      expect(runner.acquireCalls, 0, reason: 'session open must NOT acquire');

      controller.onRunStarted();
      await Future<void>.delayed(Duration.zero);
      expect(controller.acquired, isTrue);
      expect(controller.status().held, isTrue);

      await controller.onRunSettled();
      expect(runner.handles.single.released, 1);
      expect(controller.acquired, isFalse);
      expect(controller.status().held, isFalse);
    });

    test('the next run re-acquires (acquire → release → acquire)', () async {
      final runner = _GatedRunner();
      final controller = PowerAssertionController(
        runner: runner,
        level: PowerAssertionLevel.idle,
      );
      for (var i = 0; i < 2; i++) {
        controller.onRunStarted();
        await Future<void>.delayed(Duration.zero);
        await controller.onRunSettled();
      }
      expect(runner.acquireCalls, 2);
      expect(runner.handles, hasLength(2));
      expect(runner.handles.every((h) => h.released == 1), isTrue);
    });

    test('a run that settles while the spawn is still in flight strands '
        'nothing: release waits the acquire out', () async {
      final runner = _GatedRunner();
      final controller = PowerAssertionController(
        runner: runner,
        level: PowerAssertionLevel.idle,
      );

      // The run starts — the spawn is now in flight, unfinished.
      controller.onRunStarted();
      expect(runner.acquireCalls, 1);
      expect(controller.acquired, isFalse, reason: 'still spawning');

      // The run settles BEFORE the spawn completed (a very short turn).
      final settled = controller.onRunSettled();
      await Future<void>.delayed(Duration.zero);
      // Clock advances: the spawn finishes — and must be released by
      // the pending settle, not stranded until session close.
      runner.tick();
      await settled;

      expect(controller.acquired, isFalse);
      expect(runner.handles.single.released, 1);
      // And the safety release at session close is still a clean no-op.
      await controller.onSessionClosed();
      expect(runner.handles.single.released, 1);
    });

    test('a double run-start acquires once (idempotent)', () async {
      final runner = _GatedRunner();
      final controller = PowerAssertionController(
        runner: runner,
        level: PowerAssertionLevel.display,
      );
      controller.onRunStarted();
      controller.onRunStarted();
      await Future<void>.delayed(Duration.zero);
      expect(runner.acquireCalls, 1);
    });

    test('a spawn failure warns and the run continues unguarded', () async {
      final runner = _GatedRunner()..error = Exception('caffeinate missing');
      final warnings = <String>[];
      final controller = PowerAssertionController(
        runner: runner,
        level: PowerAssertionLevel.idle,
        onWarn: warnings.add,
      );
      controller.onRunStarted();
      await controller.acquire();
      expect(warnings.single, contains('sleep prevention unavailable'));
      // Settling after a failed acquire is a clean no-op, not an error.
      await controller.onRunSettled();
      expect(controller.acquired, isFalse);
    });

    test('level off never acquires', () async {
      final runner = _GatedRunner();
      final controller = PowerAssertionController(
        runner: runner,
        level: PowerAssertionLevel.off,
      );
      controller.onRunStarted();
      await controller.onRunSettled();
      await controller.onSessionOpened();
      expect(runner.acquireCalls, 0);
    });
  });

  group('session hold (the explicit opt-in)', () {
    test('session open acquires; runs neither acquire nor release', () async {
      final runner = _GatedRunner();
      final controller = PowerAssertionController(
        runner: runner,
        level: PowerAssertionLevel.idle,
        hold: PowerAssertionHold.session,
      );

      await controller.onSessionOpened();
      expect(runner.acquireCalls, 1);
      expect(controller.status().held, isTrue);

      // A run in flight must not touch the session-held assertion.
      controller.onRunStarted();
      await Future<void>.delayed(Duration.zero);
      await controller.onRunSettled();
      expect(runner.acquireCalls, 1, reason: 'no re-acquire per run');
      expect(runner.handles.single.released, 0, reason: 'stays held');
      expect(controller.status().held, isTrue);

      await controller.onSessionClosed();
      expect(runner.handles.single.released, 1);
    });

    test('the status line names the hold', () async {
      final runner = _GatedRunner();
      final perRun = PowerAssertionController(
        runner: runner,
        level: PowerAssertionLevel.idle,
      );
      expect(
        perRun.status().toString(),
        'sleepPrevention=idle hold=per-run held=no (not acquired)',
      );
      final session = PowerAssertionController(
        runner: runner,
        level: PowerAssertionLevel.system,
        hold: PowerAssertionHold.session,
      );
      expect(
        session.status().toString(),
        startsWith('sleepPrevention=system hold=session held='),
      );
    });
  });
}
