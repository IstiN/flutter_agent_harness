// Issue #1786 E2E-equivalent (the 2026-10-22 incident as fixture): a REAL
// foreground `bash` call with a huge explicit timeout and no output — the
// exact shape that parked a live fa session for 19+ minutes — is force-
// backgrounded at the budget: the unreachability window ends at B (not at
// the command's runtime), the still-running command is handed to the
// `ShellJobRegistry` untouched (reversible, output continuity), and the
// ladder announces what it did. (Mid-call steering delivery over a real
// AgentCli is covered by the CLI-side budget suite; at this level the
// steer-yield fast path has its own suite — here the BUDGET is the net.)
//
// Real process, real registry, real agent loop; only the provider stream is
// scripted (the repo's standard scripted-turn pattern — no fake_async,
// second-scale budgets on a real clock).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

List<AssistantMessageEvent> _toolTurn(List<ToolCall> calls) {
  final empty = _assistant();
  final partial = _assistant(content: calls, stopReason: StopReason.toolUse);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
  return events;
}

class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fa-budget-e2e-');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test(
    'AC8: silent foreground bash with a huge explicit timeout is handed to '
    'the background at the budget, announced, and the turn continues',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final env = LocalExecutionEnv(cwd: tempDir.path);
      final registry = ShellJobRegistry(env: env, jobLogDir: tempDir.path);
      final tool = shellTool(env, jobs: registry);
      final fake = _FakeStreamFunction([
        _toolTurn([
          // The incident shape: a long silent command whose explicit
          // timeout is far larger than any budget (the stuck supervisor's
          // 2x-declared threshold is defeated by the same move).
          ToolCall(
            id: 'c1',
            name: 'bash',
            arguments: {'command': 'sleep 30', 'timeout': 3600},
          ),
        ]),
        _textTurn('answered after the hand-back'),
      ]);
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        foregroundCall: const ForegroundCallBudgetConfig(
          budget: Duration(seconds: 2),
          cancelGrace: Duration(milliseconds: 500),
        ),
        toolExecutor: (toolCall, cancelToken, onUpdate) =>
            tool.execute(toolCall.arguments, cancelToken, onUpdate),
      );
      agent.state.tools = [tool];
      final budgetEvents = <ToolCallBudgetEvent>[];
      agent.subscribe((event, token) async {
        if (event is ToolCallBudgetEvent) budgetEvents.add(event);
      });

      final sw = Stopwatch()..start();
      await agent.prompt('run the long thing');
      final elapsed = sw.elapsed;

      // Bounded unreachability: the whole turn settles at ~B, not at the
      // command's runtime (30s) — and never past the budget + grace slack.
      expect(elapsed < const Duration(seconds: 15), isTrue);

      // The still-running command was backgrounded untouched: the tool
      // result is the hand-back (job id + log path), never a kill, marked
      // by the budget announcement.
      final resultText = agent.state.messages
          .whereType<ToolResultMessage>()
          .firstWhere((m) => m.toolCallId == 'c1')
          .content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join('\n');
      expect(resultText, contains('moved to background job'));
      expect(resultText, contains('Log: '));
      expect(resultText, contains('[foreground-budget]'));

      // The budget ladder announced what it did (AC6): the force rung with
      // the reversible background outcome.
      expect(budgetEvents, isNotEmpty);
      expect(
        budgetEvents.every((e) => e.detail.startsWith('[foreground-budget]')),
        isTrue,
      );
      expect(
        budgetEvents.where(
          (e) => e.action == ForegroundBudgetAction.background,
        ),
        isNotEmpty,
      );

      // The turn continued after the escalation: the follow-up text turn
      // answered.
      final answers = agent.state.messages
          .whereType<AssistantMessage>()
          .where((m) => m.stopReason == StopReason.stop)
          .length;
      expect(answers, greaterThanOrEqualTo(1));
    },
  );
}
