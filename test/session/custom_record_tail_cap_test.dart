/// The boot raw-scan tail cap (the goal_builder 2.7GB incident): the
/// windowed storage never rotates, so a marathon session's PRIMARY grows
/// unbounded (measured 2.7GB against the 80MB rotate / 95MB hard-cap
/// design). Every boot-scoped consumer of
/// `JsonlSessionRepo.readCustomRecordsOfType` (orphan-report seed,
/// steering recovery, obligations-latest, subagent-registry latest) is a
/// TAIL consumer — `records.last` or pending-vs-consumed steering — so
/// the scan only ever needs the tail region a properly rotated primary
/// promised (≤ kSessionSegmentHardCapBytes). Scanning a giant primary
/// from offset 0 added 10+s to every resume open.
library;

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart' as fah_io;
import 'package:test/test.dart';

void main() {
  late io.Directory tmp;
  late fah_io.LocalFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() async {
    tmp = await io.Directory.systemTemp.createTemp('fah-tail-cap-');
    fs = fah_io.LocalFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: tmp.path);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('tailCapBytes bounds the streamed scan to the file tail — records '
      'beyond the cap are not returned, tail records are', () async {
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await session.appendCustomEntry(
      customType: 'orphan_report',
      data: {'n': 'old'},
    );
    // Push the old record beyond the cap: ~64KB of filler lines.
    for (var i = 0; i < 64; i++) {
      await session.appendMessage(UserMessage.text('filler$i ${'x' * 1000}'));
    }
    await session.appendCustomEntry(
      customType: 'orphan_report',
      data: {'n': 'new'},
    );
    final metadata = await session.getMetadata();

    // Explicit tiny cap: only the tail record survives.
    final tail = await repo.readCustomRecordsOfType(metadata, {
      'orphan_report',
    }, tailCapBytes: 32 * 1024);
    expect(tail.map((r) => (r.data as Map)['n']), ['new']);

    // Explicit unbounded: the whole file is scanned (deep-history
    // callers opt out of the cap).
    final all = await repo.readCustomRecordsOfType(metadata, {
      'orphan_report',
    }, tailCapBytes: null);
    expect(all.map((r) => (r.data as Map)['n']), ['old', 'new']);
  }, timeout: const Timeout(Duration(seconds: 60)));

  // THE sentinel regression test (review): under the old
  // `tailCapBytes ?? kSessionSegmentHardCapBytes` coalescing an explicit
  // null was indistinguishable from omitting the parameter — the
  // documented unbounded escape was a silent no-op that only ever bit on
  // files past the 95MB default (exactly the giant primaries the escape
  // exists for). This fixture is such a file: explicit null MUST see the
  // head record, the default (omitted) MUST NOT. Fails under the old
  // code, green under the non-null-default signature.
  test('a >95MB primary: the default cap scans the tail only, an explicit '
      'null is genuinely unbounded (sentinel regression)', () async {
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await session.appendCustomEntry(
      customType: 'orphan_report',
      data: {'n': 'head'},
    );
    final metadata = await session.getMetadata();

    // Grow the primary past the 95MB hard cap with blank filler lines
    // (each empty line fails the scanner's field-shaped gate and is
    // skipped; nothing accumulates), then append the tail record.
    final file = io.File(metadata.path);
    expect(await file.exists(), isTrue);
    final sink = file.openWrite(mode: io.FileMode.append);
    final blank = Uint8List.fromList(List.filled(1 << 20, 0x0A)); // 1MB of '\n'
    final fillerBlocks =
        (kSessionSegmentHardCapBytes ~/ (1 << 20)) + 2; // >95MB total
    for (var i = 0; i < fillerBlocks; i++) {
      sink.add(blank);
    }
    await sink.flush();
    await sink.close();
    // Assert BEFORE the tail append: the next appendCustomEntry sees a
    // >80MB primary and rotates (.part-01 + fresh primary) — the scan
    // covers the whole chain either way, but the primary itself is
    // small again after rotation.
    expect(
      await file.length(),
      greaterThan(kSessionSegmentHardCapBytes),
      reason: 'fixture must cross the default cap for the test to bite',
    );
    await session.appendCustomEntry(
      customType: 'orphan_report',
      data: {'n': 'tail'},
    );

    // Default (omitted): the tail region only — the head record is
    // beyond the 95MB window. This is the goal_builder guard itself.
    final defaultScan = await repo.readCustomRecordsOfType(metadata, {
      'orphan_report',
    });
    expect(defaultScan.map((r) => (r.data as Map)['n']), ['tail']);

    // Explicit null: unbounded — the head record is found. Under the
    // old coalescing null became the 95MB default and this FAILED.
    final unbounded = await repo.readCustomRecordsOfType(metadata, {
      'orphan_report',
    }, tailCapBytes: null);
    expect(unbounded.map((r) => (r.data as Map)['n']), ['head', 'tail']);
  }, timeout: const Timeout(Duration(seconds: 180)));
}
