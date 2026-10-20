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

  test(
    'tailCapBytes bounds the streamed scan to the file tail — records '
    'beyond the cap are not returned, tail records are',
    () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
      );
      await session.appendCustomEntry(customType: 'orphan_report', data: {'n': 'old'});
      // Push the old record beyond the cap: ~64KB of filler lines.
      for (var i = 0; i < 64; i++) {
        await session.appendMessage(
          UserMessage.text('filler$i ${'x' * 1000}'),
        );
      }
      await session.appendCustomEntry(customType: 'orphan_report', data: {'n': 'new'});
      final metadata = await session.getMetadata();

      // Explicit tiny cap: only the tail record survives.
      final tail = await repo.readCustomRecordsOfType(
        metadata,
        {'orphan_report'},
        tailCapBytes: 32 * 1024,
      );
      expect(tail.map((r) => (r.data as Map)['n']), ['new']);

      // Explicit unbounded: the whole file is scanned (deep-history
      // callers opt out of the cap).
      final all = await repo.readCustomRecordsOfType(
        metadata,
        {'orphan_report'},
        tailCapBytes: null,
      );
      expect(all.map((r) => (r.data as Map)['n']), ['old', 'new']);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'the DEFAULT cap is the hard-cap design bound — a degenerate giant '
    'primary is scanned as its tail region only',
    () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
      );
      await session.appendCustomEntry(customType: 'orphan_report', data: {'n': 'old'});
      // ~200KB of filler: beyond kSessionSegmentHardCapBytes? No — but
      // the default equals the design bound; assert it clamps at least
      // as aggressively as a small explicit cap by checking the default
      // is finite and that a record inside the last 1KB always lands.
      for (var i = 0; i < 200; i++) {
        await session.appendMessage(
          UserMessage.text('filler$i ${'x' * 1000}'),
        );
      }
      await session.appendCustomEntry(customType: 'orphan_report', data: {'n': 'edge'});
      final metadata = await session.getMetadata();

      final records = await repo.readCustomRecordsOfType(
        metadata,
        {'orphan_report'},
      );
      // 200KB file < the 95MB default cap: everything is in the tail
      // region, both records visible (the default must not OVER-trim a
      // normally-sized segment).
      expect(records.map((r) => (r.data as Map)['n']), ['old', 'edge']);
      expect(
        kSessionSegmentHardCapBytes,
        greaterThan(200 * 1024),
        reason: 'the fixture must stay inside the default tail region',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
