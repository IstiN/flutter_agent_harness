// Resume-hint regression for the windowed marathon boot (issue #503):
// exiting a session resumed by NAME must name that name in the printed
// hint, not the raw session id. Split out of agent_cli_test.dart (file
// size gate).
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
    'exit hint keeps the NAME after a windowed marathon resume (#503)',
    () async {
      // A marathon session: the name record sits at the file head, then
      // >8MiB of compacted-away records, then the compaction boundary
      // and a small live tail. The windowed boot walks back only to the
      // boundary, so the head (with the name) never becomes resident —
      // getSessionName() reads null and the hint used to degrade to the
      // raw session id.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendSessionName('work');
      final bulk = 'x' * 32768;
      for (var i = 0; i < 300; i++) {
        await session.appendMessage(UserMessage.text('old $i $bulk'));
      }
      final kept = await session.appendMessage(UserMessage.text('kept'));
      await session.appendCompaction(
        summary: 'older turns compacted',
        firstKeptEntryId: kept,
        tokensBefore: 100000,
      );
      for (var i = 0; i < 10; i++) {
        await session.appendMessage(UserMessage.text('tail $i $bulk'));
      }

      final fake = FakeStreamFunction([textTurn('hi')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'work',
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      io.sendLine('q');
      await waitForIt(() => fake.calls >= 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      expect(
        io.out.toString(),
        contains("resume this session with: fa --session 'work'"),
      );
    },
  );
}
