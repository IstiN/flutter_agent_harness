/// gh-1746 — `SessionRetentionSweeper` core: usage walk, selection order,
/// exemptions, unit deletion, boot policy, and the REG-2 survival
/// property. Everything runs on `MemoryExecutionEnv` with an injected
/// clock — deterministic, no real filesystem.
@TestOn('vm')
library;

import 'dart:math';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/session_retention.dart';
import 'package:test/test.dart';

DateTime _clockNow = DateTime(2026, 1, 10, 12);

DateTime _clock() => _clockNow;

/// Backdated mtime helper: [age] days before the clock.
DateTime daysAgo(int age) => _clockNow.subtract(Duration(days: age));

void main() {
  late MemoryExecutionEnv env;
  late JsonlSessionRepo repo;
  late FileSessionPresenceStore presence;

  setUp(() {
    _clockNow = DateTime(2026, 1, 10, 12);
    env = MemoryExecutionEnv(cwd: '/work');
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    presence = FileSessionPresenceStore(env: env, root: '/sessions', now: _clock);
  });

  /// Seeds a session and returns its id; [sizeBytes] of transcript body
  /// rides a message so the file really carries the bytes.
  Future<String> seedSession({
    String? name,
    String cwd = '/work',
    DateTime? lastUsed,
    int sizeBytes = 0,
  }) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: cwd));
    if (sizeBytes > 0) {
      await session.appendMessage(UserMessage.text('x' * sizeBytes));
    }
    if (name != null) await session.appendSessionName(name);
    final metadata = await session.getMetadata();
    if (lastUsed != null) {
      env.setMtime(metadata.path, lastUsed.millisecondsSinceEpoch);
    }
    return metadata.id;
  }

  SessionRetentionSweeper sweeper({
    SessionRetentionConfig retention = const SessionRetentionConfig(),
    String? currentSessionId,
    void Function(String line)? log,
  }) => SessionRetentionSweeper(
    fs: env,
    sessionsRoot: '/sessions',
    retention: retention,
    presenceStore: presence,
    now: _clock,
    log: log,
    currentSessionId: currentSessionId,
  );

  group('usage walk', () {
    test('counts units: primaries, segments, sidecars, usage dirs', () async {
      final a = await seedSession(sizeBytes: 300, lastUsed: daysAgo(30));
      final b = await seedSession(sizeBytes: 500, lastUsed: daysAgo(40));
      // A rotated segment + corrupt sidecar for b (raw sibling files).
      final bMeta = (await repo.list()).firstWhere((m) => m.id == b);
      await env.writeFile('${bMeta.path}.part-0001', 'segment');
      await env.writeFile('${bMeta.path}.part-0001.corrupt', 'junk');
      // `.tools/<sid>.yaml` scope file for a.
      final aMeta = (await repo.list()).firstWhere((m) => m.id == a);
      final aDir = aMeta.path.substring(0, aMeta.path.lastIndexOf('/'));
      await env.writeFile('$aDir/.tools/$a.yaml', 'tools: {}');
      // Per-session usage directory (gh-1241 layout).
      await env.writeFile('/sessions/$a/usage.json', '{"v":1}');
      // Housekeeping that must NEVER count: trash + presence + a stray
      // non-jsonl file.
      await env.writeFile('/sessions/.trash/junk.jsonl', 'trash');
      await env.writeFile(
        '/sessions/.presence/$b.json',
        '{"startedAt":"","touchedAt":""}',
      );
      await env.writeFile('/sessions/--work--/notes.txt', 'not a session');

      final usage = await sweeper().usage();
      expect(usage.totalBytes, greaterThan(800 + 7 + 4 + 10 + 6));
      final aEntry = usage.sessions.firstWhere((s) => s.sessionId == a);
      final bEntry = usage.sessions.firstWhere((s) => s.sessionId == b);
      // a carries its tools yaml + usage dir on top of its file.
      expect(aEntry.bytes, greaterThan(bEntry.bytes - 500));
      expect(usage.sessions, hasLength(2));
    });

    test('spill bytes are measured but never counted toward the cap',
        () async {
      final a = await seedSession(sizeBytes: 100, lastUsed: daysAgo(30));
      await env.writeFile('/work/.fah/spills/$a/1.txt', 'spill body');

      final usage = await sweeper().usage();
      final entry = usage.sessions.single;
      expect(entry.spillBytes, 'spill body'.length);
      expect(entry.bytes, lessThan(entry.bytes + entry.spillBytes + 1));
      expect('$entry'.contains('spill'), isFalse);
      // totalBytes equals the sum of root-side unit bytes only.
      var sum = 0;
      for (final session in usage.sessions) {
        sum += session.bytes;
      }
      expect(usage.totalBytes, sum);
    });

    test('E3: an mtime older than the header falls back to the header time',
        () async {
      final a = await seedSession(sizeBytes: 10, lastUsed: null);
      final metadata = (await repo.list()).firstWhere((m) => m.id == a);
      // Backup tool touched the mtime backwards — before creation.
      env.setMtime(
        metadata.path,
        DateTime(2001).millisecondsSinceEpoch,
      );
      final usage = await sweeper().usage();
      expect(usage.sessions.single.lastUsedAt, usage.sessions.single.createdAt);
      expect(usage.sessions.single.lastUsedAt.year, greaterThan(2020));
    });
  });

  group('plan + apply (AC2/AC3/AC4)', () {
    test('AC2: total under the cap — no deletions, silent', () async {
      await seedSession(sizeBytes: 100, lastUsed: daysAgo(60));
      final report = await sweeper(
        retention: const SessionRetentionConfig(
          maxTotalBytes: 1 << 30,
          minAgeDays: 0,
        ),
      ).sweep(dryRun: false);
      expect(report.deletions, isEmpty);
      expect(report.applied, isFalse);
      expect(report.logLines, isEmpty);
      expect((await repo.list()), hasLength(1));
    });

    test('AC3: oldest-last-used deleted first until under the cap',
        () async {
      final oldest = await seedSession(sizeBytes: 100, lastUsed: daysAgo(60));
      final middle = await seedSession(sizeBytes: 100, lastUsed: daysAgo(30));
      await seedSession(sizeBytes: 100, lastUsed: daysAgo(1));
      final usage = await sweeper().usage();
      // A cap that forces out exactly the two oldest units.
      final cap = usage.totalBytes - 250;
      final report = await sweeper(
        retention: SessionRetentionConfig(maxTotalBytes: cap, minAgeDays: 0),
      ).sweep(dryRun: false);
      final deletedIds = report.deletions.map((d) => d.sessionId).toSet();
      expect(deletedIds, contains(oldest));
      expect(deletedIds, contains(middle));
      // Oldest really goes first.
      expect(report.deletions.first.sessionId, oldest);
      expect(report.remainingBytes, lessThanOrEqualTo(cap));
    });

    test('AC3: live, named, young and current sessions are exempt',
        () async {
      final live = await seedSession(sizeBytes: 100, lastUsed: daysAgo(60));
      final named = await seedSession(
        name: 'keepme',
        sizeBytes: 100,
        lastUsed: daysAgo(59),
      );
      final young = await seedSession(sizeBytes: 100, lastUsed: daysAgo(1));
      final current = await seedSession(sizeBytes: 100, lastUsed: daysAgo(58));
      await presence.register(live);
      final usage = await sweeper().usage();
      final report = await sweeper(
        retention: SessionRetentionConfig(
          maxTotalBytes: usage.totalBytes - 50,
          minAgeDays: 14,
        ),
        currentSessionId: current,
      ).sweep(dryRun: false);
      expect(report.deletions, isEmpty);
      expect(report.hasBlockerOverflow, isTrue);
      final reasons = {
        for (final blocker in report.blockers)
          blocker.sessionId: blocker.exemption,
      };
      expect(reasons[live], SessionRetentionExemption.live);
      expect(reasons[named], SessionRetentionExemption.named);
      expect(reasons[young], SessionRetentionExemption.tooYoung);
      expect(reasons[current], SessionRetentionExemption.current);
      expect((await repo.list()), hasLength(4));
    });

    test('keepNamed: false makes named sessions deletable', () async {
      final named = await seedSession(
        name: 'doomed',
        sizeBytes: 100,
        lastUsed: daysAgo(60),
      );
      final usage = await sweeper().usage();
      final report = await sweeper(
        retention: SessionRetentionConfig(
          maxTotalBytes: usage.totalBytes - 20,
          minAgeDays: 0,
          keepNamed: false,
        ),
      ).sweep(dryRun: false);
      expect(report.deletions.single.sessionId, named);
    });

    test('AC4: exempt-only overflow names each blocker with its size',
        () async {
      final a = await seedSession(sizeBytes: 100, lastUsed: daysAgo(60));
      final b = await seedSession(sizeBytes: 300, lastUsed: daysAgo(59));
      await presence.register(a);
      final usage = await sweeper().usage();
      final report = await sweeper(
        retention: SessionRetentionConfig(
          maxTotalBytes: usage.totalBytes - 10,
          minAgeDays: 14,
        ),
      ).sweep(dryRun: true);
      expect(report.deletions, isEmpty);
      expect(report.hasBlockerOverflow, isTrue);
      // The young 300B session blocks harder than the live 100B one —
      // blockers sort largest-first.
      expect(report.blockers.first.bytes, greaterThan(report.blockers.last.bytes));
      expect(report.blockers.map((bl) => bl.sessionId), containsAll([a, b]));
    });

    test('E1: a cap smaller than one marathon session still deletes it',
        () async {
      final marathon = await seedSession(sizeBytes: 5000, lastUsed: daysAgo(60));
      final report = await sweeper(
        retention: const SessionRetentionConfig(maxTotalBytes: 1, minAgeDays: 0),
      ).sweep(dryRun: false);
      expect(report.deletions.single.sessionId, marathon);
    });
  });

  group('apply deletes whole units (AC5) + logs (AC7)', () {
    test('sidecars die with the session; one log line per deletion',
        () async {
      final doomed = await seedSession(
        cwd: '/work',
        sizeBytes: 100,
        lastUsed: daysAgo(60),
      );
      final survivor = await seedSession(sizeBytes: 100, lastUsed: daysAgo(61));
      final doomedMeta = (await repo.list()).firstWhere(
        (m) => m.id == doomed,
      );
      await env.writeFile('${doomedMeta.path}.part-0001', 'segment');
      await env.writeFile('${doomedMeta.path}.corrupt', 'junk');
      final doomedDir = doomedMeta.path.substring(
        0,
        doomedMeta.path.lastIndexOf('/'),
      );
      await env.writeFile('$doomedDir/.tools/$doomed.yaml', 'tools: {}');
      await env.writeFile('/sessions/$doomed/usage.json', '{"v":1}');
      await env.writeFile('/work/.fah/spills/$doomed/1.txt', 'spill');
      await env.writeFile(
        '/work/.fah/spills/$survivor/1.txt',
        'keep me',
      );

      final usage = await sweeper().usage();
      final lines = <String>[];
      final report = await sweeper(
        retention: SessionRetentionConfig(
          maxTotalBytes: usage.totalBytes - 10,
          minAgeDays: 0,
        ),
        log: lines.add,
      ).sweep(dryRun: false);
      expect(report.deletions.single.sessionId, doomed);
      expect(report.applied, isTrue);
      expect((await env.exists(doomedMeta.path)).valueOrNull, isFalse);
      expect(
        (await env.exists('${doomedMeta.path}.part-0001')).valueOrNull,
        isFalse,
      );
      expect(
        (await env.exists('${doomedMeta.path}.corrupt')).valueOrNull,
        isFalse,
      );
      expect(
        (await env.exists('$doomedDir/.tools/$doomed.yaml')).valueOrNull,
        isFalse,
      );
      expect((await env.exists('/sessions/$doomed')).valueOrNull, isFalse);
      expect(
        (await env.exists('/work/.fah/spills/$doomed')).valueOrNull,
        isFalse,
      );
      // The survivor's unit and spills stay.
      expect(
        (await env.exists('/work/.fah/spills/$survivor')).valueOrNull,
        isTrue,
      );
      // AC7: exactly one deletion line, naming file + size + age + reason.
      expect(report.logLines, hasLength(1));
      expect(
        report.logLines.single,
        allOf(
          contains('retention: deleted '),
          contains(doomedMeta.path),
          contains('over-cap'),
        ),
      );
      expect(lines, report.logLines);
      // Freed bytes include the spill bytes.
      expect(report.freedBytes, greaterThan(report.rootFreedBytes));
    });

    test('E2: a session that becomes live mid-sweep is skipped', () async {
      final a = await seedSession(sizeBytes: 100, lastUsed: daysAgo(60));
      final b = await seedSession(sizeBytes: 100, lastUsed: daysAgo(59));
      final usage = await sweeper().usage();
      final report = await sweeper(
        retention: SessionRetentionConfig(
          maxTotalBytes: usage.totalBytes - 10,
          minAgeDays: 0,
        ),
      ).sweep(dryRun: false).then((report) async {
        // b became live while the plan ran (the apply loop re-checks).
        await presence.register(b);
        return report;
      });
      final deleted = report.deletions.map((d) => d.sessionId).toSet();
      expect(deleted, contains(a));
      expect(report.logLines.where((l) => l.contains('skipped')), isNotEmpty);
      expect((await repo.list()).map((m) => m.id), contains(b));
    });

    test('E6: the cap is global across slugs — oldest wins globally',
        () async {
      final oldOther = await seedSession(
        cwd: '/other',
        sizeBytes: 100,
        lastUsed: daysAgo(60),
      );
      await seedSession(cwd: '/work', sizeBytes: 100, lastUsed: daysAgo(1));
      final usage = await sweeper().usage();
      final report = await sweeper(
        retention: SessionRetentionConfig(
          maxTotalBytes: usage.totalBytes - 20,
          minAgeDays: 0,
        ),
      ).sweep(dryRun: false);
      expect(report.deletions.single.sessionId, oldOther);
    });
  });

  group('boot policy (E5 + posture B)', () {
    test('no cap: deletions never run; the soft warn fires past 5 GiB',
        () async {
      await seedSession(sizeBytes: 100, lastUsed: daysAgo(60));
      final quiet = await sweeper().enforceAtBoot();
      expect(quiet.capConfigured, isFalse);
      expect(quiet.overSoftWarn, isFalse);
      expect(quiet.deletions, isEmpty);

      final usage = await sweeper().usage();
      // Grow the root past the soft threshold without another session.
      await env.writeFile(
        '/sessions/--work--/filler.bin',
        'z' * (retentionSoftWarnBytes - usage.totalBytes + 1024),
      );
      final loud = await sweeper().enforceAtBoot();
      expect(loud.overSoftWarn, isTrue);
      expect(loud.deletions, isEmpty);
    });

    test('E5: cap set with sweep off — over-cap note, no deletions',
        () async {
      await seedSession(sizeBytes: 100, lastUsed: daysAgo(60));
      final usage = await sweeper().usage();
      final report = await sweeper(
        retention: SessionRetentionConfig(
          maxTotalBytes: usage.totalBytes - 10,
          sweep: SessionRetentionSweepMode.off,
        ),
      ).enforceAtBoot();
      expect(report.overCapSweepOff, isTrue);
      expect(report.deletions, isEmpty);
      expect((await repo.list()), hasLength(1));
      // The manual verb still enforces it.
      final manual = await sweeper(
        retention: SessionRetentionConfig(
          maxTotalBytes: usage.totalBytes - 10,
          sweep: SessionRetentionSweepMode.off,
        ),
      ).sweep(dryRun: false);
      expect(manual.deletions, hasLength(1));
    });
  });

  group('E4 path escape', () {
    test('a path-shaped session id is never a candidate', () async {
      // A file whose basename sid decodes to `..` — hostile shape.
      await env.writeFile(
        '/sessions/--work--/20260101_...jsonl',
        '{"type":"session","version":3,"id":"../evil",'
        '"timestamp":"2025-01-01T00:00:00.000Z","cwd":"/work"}\n',
      );
      final usage = await sweeper().usage();
      expect(usage.sessions, isEmpty);
      final report = await sweeper(
        retention: const SessionRetentionConfig(maxTotalBytes: 1, minAgeDays: 0),
      ).sweep(dryRun: false);
      expect(report.deletions, isEmpty);
      // Nothing outside the root was touched (the probe file survives).
      expect(
        (await env.exists('/sessions/--work--/20260101_...jsonl'))
            .valueOrNull,
        isTrue,
      );
    });
  });

  group('REG-2 survival property', () {
    test('named/live/young/current survive every sweep shape', () async {
      final random = Random(1746);
      for (var round = 0; round < 25; round++) {
        // Fresh root per round.
        env = MemoryExecutionEnv(cwd: '/work');
        repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
        presence = FileSessionPresenceStore(
          env: env,
          root: '/sessions',
          now: _clock,
        );
        final ids = <String, _Shape>{};
        for (var i = 0; i < 6; i++) {
          final shape = _Shape(
            name: random.nextBool() ? 'named-$i' : null,
            live: random.nextBool(),
            ageDays: random.nextInt(40),
            current: i == 0 && random.nextBool(),
          );
          final id = await seedSession(
            name: shape.name,
            lastUsed: daysAgo(shape.ageDays),
            sizeBytes: 50 + random.nextInt(400),
          );
          if (shape.live) await presence.register(id);
          ids[id] = shape;
        }
        String? currentId;
        for (final entry in ids.entries) {
          if (entry.value.current) currentId = entry.key;
        }
        final usage = await sweeper().usage();
        final cap = usage.totalBytes * random.nextInt(100) ~/ 100;
        final report = await sweeper(
          retention: SessionRetentionConfig(
            maxTotalBytes: cap,
            minAgeDays: 14,
          ),
          currentSessionId: currentId,
        ).sweep(dryRun: false);
        for (final deletion in report.deletions) {
          final shape = ids[deletion.sessionId]!;
          expect(
            shape.name != null,
            isFalse,
            reason: 'named session swept (round $round)',
          );
          expect(shape.live, isFalse, reason: 'live session swept');
          expect(shape.ageDays, greaterThanOrEqualTo(14),
              reason: 'young session swept');
          expect(deletion.sessionId, isNot(currentId));
        }
        // Under the cap afterwards, or honest blockers remain.
        if (report.remainingBytes > cap && cap > 0) {
          expect(report.hasBlockerOverflow, isTrue);
        }
      }
    });
  });

  group('report rendering', () {
    test('the dry-run plan prints the exact actions; apply matches',
        () async {
      final doomed = await seedSession(sizeBytes: 100, lastUsed: daysAgo(60));
      await seedSession(sizeBytes: 100, lastUsed: daysAgo(1));
      final usage = await sweeper().usage();
      final retention = SessionRetentionConfig(
        maxTotalBytes: usage.totalBytes - 10,
        minAgeDays: 0,
      );
      final plan = await sweeper(retention: retention).sweep(dryRun: true);
      final planLines = sessionSweepReportLines(plan);
      expect(planLines.any((l) => l.startsWith('sessions clean: dry run')),
          isTrue);
      expect(
        planLines.any((l) => l.contains('would delete') && l.contains(doomed)),
        isTrue,
      );
      expect((await repo.list()), hasLength(2));
      final applied = await sweeper(retention: retention).sweep(dryRun: false);
      final appliedLines = sessionSweepReportLines(applied);
      expect(
        appliedLines.any((l) => l.contains('deleted') && l.contains(doomed)),
        isTrue,
      );
      expect(
        appliedLines.any((l) => l.contains('freed:')),
        isTrue,
      );
    });

    test('formatRetentionBytes renders stable human units', () {
      expect(formatRetentionBytes(37), '37 B');
      expect(formatRetentionBytes(2048), '2 KB');
      expect(formatRetentionBytes(1536), '1.5 KB');
      expect(formatRetentionBytes(5 * 1024 * 1024 * 1024), '5 GB');
    });
  });
}

class _Shape {
  const _Shape({this.name, this.live = false, this.ageDays = 0, this.current = false});

  final String? name;
  final bool live;
  final int ageDays;
  final bool current;
}
