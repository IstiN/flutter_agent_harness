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
  });
}
