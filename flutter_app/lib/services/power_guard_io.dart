/// IO implementation: the app-side sleep-prevention guard. Never blocks
/// app boot — an unreadable config or a missing helper yields null and
/// the session simply runs unguarded.
library;

import 'dart:io' as io;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart' as harness_io;

import '../sandbox/env_factory_io.dart' show desktopHomeDir;
import 'app_log.dart';

/// The app's power-assertion controller, or null when sleep prevention
/// is off (`power.sleepPrevention: off`) or unavailable. Warnings go to
/// the app debug log (logs/app.log), never the UI — the guard is
/// best-effort.
PowerAssertionController? createAppPowerAssertion() {
  try {
    final home = desktopHomeDir();
    if (home == null) return null;
    final level =
        loadCliConfig(home).powerSleepPrevention ?? PowerAssertionLevel.idle;
    if (level == PowerAssertionLevel.off) return null;
    return PowerAssertionController(
      runner: harness_io.hostPowerRunner(pid: io.pid),
      level: level,
      onWarn: (message) => AppLog.i('power', message),
    );
  } on Object {
    // The guard must never take the app down with it.
    return null;
  }
}
