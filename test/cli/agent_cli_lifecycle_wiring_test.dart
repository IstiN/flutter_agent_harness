@TestOn('vm')
library;

/// Issue #222 — REAL `AgentCli` wiring (review blockers):
///
/// - AC1 dead-wiring guard: the lifecycle tools the constructor wires
///   (`readMessages` / `resumeChild` / `childSessionOpener`) are REGISTERED
///   and WORK through `cli.agent.state.tools`. Reverting any of those three
///   wiring lines in `agent_cli.dart` turns this red (issues #67/#70 class).
/// - AC5 `/tasks` half: the CLI `/tasks` listing folds a supersedes chain
///   into ONE logical entry.

import 'dart:convert';

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

  AgentCli cliFor(StreamFunction streamFunction) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  ToolCall taskCall(String id, Map<String, dynamic> arguments) {
    return ToolCall(id: id, name: 'task', arguments: arguments);
  }

  String textOf(ToolExecutionResult result) =>
      result.content.whereType<TextContent>().map((b) => b.text).join();

  test('the real CLI registers WORKING lifecycle tools (readMessages, '
      'resumeChild, childSessionOpener all wired)', () async {
    final fake = FakeStreamFunction([
      // 1. The parent delegates a BLOCKING child.
      toolTurn([
        taskCall('t1', {
          'context': 'repo state',
          'tasks': [
            {'name': 'scout', 'task': 'survey the repo'},
          ],
        }),
      ]),
      // 2. The child's turn.
      textTurn('scout says: all quiet'),
      // 3. The parent wraps up.
      textTurn('delegated'),
      // 4. The resume run launched by task_send below.
      textTurn('survey extended'),
    ]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    io.sendLine('delegate it');
    await waitForIt(() => fake.calls == 3 && !cli.isBusy);
    // The fire-and-forget transcript flush attaches the real JSONL path.
    await waitForIt(() {
      final handle = cli.subagentManager['scout'];
      return handle != null && handle.sessionId != '/scout';
    });
    expect(cli.subagentManager['scout']!.status, SubagentStatus.completed);

    // Registered through the real tool registry (the model-visible list).
    final tools = cli.agent.state.tools.whereType<AgentTool>().toList();
    final names = tools.map((t) => t.name).toSet();
    expect(names, containsAll(['task_send', 'task_resume', 'task_observe']));
    final send = tools.firstWhere((t) => t.name == 'task_send');
    final resume = tools.firstWhere((t) => t.name == 'task_resume');
    // With resumeChild wired the descriptors advertise the capability…
    expect(send.description, isNot(contains('steering: unavailable')));
    expect(resume.description, isNot(contains('UNAVAILABLE on this host')));
    // …and the restart-shape session reopening is wired too.
    expect(cli.taskConfig.childSessionOpener, isNotNull);

    // task_observe reads the child's REAL transcript (readMessages wired).
    final observe = tools.firstWhere((t) => t.name == 'task_observe');
    final observed = textOf(await observe.execute({'id': 'scout'}, null, null));
    expect(observed, contains('scout says: all quiet'));
    expect(observed, isNot(contains('session reading not available')));

    // task_send resumes the completed child in its own session.
    final sent = textOf(
      await send.execute(
        {'id': 'scout', 'message': 'one more pass'},
        null,
        null,
      ),
    );
    expect(sent, contains('child resumed'));
    expect(cli.subagentManager['scout']!.status, SubagentStatus.completed);

    io.sendLine('/exit');
    await run;
    expect(fake.calls, 4);
  });

  test(
    '/tasks folds a supersedes chain into ONE logical entry (AC5 CLI half)',
    () async {
      final fake = FakeStreamFunction([
        // Generation 1: background spawn → parent wrap-up → child result →
        // async-result re-wake.
        toolTurn([
          taskCall('t1', {
            'context': 'repo state',
            'background': true,
            'tasks': [
              {'name': 'Scout', 'task': 'survey the repo'},
            ],
          }),
        ]),
        textTurn('delegated the survey'),
        textTurn('survey says: all quiet'),
        textTurn('noted'),
        // Generation 2: an explicit respawn of the same display name.
        toolTurn([
          taskCall('t2', {
            'context': 'repo state',
            'background': true,
            'tasks': [
              {'name': 'Scout', 'task': 'survey again'},
            ],
          }),
        ]),
        textTurn('delegated again'),
        textTurn('second survey done'),
        textTurn('noted 2'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      io.sendLine('delegate it');
      await waitForIt(() => fake.calls == 4 && !cli.isBusy);
      io.sendLine('again');
      await waitForIt(() => fake.calls == 8 && !cli.isBusy);
      io.sendLine('/tasks');
      await waitForIt(() => io.out.toString().contains('background agents:'));
      io.sendLine('/exit');
      await run;

      // The chain exists: Scout-2 supersedes the dead first generation.
      expect(cli.subagentManager['Scout-2']!.supersedes, 'Scout');
      expect(cli.taskConfig.jobManager.jobs.map((j) => j.id), [
        'Scout',
        'Scout-2',
      ]);

      final out = io.out.toString();
      final section = out.substring(out.lastIndexOf('background agents:'));
      final rows = const LineSplitter()
          .convert(section)
          .skip(1)
          .takeWhile((line) => line.startsWith('  '))
          .toList();
      expect(rows, hasLength(1), reason: 'one logical entry: $section');
      expect(rows.single, contains('Scout-2'));
      expect(rows.single, contains('supersedes Scout'));
    },
  );
}
