import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Switch-stage attribution (gh-1734 acceptance): a mid-REPL `/session`
/// switch logs `boot_stage` lines covering EVERY switch stage —
/// open/walk/context (the session load), rehydrate (subagent registry),
/// replay (transcript replay) — bracketed by switch-begin/switch-done
/// lines naming the target session, so a regression is attributable from
/// fa.log alone.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late JsonlSessionRepo repo;
  late String alphaId;
  late String betaId;

  setUp(() async {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final alpha = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await alpha.appendSessionName('alpha');
    await alpha.appendMessage(UserMessage.text('alpha hello'));
    alphaId = (await alpha.getMetadata()).id;
    final beta = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await beta.appendSessionName('beta');
    await beta.appendMessage(UserMessage.text('beta hello'));
    betaId = (await beta.getMetadata()).id;
  });

  tearDown(() => io.close());

  AgentCli cliFor(StreamFunction streamFunction, {String? sessionName}) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
        sessionName: sessionName,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  Future<String> readLog() async =>
      (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ?? '';

  test('a switch logs every stage: begin/open/walk/context/rehydrate/'
      'replay/done', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    io.sendLine('/session beta');
    await waitForIt(
      () => io.out.toString().contains("switched to session 'beta'"),
    );
    await waitForIt(
      () async => (await readLog()).contains('boot_stage switch-done'),
      reason: 'the switch-done line lands in fa.log',
    );
    io.sendLine('/exit');
    await run;

    final log = await readLog();
    final lines = log.split('\n');
    int indexOf(bool Function(String) predicate) {
      final matches = [
        for (var i = 0; i < lines.length; i++)
          if (predicate(lines[i])) i,
      ];
      return matches.isEmpty ? -1 : matches.last;
    }

    final begin = indexOf(
      (l) => l.contains('boot_stage switch-begin') && l.contains(betaId),
    );
    final open = indexOf(
      (l) => l.contains('boot_stage open') && l.contains(betaId),
    );
    final walk = indexOf(
      (l) => l.contains('boot_stage walk') && l.contains(betaId),
    );
    final context = indexOf(
      (l) => l.contains('boot_stage context') && l.contains(betaId),
    );
    final rehydrate = indexOf(
      (l) => l.contains('boot_stage rehydrate') && l.contains(betaId),
    );
    final replay = indexOf(
      (l) => l.contains('boot_stage replay') && l.contains(betaId),
    );
    final done = indexOf(
      (l) => l.contains('boot_stage switch-done') && l.contains(betaId),
    );

    expect(begin, greaterThanOrEqualTo(0), reason: 'switch-begin logged');
    expect(open, greaterThan(begin), reason: 'open follows switch-begin');
    expect(walk, greaterThan(open), reason: 'walk follows open');
    expect(context, greaterThan(walk), reason: 'context follows walk');
    expect(
      rehydrate,
      greaterThan(context),
      reason: 'subagent rehydrate is its own attributable stage',
    );
    expect(
      replay,
      greaterThan(rehydrate),
      reason: 'transcript replay is its own attributable stage',
    );
    expect(done, greaterThan(replay), reason: 'switch-done closes the set');
  });

  test('a warm switch back to an unchanged session reuses the built '
      'context (source=cache)', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    io.sendLine('/session beta');
    await waitForIt(
      () => io.out.toString().contains("switched to session 'beta'"),
    );
    io.sendLine('/session $alphaId');
    await waitForIt(
      () => io.out.toString().contains("switched to session '$alphaId'"),
      reason: 'switch back to alpha by exact id',
    );
    await waitForIt(
      () async =>
          (await readLog()).contains('boot_stage context') &&
          (await readLog()).split('boot_stage context').length >= 4,
      reason: 'alpha boot + beta switch + alpha switch contexts logged',
    );
    io.sendLine('/exit');
    await run;

    final log = await readLog();
    final alphaContexts = log
        .split('\n')
        .where(
          (line) =>
              line.contains('boot_stage context') && line.contains(alphaId),
        )
        .toList();
    expect(alphaContexts, isNotEmpty);
    expect(
      alphaContexts.last,
      contains('source=cache'),
      reason:
          'alpha was opened at boot and unchanged since — the warm switch '
          'back must reuse the built context',
    );
    // The replayed transcript still shows the session's content.
    expect(io.out.toString(), contains('alpha hello'));
  });

  test('an appended record invalidates the cache — the next switch '
      'rebuilds', () async {
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    io.sendLine('/session beta');
    await waitForIt(
      () => io.out.toString().contains("switched to session 'beta'"),
    );
    // A foreign writer appends to alpha while the CLI sits on beta.
    final alphaSession = await repo.open(
      await _metadataById(repo, alphaId),
      windowed: true,
    );
    await alphaSession.appendMessage(UserMessage.text('alpha grew'));
    io.sendLine('/session $alphaId');
    await waitForIt(
      () => io.out.toString().contains("switched to session '$alphaId'"),
    );
    io.sendLine('/exit');
    await run;

    final log = await readLog();
    final alphaContexts = log
        .split('\n')
        .where(
          (line) =>
              line.contains('boot_stage context') && line.contains(alphaId),
        )
        .toList();
    expect(alphaContexts, isNotEmpty);
    expect(
      alphaContexts.last,
      isNot(contains('source=cache')),
      reason: 'alpha changed on disk — the context must rebuild',
    );
    expect(io.out.toString(), contains('alpha grew'));
  });
}

Future<SessionMetadata> _metadataById(
  JsonlSessionRepo repo,
  String id,
) async {
  final sessions = await repo.list();
  return sessions.firstWhere((m) => m.id == id);
}
