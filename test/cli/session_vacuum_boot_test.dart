// Issue #1882 AC2 — the resume seam of the keep-latest vacuum:
// `sessions.vacuumLedgers: true` drops the resumed session's superseded
// ledger snapshots through the same surgery as `fa session repair` (with
// the dim report line), the default (section absent) leaves the file
// byte-untouched, and a live presence row (another instance holds the
// session) skips the vacuum. Mirrors session_retention_boot_test.dart's
// harness.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO bootIo;
  late JsonlSessionRepo repo;
  late FileSessionPresenceStore presence;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    bootIo = FakeCliIO();
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    presence = FileSessionPresenceStore(env: env, root: '/sessions');
  });

  tearDown(() => bootIo.close());

  Future<String> readFile(String path) async =>
      (await env.readTextFile(path)).valueOrNull ?? '';

  /// Seeds a real session through the repo: two messages plus three
  /// superseded `shell_job_registry` snapshots (the real append order —
  /// every record parents onto the previous leaf).
  Future<SessionMetadata> seedBloatedSession() async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('start'));
    for (var gen = 1; gen <= 3; gen++) {
      await session.appendCustomEntry(
        customType: 'shell_job_registry',
        data: {
          'jobs': [
            {'id': 'job-$gen', 'status': 'completed', 'output': 'o' * 512},
          ],
        },
      );
    }
    await session.appendMessage(UserMessage.text('end'));
    return session.getMetadata();
  }

  Future<List<String>> fileLines(String path) async =>
      (await readFile(path)).trim().split('\n');

  AgentCli bootCli(
    StreamFunction streamFunction, {
    String? sessionName,
    bool vacuum = false,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      sessionName: sessionName,
      sessionsRetention: SessionsConfig(vacuumLedgers: vacuum),
      presenceStore: presence,
      homeDir: '/home',
    ),
    io: bootIo,
    streamFunction: streamFunction,
  );

  group('sessions.vacuumLedgers at resume (issue #1882 AC2)', () {
    test('opt-in: the resume drops superseded snapshots and reports the '
        'reclaim', () async {
      final target = await seedBloatedSession();
      final before = await fileLines(target.path);
      expect(
        before.where((line) => line.contains('"shell_job_registry"')),
        hasLength(3),
      );

      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = bootCli(fake.call, sessionName: target.id, vacuum: true);
      final run = cli.run();
      await waitForIt(
        () => !cli.isBusy && bootIo.out.toString().contains('ok'),
        reason: 'the scripted first turn completes',
      );
      bootIo.sendLine('/exit');
      await run;

      final after = await fileLines(target.path);
      final registryLines = after
          .where((line) => line.contains('"shell_job_registry"'))
          .toList();
      expect(registryLines, hasLength(1), reason: 'only the latest snapshot');
      // The KEPT snapshot is the NEWEST one (gen 3).
      expect(registryLines.single, contains('"job-3"'));
      // Messages survive byte-verbatim.
      expect(
        after.where((line) => line.contains('"role":"user"')),
        before.where((line) => line.contains('"role":"user"')),
      );
      // The dim report line names the reclaim and the backup.
      expect(bootIo.out.toString(), contains('vacuum: dropped 2 '));
      expect(bootIo.out.toString(), contains('.bak'));
      // Resume correctness: the real open replays every seeded record —
      // both messages and the kept snapshot (the scripted turn may add
      // its own records on top).
      final reopened = await JsonlSessionStorage.open(env, target.path);
      final entries = await reopened.getEntries();
      final seededIds = [
        for (final line in before)
          if (!line.contains('"session"') &&
              !line.contains('"shell_job_registry"'))
            (jsonDecode(line) as Map)['id'] as String,
      ];
      final keptId = (jsonDecode(registryLines.single) as Map)['id'] as String;
      final entryIds = [for (final e in entries) e.id];
      expect(
        entryIds.toSet().containsAll([...seededIds, keptId]),
        isTrue,
        reason: 'the vacuumed session replays every seeded record',
      );
      // The pre-vacuum bytes live at `<path>.bak`.
      expect(await fileLines('${target.path}.bak'), before);
    });

    test('default (no section): the boot never vacuums', () async {
      final target = await seedBloatedSession();

      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = bootCli(fake.call, sessionName: target.id, vacuum: false);
      final run = cli.run();
      await waitForIt(
        () => !cli.isBusy && bootIo.out.toString().contains('ok'),
        reason: 'the scripted first turn completes',
      );
      bootIo.sendLine('/exit');
      await run;

      // The boot's own turn appends records, but the three seeded
      // snapshots all survive — nothing rewrote the ledger history.
      expect(
        (await fileLines(
          target.path,
        )).where((line) => line.contains('"shell_job_registry"')),
        hasLength(3),
      );
      expect(bootIo.out.toString(), isNot(contains('vacuum:')));
      // No silent backup either — no rewrite happened.
      expect(await readFile('${target.path}.bak'), isEmpty);
    });

    test('a live presence row (another instance) skips the vacuum', () async {
      final target = await seedBloatedSession();
      // Another live instance holds the session: this process has not
      // registered its own row yet (that happens after the load), so the
      // row can only be someone else's.
      await presence.register(target.id);

      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = bootCli(fake.call, sessionName: target.id, vacuum: true);
      final run = cli.run();
      await waitForIt(
        () => !cli.isBusy && bootIo.out.toString().contains('ok'),
        reason: 'the scripted first turn completes',
      );
      bootIo.sendLine('/exit');
      await run;

      // All three snapshots remain — no rewrite.
      expect(
        (await fileLines(
          target.path,
        )).where((line) => line.contains('"shell_job_registry"')),
        hasLength(3),
      );
      expect(
        await readFile('${target.path}.bak'),
        isEmpty,
        reason: 'no backup — no rewrite',
      );
    });
  });
}
