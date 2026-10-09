// Direct coverage for JsonlSessionRepo.readCustomRecordsOfType: the
// restart-time scan behind recovered steering (#437). The implementation
// streams the file in bounded blocks (issue #503 boot cost: the previous
// whole-file readTextLines cost ~2.7s on a 434MB marathon session); these
// tests pin behavior independent of the blocking.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('JsonlSessionRepo.readCustomRecordsOfType', () {
    late MemoryExecutionEnv env;
    late JsonlSessionRepo repo;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    });

    test('returns only custom records of the requested types', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('hello'));
      await session.appendCustomEntry(
        customType: 'steering',
        data: {'text': 'do this later'},
      );
      await session.appendCustomEntry(customType: 'other_type', data: {'x': 1});
      await session.appendMessage(UserMessage.text('world'));
      await session.appendCustomEntry(
        customType: 'steering',
        data: {'text': 'and this'},
      );

      final meta = (await repo.list(cwd: '/work')).single;
      final records = await repo.readCustomRecordsOfType(meta, {'steering'});

      expect(records, hasLength(2));
      expect(records.map((r) => (r.data as Map)['text']), [
        'do this later',
        'and this',
      ]);
    });

    test('substring gate does not leak types inside content', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      // A message whose TEXT mentions the type name must not surface:
      // the gate is a pre-filter, the parsed record decides.
      await session.appendMessage(UserMessage.text('mentions steering here'));
      final meta = (await repo.list(cwd: '/work')).single;
      final records = await repo.readCustomRecordsOfType(meta, {'steering'});
      expect(records, isEmpty);
    });

    test('a torn tail line is skipped', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendCustomEntry(
        customType: 'steering',
        data: {'text': 'good'},
      );
      final meta = (await repo.list(cwd: '/work')).single;
      // Simulate a crash mid-write: half a JSON line at EOF.
      await env.appendFile(meta.path, '{"type":"custom","customType":"steer');

      final records = await repo.readCustomRecordsOfType(meta, {'steering'});
      expect(records, hasLength(1));
      expect((records.single.data as Map)['text'], 'good');
    });

    test('missing file yields an empty list', () async {
      final meta = SessionMetadata(
        id: 'gone',
        path: '/sessions/nope.jsonl',
        cwd: '/work',
        createdAt: DateTime.now().toUtc(),
      );
      expect(await repo.readCustomRecordsOfType(meta, {'steering'}), isEmpty);
    });

    test(
      'block boundary inside a line still parses (streaming seam)',
      () async {
        // Force a line longer than any reasonable read block: the streaming
        // reader must carry the partial line across block boundaries.
        final session = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        await session.appendMessage(UserMessage.text('a' * 300000));
        await session.appendCustomEntry(
          customType: 'steering',
          data: {'text': 'after the giant line'},
        );
        final meta = (await repo.list(cwd: '/work')).single;
        final records = await repo.readCustomRecordsOfType(meta, {'steering'});
        expect(records, hasLength(1));
        expect((records.single.data as Map)['text'], 'after the giant line');
      },
    );

    test(
      'tiny blocks stress every seam: lines and gates spanning blocks',
      () async {
        final prev = JsonlSessionRepo.debugCustomRecordScanBlockBytes;
        JsonlSessionRepo.debugCustomRecordScanBlockBytes = 64;
        addTearDown(
          () => JsonlSessionRepo.debugCustomRecordScanBlockBytes = prev,
        );
        final session = await repo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        await session.appendMessage(UserMessage.text('first message'));
        await session.appendCustomEntry(
          customType: 'steering',
          data: {'text': 'one'},
        );
        await session.appendMessage(UserMessage.text('b' * 5000));
        await session.appendCustomEntry(
          customType: 'steering_consumed',
          data: {'id': 'x'},
        );
        await session.appendCustomEntry(
          customType: 'steering',
          data: {'text': 'two', 'payload': 'c' * 500}, // record itself spans
        );
        final meta = (await repo.list(cwd: '/work')).single;
        final records = await repo.readCustomRecordsOfType(meta, {
          'steering',
          'steering_consumed',
        });
        expect(records, hasLength(3));
        expect(records.where((r) => r.customType == 'steering'), hasLength(2));
        expect(
          records.where((r) => r.customType == 'steering_consumed'),
          hasLength(1),
        );
      },
    );

    test(
      'a record starting exactly at a block boundary is not skipped',
      () async {
        // Regression: when the previous block ends exactly on '\n', the
        // carry is empty and text[0..firstNl] is a COMPLETE record line —
        // scanning from firstNl + 1 silently dropped it. Blocks must be
        // larger than a record line, or the line always rides the carry
        // path and the hole never opens.
        const blockBytes = 4096;
        final prev = JsonlSessionRepo.debugCustomRecordScanBlockBytes;
        JsonlSessionRepo.debugCustomRecordScanBlockBytes = blockBytes;
        addTearDown(
          () => JsonlSessionRepo.debugCustomRecordScanBlockBytes = prev,
        );

        await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
        final meta = (await repo.list(cwd: '/work')).single;
        final steeringLine =
            '{"type":"custom","id":"r1",'
            '"timestamp":"2026-01-01T00:00:00.000Z",'
            '"customType":"steering","data":{"text":"aligned-at-boundary"}}\n';
        expect(
          steeringLine.length < blockBytes,
          isTrue,
          reason: 'the record line must fit inside one block',
        );
        // Pad with one inert filler line (never gate-matched, never
        // decoded — it just occupies bytes) ending exactly at offset
        // blockBytes, so the steering record STARTS on the boundary
        // (previous block ends on '\n', so the carry is empty).
        final head = await env.readTextFile(meta.path);
        final existing = head.valueOrNull ?? '';
        final padTarget = blockBytes - existing.length;
        final filler = '${'x' * (padTarget - 1)}\n';
        expect(filler.length, padTarget);
        await env.appendFile(meta.path, filler + steeringLine);
        expect(
          (await env.fileInfo(meta.path)).valueOrNull!.size % blockBytes,
          steeringLine.length,
          reason: 'the steering record must start exactly on a boundary',
        );

        final records = await repo.readCustomRecordsOfType(meta, {'steering'});
        expect(records, hasLength(1));
        expect((records.single.data as Map)['text'], 'aligned-at-boundary');
      },
    );

    test('scans the whole segment chain of a rotated session', () async {
      // gh-1077 review: registry snapshots flushed before a rotation
      // live in a `.part-NN` segment — a primary-only scan makes them
      // invisible to subagent adoption (#488), memory refresh and ttsr.
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendCustomEntry(
        customType: 'steering',
        data: {'text': 'before rotation'},
      );
      await session.appendCustomEntry(
        customType: 'steering',
        data: {'text': 'after rotation'},
      );
      final meta = (await repo.list(cwd: '/work')).single;
      // Simulate a rotation between the two records: header + first
      // record archived to the part, header + second stays primary.
      final content = (await env.readTextFile(meta.path)).getOrThrow();
      final lines = content.trim().split('\n');
      await env.writeFile(
        '${meta.path}.part-0001',
        '${lines[0]}\n${lines[1]}\n',
      );
      await env.writeFile(meta.path, '${lines[0]}\n${lines[2]}\n');

      final records = await repo.readCustomRecordsOfType(meta, {'steering'});
      expect(records.map((r) => (r.data as Map)['text']), [
        'before rotation',
        'after rotation',
      ]);
    });

    test('dedupes record ids repeated across segments', () async {
      // gh-1077 review round 5: between a failed rotation seed and the
      // next open, the archived part and the restored primary hold the
      // SAME records. The open path dedupes (seenRecordIds); the raw
      // scan must too, or a registry snapshot flushed just before the
      // rotation is returned twice.
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendCustomEntry(
        customType: 'steering',
        data: {'text': 'before rotation'},
      );
      await session.appendCustomEntry(
        customType: 'steering',
        data: {'text': 'after rotation'},
      );
      final meta = (await repo.list(cwd: '/work')).single;
      // Simulate the failed-seed window: the part is an exact copy of the
      // whole primary (both records), the primary holds both too.
      final content = (await env.readTextFile(meta.path)).getOrThrow();
      await env.writeFile('${meta.path}.part-0001', content);

      final records = await repo.readCustomRecordsOfType(meta, {'steering'});
      expect(records.map((r) => (r.data as Map)['text']), [
        'before rotation',
        'after rotation',
      ]);
    });

    test('orphan_report batches (gh-1449) round-trip append + scan', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('hello'));
      // Two reported batches (two separate repair passes), one other-type
      // record that must not leak in.
      await session.appendCustomEntry(
        customType: orphanReportRecordType,
        data: orphanReportRecordData({
          'bash|198|1767225600000',
          'task|toolu_9|1767225601000',
        }),
      );
      await session.appendCustomEntry(
        customType: 'steering',
        data: {'text': 'unrelated'},
      );
      await session.appendCustomEntry(
        customType: orphanReportRecordType,
        data: orphanReportRecordData({'read|ghost|1767225602000'}),
      );

      final meta = (await repo.list(cwd: '/work')).single;
      final restored = orphanReportKeysFromRecords(
        await repo.readCustomRecordsOfType(meta, {orphanReportRecordType}),
      );
      expect(restored, {
        'bash|198|1767225600000',
        'task|toolu_9|1767225601000',
        'read|ghost|1767225602000',
      });
    });
  });
}
