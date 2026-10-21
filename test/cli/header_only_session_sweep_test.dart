/// gh-1660 — boot-time header-only session sweep (dead-wiring guard):
/// `cleanupEmptySessions` existed for a long time but no production code
/// called it, so header-only session files (one `{type:session}` line,
/// no transcript) left by crashed/killed runs lingered forever. Every
/// boot now sweeps them — files older than the grace — while keeping
/// fresh header-only files (a concurrently booting process's brand-new
/// file looks exactly like that) and real sessions.
@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  test(
    'boot sweeps an old header-only session, keeps fresh and real ones',
    () async {
      final seeder = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      // Real session: header + transcript, mtime backdated past the grace —
      // never empty-cleanup food.
      final real = await seeder.create(JsonlSessionCreateOptions(cwd: '/work'));
      await real.appendMessage(UserMessage.text('real transcript'));
      final realPath = (await real.getMetadata()).path;
      // Header-only session, old: garbage a killed run left behind.
      final staleEmpty = await seeder.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final staleEmptyPath = (await staleEmpty.getMetadata()).path;
      // Fresh header-only session: protected by the grace.
      final freshEmpty = await seeder.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final freshEmptyPath = (await freshEmpty.getMetadata()).path;
      final past = DateTime.now().subtract(const Duration(minutes: 30));
      env.setMtime(realPath, past.millisecondsSinceEpoch);
      env.setMtime(staleEmptyPath, past.millisecondsSinceEpoch);

      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
        ),
        io: io,
        streamFunction: FakeStreamFunction([
          textTurn('unused — the REPL exits before any prompt'),
        ]).call,
      );
      final run = cli.run();
      io.sendLine('/exit');
      await run;

      await waitForIt(
        () async => (await env.exists(staleEmptyPath)).valueOrNull == false,
        reason: 'old header-only session swept at boot',
      );
      expect((await env.exists(freshEmptyPath)).valueOrNull, isTrue);
      expect((await env.exists(realPath)).valueOrNull, isTrue);
    },
  );
}
