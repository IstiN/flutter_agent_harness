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
  test('picker row keys open and switch to the picked session', () async {
    await seedTree();
    final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);

    await cli.openSessionsPickerForTest();
    // r0: the parent row — opens it and switches to it.
    await cli.tuiPickSessionForTest('r0');
    expect(io.out.toString(), contains("switched to session 'goal_builder'"));

    // r1: the nested child row (tree mode: parent first, child second).
    await cli.tuiPickSessionForTest('r1');
    expect(io.out.toString(), contains("switched to session 'explore'"));

    // Out-of-range and malformed row keys are ignored, never throw.
    await cli.tuiPickSessionForTest('r99');
    await cli.tuiPickSessionForTest('rx');
  });

  test(
    'a broken session file surfaces inline instead of killing the TUI',
    () async {
      await seedTree();
      final cli = cliFor(FakeStreamFunction([textTurn('ok')]).call);

      // The picker caches its rows; the file vanishing after the listing
      // (another host deleted it) must not kill the TUI on selection.
      await cli.openSessionsPickerForTest();
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final victim = (await repo.list()).firstWhere(
        (m) => m.metadata?['parent'] != null,
      );
      (await env.remove(victim.path)).getOrThrow();

      // Item 0 is the view toggle; the victim child is the item after its
      // parent, so its row key is (itemIndex - 1).
      final itemIndex = cli.sessionPickerItemsForTest!.indexWhere(
        (item) => item.label.contains('explore'),
      );
      await cli.tuiPickSessionForTest('r${itemIndex - 1}');
      expect(
        io.out.toString(),
        contains('failed to open session'),
        reason: 'the broken file reports inline, the TUI survives',
      );
    },
  );
}
