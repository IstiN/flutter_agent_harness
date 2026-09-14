@TestOn('vm')
library;

/// The app's power guard (issues #325/#326): the app cannot throw on a
/// bad `power:` config the way the CLI does — it must degrade to "no
/// assertion" WITHOUT swallowing the why silently: the config error is
/// logged (issue #326 MINOR: parity with CLI strictness where the app
/// can't be strict), and the hold lifecycle follows the config.

import 'dart:io';

import 'package:fa/services/app_log.dart';
import 'package:fa/services/power_guard_io.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    AppLog.reset();
    tmp = Directory.systemTemp.createTempSync('fa-power-guard-test-');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
    AppLog.reset();
  });

  File writeConfig(String yaml) {
    final file = File('${tmp.path}/.fah/config.yaml')
      ..createSync(recursive: true);
    file.writeAsStringSync(yaml);
    return file;
  }

  test('a config error degrades to null AND is logged (not swallowed)', () {
    writeConfig('power:\n  sleepPrevention: sometimes\n');
    final controller = buildAppPowerAssertion(home: tmp.path);
    expect(controller, isNull);
    expect(
      AppLog.dump(),
      contains('[power] sleep-prevention config unavailable'),
    );
    // The log names the offending key — diagnosable, not just "off".
    expect(AppLog.dump(), contains('power.sleepPrevention'));
  });

  test('a missing home is a silent null (no config to be wrong about)', () {
    expect(buildAppPowerAssertion(home: null), isNull);
    expect(AppLog.dump(), '');
  });

  test('level off disables the guard without logging', () {
    writeConfig('power:\n  sleepPrevention: off\n');
    expect(buildAppPowerAssertion(home: tmp.path), isNull);
    expect(AppLog.dump(), '');
  });

  test('defaults: idle level, per-run hold (#326 default)', () {
    writeConfig('power:\n  sleepPrevention: display\n');
    final controller = buildAppPowerAssertion(home: tmp.path);
    expect(controller, isNotNull);
    expect(controller!.level, PowerAssertionLevel.display);
    expect(controller.hold, PowerAssertionHold.perRun);
    expect(
      controller.acquired,
      isFalse,
      reason: 'per-run must not acquire at construction',
    );
  });

  test('explicit session hold is honoured', () {
    writeConfig('power:\n  sleepPrevention: system\n  hold: session\n');
    final controller = buildAppPowerAssertion(home: tmp.path);
    expect(controller!.level, PowerAssertionLevel.system);
    expect(controller.hold, PowerAssertionHold.session);
  });

  test('an absent config file keeps the defaults (idle, per-run)', () {
    final controller = buildAppPowerAssertion(home: tmp.path);
    expect(controller!.level, PowerAssertionLevel.idle);
    expect(controller.hold, PowerAssertionHold.perRun);
  });
}
