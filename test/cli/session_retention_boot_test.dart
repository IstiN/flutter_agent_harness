/// gh-1746 review follow-up — the BOOT seam of the retention sweep:
/// `_initializeSession` must exempt the session this process is about to
/// open (the sweep deletes files, so it must never eat the resume target
/// whose presence row registers only after the load), the `[retention]`
/// report must land in the boot log BEFORE the boot marker (AC7's
/// wiring), a section-free boot must stay byte-identical legacy (REG-1,
/// merge-blocking), and the real-fs `fa session clean` verb must plan on
/// a dry run and apply exactly that plan (E2E-1) on a real filesystem.
@TestOn('vm')
library;

import 'dart:io' as io;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/cli/session_clean_command.dart';
import 'package:flutter_agent_harness/src/cli/session_tree.dart';
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

  Future<SessionMetadata> seedSession({
    String? name,
    required DateTime lastUsed,
    int sizeBytes = 0,
  }) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    if (sizeBytes > 0) {
      await session.appendMessage(UserMessage.text('x' * sizeBytes));
    }
    if (name != null) await session.appendSessionName(name);
    final metadata = await session.getMetadata();
    env.setMtime(metadata.path, lastUsed.millisecondsSinceEpoch);
    return metadata;
  }

  SessionsConfig retention({int maxTotalBytes = 1, bool keepNamed = true}) =>
      SessionsConfig(
        retention: SessionRetentionConfig(
          maxTotalBytes: maxTotalBytes,
          minAgeDays: 0,
          keepNamed: keepNamed,
        ),
      );

  AgentCli bootCli(
    StreamFunction streamFunction, {
    String? sessionName,
    SessionsConfig? sessions,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      sessionName: sessionName,
      sessionsRetention: sessions,
      presenceStore: presence,
      homeDir: '/home',
    ),
    io: bootIo,
    streamFunction: streamFunction,
  );

  Future<String> bootLog() async =>
      (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ?? '';

  group('boot seam (gh-1746 review)', () {
    test('REGRESSION: the boot sweep never deletes the session this boot '
        'is about to open (resume by id)', () async {
      final target = await seedSession(
        lastUsed: DateTime.now().subtract(const Duration(days: 60)),
        sizeBytes: 500,
      );
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = bootCli(
        fake.call,
        sessionName: target.id,
        sessions: retention(),
      );
      final run = cli.run();
      await waitForIt(
        () => !cli.isBusy && bootIo.out.toString().contains('ok'),
        reason: 'the scripted first turn completes',
      );
      bootIo.sendLine('/exit');
      await run;
      // The resume target survived its own boot sweep: the transcript is
      // still listed and the file still carries its bytes.
      final ids = (await repo.list()).map((m) => m.id);
      expect(ids, contains(target.id));
      final read = await env.readTextFile(target.path);
      expect(read.valueOrNull, isNotNull);
      expect(read.valueOrNull!, contains('"id"'));
    });

    test('REGRESSION: resume by NAME with keepNamed:false still exempts '
        'the target', () async {
      final target = await seedSession(
        name: 'marathon',
        lastUsed: DateTime.now().subtract(const Duration(days: 60)),
        sizeBytes: 500,
      );
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = bootCli(
        fake.call,
        sessionName: 'marathon',
        sessions: retention(keepNamed: false),
      );
      final run = cli.run();
      await waitForIt(
        () => !cli.isBusy && bootIo.out.toString().contains('ok'),
        reason: 'the scripted first turn completes',
      );
      bootIo.sendLine('/exit');
      await run;
      final ids = (await repo.list()).map((m) => m.id);
      expect(ids, contains(target.id));
      expect((await env.readTextFile(target.path)).valueOrNull, isNotNull);
    });

    test('AC7: the [retention] report lands in the boot log BEFORE the '
        'boot marker (the sweep runs before the session opens)', () async {
      final target = await seedSession(
        lastUsed: DateTime.now().subtract(const Duration(days: 60)),
        sizeBytes: 500,
      );
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = bootCli(
        fake.call,
        sessionName: target.id,
        sessions: retention(),
      );
      final run = cli.run();
      await waitForIt(
        () => !cli.isBusy && bootIo.out.toString().contains('ok'),
        reason: 'the scripted first turn completes',
      );
      bootIo.sendLine('/exit');
      await run;
      final log = await bootLog();
      expect(log, contains('[retention]'));
      final retentionAt = log.indexOf('[retention]');
      final bootAt = log.indexOf('fa boot sid=');
      expect(bootAt, greaterThan(-1));
      expect(retentionAt, lessThan(bootAt));
    });

    test(
      'the /sessions listing gains the usage footer only under a cap',
      () async {
        final target = await seedSession(
          lastUsed: DateTime.now().subtract(const Duration(days: 60)),
          sizeBytes: 500,
        );
        // WITH a cap: the listing carries the usage footer line.
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = bootCli(
          fake.call,
          sessionName: target.id,
          sessions: retention(maxTotalBytes: 10 << 20),
        );
        final run = cli.run();
        await waitForIt(
          () => !cli.isBusy && bootIo.out.toString().contains('ok'),
          reason: 'the scripted first turn completes',
        );
        bootIo.sendLine('/sessions');
        await waitForIt(
          () => bootIo.out.toString().contains('total:'),
          reason: 'the usage footer prints under a cap',
        );
        expect(bootIo.out.toString(), contains('cap:'));
        bootIo.sendLine('/exit');
        await run;

        // WITHOUT a cap (REG-1): no footer at all.
        final bareIo = FakeCliIO();
        final bareRepo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
        final bareSession = await bareRepo.create(
          JsonlSessionCreateOptions(cwd: '/work'),
        );
        final bareMetadata = await bareSession.getMetadata();
        final bare = AgentCli(
          config: AgentCliConfig(
            model: testModel,
            apiKey: '[REDACTED:Sensitive Value]',
            env: env,
            sessionRoot: '/sessions',
            providerKind: 'openai-completions',
            sessionName: bareMetadata.id,
            presenceStore: presence,
            homeDir: '/home',
          ),
          io: bareIo,
          streamFunction: fake.call,
        );
        final bareRun = bare.run();
        await waitForIt(
          () => !bare.isBusy && bareIo.out.toString().contains('ok'),
          reason: 'the scripted first turn completes',
        );
        bareIo.sendLine('/sessions');
        await waitForIt(
          () => bareIo.out.toString().contains('switch:'),
          reason: 'the listing completes',
        );
        expect(bareIo.out.toString(), isNot(contains('total:')));
        expect(bareIo.out.toString(), isNot(contains('cap:')));
        bareIo.sendLine('/exit');
        await bareRun;
        await bareIo.close();
      },
    );

    test('REG-1 (merge-blocking): no sessions section — the boot never '
        'notes, never touches a byte', () async {
      final untouched = await seedSession(
        lastUsed: DateTime.now().subtract(const Duration(days: 600)),
        sizeBytes: 500,
      );
      final before = (await env.readTextFile(untouched.path)).valueOrNull;
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = bootCli(
        fake.call,
        sessionName: untouched.id,
        // NO sessionsRetention: the byte-identical legacy boot.
      );
      final run = cli.run();
      await waitForIt(
        () => !cli.isBusy && bootIo.out.toString().contains('ok'),
        reason: 'the scripted first turn completes',
      );
      bootIo.sendLine('/exit');
      await run;
      final log = await bootLog();
      expect(log, isNot(contains('[retention]')));
      expect(bootIo.out.toString(), isNot(contains('sessions clean')));
      // Nothing was deleted or truncated: the seeded records are still the
      // file's prefix (the boot itself may append lifecycle records — the
      // retention seam must add nothing of its own).
      final after = (await env.readTextFile(untouched.path)).valueOrNull;
      expect(after, isNotNull);
      expect(after!.startsWith(before!), isTrue);
      expect((await repo.list()).map((m) => m.id), contains(untouched.id));
    });
  });

  group('E2E-1: fa session clean on a REAL filesystem', () {
    late io.Directory temp;
    late LocalExecutionEnv localEnv;
    late JsonlSessionRepo localRepo;
    late String root;

    setUp(() {
      temp = io.Directory.systemTemp.createTempSync('fah_retention_e2e');
      root = '${temp.path}/sessions';
      io.Directory(root).createSync(recursive: true);
      localEnv = LocalExecutionEnv(cwd: temp.path);
      localRepo = JsonlSessionRepo(fs: localEnv, sessionsRoot: root);
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    Future<SessionMetadata> seedRealSession({
      required DateTime lastUsed,
      int sizeBytes = 0,
    }) async {
      final session = await localRepo.create(
        JsonlSessionCreateOptions(cwd: temp.path),
      );
      if (sizeBytes > 0) {
        await session.appendMessage(UserMessage.text('x' * sizeBytes));
      }
      final metadata = await session.getMetadata();
      // Backdate the header timestamp too: the E3 floor lifts last-used to
      // createdAt when the mtime sits before it, so an old mtime alone
      // would never make the unit old.
      final raw = io.File(metadata.path).readAsStringSync();
      io.File(metadata.path).writeAsStringSync(
        raw.replaceFirst(
          RegExp(r'"timestamp":"[^"]+"'),
          '"timestamp":"${lastUsed.toIso8601String()}"',
        ),
      );
      io.File(metadata.path).setLastModifiedSync(lastUsed);
      return metadata;
    }

    test('dry run prints the plan and deletes nothing; apply deletes '
        'exactly that plan (AC6)', () async {
      final doomed = await seedRealSession(
        lastUsed: DateTime.now().subtract(const Duration(days: 60)),
        sizeBytes: 500,
      );
      final keeper = await seedRealSession(
        lastUsed: DateTime.now().subtract(const Duration(days: 0, minutes: 1)),
      );
      final buffer = StringBuffer();
      final planCode = await runSessionCleanCliCommand(
        write: buffer.write,
        writeln: (line) => buffer.writeln(line),
        env: localEnv,
        sessionRoot: root,
        // The default 14-day guard keeps the fresh keeper exempt; only the
        // 60-day-old unit is plan food.
        retention: const SessionRetentionConfig(maxTotalBytes: 1),
        dryRun: true,
        presenceStore: FileSessionPresenceStore(env: localEnv, root: root),
      );
      expect(planCode, 0);
      expect(buffer.toString(), contains('would delete'));
      expect(buffer.toString(), contains(doomed.id));
      // The dry run deleted nothing.
      expect(
        (await localRepo.list()).map((m) => m.id),
        containsAll([doomed.id, keeper.id]),
      );
      expect(io.File(doomed.path).existsSync(), isTrue);

      final applied = StringBuffer();
      final applyCode = await runSessionCleanCliCommand(
        write: applied.write,
        writeln: (line) => applied.writeln(line),
        env: localEnv,
        sessionRoot: root,
        retention: const SessionRetentionConfig(maxTotalBytes: 1),
        dryRun: false,
        presenceStore: FileSessionPresenceStore(env: localEnv, root: root),
      );
      expect(applyCode, 0);
      expect(applied.toString(), contains('deleted'));
      expect(applied.toString(), contains(doomed.id));
      // Apply performed exactly the plan: doomed gone, keeper alive.
      expect(
        (await localRepo.list()).map((m) => m.id),
        isNot(contains(doomed.id)),
      );
      expect((await localRepo.list()).map((m) => m.id), contains(keeper.id));
      expect(io.File(doomed.path).existsSync(), isFalse);
      expect(io.File(keeper.path).existsSync(), isTrue);
    });

    test('fa session list prints the usage footer only under a cap', () async {
      await seedRealSession(
        lastUsed: DateTime.now().subtract(const Duration(days: 60)),
        sizeBytes: 500,
      );
      final buffer = StringBuffer();
      final code = await runSessionListCliCommand(
        write: buffer.write,
        writeln: (line) => buffer.writeln(line),
        env: localEnv,
        sessionRoot: root,
        cwd: temp.path,
        json: false,
        flat: false,
        retention: const SessionRetentionConfig(maxTotalBytes: 10 << 20),
      );
      expect(code, 0);
      expect(buffer.toString(), contains('total:'));
      expect(buffer.toString(), contains('cap:'));
      expect(buffer.toString(), contains('across 1 sessions'));

      // No cap (REG-1): the listing is byte-identical legacy — no footer.
      final bare = StringBuffer();
      final bareCode = await runSessionListCliCommand(
        write: bare.write,
        writeln: (line) => bare.writeln(line),
        env: localEnv,
        sessionRoot: root,
        cwd: temp.path,
        json: false,
        flat: false,
      );
      expect(bareCode, 0);
      expect(bare.toString(), isNot(contains('total:')));
      expect(bare.toString(), isNot(contains('cap:')));
    });
  });
}
