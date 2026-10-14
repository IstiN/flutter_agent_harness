// The herdr report spawn transport (issue #1481): one fire-and-forget
// subprocess of `$HERDR_BIN_PATH pane …` per report. The reporter cuts its
// own await at 2s; the subprocess itself must not linger (kill-on-timeout)
// and must not block on a full stdout/stderr pipe — a chatty herdr emitting
// more than the OS pipe buffer (~64 KiB) would otherwise hold `exitCode`
// open until the kill window, one killed process per transition, silently
// (v2 review hardening).
//
// A standalone bin library (not a part of fah.dart) so the transport is
// directly unit-testable — test/bin_herdr_spawn_drain_test.dart — following
// the fah_boot_restore.dart pattern.
library;

import 'dart:async';
import 'dart:io';

/// Spawns one herdr report and awaits its exit, killing the subprocess if
/// it outlives [killAfter]. The child's stdout/stderr are drained so it can
/// never block on a full pipe; the drains are unawaited — this function's
/// own awaits are the kill window and [Process.exitCode] only.
Future<void> spawnHerdrReport(
  List<String> argv, {
  Duration killAfter = const Duration(seconds: 5),
}) async {
  final process = await Process.start(argv.first, argv.sublist(1));
  unawaited(process.stdout.drain<void>());
  unawaited(process.stderr.drain<void>());
  await process.exitCode.timeout(
    killAfter,
    onTimeout: () {
      process.kill();
      return process.exitCode;
    },
  );
}
