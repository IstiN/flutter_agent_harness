import 'dart:convert';

import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/session_repair.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  const path = '/sessions/bloated.jsonl';

  setUp(() {
    fs = MemoryFileSystem(cwd: '/');
  });

  Future<void> writeSession(List<String> lines) =>
      fs.writeFile(path, '${lines.join('\n')}\n');

  String header() => jsonEncode({
    'type': 'session',
    'version': 3,
    'id': 'bloat',
    'timestamp': '2026-09-07T00:00:00.000Z',
    'cwd': '/work',
  });

  String message(String id, {String? parentId, String text = 'hi'}) =>
      jsonEncode({
        'type': 'message',
        'id': id,
        if (parentId != null) 'parentId': parentId,
        'timestamp': '2026-09-07T00:00:01.000Z',
        'message': {'role': 'user', 'content': text},
      });

  String custom(
    String id, {
    required String customType,
    Object? data = const {'n': 1},
    String? parentId,
  }) => jsonEncode({
    'type': 'custom',
    'id': id,
    if (parentId != null) 'parentId': parentId,
    'timestamp': '2026-09-07T00:00:02.000Z',
    'customType': customType,
    'data': data,
  });

  group('repairSessionLedgers (gh-1073)', () {
    test('drops ledger customs, keeps the latest snapshot per superseding '
        'type, keeps messages and custom_message', () async {
      await writeSession([
        header(),
        message('m1'),
        custom('c1', customType: 'model_request_summary', data: {'x': 'p' * 1000}),
        custom('c2', customType: 'model_request_summary', data: {'y': 'p' * 1000}),
        custom('j1', customType: 'shell_job_registry', data: {'gen': 1}),
        custom('j2', customType: 'shell_job_registry', data: {'gen': 2}),
        custom('j3', customType: 'shell_job_registry', data: {'gen': 3}),
        custom('s1', customType: 'subagent_registry', data: {'gen': 1}),
        custom('s2', customType: 'subagent_registry', data: {'gen': 2}),
        custom(
          'cm1',
          customType: 'custom_message',
          data: null,
        ),
        message('m2', parentId: 'm1'),
      ]);
      final report = await repairSessionLedgers(fs, path);
      expect(report.droppedByType['model_request_summary'], 2);
      expect(report.droppedByType['shell_job_registry'], 2,
          reason: 'superseded snapshots drop, the latest is kept');
      expect(report.keptLatestByType['shell_job_registry'], 1);
      expect(report.keptLatestByType['subagent_registry'], 1);
      final healed = (await fs.readTextFile(path)).getOrThrow();
      final ids = [
        for (final line in healed.trim().split('\n'))
          (jsonDecode(line) as Map)['id'],
      ];
      // Header + messages + the LATEST registry snapshots + the
      // custom_message. The custom_message is a CustomRecord whose type
      // is NOT a ledger type: kept (it projects into context).
      expect(ids, ['bloat', 'm1', 'j3', 's2', 'cm1', 'm2']);
      expect(report.recordsRead, 10);
      expect(report.bytesAfter, lessThan(report.bytesBefore));
      // The original is preserved as a backup.
      final backup = (await fs.readTextFile('$path.bak')).getOrThrow();
      expect(backup, contains('"customType":"model_request_summary"'));
    });

    test('a second repair rotates the previous backup instead of '
        'overwriting it', () async {
      await writeSession([
        header(),
        message('m1'),
        custom('c1', customType: 'model_request_summary'),
      ]);
      await repairSessionLedgers(fs, path);
      final firstRepair = (await fs.readTextFile(path)).getOrThrow();
      // A new ledger record lands; the user repairs again (exactly the
      // twice-run shape: dry-run, then real, then again after a mistake).
      await fs.appendFile(
        path,
        '${custom('c2', customType: 'model_request_summary')}\n',
      );
      final beforeSecondRepair = (await fs.readTextFile(path)).getOrThrow();
      await repairSessionLedgers(fs, path);
      // The newest backup is the pre-second-repair file…
      expect(
        (await fs.readTextFile('$path.bak')).getOrThrow(),
        beforeSecondRepair,
      );
      // …and the first repair's input — the pristine original — survives
      // at .bak1 instead of being silently replaced.
      final pristine = (await fs.readTextFile('$path.bak1')).getOrThrow();
      expect(pristine, contains('"id":"c1"'));
      expect(pristine, isNot(contains('"id":"c2"')));
      expect(firstRepair, isNot(contains('"id":"c1"')));
    });

    test('dry-run counts without touching the file', () async {
      await writeSession([
        header(),
        message('m1'),
        custom('c1', customType: 'model_request_summary'),
      ]);
      final before = (await fs.readTextFile(path)).getOrThrow();
      final report = await repairSessionLedgers(fs, path, dryRun: true);
      expect(report.droppedByType['model_request_summary'], 1);
      expect((await fs.readTextFile(path)).getOrThrow(), before);
      expect((await fs.exists('$path.bak')).getOrThrow(), isFalse);
    });

    test('a missing file fails with notFound', () async {
      await expectLater(
        repairSessionLedgers(fs, '/sessions/nope.jsonl'),
        throwsA(
          isA<SessionRepairException>().having(
            (e) => e.code,
            'code',
            SessionRepairErrorCode.notFound,
          ),
        ),
      );
    });

    test('an unknown custom type is kept (conservative by default)', () async {
      await writeSession([
        header(),
        custom('u1', customType: 'plugin_widget'),
      ]);
      await repairSessionLedgers(fs, path);
      final healed = (await fs.readTextFile(path)).getOrThrow();
      expect(healed, contains('plugin_widget'));
    });

    test('a line that cannot be sniffed is kept verbatim', () async {
      await writeSession([
        header(),
        message('m1'),
        '{"type":"message","id":"to', // torn tail — repair never deletes
      ]);
      await repairSessionLedgers(fs, path);
      final healed = (await fs.readTextFile(path)).getOrThrow();
      expect(healed, contains('"to'));
    });
  });
}
