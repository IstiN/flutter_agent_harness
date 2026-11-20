import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// `fa --session <name>` with SAME-NAMED sessions from different folders:
/// the launch folder's session must win (the live bug opened whatever
/// `_repo.list()` returned first — a different project's session), and an
/// ambiguous remainder auto-resolves to the most recent with a printed
/// pointer at the exact ids.
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

  AgentCli cliFor(StreamFunction streamFunction, {String? sessionName}) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        sessionName: sessionName,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  test('the launch folder wins over a namesake from another project', () async {
    final foreign = await namedSession('widgets', '/other');
    final local = await namedSession('widgets', '/work');
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, sessionName: 'widgets');
    final run = cli.run();
    await io.out.waitUntilContains(
      local.id,
      reason: 'the local session id appears in the boot banner',
    );
    expect(io.out.toString(), isNot(contains(foreign.id)));
    io.sendLine('/exit');
    await run;
  });

  test('a single namesake in ANOTHER folder still opens', () async {
    final foreign = await namedSession('widgets', '/other');
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, sessionName: 'widgets');
    final run = cli.run();
    await io.out.waitUntilContains(foreign.id);
    io.sendLine('/exit');
    await run;
  });

  test('a rotated session resolves by name (#2321 incident shape)', () async {
    // The only session_info rotated into `.part-0001` (header+name),
    // the primary keeps the post-rotation work records: `fa --session
    // <name>` must boot the ORIGINAL, not silently create a namesake.
    final original = await namedSession('network-redesign', '/work');
    final session = await repo.open(original);
    await session.appendMessage(UserMessage.text('real work'));
    final metadata = await session.getMetadata();
    final content = (await env.readTextFile(metadata.path)).valueOrNull!;
    final lines = content.trim().split('\n');
    await env.writeFile(
      '${metadata.path}.part-0001',
      '${lines[0]}\n${lines[1]}\n',
    );
    await env.writeFile(
      metadata.path,
      '${lines[0]}\n${lines.sublist(2).join('\n')}\n',
    );

    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, sessionName: 'network-redesign');
    final run = cli.run();
    await io.out.waitUntilContains(
      original.id,
      reason: 'the rotated original boots — no empty namesake',
    );
    io.sendLine('/exit');
    await run;
    // The boot found the original: no empty namesake was created.
    final sessions = await repo.list();
    expect(sessions, hasLength(1));
    expect(sessions.single.id, original.id);
  });

  test('several in one folder: most recent + a note with the ids', () async {
    final older = await namedSession('widgets', '/work');
    // Distinct createdAt ordering for the most-recent rule.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final newer = await namedSession('widgets', '/work');
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, sessionName: 'widgets');
    final run = cli.run();
    await io.out.waitUntilContains(newer.id);
    final out = io.out.toString();
    expect(out, contains("2 sessions named 'widgets'"));
    expect(out, contains('fa --session <id>'));
    expect(out, isNot(contains(older.id)));
    io.sendLine('/exit');
    await run;
  });

  test('mid-session /session <name> asks when ambiguous', () async {
    final first = await namedSession('widgets', '/other');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = await namedSession('widgets', '/other-2');
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    io.sendLine('/session widgets');
    await io.out.waitUntilContains(
      "Several sessions named 'widgets'",
      reason: 'the ambiguity question lists the candidates',
    );
    // Both rows carry their folder + id; answer with the number of the
    // row holding the SECOND session (the repo list order is not the
    // creation order).
    expect(io.out.toString(), contains(first.cwd));
    expect(io.out.toString(), contains(second.cwd));
    final row = io.out
        .toString()
        .split('\n')
        .firstWhere((line) => line.contains(second.id));
    final number = RegExp(r'^\s*(\d+)\)').firstMatch(row)!.group(1)!;
    io.sendLine(number);
    await io.out.waitUntilContains(
      "switched to session 'widgets'",
      reason: 'the chosen session loads',
    );
    io.sendLine('/exit');
    await run;
  });
}
