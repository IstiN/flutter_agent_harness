/// gh-1746 — `SessionRetentionSweeper` core: usage walk, selection order,
/// exemptions, unit deletion, boot policy, and the REG-2 survival
/// property. Everything runs on `MemoryExecutionEnv` with an injected
/// clock — deterministic, no real filesystem.
@TestOn('vm')
library;

import 'dart:math';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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
    presence = FileSessionPresenceStore(
      env: env,
      root: '/sessions',
      now: _clock,
    );
  });

  /// Seeds a session and returns its id; [sizeBytes] of transcript body
  /// rides a message so the file really carries the bytes. [createdAt]
  /// rewrites the header timestamp (the repo stamps real time at
  /// creation) so ages are deterministic against the fake clock;
  /// [lastUsed] backdates the mtime — always ≥ [createdAt] so the E3
  /// floor never masks the intended age.
  Future<String> seedSession({
    String? name,
    String cwd = '/work',
    DateTime? createdAt,
    DateTime? lastUsed,
    int sizeBytes = 0,
  }) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: cwd));
    if (sizeBytes > 0) {
      await session.appendMessage(UserMessage.text('x' * sizeBytes));
    }
    if (name != null) await session.appendSessionName(name);
    final metadata = await session.getMetadata();
    final effectiveCreated = createdAt ?? _clockNow;
    if (createdAt != null) {
      final raw = (await env.readTextFile(metadata.path)).valueOrNull!;
      await env.writeFile(
        metadata.path,
        raw.replaceFirst(
          RegExp(r'"timestamp":"[^"]+"'),
          '"timestamp":"${createdAt.toIso8601String()}"',
        ),
      );
    }
    env.setMtime(
      metadata.path,
      (lastUsed ?? effectiveCreated).millisecondsSinceEpoch,
    );
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

    test('spill bytes are measured but never counted toward the cap', () async {
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

    test(
      'E3: an mtime older than the header falls back to the header time',
      () async {
        final a = await seedSession(sizeBytes: 10, lastUsed: null);
        final metadata = (await repo.list()).firstWhere((m) => m.id == a);
        // Backup tool touched the mtime backwards — before creation.
        env.setMtime(metadata.path, DateTime(2001).millisecondsSinceEpoch);
        final usage = await sweeper().usage();
        expect(
          usage.sessions.single.lastUsedAt,
          usage.sessions.single.createdAt,
        );
        expect(usage.sessions.single.lastUsedAt.year, greaterThan(2020));
      },
    );

    test(
      'a header id that disagrees with the filename is unidentified',
      () async {
        // A foreign/planted header: the FILENAME sid keys the sweep unit;
        // a header claiming a different id must not make that unit
        // sweepable under the filename key (gh-1746 review).
        await env.writeFile(
          '/sessions/--work--/20260101_mismatch.jsonl',
          '{"type":"session","version":3,"id":"other-id",'
              '"timestamp":"2025-01-01T00:00:00.000Z","cwd":"/work"}\n',
        );
        env.setMtime(
          '/sessions/--work--/20260101_mismatch.jsonl',
          daysAgo(60).millisecondsSinceEpoch,
        );
        final usage = await sweeper().usage();
        expect(usage.sessions, isEmpty);
        final report = await sweeper(
          retention: const SessionRetentionConfig(
            maxTotalBytes: 1,
            minAgeDays: 0,
          ),
        ).sweep(dryRun: false);
        expect(report.deletions, isEmpty);
        expect(
          (await env.exists(
            '/sessions/--work--/20260101_mismatch.jsonl',
          )).valueOrNull,
          isTrue,
        );
      },
    );

    test('the shared filename parser and the repo agree on ids', () async {
      // One parser for the `<timestamp>_<sid>.jsonl` encoding (gh-1746
      // review): whatever the repo lists must equal what the retention
      // walk's shared helper decodes from the same paths — the two can
      // never drift.
      final a = await seedSession(sizeBytes: 10, lastUsed: daysAgo(5));
      final b = await seedSession(sizeBytes: 10, lastUsed: daysAgo(4));
      await env.writeFile('/sessions/--work--/notes.txt', 'not a session');
      final repoIds = (await repo.list()).map((m) => m.id).toSet();
      final walkPaths = (await sweeper().usage()).sessions
          .map((s) => s.path)
          .toSet();
      expect(
        {for (final path in walkPaths) sessionIdFromSessionPath(path)!},
        repoIds,
        reason: 'repo-listed ids and shared-helper-decoded ids must match',
      );
      expect(repoIds, containsAll([a, b]));
      // Null shapes: a non-jsonl file and a no-id basename decode to null.
      expect(sessionIdFromSessionPath('/sessions/--work--/notes.txt'), isNull);
      expect(sessionIdFromSessionPath('/x/20260101_.jsonl'), isNull);
      expect(sessionIdFromSessionPath('/x/plain.txt'), isNull);
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

    test('AC3: oldest-last-used deleted first until under the cap', () async {
      final oldest = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(60),
      );
      final middle = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(30),
      );
      await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(1),
      );
      final usage = await sweeper().usage();
      // A cap that forces out exactly the two oldest (equal-sized) units.
      final unit = usage.sessions.first.bytes;
      final cap = usage.totalBytes - unit * 2 + 1;
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

    test('AC3: live, named, young and current sessions are exempt', () async {
      final live = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(60),
      );
      final named = await seedSession(
        name: 'keepme',
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(59),
      );
      final young = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(1),
      );
      final current = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(58),
      );
      await presence.register(live);
      final report = await sweeper(
        retention: SessionRetentionConfig(
          // A cap of 1 makes the overflow need EVERY exempt unit — the
          // minimal-blocker note then names all four exemptions.
          maxTotalBytes: 1,
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

    test('AC4: the blocker note names only the sessions that explain the '
        'overflow, largest first', () async {
      // One giant LIVE session is the real blocker; several small young
      // sessions and one deletable old session pad the store. The note
      // must name the giant — not every exempt unit in the walk.
      final giant = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 900,
        lastUsed: daysAgo(0),
      );
      for (var i = 0; i < 3; i++) {
        await seedSession(
          createdAt: daysAgo(90),
          sizeBytes: 10,
          lastUsed: daysAgo(1),
        );
      }
      final deletable = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(80),
      );
      await presence.register(giant);
      final usage = await sweeper().usage();
      // A cap 400 B below the total: only the small old unit is deletable
      // (minAgeDays 14 shields the young pads; the giant is live), and the
      // 16-ish-byte overflow it leaves is far below the giant's unit.
      final cap = usage.totalBytes - 400;
      final report = await sweeper(
        retention: SessionRetentionConfig(maxTotalBytes: cap, minAgeDays: 14),
      ).sweep(dryRun: false);
      // The small old unit was deleted; the root is still over the cap.
      expect(report.deletions.map((d) => d.sessionId), [deletable]);
      expect(report.hasBlockerOverflow, isTrue);
      // Only the giant is NEEDED to explain the overflow: its bytes alone
      // exceed the overflow, so the smaller young pads stay unnamed.
      expect(report.blockers, hasLength(1));
      expect(report.blockers.single.sessionId, giant);
      expect(report.blockers.single.exemption, SessionRetentionExemption.live);
    });

    test('keepNamed: false makes named sessions deletable', () async {
      final named = await seedSession(
        name: 'doomed',
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(60),
      );
      final usage = await sweeper().usage();
      final report = await sweeper(
        retention: SessionRetentionConfig(
          maxTotalBytes: usage.totalBytes - 1,
          minAgeDays: 0,
          keepNamed: false,
        ),
      ).sweep(dryRun: false);
      expect(report.deletions.single.sessionId, named);
    });

    test(
      'AC4: exempt-only overflow names each blocker with its size',
      () async {
        final a = await seedSession(
          createdAt: daysAgo(90),
          sizeBytes: 100,
          lastUsed: daysAgo(60),
        );
        final b = await seedSession(
          createdAt: daysAgo(90),
          sizeBytes: 300,
          lastUsed: daysAgo(1),
        );
        await presence.register(a);
        final report = await sweeper(
          retention: const SessionRetentionConfig(
            // A cap of 1: the overflow (total − 1) needs BOTH exempt units
            // to explain — the minimal-blocker note then names each.
            maxTotalBytes: 1,
            minAgeDays: 14,
          ),
        ).sweep(dryRun: true);
        expect(report.deletions, isEmpty);
        expect(report.hasBlockerOverflow, isTrue);
        // The young 300B session blocks harder than the live 100B one —
        // blockers sort largest-first.
        expect(
          report.blockers.first.bytes,
          greaterThan(report.blockers.last.bytes),
        );
        expect(report.blockers.map((bl) => bl.sessionId), containsAll([a, b]));
      },
    );

    test(
      'E1: a cap smaller than one marathon session still deletes it',
      () async {
        final marathon = await seedSession(
          createdAt: daysAgo(90),
          sizeBytes: 5000,
          lastUsed: daysAgo(60),
        );
        final report = await sweeper(
          retention: const SessionRetentionConfig(
            maxTotalBytes: 1,
            minAgeDays: 0,
          ),
        ).sweep(dryRun: false);
        expect(report.deletions.single.sessionId, marathon);
      },
    );
  });

  group('apply deletes whole units (AC5) + logs (AC7)', () {
    test('sidecars die with the session; one log line per deletion', () async {
      final doomed = await seedSession(
        cwd: '/work',
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(60),
      );
      final survivor = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(2),
      );
      final doomedMeta = (await repo.list()).firstWhere((m) => m.id == doomed);
      await env.writeFile('${doomedMeta.path}.part-0001', 'segment');
      await env.writeFile('${doomedMeta.path}.corrupt', 'junk');
      final doomedDir = doomedMeta.path.substring(
        0,
        doomedMeta.path.lastIndexOf('/'),
      );
      await env.writeFile('$doomedDir/.tools/$doomed.yaml', 'tools: {}');
      await env.writeFile('/sessions/$doomed/usage.json', '{"v":1}');
      await env.writeFile('/work/.fah/spills/$doomed/1.txt', 'spill');
      await env.writeFile('/work/.fah/spills/$survivor/1.txt', 'keep me');

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
      final a = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(60),
      );
      final b = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(59),
      );
      await presence.register(b); // b owns a real heartbeat row...
      final usage = await sweeper().usage();
      final unit = usage.sessions.first.bytes;
      // Flipping presence: the plan and a's unlink see b absent; the
      // check immediately before b's unlink sees it live.
      var listCalls = 0;
      late SessionRetentionSweeper flippingSweeper;
      final flippingPresence = _FlippingPresence(
        delegate: presence,
        lateLiveId: b,
        liveFromCall: 3,
        onCall: () => listCalls++,
      );
      flippingSweeper = SessionRetentionSweeper(
        fs: env,
        sessionsRoot: '/sessions',
        retention: SessionRetentionConfig(
          maxTotalBytes: usage.totalBytes - unit * 2 + 1,
          minAgeDays: 0,
        ),
        presenceStore: flippingPresence,
        now: _clock,
        currentSessionId: null,
      );
      final report = await flippingSweeper.sweep(dryRun: false);
      final deleted = report.deletions.map((d) => d.sessionId).toSet();
      expect(deleted, contains(a));
      expect(report.logLines.where((l) => l.contains('skipped')), isNotEmpty);
      expect((await repo.list()).map((m) => m.id), contains(b));
    });

    test('E6: the cap is global across slugs — oldest wins globally', () async {
      final oldOther = await seedSession(
        cwd: '/other',
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(60),
      );
      await seedSession(
        cwd: '/work',
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(1),
      );
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
    test(
      'no cap: deletions never run; the soft warn fires past the seam',
      () async {
        await seedSession(
          createdAt: daysAgo(90),
          sizeBytes: 100,
          lastUsed: daysAgo(60),
        );
        final quiet = await sweeper().enforceAtBoot();
        expect(quiet.capConfigured, isFalse);
        expect(quiet.overSoftWarn, isFalse);
        expect(quiet.deletions, isEmpty);

        final usage = await sweeper().usage();
        final loud = await SessionRetentionSweeper(
          fs: env,
          sessionsRoot: '/sessions',
          presenceStore: presence,
          now: _clock,
          softWarnBytes: usage.totalBytes - 1,
        ).enforceAtBoot();
        expect(loud.capConfigured, isFalse);
        expect(loud.overSoftWarn, isTrue);
        expect(loud.deletions, isEmpty);
      },
    );

    test('E5: cap set with sweep off — over-cap note, no deletions', () async {
      await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(60),
      );
      final usage = await sweeper().usage();
      final retention = SessionRetentionConfig(
        maxTotalBytes: usage.totalBytes - 1,
        sweep: SessionRetentionSweepMode.off,
      );
      final report = await sweeper(retention: retention).enforceAtBoot();
      expect(report.overCapSweepOff, isTrue);
      expect(report.deletions, isEmpty);
      expect((await repo.list()), hasLength(1));
      // The manual verb still enforces it.
      final manual = await sweeper(retention: retention).sweep(dryRun: false);
      expect(manual.deletions, hasLength(1));
    });
  });

  group('fail-closed presence (gh-1746 review)', () {
    test('a missing presence store aborts the sweep like a failed probe — '
        'live sessions survive', () async {
      final live = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 700,
        lastUsed: daysAgo(60),
      );
      await presence.register(live);
      final dead = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 300,
        lastUsed: daysAgo(60),
      );

      // No `presenceStore` — the shape under review. The default must
      // FAIL CLOSED: an embedder host that forgot to wire presence must
      // never sweep live sessions while believing none are live.
      final report = await SessionRetentionSweeper(
        fs: env,
        sessionsRoot: '/sessions',
        retention: const SessionRetentionConfig(
          maxTotalBytes: 1,
          minAgeDays: 0,
        ),
        now: _clock,
      ).enforceAtBoot();

      expect(report.deletions, isEmpty);
      expect(report.applied, isFalse);
      expect(
        report.notes,
        contains('retention: presence store missing — sweep aborted'),
      );
      // Both units — the live one AND the deletable one — are untouched:
      // the whole sweep aborted, nothing was risked.
      final survivors = (await repo.list()).map((m) => m.id).toSet();
      expect(survivors, containsAll([live, dead]));
    });

    test(
      'the dry-run plan aborts too — no phantom plan without presence',
      () async {
        await seedSession(
          createdAt: daysAgo(90),
          sizeBytes: 300,
          lastUsed: daysAgo(60),
        );
        final report = await SessionRetentionSweeper(
          fs: env,
          sessionsRoot: '/sessions',
          retention: const SessionRetentionConfig(
            maxTotalBytes: 1,
            minAgeDays: 0,
          ),
          now: _clock,
        ).sweep(dryRun: true);
        expect(report.deletions, isEmpty);
        expect(
          report.notes,
          contains('retention: presence store missing — sweep aborted'),
        );
      },
    );

    test('allowMissingPresence: true opts back into the test-only shape — '
        'null reads as "nothing is live"', () async {
      final live = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 700,
        lastUsed: daysAgo(60),
      );
      await presence.register(live);
      final sweeper = SessionRetentionSweeper(
        fs: env,
        sessionsRoot: '/sessions',
        retention: const SessionRetentionConfig(
          maxTotalBytes: 1,
          minAgeDays: 0,
        ),
        now: _clock,
        allowMissingPresence: true,
      );
      final report = await sweeper.sweep(dryRun: false);
      // The explicit opt-in sweeps as if nothing were live: the live
      // session is NOT protected (that is the documented convenience —
      // and exactly why it must stay opt-in).
      expect(report.deletions.map((a) => a.sessionId), contains(live));
      expect(report.applied, isTrue);
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
        retention: const SessionRetentionConfig(
          maxTotalBytes: 1,
          minAgeDays: 0,
        ),
      ).sweep(dryRun: false);
      expect(report.deletions, isEmpty);
      // Nothing outside the root was touched (the probe file survives).
      expect(
        (await env.exists('/sessions/--work--/20260101_...jsonl')).valueOrNull,
        isTrue,
      );
    });

    test('a RELATIVE header cwd is never measured or deleted (spill '
        'traversal)', () async {
      // A planted/corrupted header whose cwd is relative: interpolating it
      // into the spill path would measure/delete OUTSIDE any root.
      const planted = '/sessions/--work--/20260101_relative.jsonl';
      await env.writeFile(
        planted,
        '{"type":"session","version":3,"id":"relative",'
        '"timestamp":"2025-01-01T00:00:00.000Z","cwd":"../../etc"}\n',
      );
      env.setMtime(planted, daysAgo(60).millisecondsSinceEpoch);
      await env.writeFile(
        '/work/etc/.fah/spills/relative/secret.txt',
        'precious',
      );
      final usage = await sweeper().usage();
      expect(usage.sessions, isEmpty);
      final report = await sweeper(
        retention: const SessionRetentionConfig(
          maxTotalBytes: 1,
          minAgeDays: 0,
        ),
      ).sweep(dryRun: false);
      expect(report.deletions, isEmpty);
      // The outside tree survives untouched.
      expect(
        (await env.readTextFile(
          '/work/etc/.fah/spills/relative/secret.txt',
        )).valueOrNull,
        'precious',
      );
      // The walk explains the skip.
      expect(
        usage.notes.any((n) => n.contains('cwd')),
        isTrue,
        reason:
            'the unsafe header cwd is reported, not silent: '
            '${usage.notes}',
      );
    });

    test(
      'an ABSOLUTE cwd with a `..` segment is never measured or deleted',
      () async {
        const planted = '/sessions/--work--/20260101_dotdot.jsonl';
        await env.writeFile(
          planted,
          '{"type":"session","version":3,"id":"dotdot",'
          '"timestamp":"2025-01-01T00:00:00.000Z","cwd":"/work/../evil"}\n',
        );
        env.setMtime(planted, daysAgo(60).millisecondsSinceEpoch);
        await env.writeFile('/evil/.fah/spills/dotdot/secret.txt', 'precious');
        final usage = await sweeper().usage();
        // Fail closed: an unsafe header cwd disqualifies the unit entirely
        // (no measurement, no deletion decision can rest on it).
        expect(usage.sessions, isEmpty);
        final report = await sweeper(
          retention: const SessionRetentionConfig(
            maxTotalBytes: 1,
            minAgeDays: 0,
          ),
        ).sweep(dryRun: false);
        expect(report.deletions, isEmpty);
        expect(
          (await env.readTextFile(
            '/evil/.fah/spills/dotdot/secret.txt',
          )).valueOrNull,
          'precious',
        );
        expect(
          usage.notes.any((n) => n.contains('cwd')),
          isTrue,
          reason:
              'the unsafe header cwd is reported, not silent: '
              '${usage.notes}',
        );
      },
    );

    test('a safe absolute cwd still sweeps normally (the guard does not '
        'over-block)', () async {
      final doomed = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(60),
      );
      await env.writeFile('/work/.fah/spills/$doomed/1.txt', 'spill body');
      final report = await sweeper(
        retention: const SessionRetentionConfig(
          maxTotalBytes: 1,
          minAgeDays: 0,
        ),
      ).sweep(dryRun: false);
      expect(report.deletions.map((d) => d.sessionId), contains(doomed));
      expect(report.spillFreedBytes, 'spill body'.length);
      expect(
        (await env.exists('/work/.fah/spills/$doomed/1.txt')).valueOrNull,
        isFalse,
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
            createdAt: daysAgo(shape.ageDays + 30),
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
          retention: SessionRetentionConfig(maxTotalBytes: cap, minAgeDays: 14),
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
          expect(
            shape.ageDays,
            greaterThanOrEqualTo(14),
            reason: 'young session swept',
          );
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
    test('the dry-run plan prints the exact actions; apply matches', () async {
      final doomed = await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(60),
      );
      await seedSession(
        createdAt: daysAgo(90),
        sizeBytes: 100,
        lastUsed: daysAgo(1),
      );
      final usage = await sweeper().usage();
      final retention = SessionRetentionConfig(
        maxTotalBytes: usage.totalBytes - 10,
        minAgeDays: 0,
      );
      final plan = await sweeper(retention: retention).sweep(dryRun: true);
      final planLines = sessionSweepReportLines(plan);
      expect(
        planLines.any((l) => l.startsWith('sessions clean: dry run')),
        isTrue,
      );
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
      expect(appliedLines.any((l) => l.contains('freed:')), isTrue);
    });

    test('formatRetentionBytes renders stable human units', () {
      expect(formatRetentionBytes(37), '37 B');
      expect(formatRetentionBytes(2048), '2 KB');
      expect(formatRetentionBytes(1536), '1.5 KB');
      expect(formatRetentionBytes(5 * 1024 * 1024 * 1024), '5 GB');
    });

    test('the /sessions usage footer renders only under a cap', () {
      const noCap = SessionRetentionConfig();
      const capped = SessionRetentionConfig(maxTotalBytes: 5 << 30);
      final when = DateTime(2026, 1, 10);
      final usage = SessionUsageSnapshot(
        sessions: [
          SessionDiskUsage(
            sessionId: 'a',
            path: '/sessions/--w--/1_a.jsonl',
            bytes: 2048,
            createdAt: when,
            lastUsedAt: when,
          ),
        ],
        totalBytes: 2048,
      );
      // REG-1: no cap → NO footer line (byte-identical legacy listing).
      expect(sessionUsageFooterLine(usage, noCap), isNull);
      expect(
        sessionUsageFooterLine(usage, capped),
        'total: 2 KB across 1 sessions · cap: 5 GB',
      );
    });
  });
}

