import 'package:flutter_agent_harness/src/power_config.dart';
import 'package:flutter_agent_harness/src/power_runner.dart';
import 'package:test/test.dart';

/// A runner that records acquisitions without spawning anything.
class _FakeRunner implements PowerAssertionRunner {
  _FakeRunner({this.error});

  /// When set, acquire throws instead (spawn failure path).
  final Object? error;

  final acquisitions = <PowerAssertionOptions>[];
  final handles = <_FakeHandle>[];

  @override
  Future<PowerAssertionHandle> acquire(PowerAssertionOptions options) async {
    if (error != null) throw error!;
    acquisitions.add(options);
    final handle = _FakeHandle('fake ${options.reason}');
    handles.add(handle);
    return handle;
  }
}

class _FakeHandle implements PowerAssertionHandle {
  _FakeHandle(this.description);

  @override
  final String description;

  var released = 0;
  Object? releaseError;

  @override
  bool get held => released == 0;

  @override
  Future<void> release() async {
    if (releaseError != null) throw releaseError!;
    released++;
  }
}

/// The session lifecycle (issue #325, ported from oh-my-pi's
/// AgentSession): idempotent acquire at session start, release on exit,
/// warn-not-crash on both sides.
void main() {
  test('off acquires nothing', () async {
    final runner = _FakeRunner();
    final controller = PowerAssertionController(
      runner: runner,
      level: PowerAssertionLevel.off,
    );
    await controller.acquire();
    expect(runner.acquisitions, isEmpty);
    expect(controller.acquired, isFalse);
  });

  test('acquire delegates the translated options once; release ends it', () async {
    final runner = _FakeRunner();
    final controller = PowerAssertionController(
      runner: runner,
      level: PowerAssertionLevel.display,
    );
    await controller.acquire();
    await controller.acquire(); // idempotent
    expect(runner.acquisitions, hasLength(1));
    expect(runner.acquisitions.single.idle, isTrue);
    expect(runner.acquisitions.single.display, isTrue);
    expect(controller.acquired, isTrue);

    await controller.release();
    await controller.release(); // idempotent
    expect(runner.handles.single.released, 1);
    expect(controller.acquired, isFalse);
  });

  test('a spawn failure warns and the session continues unguarded', () async {
    final warnings = <String>[];
    final controller = PowerAssertionController(
      runner: _FakeRunner(error: Exception('caffeinate: not found')),
      level: PowerAssertionLevel.idle,
      onWarn: warnings.add,
    );
    await controller.acquire();
    expect(controller.acquired, isFalse);
    expect(warnings.single, contains('power: sleep prevention unavailable'));
    expect(warnings.single, contains('caffeinate: not found'));
  });

  test('a release failure warns but never throws', () async {
    final warnings = <String>[];
    final runner = _FakeRunner();
    final controller = PowerAssertionController(
      runner: runner,
      level: PowerAssertionLevel.idle,
      onWarn: warnings.add,
    );
    await controller.acquire();
    runner.handles.single.releaseError = Exception('already reaped');
    await controller.release();
    expect(controller.acquired, isFalse);
    expect(warnings.single, contains('power: sleep prevention release failed'));
  });

  test('status renders the level, held state and holder', () async {
    final runner = _FakeRunner();
    final controller = PowerAssertionController(
      runner: runner,
      level: PowerAssertionLevel.system,
    );
    expect(
      controller.status().toString(),
      'sleepPrevention=system held=no (not acquired)',
    );
    await controller.acquire();
    expect(
      controller.status().toString(),
      'sleepPrevention=system held=yes (fake fa agent session)',
    );
    await controller.release();
    expect(
      controller.status().toString(),
      'sleepPrevention=system held=no (not acquired)',
    );
  });

  test('status explains the off level', () async {
    final controller = PowerAssertionController(
      runner: _FakeRunner(),
      level: PowerAssertionLevel.off,
    );
    await controller.acquire();
    expect(
      controller.status().toString(),
      'sleepPrevention=off held=no (disabled by config)',
    );
  });

  test('NoopPowerAssertionRunner degrades cleanly', () async {
    const runner = NoopPowerAssertionRunner('not implemented on windows yet');
    final handle = await runner.acquire(
      powerAssertionOptions(PowerAssertionLevel.idle)!,
    );
    expect(handle.held, isFalse);
    expect(handle.description, contains('not implemented'));
    await handle.release(); // no-op, never throws
  });
}
