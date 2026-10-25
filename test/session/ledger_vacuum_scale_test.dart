// Issue #1882 AC2 measured proof: the keep-latest vacuum on a synthetic
// 10,400-snapshot ledger fixture — file size before/after, every
// non-ledger record byte-verbatim, the LATEST snapshots preserved, the
// pre-vacuum bytes at `<path>.bak`, and the REAL open path still
// yielding the whole transcript (resume correctness).
//
// The fixture mirrors real append order: every record (messages AND
// registry snapshots) parents onto the previous leaf, so the parent
// chain runs THROUGH the dropped snapshots — the hardest shape vacuum
// must survive (the windowed open tolerates dangling parent ids).
import 'dart:convert';

import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_storage.dart';
import 'package:flutter_agent_harness/src/session_repair.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  const path = '/sessions/marathon.jsonl';

  setUp(() {
    fs = MemoryFileSystem(cwd: '/');
  });

  /// Builds the marathon fixture: [messageCount] chained user messages,
  /// a `shell_job_registry` snapshot after every message up to
  /// [jobSnapshots] total, and a `subagent_registry` snapshot every 50th
  /// message up to [subagentSnapshots] total. Returns the lines.
  List<String> buildFixture({
    int messageCount = 2000,
    int jobSnapshots = 10000,
    int subagentSnapshots = 200,
  }) {
    var jobs = 0;
    var subs = 0;
    String? prev;
    final lines = <String>[
      jsonEncode({
        'type': 'session',
        'version': 3,
        'id': 'marathon',
        'timestamp': '2026-09-03T00:00:00.000Z',
        'cwd': '/work',
      }),
    ];
    void addRecord(String id, Map<String, Object?> record) {
      lines.add(jsonEncode({...record, 'parentId': ?prev}));
      prev = id;
    }

    for (var i = 1; i <= messageCount; i++) {
      addRecord('m$i', {
        'type': 'message',
        'id': 'm$i',
        'timestamp': '2026-09-03T00:00:01.000Z',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'turn $i — ${'detail ' * 20}'},
          ],
        },
      });
      if (jobs < jobSnapshots) {
        // Real bursts append SEVERAL snapshots per turn (the persist
        // window coalesces, but each window flush is one snapshot) —
        // five per message reaches the 10k scale on 2k turns.
        for (var burst = 0; burst < 5 && jobs < jobSnapshots; burst++) {
          final id = 'j${++jobs}';
          // ~640 bytes of job rows: six rows of realistic shape.
          addRecord(id, {
            'type': 'custom',
            'id': id,
            'timestamp': '2026-09-03T00:00:02.000Z',
            'customType': 'shell_job_registry',
            'data': {
              'jobs': [
                for (var r = 0; r < 6; r++)
                  {
                    'id': 'job-$jobs-$r',
                    'kind': 'background-shell',
                    'status': 'completed',
                    'command': 'dart test test/suite_${jobs}_$r.dart',
                    'exitCode': 0,
                    'outputPreview': 'x' * 60,
                  },
              ],
            },
          });
        }
      }
      if (i % 10 == 0 && subs < subagentSnapshots) {
        final id = 's${++subs}';
        final summary = 'finding ' * 40;
        addRecord(id, {
          'type': 'custom',
          'id': id,
          'timestamp': '2026-09-03T00:00:03.000Z',
          'customType': 'subagent_registry',
          'data': {
            'children': [
              for (var r = 0; r < 4; r++)
                {
                  'id': 'explore-$subs-$r',
                  'name': 'explore',
                  'agentType': 'explore',
                  'status': 'completed',
                  'summary': summary,
                },
            ],
          },
        });
      }
    }
    return lines;
  }

  Map<String, dynamic> decode(String line) =>
      jsonDecode(line) as Map<String, dynamic>;

  group('ledger vacuum scale (issue #1882 AC2)', () {
    test(
      '10,400 snapshots: size collapses, records stay byte-verbatim, '
      'latest snapshots survive, the real open replays the transcript',
      () async {
        final lines = buildFixture();
        final bytesBeforeInput = lines.join('\n').length;
        await fs.writeFile(path, '${lines.join('\n')}\n');
        final stat = await fs.fileInfo(path);
        final bytesBefore = stat.valueOrNull!.size;

        // Dry run first: the projection must equal the applied outcome
        // (the gh-1590 contract) on this fixture too.
        final plan = await repairSessionLedgers(fs, path, dryRun: true);
        expect(plan.dryRun, isTrue);
        expect(plan.droppedByType['shell_job_registry'], 9999);
        expect(plan.droppedByType['subagent_registry'], 199);
        expect(plan.keptLatestByType['shell_job_registry'], 1);
        expect(plan.keptLatestByType['subagent_registry'], 1);

        final report = await repairSessionLedgers(fs, path);
        final bytesAfter = report.bytesAfter;
        expect(report.dryRun, isFalse);
        expect(report.droppedByType['shell_job_registry'], 9999);
        expect(report.droppedByType['subagent_registry'], 199);
        expect(report.keptLatestByType['shell_job_registry'], 1);
        expect(report.keptLatestByType['subagent_registry'], 1);
        // The measured collapse (printed for the PR body): ≥ 90% of the
        // file is superseded snapshots.
        // ignore: avoid_print
        print(
          'AC2 measured: $bytesBefore → $bytesAfter bytes '
          '(${(100 * (1 - bytesAfter / bytesBefore)).toStringAsFixed(1)}% '
          'reclaimed; fixture input ${bytesBeforeInput}B)',
        );
        expect(bytesAfter, lessThan(bytesBefore ~/ 5));
        expect(report.bytesAfter, plan.bytesAfter);

        // Byte-verbatim: the vacuumed file is EXACTLY the original minus
        // the dropped snapshot lines — every surviving line (header,
        // messages, latest snapshots) is byte-identical, in order.
        final healed = (await fs.readTextFile(path)).getOrThrow();
        final healedLines = healed.trim().split('\n');
        final droppedIds = {
          for (final line in lines)
            if (decode(line)['customType'] == 'shell_job_registry' &&
                decode(line)['id'] != 'j10000')
              decode(line)['id'] as String,
          for (final line in lines)
            if (decode(line)['customType'] == 'subagent_registry' &&
                decode(line)['id'] != 's200')
              decode(line)['id'] as String,
        };
        final expected = lines
            .where((line) => !droppedIds.contains(decode(line)['id']))
            .toList();
        expect(healedLines, expected);

        // The LATEST snapshots are present verbatim.
        expect(
          healed.contains(
            lines.firstWhere((line) => decode(line)['id'] == 'j10000'),
          ),
          isTrue,
        );
        expect(
          healed.contains(
            lines.firstWhere((line) => decode(line)['id'] == 's200'),
          ),
          isTrue,
        );

        // The pre-vacuum bytes live at `<path>.bak` (renamed, not copied).
        final backup = await fs.readTextFile('$path.bak');
        expect(backup.valueOrNull, '${lines.join('\n')}\n');

        // Resume correctness through the REAL open path: every surviving
        // record is reachable, in order — nothing orphaned away.
        final reopened = await JsonlSessionStorage.open(fs, path);
        final entries = await reopened.getEntries();
        expect(entries, hasLength(expected.length - 1));
        expect(entries.first.id, 'm1');
        expect(
          [for (final e in entries) e.id],
          containsAll(['m2000', 'j10000', 's200']),
          reason: 'the last message and both latest snapshots survive',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
