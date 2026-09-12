import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The REPL sessions surfaces (issue #198): the line-mode `/sessions` list
/// nests subagent sessions under their parent, and the picker seams expose
/// the same tree with a tree/flat toggle.
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
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  Future<void> seedTree() async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final parent = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await parent.appendSessionName('goal_builder');
    final child = await repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {
          'agent': 'subagent',
          'id': 'ag-a',
          'parent': (await parent.getMetadata()).id,
        },
      ),
    );
    await child.appendSessionName('explore');
  }

  test('line-mode /sessions nests children under the parent', () async {
    await seedTree();
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    io.sendLine('/sessions list');
    await waitForIt(
      () => io.out.toString().contains('+1 agents'),
      reason: '/sessions list tree output',
    );
    final out = io.out.toString();
    expect(out, contains('goal_builder [work]  [+1 agents]'));
    expect(out, contains('↳ explore'));
    expect(out, isNot(contains('explore [work]')));

    io.sendLine('/exit');
    await run;
  });

  test(
    'picker builds the tree with a toggle; flat/tree keys flip it',
    () async {
      await seedTree();
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);

      await cli.openSessionsPickerForTest();
      final items = cli.sessionPickerItemsForTest!;
      expect(items.first.key, 'flat');
      expect(items.map((i) => i.label), contains(contains('1) goal_builder')));
      expect(items.map((i) => i.label), contains(contains('↳ explore')));

      // The toggle key flips the view: the next open shows the tree toggle.
      await cli.tuiPickSessionForTest('flat');
      await cli.openSessionsPickerForTest();
      expect(cli.sessionPickerItemsForTest!.first.key, 'tree');
      await cli.tuiPickSessionForTest('tree');
      await cli.openSessionsPickerForTest();
      expect(cli.sessionPickerItemsForTest!.first.key, 'flat');

      // Unknown keys are ignored, never throw.
      await cli.tuiPickSessionForTest('bogus');
    },
  );
}
