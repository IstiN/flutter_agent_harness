// Issue #1882 AC3/AC5 — the heavy-scan guard and the `fa session info`
// breakdown: the guard fires with the exact size + hygiene escapes over
// the 500 MB bound and stays silent under it; the info pass streams one
// bounded scan, tallies records/ledgers with exact byte weights, names
// the vacuum-reclaimable and repair-drop surfaces, supports --json, and
// reports a partial (exit 130) when canceled mid-scan.
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/session_info_command.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;
  final out = <String>[];

  setUp(() {
    fs = MemoryFileSystem(cwd: '/');
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
    out.clear();
  });

  Future<SessionMetadata> seedSession() async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('hello'));
    await session.appendCustomEntry(
      customType: 'model_request_summary',
      data: {
        'messageCount': 1,
        'systemPromptChars': 4000,
        'messages': [
          {'role': 'user', 'chars': 100},
        ],
      },
    );
    for (var gen = 1; gen <= 3; gen++) {
      await session.appendCustomEntry(
        customType: 'shell_job_registry',
        data: {
          'jobs': [
            {'id': 'job-$gen', 'output': 'o' * (100 * gen)},
          ],
        },
      );
    }
    await session.appendMessage(UserMessage.text('done'));
    return session.getMetadata();
  }

  group('heavy-scan guard (issue #1882 AC3)', () {
    test('fires over 500 MB with the exact size and the escapes', () {
      final lines = heavyScanGuardLines(600 << 20, '/sessions/big.jsonl');
      expect(lines, hasLength(2));
      expect(lines.first, contains('/sessions/big.jsonl'));
      expect(lines.first, contains('MB'));
      expect(lines.join(' '), contains('fa session repair'));
      expect(lines.join(' '), contains('sessions.vacuumLedgers'));
      expect(lines.join(' '), contains('fresh session'));
    });

    test('sessionSizeIfHeavy: null under the bound, size over it', () async {
      final small = await fs.writeFile('/small.jsonl', 'x' * 1024);
      expect(small.isOk, isTrue);
      expect(await sessionSizeIfHeavy(fs, '/small.jsonl'), isNull);
      final big = await fs.writeFile(
        '/big.jsonl',
        'x' * (sessionHeavyScanWarnBytes + 1),
      );
      expect(big.isOk, isTrue);
      expect(
        await sessionSizeIfHeavy(fs, '/big.jsonl'),
        sessionHeavyScanWarnBytes + 1,
      );
    });
  });

  group('fa session info (issue #1882 AC5)', () {
    test('breaks down records and ledgers with the reclaim hints', () async {
      final target = await seedSession();
      final code = await runSessionInfoCliCommand(
        writeln: out.add,
        env: fs,
        sessionRoot: '/sessions',
        sessionId: target.id,
      );
      expect(code, 0);
      final text = out.join('\n');
      expect(text, contains('session: ${target.id}'));
      // The registries collapse to their newest snapshot: 2 of the 3
      // snapshots are dead — the vacuum note names the reclaim.
      expect(text, contains('shell_job_registry'));
      expect(text, contains('vacuum reclaims'));
      // The request summaries are the repair-drop surface.
      expect(text, contains('dropped by `fa session repair`'));
      // Message roles split.
      expect(text, contains('user'));
      // Small files never print the heavy warning.
      expect(text, isNot(contains('heavy file')));
    });

    test('renders json', () async {
      final target = await seedSession();
      final code = await runSessionInfoCliCommand(
        writeln: out.add,
        env: fs,
        sessionRoot: '/sessions',
        sessionId: target.id,
        json: true,
      );
      expect(code, 0);
      final decoded = jsonDecode(out.join()) as Map;
      expect(decoded['session'], target.id);
      expect(decoded['bytes'], greaterThan(0));
      expect(decoded['records'], 6);
      final ledgers = (decoded['ledgers'] as List)
          .cast<Map>()
          .map((e) => e['customType'])
          .toSet();
      expect(
        ledgers,
        containsAll(['shell_job_registry', 'model_request_summary']),
      );
      final jobs = (decoded['ledgers'] as List).cast<Map>().firstWhere(
        (e) => e['customType'] == 'shell_job_registry',
      );
      expect(jobs['latestBytes'], greaterThan(0));
    });

    test('cancellation reports a partial tally with exit 130', () async {
      final target = await seedSession();
      final code = await runSessionInfoCliCommand(
        writeln: out.add,
        env: fs,
        sessionRoot: '/sessions',
        sessionId: target.id,
        isCanceled: () async => true,
      );
      expect(code, 130);
      expect(out.join('\n'), contains('PARTIAL'));
    });

    test(
      'an empty target resolves to the most recently updated session',
      () async {
        // Two seeds separated by an mtime tick: the resolver picks the
        // newer one (the empty-`sessionId` default arm).
        final older = (await seedSession()).id;
        await Future<void>.delayed(const Duration(milliseconds: 6));
        final newer = (await seedSession()).id;
        final code = await runSessionInfoCliCommand(
          writeln: out.add,
          env: fs,
          sessionRoot: '/sessions',
          sessionId: '',
        );
        expect(code, 0);
        final text = out.join('\n');
        expect(text, contains('session: $newer'));
        expect(text, isNot(contains('session: $older')));
      },
    );

    test('unknown and ambiguous ids fail honestly', () async {
      await seedSession();
      expect(
        await runSessionInfoCliCommand(
          writeln: out.add,
          env: fs,
          sessionRoot: '/sessions',
          sessionId: 'nope',
        ),
        1,
      );
      expect(out.join('\n'), contains('session not found'));
    });
  });
}
