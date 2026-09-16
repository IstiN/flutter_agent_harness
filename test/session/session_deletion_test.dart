/// Issue #522 regression: session-file deletion is journaled, soft
/// (trash, never unlink), and refuses live sessions.
///
/// The gate lives in [JsonlSessionRepo] — every caller (CLI empty-cleanup,
/// app sidebar, manager close, the empty-session sweep) routes through
/// `delete` / `cleanupEmptySessions`, so a vanished session file always
/// leaves a named culprit in `<sessionsRoot>/session_ops.journal` and a
/// recoverable copy under `<sessionsRoot>/.trash/`.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryExecutionEnv fs;
  late JsonlSessionRepo repo;
  // Clock seam: the trash stamp and the journal `at` both come from this.
  var clock = DateTime.utc(2026, 9, 16, 21, 0, 0);

  setUp(() async {
    fs = MemoryExecutionEnv(cwd: '/');
    clock = DateTime.utc(2026, 9, 16, 21, 0, 0);
    repo = JsonlSessionRepo(
      fs: fs,
      sessionsRoot: '/sessions',
      processId: 4242,
      now: () => clock,
    );
  });

  Future<SessionMetadata> seedSession(String id, {String? extraLine}) async {
    final session = await repo.create(
      JsonlSessionCreateOptions(id: id, cwd: '/proj'),
    );
    if (extraLine != null) {
      final path = (await session.getMetadata()).path;
      await fs.appendFile(path, '$extraLine\n');
    }
    return session.getMetadata();
  }

  Future<List<Map<String, dynamic>>> journalLines() async {
    final raw = (await fs.readTextFile(
      '/sessions/session_ops.journal',
    )).valueOrNull!;
    return [
      for (final line in raw.split('\n'))
        if (line.trim().isNotEmpty)
          (jsonDecode(line) as Map).cast<String, dynamic>(),
    ];
  }

  group('deletion journal + trash (AC1, AC3)', () {
    test(
      'delete moves the file into .trash and journals the culprit',
      () async {
        final metadata = await seedSession('aaaaaaaaaaaaaaaaaaaaaaaaaaaa0001');
        await repo.delete(metadata, actor: 'test:delete');

        // The original path is empty and a trash copy exists.
        expect((await fs.exists(metadata.path)).valueOrNull, isFalse);
        final trash = (await fs.listDir('/sessions/.trash')).valueOrNull!;
        expect(trash, hasLength(1));
        expect(trash.single.name, contains(metadata.id));
        expect(
          (await fs.readTextFile(trash.single.path)).valueOrNull,
          isNotNull,
        );

        // The journal names who, what, when.
        final entry = (await journalLines()).single;
        expect(entry['op'], 'delete');
        expect(entry['session'], metadata.id);
        expect(entry['pid'], 4242);
        expect(entry['actor'], 'test:delete');
        expect(entry['result'], 'trash');
        expect(entry['path'], metadata.path);
        expect(entry['at'], clock.toIso8601String());
      },
    );

    test(
      'cleanupEmptySessions trashes and journals only empty files',
      () async {
        final empty = await seedSession('aaaaaaaaaaaaaaaaaaaaaaaaaaaa0002');
        final content = await seedSession(
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaa0003',
          extraLine: '{"record":"real"}',
        );

        final removed = await repo.cleanupEmptySessions();

        expect(removed, 1);
        expect((await fs.exists(empty.path)).valueOrNull, isFalse);
        expect((await fs.exists(content.path)).valueOrNull, isTrue);
        final entry = (await journalLines()).single;
        expect(entry['op'], 'cleanup-empty');
        expect(entry['result'], 'trash');
      },
    );

    test('.trash contents never surface in list()', () async {
      final metadata = await seedSession('aaaaaaaaaaaaaaaaaaaaaaaaaaaa0004');
      await repo.delete(metadata);
      expect(await repo.list(), isEmpty);
    });

    test('deleting a missing file is journaled, not thrown', () async {
      final metadata = await seedSession('aaaaaaaaaaaaaaaaaaaaaaaaaaaa0005');
      await repo.delete(metadata);
      await repo.delete(metadata); // already gone once
      expect((await journalLines()).last['result'], 'missing');
    });
    test('purgeTrash removes only entries older than the ttl', () async {
      // mtime-driven ttl: age a real entry past a tiny ttl — a 60ms wait
      // guarantees its mtime is strictly older than the 50ms cutoff.
      final realRepo = JsonlSessionRepo(
        fs: fs,
        sessionsRoot: '/sessions',
        processId: 4242,
      );
      final old = await seedSession('aaaaaaaaaaaaaaaaaaaaaaaaaaaa0006');
      await realRepo.delete(old);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await realRepo.purgeTrash(ttl: const Duration(milliseconds: 50));

      expect((await fs.listDir('/sessions/.trash')).valueOrNull, isEmpty);
      expect((await journalLines()).last['op'], 'purge');

      // A minutes-old entry survives a 30-day ttl.
      final fresh = await seedSession('aaaaaaaaaaaaaaaaaaaaaaaaaaaa0007');
      await realRepo.delete(fresh);
      await realRepo.purgeTrash(ttl: const Duration(days: 30));
      expect((await fs.listDir('/sessions/.trash')).valueOrNull, hasLength(1));
      expect(fresh.id, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaa0007');
    });
  });

  group('live-session guard (AC2)', () {
    late FileSessionPresenceStore presence;
    late JsonlSessionRepo guardedRepo;

    setUp(() {
      presence = FileSessionPresenceStore(
        env: fs,
        root: '/sessions',
        now: () => clock,
        staleAfter: const Duration(seconds: 15),
      );
      guardedRepo = JsonlSessionRepo(
        fs: fs,
        sessionsRoot: '/sessions',
        processId: 4242,
        presenceStore: presence,
        now: () => clock,
      );
    });

    test('a fresh foreign heartbeat refuses the delete by name', () async {
      final metadata = await seedSession('aaaaaaaaaaaaaaaaaaaaaaaaaaaa0008');
      await presence.register(metadata.id, pid: 9999);

      await expectLater(
        guardedRepo.delete(metadata, actor: 'test:guarded'),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.liveSession,
          ),
        ),
      );

      // Nothing was destroyed: the file is in place, no trash was created.
      expect((await fs.exists(metadata.path)).valueOrNull, isTrue);
      expect((await fs.exists('/sessions/.trash')).valueOrNull, isFalse);
    });

    test('an expired heartbeat deletes with a journal entry', () async {
      final metadata = await seedSession('aaaaaaaaaaaaaaaaaaaaaaaaaaaa0009');
      await presence.register(metadata.id, pid: 9999);
      clock = clock.add(const Duration(seconds: 30));

      await guardedRepo.delete(metadata, actor: 'test:guarded');

      expect((await fs.exists(metadata.path)).valueOrNull, isFalse);
      final entry = (await journalLines()).last;
      expect(entry['result'], 'trash');
      expect(entry['session'], metadata.id);
    });

    test('the owning pid may delete its own live session', () async {
      final metadata = await seedSession('aaaaaaaaaaaaaaaaaaaaaaaaaaaa001a');
      await presence.register(metadata.id, pid: 4242);

      await guardedRepo.delete(metadata, actor: 'test:self');

      expect((await fs.exists(metadata.path)).valueOrNull, isFalse);
    });

    test('cleanupEmptySessions skips a live header-only session', () async {
      final live = await seedSession('aaaaaaaaaaaaaaaaaaaaaaaaaaaa001b');
      await seedSession('aaaaaaaaaaaaaaaaaaaaaaaaaaaa001c'); // dead empty
      await presence.register(live.id, pid: 9999);

      final removed = await guardedRepo.cleanupEmptySessions();

      expect(removed, 1);
      expect((await fs.exists(live.path)).valueOrNull, isTrue);
    });
  });

  group('no raw unlink on session files (AC3 grep-test)', () {
    test('the gate is the only remove site in the session zones', () async {
      const zones = [
        'lib/src/session',
        'lib/src/cli',
        'flutter_app/lib/services',
        'flutter_app/lib/ui/widgets',
      ];
      // Files whose removals provably never touch session files:
      // - clipboard_reader: temp pasteboard images in the system temp dir
      // - sessions_root: a `.probe_<micros>` writability probe file
      const allowed = {
        'lib/src/cli/clipboard_reader.dart',
        'flutter_app/lib/services/sessions_root.dart',
      };
      final offenders = <String>[];
      for (final zone in zones) {
        final dir = Directory(zone);
        if (!dir.existsSync()) continue;
        for (final entity in dir.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          // session_repo.dart is the gate itself — the one allowed site.
          if (entity.path.endsWith('session_repo.dart')) continue;
          if (allowed.contains(entity.path)) continue;
          final text = entity.readAsStringSync();
          if (text.contains('_fs.remove(') ||
              text.contains('fs.remove(') ||
              text.contains('deleteSync(')) {
            offenders.add(entity.path);
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'session-file removal must route through the '
            'session_repo.dart gate (journal + trash + live guard)',
      );
    });
  });
}
