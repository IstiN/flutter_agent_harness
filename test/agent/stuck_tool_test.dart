import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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
  final contexts = <Context>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

Tool _tool(String name) {
  return Tool(name: name, description: '$name tool', parameters: const {});
}

typedef _TestExecutor =
    Future<ToolExecutionResult> Function(
      int attempt,
      ToolUpdateCallback? onUpdate,
      CancelToken? cancelToken,
    );

final class _SupervisedRunOutcome {
  _SupervisedRunOutcome(this.resultText, this.heartbeats, this.stuckEvents);

  final String resultText;
  final List<ToolCallHeartbeatEvent> heartbeats;
  final List<ToolCallStuckEvent> stuckEvents;
}

/// Stuck-call supervision (gh-1054): heartbeats while a tool call runs past
/// its threshold, then — in autonomous mode — cancel + retry once, then
/// background conversion, then a session-visible escalation. Never a silent
/// 10-minute wait for the external watchdog.
void main() {
  group('StuckToolConfig thresholds', () {
    test(
      'threshold is the greater of (factor × declared timeout) and floor',
      () {
        const config = StuckToolConfig(
          floor: Duration(seconds: 300),
          declaredTimeoutFactor: 2,
        );
        // A declared 15-minute call is not pestered before 30 minutes.
        expect(
          config.stuckThreshold(const Duration(minutes: 15)),
          const Duration(minutes: 30),
        );
        // Anything without a declared timeout uses the absolute floor.
        expect(config.stuckThreshold(null), const Duration(seconds: 300));
        // A small declared timeout still gets the floor.
        expect(
          config.stuckThreshold(const Duration(seconds: 30)),
          const Duration(seconds: 300),
        );
      },
    );

    test('heartbeats start at half the threshold — before the follow-up', () {
      const config = StuckToolConfig(
        floor: Duration(seconds: 300),
        declaredTimeoutFactor: 2,
      );
      // Declared 15 min: heartbeats from 15 min (its own declared bound —
      // "running past its own declared bound"), follow-up at 30 min.
      expect(
        config.heartbeatStart(const Duration(minutes: 15)),
        const Duration(minutes: 15),
      );
      // No declared timeout: heartbeats from half the floor.
      expect(config.heartbeatStart(null), const Duration(seconds: 150));
    });

    test('default exclude list keeps user-interaction and subagent tools '
        'out of supervision', () {
      const config = StuckToolConfig();
      expect(config.excludes('ask'), isTrue);
      expect(config.excludes('request_secret'), isTrue);
      expect(config.excludes('task'), isTrue);
      expect(config.excludes('bash'), isFalse);
      expect(config.excludes('mcp__server__tool'), isFalse);
    });

    test('yaml round-trip keeps non-default values', () {
      const config = StuckToolConfig(
        floor: Duration(seconds: 42),
        declaredTimeoutFactor: 3,
        heartbeatInterval: Duration(seconds: 7),
        cancelGrace: Duration(seconds: 1),
        followUp: StuckFollowUpMode.advisory,
        enabled: false,
        excludeTools: ['task', 'ask'],
      );
      final restored = StuckToolConfig.fromYaml(config.toYamlMap());
      expect(restored.floor, config.floor);
      expect(restored.declaredTimeoutFactor, config.declaredTimeoutFactor);
      expect(restored.heartbeatInterval, config.heartbeatInterval);
      expect(restored.cancelGrace, config.cancelGrace);
      expect(restored.followUp, config.followUp);
      expect(restored.enabled, config.enabled);
      expect(restored.excludeTools, config.excludeTools);
    });

    test('yaml parse is strict', () {
      expect(
        () => StuckToolConfig.fromYaml({'floorSeconds': 10, 'unknown': true}),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => StuckToolConfig.fromYaml({'floorSeconds': 'ten'}),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => StuckToolConfig.fromYaml({'floorSeconds': -1}),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => StuckToolConfig.fromYaml({'followUp': 'sometimes'}),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => StuckToolConfig.fromYaml({'heartbeatSeconds': 0}),
        throwsA(isA<ConfigException>()),
      );
      // A zero cancel grace stays legal — the grace gate handles it.
      expect(
        StuckToolConfig.fromYaml({'cancelGraceSeconds': 0}).cancelGrace,
        Duration.zero,
      );
    });
  });

  group('stuck-call supervision in the agent loop', () {
    const stuck = StuckToolConfig(
      floor: Duration(milliseconds: 300),
      declaredTimeoutFactor: 2,
      heartbeatInterval: Duration(milliseconds: 60),
      cancelGrace: Duration(milliseconds: 120),
    );

    Future<_SupervisedRunOutcome> runSupervisedTurn({
      required _TestExecutor executor,
      List<ToolCall> calls = const [
        ToolCall(id: 'c1', name: 'bash', arguments: {'command': 'long-thing'}),
      ],
      StuckToolConfig config = stuck,
      String registeredTool = 'bash',
    }) async {
      final fake = _FakeStreamFunction([
        _toolTurn(calls),
        _textTurn('done answering'),
      ]);
      // Invocation count per call id: the supervisor retries the SAME tool
      // call, so attempt N is invocation N of that id.
      final attempts = <String, int>{};
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        stuckTool: config,
        toolExecutor: (toolCall, cancelToken, onUpdate) {
          final attempt = (attempts[toolCall.id] ?? 0) + 1;
          attempts[toolCall.id] = attempt;
          return executor(attempt, onUpdate, cancelToken);
        },
      );
      agent.state.tools = [_tool(registeredTool)];
      final heartbeats = <ToolCallHeartbeatEvent>[];
      final stuckEvents = <ToolCallStuckEvent>[];
      agent.subscribe((event, token) async {
        if (event is ToolCallHeartbeatEvent) heartbeats.add(event);
        if (event is ToolCallStuckEvent) stuckEvents.add(event);
      });
      await agent.prompt('run the long thing');
      final result = agent.state.messages
          .whereType<ToolResultMessage>()
          .firstWhere((m) => m.toolCallId == 'c1');
      return _SupervisedRunOutcome(
        [
          for (final block in result.content)
            if (block is TextContent) block.text,
        ].join('\n'),
        heartbeats,
        stuckEvents,
      );
    }

    test(
      'AC1: a hanging call emits heartbeat records while it is outstanding',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final outcome = await runSupervisedTurn(
          config: const StuckToolConfig(
            floor: Duration(milliseconds: 500),
            declaredTimeoutFactor: 2,
            heartbeatInterval: Duration(milliseconds: 80),
            cancelGrace: Duration(milliseconds: 100),
          ),
          executor: (attempt, onUpdate, _) async {
            // Hangs forever, honors nothing: attempt 1 is cancelled+retried,
            // attempt 2 escalates.
            await Completer<void>().future;
            throw StateError('hangs forever');
          },
        );
        // Heartbeats during the outstanding call, naming the tool.
        expect(outcome.heartbeats.length, greaterThanOrEqualTo(2));
        expect(outcome.heartbeats.every((h) => h.toolName == 'bash'), isTrue);
        // Heartbeats only start at half the threshold (250ms) — never before.
        expect(
          outcome.heartbeats.every(
            (h) => h.elapsed >= const Duration(milliseconds: 250),
          ),
          isTrue,
        );
      },
    );

    test(
      'AC2: at the threshold the stuck call is cancelled and retried once '
      'with a marked result',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final outcome = await runSupervisedTurn(
          executor: (attempt, onUpdate, _) async {
            if (attempt == 1) {
              // Ignores the cancel token entirely (a wedged exec).
              await Completer<void>().future;
            }
            return ToolExecutionResult.text('retry output');
          },
        );
        expect(
          outcome.stuckEvents.map((e) => e.action),
          contains(StuckFollowUpAction.cancelRetry),
        );
        expect(outcome.resultText, contains('retry output'));
        expect(outcome.resultText, contains('[stuck-call]'));
        expect(
          outcome.stuckEvents.any(
            (e) => e.action == StuckFollowUpAction.escalate,
          ),
          isFalse,
        );
      },
    );

    test(
      'AC2 (token-obeying executor): an abort-shaped throw at the '
      'supervisor cancel never short-circuits the marked retry — the real '
      'bash shape (`Command aborted` once the job registry kills the '
      'process), not just a cancel-ignoring zombie',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final outcome = await runSupervisedTurn(
          config: const StuckToolConfig(
            floor: Duration(milliseconds: 240),
            declaredTimeoutFactor: 2,
            heartbeatInterval: Duration(milliseconds: 60),
            cancelGrace: Duration(milliseconds: 400),
          ),
          executor: (attempt, onUpdate, cancelToken) async {
            if (attempt == 1) {
              // Answers the supervisor's cancel with the bash failure
              // shape instead of hanging past the cancel grace.
              await cancelToken?.onCancel;
              throw StateError('Command aborted');
            }
            return ToolExecutionResult.text('retry completed fine');
          },
        );
        expect(
          outcome.stuckEvents.map((e) => e.action),
          contains(StuckFollowUpAction.cancelRetry),
        );
        expect(outcome.resultText, contains('retry completed fine'));
        expect(outcome.resultText, contains('[stuck-call]'));
        expect(outcome.resultText, contains('retried once'));
        expect(
          outcome.stuckEvents.any(
            (e) => e.action == StuckFollowUpAction.escalate,
          ),
          isFalse,
        );
      },
    );

    test(
      'AC4 (token-obeying retry): a retry that throws at its yield cancel '
      'instead of handing back still escalates session-visibly',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final outcome = await runSupervisedTurn(
          config: const StuckToolConfig(
            floor: Duration(milliseconds: 240),
            declaredTimeoutFactor: 2,
            heartbeatInterval: Duration(milliseconds: 60),
            cancelGrace: Duration(milliseconds: 400),
          ),
          executor: (attempt, onUpdate, cancelToken) async {
            if (attempt == 1) {
              await cancelToken?.onCancel;
              throw StateError('Command aborted');
            }
            final yieldToken = currentYieldToken();
            if (yieldToken != null) {
              await yieldToken.onCancel;
            }
            throw StateError('yield abort');
          },
        );
        final escalation = outcome.stuckEvents.firstWhere(
          (e) => e.action == StuckFollowUpAction.escalate,
        );
        expect(escalation.elapsed, greaterThan(Duration.zero));
        // The escalation names WHY the retry failed, not just that it did.
        expect(escalation.detail, contains('yield abort'));
        expect(outcome.resultText, contains('[stuck-call escalation]'));
        expect(outcome.resultText, contains('bash'));
      },
    );

    test(
      'AC3: a retry that hangs again is converted to a background job '
      'and the turn continues with the job id + log path',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final outcome = await runSupervisedTurn(
          executor: (attempt, onUpdate, _) async {
            // Yield-aware like the bash tool over a jobs-capable env: on the
            // yield cancel it hands the call back as a background conversion.
            final yieldToken = currentYieldToken();
            if (attempt == 2 && yieldToken != null) {
              await yieldToken.onCancel;
              return ToolExecutionResult.text(
                'The command is still running and was moved to background job '
                'sh-9-x (the process was NOT killed).\n'
                'Log: /work/.fah/bash_jobs/sh-9-x.log',
              );
            }
            await Completer<void>().future;
            throw StateError('unreachable');
          },
        );
        expect(
          outcome.stuckEvents.map((e) => e.action),
          contains(StuckFollowUpAction.backgroundConvert),
        );
        expect(outcome.resultText, contains('sh-9-x'));
        expect(outcome.resultText, contains('/work/.fah/bash_jobs/sh-9-x.log'));
        expect(outcome.resultText, contains('[stuck-call]'));
        expect(
          outcome.stuckEvents.any(
            (e) => e.action == StuckFollowUpAction.escalate,
          ),
          isFalse,
        );
      },
    );

    test(
      'AC4: when recovery fails an escalation names the call, the elapsed '
      'time, and the partial output',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final outcome = await runSupervisedTurn(
          executor: (attempt, onUpdate, _) async {
            // Reports some partial output, then hangs forever ignoring every
            // cancel: recovery cannot succeed.
            onUpdate?.call(ToolExecutionResult.text('partial boot log line'));
            await Completer<void>().future;
            throw StateError('hangs forever');
          },
        );
        final escalation = outcome.stuckEvents.firstWhere(
          (e) => e.action == StuckFollowUpAction.escalate,
        );
        expect(escalation.toolName, 'bash');
        expect(escalation.elapsed, greaterThan(Duration.zero));
        expect(escalation.detail, contains('partial boot log'));
        // The result is a marked error result naming the elapsed time.
        expect(outcome.resultText, contains('[stuck-call escalation]'));
        expect(outcome.resultText, contains('bash'));
      },
    );

    test(
      'AC6: a legitimately long call (declared timeout) emits heartbeats '
      'but is NOT cancelled before its declared timeout + margin',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final outcome = await runSupervisedTurn(
          config: const StuckToolConfig(
            floor: Duration(milliseconds: 200),
            declaredTimeoutFactor: 2,
            heartbeatInterval: Duration(milliseconds: 60),
            cancelGrace: Duration(milliseconds: 100),
          ),
          calls: const [
            ToolCall(
              id: 'c1',
              name: 'bash',
              arguments: {'command': 'flutter test', 'timeout': 0.4},
            ),
          ],
          executor: (attempt, onUpdate, _) async {
            await Future<void>.delayed(const Duration(milliseconds: 560));
            onUpdate?.call(ToolExecutionResult.text('tests still running...'));
            return ToolExecutionResult.text('all tests passed');
          },
        );
        // No stuck action at all: the call finished inside its threshold
        // (2 × 0.4s declared = 0.8s).
        expect(outcome.stuckEvents, isEmpty);
        // But it WAS long enough to heartbeat (past half the threshold =
        // 0.4s, its declared bound).
        expect(outcome.heartbeats, isNotEmpty);
        expect(outcome.resultText, 'all tests passed');
      },
    );

    test(
      'advisory mode: the threshold only advises, it never cancels',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        const config = StuckToolConfig(
          floor: Duration(milliseconds: 200),
          declaredTimeoutFactor: 2,
          heartbeatInterval: Duration(milliseconds: 50),
          cancelGrace: Duration(milliseconds: 100),
          followUp: StuckFollowUpMode.advisory,
        );
        final released = Completer<void>();
        final fake = _FakeStreamFunction([
          _toolTurn(const [
            ToolCall(id: 'c1', name: 'bash', arguments: {'command': 'x'}),
          ]),
          _textTurn('done'),
        ]);
        final agent = Agent(
          model: _model,
          streamFunction: fake.call,
          stuckTool: config,
          toolExecutor: (toolCall, cancelToken, onUpdate) async {
            await released.future;
            return ToolExecutionResult.text('finished eventually');
          },
        );
        agent.state.tools = [_tool('bash')];
        final stuckEvents = <ToolCallStuckEvent>[];
        agent.subscribe((event, token) async {
          if (event is ToolCallStuckEvent) stuckEvents.add(event);
        });
        final run = agent.prompt('run');
        // Wait until the advisory fired, then let the tool finish.
        await waitForIt(
          () =>
              stuckEvents.any((e) => e.action == StuckFollowUpAction.advisory),
          reason: 'advisory stuck event',
        );
        released.complete();
        await run;
        expect(
          stuckEvents.map((e) => e.action),
          contains(StuckFollowUpAction.advisory),
        );
        expect(
          stuckEvents.any((e) => e.action == StuckFollowUpAction.cancelRetry),
          isFalse,
        );
        final result = agent.state.messages
            .whereType<ToolResultMessage>()
            .firstWhere((m) => m.toolCallId == 'c1');
        expect(
          [
            for (final block in result.content)
              if (block is TextContent) block.text,
          ].join(),
          'finished eventually',
        );
      },
    );

    test(
      'output size rides the heartbeat when the tool reports updates',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final outcome = await runSupervisedTurn(
          config: const StuckToolConfig(
            floor: Duration(milliseconds: 300),
            declaredTimeoutFactor: 2,
            heartbeatInterval: Duration(milliseconds: 60),
            cancelGrace: Duration(milliseconds: 100),
          ),
          executor: (attempt, onUpdate, _) async {
            onUpdate?.call(ToolExecutionResult.text('0123456789'));
            await Completer<void>().future;
            throw StateError('hangs forever');
          },
        );
        expect(outcome.heartbeats, isNotEmpty);
        expect(outcome.heartbeats.any((h) => h.outputBytes >= 10), isTrue);
      },
    );

    test(
      'a zero cancel grace abandons the attempt immediately',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final outcome = await runSupervisedTurn(
          config: const StuckToolConfig(
            floor: Duration(milliseconds: 150),
            declaredTimeoutFactor: 2,
            heartbeatInterval: Duration(hours: 1),
            cancelGrace: Duration.zero,
          ),
          executor: (attempt, onUpdate, _) async {
            // Ignores the cancel token; the zero grace must still move the
            // follow-up forward without waiting.
            await Completer<void>().future;
            throw StateError('hangs forever');
          },
        );
        expect(
          outcome.stuckEvents.map((e) => e.action),
          containsAll([
            StuckFollowUpAction.cancelRetry,
            StuckFollowUpAction.escalate,
          ]),
        );
      },
    );

    test(
      'a user abort during supervision ends the run without a retry storm',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final fake = _FakeStreamFunction([
          _toolTurn(const [
            ToolCall(id: 'c1', name: 'bash', arguments: {'command': 'x'}),
          ]),
        ]);
        final agent = Agent(
          model: _model,
          streamFunction: fake.call,
          stuckTool: stuck,
          toolExecutor: (toolCall, cancelToken, onUpdate) async {
            await Completer<void>().future;
            throw StateError('hangs forever');
          },
        );
        agent.state.tools = [_tool('bash')];
        final stuckEvents = <ToolCallStuckEvent>[];
        agent.subscribe((event, token) async {
          if (event is ToolCallStuckEvent) stuckEvents.add(event);
        });
        final run = agent.prompt('run');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        agent.abort();
        await run;
        // The abort path never escalates into follow-up stages: at most the
        // first stuck fire, no background conversion after the abort.
        expect(
          stuckEvents.where(
            (e) => e.action == StuckFollowUpAction.backgroundConvert,
          ),
          isEmpty,
        );
      },
    );

    test(
      'excluded tools are never supervised',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        final fake = _FakeStreamFunction([
          _toolTurn(const [
            ToolCall(id: 'c1', name: 'ask', arguments: {'question': 'hi'}),
          ]),
          _textTurn('answered'),
        ]);
        var executions = 0;
        final agent = Agent(
          model: _model,
          streamFunction: fake.call,
          stuckTool: stuck,
          toolExecutor: (toolCall, cancelToken, onUpdate) async {
            executions++;
            // Far past the threshold — a supervised call would have been
            // cancelled and retried by now.
            await Future<void>.delayed(const Duration(milliseconds: 700));
            return ToolExecutionResult.text('ok');
          },
        );
        agent.state.tools = [_tool('ask')];
        final stuckEvents = <ToolCallStuckEvent>[];
        agent.subscribe((event, token) async {
          if (event is ToolCallStuckEvent) stuckEvents.add(event);
        });
        await agent.prompt('ask the user');
        expect(executions, 1);
        expect(stuckEvents, isEmpty);
      },
    );
    test(
      'advisory mode: a tool error after the threshold is the executor\'s '
      'own — rethrown with no retry and no follow-up record',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        // Issue review (gh-1054): `cancelledBySupervisor: stuckFired`
        // conflated "the threshold fired" with "the supervisor cancelled".
        // In advisory mode nothing is ever cancelled, so a self-failed
        // call must propagate as the plain tool error — never re-executed.
        var invocations = 0;
        final outcome = await runSupervisedTurn(
          config: const StuckToolConfig(
            floor: Duration(milliseconds: 200),
            declaredTimeoutFactor: 2,
            heartbeatInterval: Duration(milliseconds: 50),
            cancelGrace: Duration(milliseconds: 100),
            followUp: StuckFollowUpMode.advisory,
          ),
          executor: (attempt, onUpdate, _) async {
            invocations++;
            // Runs past the threshold (the advisory fires), then fails on
            // its own — the error is the executor's, not a cancel's.
            await Future<void>.delayed(const Duration(milliseconds: 350));
            throw StateError('self failure');
          },
        );
        expect(invocations, 1, reason: 'advisory never retries');
        expect(outcome.resultText, contains('self failure'));
        expect(outcome.resultText, isNot(contains('[stuck-call')));
        expect(
          {for (final event in outcome.stuckEvents) event.action},
          {StuckFollowUpAction.advisory},
          reason: 'no cancel_retry / escalate records in advisory mode',
        );
      },
    );

    test(
      'a call that completes right after the cancel lands no cancel_retry '
      'record — the retry never happened',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        // Issue review: the stage record fired at the threshold claimed
        // "cancelling and retrying once" even when the call then completed
        // on its own (the cancel raced a real completion). The record is
        // only truthful when the retry actually starts.
        final outcome = await runSupervisedTurn(
          executor: (attempt, onUpdate, cancelToken) async {
            // Cancel-obeying but finishing: on the supervisor's cancel it
            // returns the (just-completed) work instead of aborting.
            if (cancelToken != null) await cancelToken.onCancel;
            return ToolExecutionResult.text('late completion');
          },
        );
        expect(outcome.resultText, contains('late completion'));
        expect(outcome.resultText, isNot(contains('[stuck-call')));
        expect(
          outcome.stuckEvents.where(
            (e) => e.action == StuckFollowUpAction.cancelRetry,
          ),
          isEmpty,
          reason: 'no retry started — no cancel_retry record',
        );
      },
    );

    test(
      'a retry that self-completes past the threshold is not marked as a '
      'background conversion',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        // Issue review: the attempt-2 completion mark claimed "converted to
        // a background job" even when the tool ignored the yield token and
        // finished its own work inside the grace window.
        final outcome = await runSupervisedTurn(
          executor: (attempt, onUpdate, cancelToken) async {
            if (attempt == 1) {
              // Wedged: cancelled and retried.
              await Completer<void>().future;
            }
            // The retry ignores the yield token entirely and just finishes
            // (past the threshold, inside the cancel grace).
            await Future<void>.delayed(const Duration(milliseconds: 340));
            return ToolExecutionResult.text('real work output');
          },
        );
        expect(outcome.resultText, contains('real work output'));
        expect(
          outcome.resultText,
          isNot(contains('converted to a background job')),
          reason: 'the retry completed its own work — no conversion happened',
        );
        expect(
          outcome.resultText,
          contains('retried once'),
          reason: 'the truthful mark: attempt 1 was cancelled and retried',
        );
      },
    );

    test(
      'a declared timeout is honored for bash only — a stray timeout arg '
      'on another tool cannot suppress supervision',
      timeout: const Timeout(Duration(seconds: 30)),
      () async {
        // Issue review: `_declaredTimeoutOf` read `timeout` as seconds for
        // every tool; a tool whose schema has no such arg (or uses another
        // unit) would inflate its threshold to factor × arg and never be
        // supervised. Only bash declares a seconds-based `timeout`.
        final outcome = await runSupervisedTurn(
          registeredTool: 'read',
          calls: const [
            ToolCall(
              id: 'c1',
              name: 'read',
              arguments: {'path': 'x', 'timeout': 30},
            ),
          ],
          executor: (attempt, onUpdate, _) async {
            // Far past the floor (300ms) but far under factor × 30s.
            await Future<void>.delayed(const Duration(milliseconds: 700));
            return ToolExecutionResult.text('ok');
          },
        );
        expect(
          outcome.stuckEvents.map((e) => e.action),
          contains(StuckFollowUpAction.cancelRetry),
          reason: 'the floor, not 2×30s, is the threshold for non-bash tools',
        );
      },
    );
  });
}

/// Polls an async [condition] like the CLI suite's [waitForIt].
Future<void> waitForIt(
  FutureOr<bool> Function() condition, {
  String? reason,
}) async {
  for (var i = 0; i < 5000; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}
