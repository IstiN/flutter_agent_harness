import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// gh-1603: an unattended (headless) run must not end as a clean success on
/// empty model responses. Clean empties get a wider nudge budget in headless
/// (the session may end only after 3 consecutive unrecoverable empties), and
/// a run that still settles empty exits with the explicit `__FA_INCOMPLETE`
/// failure marker — never a silent exit 0. Interactive keeps the #1085 M2b
/// one-nudge semantics (gh-1577 REG-1 pins it); the loop-level hiccup
/// retries and their continuation nudges are covered in the loop tests.
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
      emptyHiccupBaseDelay: Duration.zero,
    ),
    io: io,
    streamFunction: stream.call,
  );

  List<AssistantMessageEvent> emptyTurn() => [
    DoneEvent(reason: StopReason.stop, message: testAssistant()),
  ];

  bool hasContinueNudge(Context c) =>
      c.messages.any((m) => m is UserMessage && m.content == 'continue');

  group('headless clean-empty budget (gh-1603 AC1)', () {
    test('two consecutive empties: two continuation turns, then recovery '
        'finishes with exit 0', () async {
      final stream = FakeStreamFunction([
        emptyTurn(),
        emptyTurn(),
        textTurn('recovered: task complete'),
      ]);
      final cli = cliFor(stream);

      final exitCode = await cli.runHeadless('do the task');

      expect(exitCode, 0, reason: 'the run recovered — a real finish');
      expect(stream.calls, 3, reason: '2 empties + the recovered answer');
      expect(hasContinueNudge(stream.contexts[1]), isTrue);
      expect(
        hasContinueNudge(stream.contexts[2]),
        isTrue,
        reason: 'the nudge budget in headless is wider than one',
      );
      expect(io.out.toString(), isNot(contains('__FA_INCOMPLETE')));
    });

    test('three consecutive unrecoverable empties end the run with the '
        '__FA_INCOMPLETE marker and a non-zero exit', () async {
      final stream = FakeStreamFunction([
        emptyTurn(),
        emptyTurn(),
        emptyTurn(),
        textTurn('never reached'),
      ]);
      final cli = cliFor(stream);

      final exitCode = await cli.runHeadless('do the task');

      expect(exitCode, 1, reason: 'an unfinished session is a failure');
      expect(
        stream.calls,
        3,
        reason:
            'exactly N=3 consecutive empties — the budget is spent, '
            'no 4th turn and no unbounded retry storm',
      );
      expect(io.out.toString(), contains('__FA_INCOMPLETE'));
    });
  });

  group('headless terminal paths stay distinct (gh-1603)', () {
    test('hiccup exhaustion keeps its loud error exit and does NOT emit the '
        'incomplete marker', () async {
      final truncatedToolCallTurn = toolTurn([
        const ToolCall(id: 'c1', name: 'bash', arguments: {'command': 'x'}),
      ]);
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

      expect(exitCode, 1);
      expect(io.out.toString(), contains('empty completion after partial'));
      expect(
        io.out.toString(),
        isNot(contains('__FA_INCOMPLETE')),
        reason: 'the exhaustion error marker is the distinct verdict',
      );
    });

    test('a healthy first answer never triggers the incomplete path', () async {
      final stream = FakeStreamFunction([textTurn('all done')]);
      final cli = cliFor(stream);

      final exitCode = await cli.runHeadless('do the task');

      expect(exitCode, 0);
      expect(stream.calls, 1);
      expect(io.out.toString(), isNot(contains('__FA_INCOMPLETE')));
    });
  });
}
