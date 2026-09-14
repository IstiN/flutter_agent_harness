/// IO implementation: the app-side sleep-prevention guard. Never blocks
/// app boot — an unreadable config or a missing helper yields null and
/// the session simply runs unguarded. Unlike the CLI (strict: a bad
/// `power:` section throws at load), the app CANNOT die on config
/// errors, so it logs them (issue #326: silent swallowing made bad
/// configs undiagnosable) and continues unguarded.
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
PowerAssertionController? createAppPowerAssertion() =>
    buildAppPowerAssertion(home: desktopHomeDir());

/// Testable core of [createAppPowerAssertion]: reads the `power:` section
/// from `<home>/.fah/config.yaml`. A config error is LOGGED (`[power]`
/// tag in the app log, issue #326) and degrades to null — the CLI is the
/// strict surface, the app never dies on config.
PowerAssertionController? buildAppPowerAssertion({required String? home}) {
  try {
    if (home == null) return null;
    final config = loadCliConfig(home);
    final level = config.powerSleepPrevention ?? PowerAssertionLevel.idle;
    if (level == PowerAssertionLevel.off) return null;
    return PowerAssertionController(
      runner: harness_io.hostPowerRunner(pid: io.pid),
      level: level,
      hold: config.powerHold ?? PowerAssertionHold.perRun,
      onWarn: (message) => AppLog.i('power', message),
    );
  } on Object catch (error) {
    // The guard must never take the app down with it — but it must also
    // never swallow the WHY silently (issue #326): the app cannot throw
    // on a bad config like the CLI does, so the log carries it.
    AppLog.i('power', 'sleep-prevention config unavailable: $error');
    return null;
  }
}
