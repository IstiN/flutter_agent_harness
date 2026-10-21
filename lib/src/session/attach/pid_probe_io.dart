/// POSIX pid liveness probe for the session-presence sweep (gh-1660):
/// the `kill -0` dance — Dart has no `kill(pid, 0)`, so the shell asks.
/// IO-bound: reachable only through `lib/io.dart`.
library;

import 'dart:io';

/// Whether [pid] is still a live process, or `null` when this host has
/// no probe (Windows — `Process.killPid` there hard-terminates
/// regardless of signal, so it can never act as a liveness check).
///
/// A `false` answer is definitive (no such process — the owner of a
/// presence file is gone); `null` means "unknown" and callers fall back
/// to time-based staleness. Errors (spawn failures, odd shells) degrade
/// to `null` the same way — the sweep must never turn a probe hiccup
/// into a wrong deletion.
bool? probePidAlive(int pid) {
  if (!Platform.isLinux && !Platform.isMacOS) return null;
  try {
    return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
  } on Object {
    return null;
  }
}
