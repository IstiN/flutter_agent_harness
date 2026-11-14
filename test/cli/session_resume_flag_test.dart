import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// `fa --resume` (issue #2083): boots the newest session recorded for the
/// LAUNCH folder — never a newer session from another project — and a
/// folder with no sessions starts a fresh one with a printed note.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late JsonlSessionRepo repo;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  });

  tearDown(() => io.close());

  Future<SessionMetadata> namedSession(String name, String cwd) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: cwd));
    await session.appendSessionName(name);
    return session.getMetadata();
  }

  AgentCli cliFor(StreamFunction streamFunction) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        resume: true,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  test('the newest session of the launch folder opens', () async {
    final older = await namedSession('older', '/work');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final newer = await namedSession('newer', '/work');
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(
      () => io.out.toString().contains(newer.id),
      reason: 'the newest local session id appears in the boot banner',
    );
    expect(io.out.toString(), isNot(contains(older.id)));
    io.sendLine('/exit');
    await run;
  });

  test('a newer session from another folder never wins', () async {
    final local = await namedSession('local', '/work');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final foreign = await namedSession('foreign', '/other');
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(
      () => io.out.toString().contains(local.id),
      reason: 'the launch folder session opens despite being older',
    );
    expect(io.out.toString(), isNot(contains(foreign.id)));
    io.sendLine('/exit');
    await run;
  });

  test('no folder sessions starts a fresh one with a note', () async {
    final foreign = await namedSession('foreign', '/other');
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await io.out.waitUntilContains('no sessions to resume in this folder');
    expect(io.out.toString(), isNot(contains(foreign.id)));
    io.sendLine('/exit');
    await run;
  });

  test('a stale header-only resume target survives the boot sweep', () async {
    // The flag's core scenario: the last run crashed before any content,
    // so the newest folder session is a 1-line file past the sweep grace.
    // The boot sweep must exempt the resolved target (it has no presence
    // row yet) and still sweep OTHER stale header-only files.
    final target = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    final targetId = (await target.getMetadata()).id;
    final targetPath = (await target.getMetadata()).path;
    final other = await repo.create(JsonlSessionCreateOptions(cwd: '/other'));
    final otherPath = (await other.getMetadata()).path;
    final past = DateTime.now().subtract(const Duration(minutes: 30));
    env.setMtime(targetPath, past.millisecondsSinceEpoch);
    env.setMtime(otherPath, past.millisecondsSinceEpoch);

    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await io.out.waitUntilContains(targetId);
    // While the session is open the file must still be on disk: the boot
    // sweep exempted the resolved target. (After /exit the clean-exit
    // deleteSessionIfEmpty may legitimately trash the empty file — that
    // is gh-1660's other mechanism, not the race under test here.)
    expect(
      (await env.exists(targetPath)).valueOrNull,
      isTrue,
      reason: 'the resume target is exempt from the boot header-only sweep',
    );
    io.sendLine('/exit');
    await run;
    await waitForIt(
      () async => (await env.exists(otherPath)).valueOrNull == false,
      reason: 'a stale header-only file outside the target still gets swept',
    );
  });
}