/// Presence whose liveness view flips after N `list()` calls — models a
/// session that becomes live DURING the apply loop (E2).
final class _FlippingPresence implements SessionPresenceStore {
  _FlippingPresence({
    required this.delegate,
    required this.lateLiveId,
    required this.liveFromCall,
    this.onCall,
  });

  final SessionPresenceStore delegate;

  /// The id that turns live late.
  final String lateLiveId;
  final int liveFromCall;
  final void Function()? onCall;
  int _calls = 0;

  @override
  Future<void> register(String sessionId, {int? pid, String? host}) =>
      delegate.register(sessionId, pid: pid, host: host);

  @override
  Future<void> touch(String sessionId) => delegate.touch(sessionId);

  @override
  Future<void> unregister(String sessionId) => delegate.unregister(sessionId);

  @override
  Future<Map<String, SessionPresence>> list() async {
    final all = await delegate.list();
    final call = _calls++;
    onCall?.call();
    if (call >= liveFromCall - 1) return all;
    return {
      for (final entry in all.entries)
        if (entry.key != lateLiveId) entry.key: entry.value,
    };
  }
}

class _Shape {
  const _Shape({
    this.name,
    this.live = false,
    this.ageDays = 0,
    this.current = false,
  });

  final String? name;
  final bool live;
  final int ageDays;
  final bool current;
}
