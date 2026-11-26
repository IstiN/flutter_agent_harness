// The delegation nudge (issue #1739): the system-prompt-side task-tool
// description opens with the context-limited framing — delegate by default,
// perform simple asks yourself. The paragraph lives in
// prompts/tools/task.md (gen_prompts.dart is the source of truth) and rides
// the EXISTING task-tool availability: load modes without `task` (pi) never
// show it, and children (no task tool) never see it.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart' as generated;
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

const _nudgeSentences = [
  'Your session context is limited.',
  'Before performing a user request, think whether the work can be delegated '
      'to subagents',
  'If it is a simple ask, just perform it yourself.',
];

void main() {
  group(
    'UT-1: the nudge rides the task-tool description (task registered)',
    () {
      test('the generated prompt carries the three sentences', () {
        for (final sentence in _nudgeSentences) {
          expect(
            generated.taskToolDescriptionPrompt,
            contains(sentence),
            reason: 'the delegation nudge opens the task-tool description',
          );
        }
      });

      test(
        'default-mode boot: the task tool defers; the nudge rides the '
        'deferred tool + the others stub alone',
        () async {
          final env = MemoryExecutionEnv(cwd: '/work');
          final io = FakeCliIO();
          final fake = FakeStreamFunction([textTurn('ok')]);
          final cli = AgentCli(
            config: AgentCliConfig(
              model: testModel,
              apiKey: 'test-key',
              env: env,
              sessionRoot: '/sessions',
              providerKind: 'openai-completions',
            ),
            io: io,
            streamFunction: fake.call,
          );
          final run = cli.run();
          await waitForIt(
            () => cli.systemPrompt.contains('You are Fa'),
            reason: 'default boot',
          );
          io.sendLine('/exit');
          await run;
          await io.close();

          // GOAL #28 (issue #2416): the default partition defers `task` —
          // the nudge's carrier stays out of the boot manifest (one
          // `others(tool_name: "task")` call loads it, nudge included).
          final manifestCarriers = cli.agent.state.tools
              .where(
                (tool) => tool.description.contains(
                  'Your session context is limited',
                ),
              )
              .map((tool) => tool.name)
              .toList();
          expect(manifestCarriers, isEmpty, reason: 'task is deferred');
          final others = cli.agent.state.tools
              .where((tool) => tool.name == 'others')
              .toList(growable: false);
          expect(others, hasLength(1));
          expect(others.single.description, contains('task'),
              reason: 'the deferred carrier is named in the stub');
        },
      );
    },
  );

  group('UT-2: pi mode (task absent) never shows the nudge', () {
    test('the pinned tool surface carries no nudge text', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final io = FakeCliIO();
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          agentMode: 'pi',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();
      await io.out.waitUntilContains(
        'pi benchmark: initial context',
        reason: 'pi boot print',
      );
      await waitForIt(
        () => cli.agent.state.tools.length == piToolIds.length,
        reason: 'tool-scope pin applied',
      );
      io.sendLine('/exit');
      await run;
      await io.close();

      final names = cli.agent.state.tools.map((tool) => tool.name).toSet();
      expect(names, isNot(contains('task')));
      for (final tool in cli.agent.state.tools) {
        expect(
          tool.description,
          isNot(contains('Your session context is limited')),
          reason: 'no dead nudge text on ${tool.name} in pi mode',
        );
      }
    });
  });
}
