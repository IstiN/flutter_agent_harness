import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// gh-1577: an empty completion that follows partial content (truncated
/// text, tool activity, a truncation signal) is a bounded-retry provider
/// hiccup and, on exhaustion, a loud run error — never a silent exit 0.
/// Clean empties keep the issue #1085 M2b one-nudge semantics (REG-1).
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(FakeStreamFunction stream) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
    ),
    io: io,
    streamFunction: stream.call,
  );

  final truncatedToolCallTurn = toolTurn([
    const ToolCall(id: 'c1', name: 'bash', arguments: {'command': 'python3 - <<'
        '"unsigned long N = strtoull(argv[1'}),
  ]);

  List<AssistantMessageEvent> emptyTurn() => [
    DoneEvent(reason: StopReason.stop, message: testAssistant()),
  ];

  group('headless runHeadless (IT-1/IT-2/IT-3, AC4, REG-2)', () {
    test(
      'IT-1: partial stream → empty → healthy completion finishes the task '
      'with exit 0 and the retried empty in the transcript',
      () async {
        final stream = FakeStreamFunction([
          truncatedToolCallTurn,
          emptyTurn(),
          textTurn('task complete: all gates pass'),
        ]);
        final cli = cliFor(stream);

        final exitCode = await cli.runHeadless('do the task');

        expect(exitCode, 0, reason: 'the retry recovered — a real finish');
        expect(stream.calls, 3);
        final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
        final sessions = await repo.list(cwd: '/work');
        final session = await repo.open(sessions.first);
        final assistants = await session
            .getEntries()
            .then(
              (entries) => entries
                  .whereType<MessageRecord>()
                  .map((r) => r.message)
                  .whereType<AssistantMessage>()
                  .toList(),
            );
        expect(
          assistants.where((m) => m.content.isEmpty).length,
          1,
          reason: 'the retried empty stays in the transcript',
        );
        expect(
          assistants.last.content.whereType<TextContent>().single.text,
          'task complete: all gates pass',
        );
      },
    );

    test(
      'IT-2/IT-3/AC7: a persistent-empty storm exits non-zero with the loud '
      'error line after exactly N retries',
      () async {
        final stream = FakeStreamFunction([
          truncatedToolCallTurn,
          emptyTurn(),
          emptyTurn(),
          emptyTurn(),
          emptyTurn(),
          textTurn('never reached'),
        ]);
        final cli = cliFor(stream);

        final exitCode = await cli.runHeadless('do the task');

        expect(exitCode, 1, reason: 'the empty final can never map to 0');
        // partial + 4 empties (1 + 3 retries) = 5 requests.
        expect(stream.calls, 5);
        expect(
          io.out.toString(),
          contains('empty completion after partial content'),
        );
        expect(io.out.toString(), contains('3 retries'));
      },
    );

    test(
      'REG-2: the hiccup exhaustion fires across the stop-reason variants — '
      'length-flagged and silent-truncation-flagged empties never exit 0',
      () async {
        final lengthEmpty = [
          DoneEvent(reason: StopReason.length, message: testAssistant()),
        ];
        final silentTruncationEmpty = [
          DoneEvent(
            reason: StopReason.stop,
            message: testAssistant(
              errorMessage:
                  'stream ended without finish_reason — the reply may be '
                  'truncated',
            ),
          ),
        ];
        for (final scripted in [lengthEmpty, silentTruncationEmpty]) {
          final stream = FakeStreamFunction([
            truncatedToolCallTurn,
            scripted,
            scripted,
            scripted,
            scripted,
          ]);
          final cli = cliFor(stream);

          final exitCode = await cli.runHeadless('do the task');

          expect(exitCode, 1);
        }
      },
    );
  });

  group('interactive REPL (IT-4/AC5, REG-1)', () {
    test(
      'IT-4/AC5: exhaustion prints the error and returns to the prompt; the '
      'session stays steerable',
      () async {
        final stream = FakeStreamFunction([
          truncatedToolCallTurn,
          emptyTurn(),
          emptyTurn(),
          emptyTurn(),
          emptyTurn(),
          textTurn('fresh answer after the user re-asked'),
        ]);
        final cli = cliFor(stream);
        final run = cli.run();
        io.sendLine('do the task');
        int calls = 0;
        for (var i = 0; i < 400; i++) {
          calls = stream.calls;
          if (calls >= 5 && !cli.isBusy) break;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(stream.calls, 5, reason: 'exactly N retries, no storm');
        expect(io.out.toString(), contains('empty completion after partial'));
        // The session is alive: the follow-up user message runs normally.
        io.sendLine('try again please');
        for (var i = 0; i < 400; i++) {
          if (stream.calls >= 6 && !cli.isBusy) break;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(io.out.toString(), contains('fresh answer after the user re-asked'));
        io.sendLine('/exit');
        await run;
      },
    );

    test(
      'REG-1: clean empties keep the #1085 M2b semantics — one nudge, then '
      'settle',
      () async {
        final stream = FakeStreamFunction([emptyTurn(), emptyTurn()]);
        final cli = cliFor(stream);
        final run = cli.run();
        io.sendLine('hi');
        for (var i = 0; i < 400; i++) {
          if (stream.calls >= 2 && !cli.isBusy) break;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(stream.calls, 2, reason: 'one nudge, then settle — unchanged');
        expect(io.out.toString(), isNot(contains('empty completion after')));
        io.sendLine('/exit');
        await run;
      },
    );
  });
}
