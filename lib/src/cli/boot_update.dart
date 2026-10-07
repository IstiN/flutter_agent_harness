/// The `auto_update:` boot hook decision surface (issue #1377): pure
/// skip/selection rules plus the once-per-process notify-banner guard.
/// The engine (fetch, verify, swap, successor spawn) lives in the host
/// executable (`bin/self_manage.dart`); lib stays dart:io-free, so only
/// these decision pieces live here — importable by tests.
library;

import 'cli_config.dart';

/// What the boot hook does for this run: nothing (`off`, or a run that
/// must never restart itself), a bounded notify check, or apply + restart
/// before the session boots.
enum BootUpdateAction { none, notifyCheck, applyAndExit }

/// Pure skip/selection rules of the auto-update boot hook. Serve and
/// wire-daemon runs are skipped unconditionally: a daemon must not restart
/// itself under connected clients.
BootUpdateAction bootUpdateAction({
  required AutoUpdateMode mode,
  required bool serveOrDaemon,
}) {
  if (serveOrDaemon) return BootUpdateAction.none;
  return switch (mode) {
    AutoUpdateMode.off => BootUpdateAction.none,
    AutoUpdateMode.notify => BootUpdateAction.notifyCheck,
    AutoUpdateMode.on => BootUpdateAction.applyAndExit,
  };
}

/// The once-per-process guard for the `fa vX available` boot banner: the
/// first call returns the banner line, every later call returns null.
class AutoUpdateNotify {
  bool _shown = false;

  /// The banner for [latestTag] (the full release tag, `v0.1.44` — the v
  /// is part of it), or null when it already fired.
  String? banner(String latestTag) {
    if (_shown) return null;
    _shown = true;
    return 'fa $latestTag available → run: fa update';
  }
}
