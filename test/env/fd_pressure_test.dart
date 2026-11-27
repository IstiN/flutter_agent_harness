import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/env/fd_pressure.dart';
import 'package:flutter_agent_harness/src/env/fd_pressure_io.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';

/// Whether this host exposes a descriptor table at all.
final hasFdDir = Platform.isMacOS || Platform.isLinux;

/// The probe, retried briefly: a host that cannot read its descriptor
/// table answers null — the tests then SKIP honestly (the guard's own
/// documented degrade) instead of failing on an environment fact.
FdPressureSnapshot? probeWithRetry() {
  for (var i = 0; i < 5; i++) {
    final snapshot = defaultFdPressureSnapshot();
    if (snapshot != null) return snapshot;
    sleep(const Duration(milliseconds: 20));
  }
  return null;
}

void main() {
  group('fd-pressure contracts (pure)', () {
    test('the threshold is 80% of a positive limit', () {
      expect(fdPressureExceeded((open: 204, limit: 256)), isFalse);
      expect(fdPressureExceeded((open: 205, limit: 256)), isTrue);
      expect(
        fdPressureExceeded((open: 5000, limit: 0)),
        isFalse,
        reason: 'no limit / unknown never reads as pressure',
      );
    });

    test('errno 24 is recognized from the OS error and from the message', () {
      expect(
        isFdPressureError(
          const FileSystemException(
            'Cannot open file',
            '/x',
            OSError('Too many open files', 24),
          ),
        ),
        isTrue,
      );
      expect(
        isFdPressureError('ProcessException: Too many open files'),
        isTrue,
      );
      expect(isFdPressureError('FileError(unknown, p): errno 24'), isTrue);
      expect(
        isFdPressureError(
          const FileSystemException('x', '/x', OSError('No such file', 2)),
        ),
        isFalse,
      );
      expect(isFdPressureError('Command exited with code 1'), isFalse);
    });

    test('the typed error is operational and names the pressure', () {
      final error = FdPressureException(open: 240, limit: 256);
      expect(error, isA<ToolValidationException>());
      expect(error.message, startsWith('fd pressure: 240/256 open'));
      expect(error.message, contains('closing settled jobs'));
      expect(fdPressureLabel((open: 240, limit: 256)), '240/256 open');
    });
  });

  group('VM probe', () {
    test(
      'defaultFdPressureSnapshot reads this process\'s table and soft limit',
      skip: hasFdDir ? null : 'needs /dev/fd or /proc/self/fd',
      () {
        final snapshot = probeWithRetry();
        if (snapshot == null) {
          markTestSkipped('no descriptor table readable on this host');
          return;
        }
        expect(snapshot.open, greaterThan(2));
        expect(snapshot.limit, greaterThanOrEqualTo(256));
        expect(fdPressureExceeded(snapshot), isFalse);
        // A second read stays a sane count — never a cross-time equality:
        // other test files run as isolates of THIS process and open and
        // close descriptors between the two reads (hook run #2b saw 48 →
        // 44 under load), so only invariants that cannot jitter hold.
        final again = countOpenFds();
        expect(again, isNotNull);
        expect(again!, greaterThanOrEqualTo(3));
        expect(again, lessThan(snapshot.limit));
      },
    );

    test(
      'gh-2415 session-handle hygiene: bounded header reads release their '
      'handle — N session files × K rounds leave the fd table flat',
      skip: hasFdDir ? null : 'needs /dev/fd or /proc/self/fd',
      () async {
        final dir = await Directory.systemTemp.createTemp('fdh_');
        addTearDown(() => dir.delete(recursive: true));
        final env = LocalExecutionEnv(cwd: dir.path);
        // The live shape: a header-only primary, a big transcript, a
        // malformed-utf8 file (torn write) — 240 files.
        final paths = <String>[];
        for (var i = 0; i < 240; i++) {
          final path = '${dir.path}/2026-11-${i % 28 + 1}_s$i.jsonl';
          final file = File(path);
          if (i % 3 == 0) {
            await file.writeAsString('{"header":$i}\n');
          } else if (i % 29 == 0) {
            await file.writeAsBytes([0x7b, 0xff, 0xfe, 0x0a]);
          } else {
            await file.writeAsString(
              List.generate(
                3000,
                (j) => '{"r":$j,"t":"${'x' * 40}"}',
              ).join('\n'),
            );
          }
          paths.add(path);
        }
        final baseline = probeWithRetry()?.open;
        if (baseline == null) {
          markTestSkipped('no descriptor table readable on this host');
          return;
        }
        for (var round = 0; round < 4; round++) {
          for (final path in paths) {
            final lines = await env.readTextLines(path, maxLines: 2);
            if (lines.isOk) {
              expect(lines.valueOrNull!.length, lessThanOrEqualTo(2));
            }
          }
          // The drift bound: transient descriptors of other test files
          // sharing this `dart test` process (the hook runs files in
          // parallel isolates), never one per file (a leak adds 240).
          final now = probeWithRetry()?.open;
          if (now == null) {
            markTestSkipped('descriptor table became unreadable');
            return;
          }
          expect(
            now,
            lessThanOrEqualTo(baseline + 60),
            reason: 'round $round leaked a handle per header read',
          );
        }
      },
    );

    test('bounded header reads keep the stream path\'s semantics', () async {
      final dir = await Directory.systemTemp.createTemp('fdh2_');
      addTearDown(() => dir.delete(recursive: true));
      final env = LocalExecutionEnv(cwd: dir.path);
      await env.writeFile('${dir.path}/a.jsonl', 'h1\r\nh2\nh3\n');
      expect(
        (await env.readTextLines(
          '${dir.path}/a.jsonl',
          maxLines: 2,
        )).valueOrNull,
        ['h1', 'h2'],
      );
      expect(
        (await env.readTextLines(
          '${dir.path}/a.jsonl',
          maxLines: 9,
        )).valueOrNull,
        ['h1', 'h2', 'h3'],
        reason: 'fewer lines than the bound returns what exists',
      );
      expect(
        (await env.readTextLines(
          '${dir.path}/a.jsonl',
          maxLines: 0,
        )).valueOrNull,
        isEmpty,
      );
      expect(
        (await env.readTextLines('${dir.path}/missing.jsonl')).isErr,
        isTrue,
      );
      // The unbounded whole-file read keeps the streaming path.
      expect((await env.readTextLines('${dir.path}/a.jsonl')).valueOrNull, [
        'h1',
        'h2',
        'h3',
      ]);
    });
  });
}
