// herdr report spawn transport (issue #1481, v2 review hardening): the
// spawn closure in bin/fah_herdr_spawn.dart must (1) drain the child's
// stdout/stderr — a chatty herdr emitting more than the OS pipe buffer
// (~64 KiB) would otherwise block on write and hold `exitCode` open until
// the kill window, one killed process per transition, silently — and
// (2) keep the kill-on-timeout contract the rework introduced (a wedged
// herdr cannot linger past the window).
//
// Real processes (`io` tag — excluded from the pre-commit gate, run in
// CI's unit leg): dd writing 192 KiB proves the drain, sleep proves the
// kill. A standalone bin library, so the transport is importable here,
// mirroring test/bin_boot_restore_pin_test.dart.
@Tags(['io'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../bin/fah_herdr_spawn.dart';

void main() {
  group('spawnHerdrReport', () {
    test(
      'a chatty child (>64 KiB on stdout) cannot block the report on a full pipe',
      () async {
        final watch = Stopwatch()..start();
        await spawnHerdrReport(const [
          '/bin/sh',
          '-c',
          'dd if=/dev/zero bs=1024 count=192 2>/dev/null',
        ]);
        watch.stop();
        expect(
          watch.elapsed,
          lessThan(const Duration(seconds: 4)),
          reason:
              'the child finished in ${watch.elapsed} — a blocked pipe would '
              'have held the report until the 5s kill window',
        );
      },
    );

    test('a hung child is killed within the kill window', () async {
      final watch = Stopwatch()..start();
      await spawnHerdrReport(const [
        '/bin/sh',
        '-c',
        'sleep 30',
      ], killAfter: const Duration(milliseconds: 300));
      watch.stop();
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason:
            'the kill window (300ms) must reclaim the subprocess — '
            'waiting it out would take 30s',
      );
    });

    test('a clean child completes with the process, exit untouched', () async {
      await spawnHerdrReport(const ['/bin/sh', '-c', 'exit 0']);
      expect(
        Directory.current,
        isNotNull, // the await above completed
        reason: 'spawnHerdrReport returned normally',
      );
    });
  });
}
