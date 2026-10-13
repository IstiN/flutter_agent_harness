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
      // gh-1577 thread 3: the backoff is pinnable from the CLI seam —
      // zero it so the suite asserts request counts, not wall-clock sleeps.
      emptyHiccupBaseDelay: Duration.zero,
    ),
    io: io,
    streamFunction: stream.call,
  );

  final truncatedToolCallTurn = toolTurn([
    const ToolCall(
      id: 'c1',
      name: 'bash',
      arguments: {
        'command':
            'python3 - <<'
            '"unsigned long N = strtoull(argv[1',
      },
    ),
  ]);

  List<AssistantMessageEvent> emptyTurn() => [
    DoneEvent(reason: StopReason.stop, message: testAssistant()),
  ];

  group('headless runHeadless (IT-1/IT-2/IT-3, AC4, REG-2)', () {
    test('IT-1: partial stream → empty → healthy completion finishes the task '
        'with exit 0 and the retried empty in the transcript', () async {
      final stream = FakeStreamFunction([
        truncatedToolCallTurn,
        emptyTurn(),
        textTurn('task complete: all gates pass'),
      ]);
      final cli = cliFor(stream);

      final exitCode = await cli.runHeadless('do the task');

      expect(exitCode, 0, reason: 'the retry recovered — a real finish');
      expect(stream.calls, 3);
    });

    test(
      'E2/E5: an abort landing with the FINAL hiccup retry (a length-flagged '
      'empty) exits 130 — never a silent exit 0 on an aborted run',
      () async {
        final lengthEmpty = [
          DoneEvent(
            reason: StopReason.length,
            message: testAssistant(stopReason: StopReason.length),
          ),
        ];
        final stream = _CancelDuringFinalRetryStreamFunction([
          truncatedToolCallTurn,
          emptyTurn(),
          lengthEmpty,
        ]);
        final cli = cliFor(stream);

        final exit = cli.runHeadless('do the task');
        // The fake holds the final retry's stream open until the cancel
        // lands, so the interrupt is guaranteed to hit the race window.
        var armed = false;
        for (var i = 0; i < 400; i++) {
          if (stream.calls >= 3) {
            armed = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(armed, isTrue, reason: 'the final retry must be in flight');
        io.interrupt();

        final exitCode = await exit;
        expect(exitCode, 130, reason: 'aborted run — never a silent exit 0');
      },
    );
  });

  group('interactive REPL (IT-4/AC5, REG-1)', () {
    test('IT-4/AC5: exhaustion prints the error and returns to the prompt; the '
        'session stays steerable', () async {
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
      expect(
        io.out.toString(),
        contains('fresh answer after the user re-asked'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('REG-1: clean empties keep the #1085 M2b semantics — one nudge, then '
        'settle', () async {
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
    });
  });
}

/// The E2/E5 race, scripted: the FINAL hiccup retry's request stays in
/// flight (only a non-terminal Start event has been served) until the run
/// token is cancelled, and only then completes with the provider's answer —
/// an empty flagged `length`. The abort and the truncation-flagged empty
/// therefore land together, deterministically, exactly the window the
/// loop's post-retry conversion must cover.
class _CancelDuringFinalRetryStreamFunction extends FakeStreamFunction {
  _CancelDuringFinalRetryStreamFunction(super.turns);

  @override
  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final isFinal = turns.length == 1;
    models.add(model);
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    final events = turns.removeAt(0);
    if (isFinal && cancelToken != null) {
      stream.push(StartEvent(partial: testAssistant()));
      cancelToken.onCancel.then((_) {
        for (final event in events) {
          stream.push(event);
        }
        stream.end();
      });
    } else {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }
    return stream;
  }
}
