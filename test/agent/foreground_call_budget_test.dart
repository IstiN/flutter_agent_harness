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

const _c1Bash = ToolCall(
  id: 'c1',
  name: 'bash',
  arguments: {'command': 'long-thing'},
);

/// All budget events raised by every group — the UT-6 formatter sweep runs
/// over this at the end.
final _allBudgetEvents = <ToolCallBudgetEvent>[];

/// A loop-level run started but not yet awaited: the test interacts with the
/// in-flight call (observing events, poking controls) before draining [done].
final class _LoopRun {
  _LoopRun(this.done, this.events, this.fake);

  final Future<List<Message>> done;
  final List<AgentEvent> events;
  final _FakeStreamFunction fake;
}

_LoopRun _startBudgetLoop({
  required _TestExecutor executor,
  List<ToolCall> calls = const [_c1Bash],
  ForegroundCallBudgetConfig budget = const ForegroundCallBudgetConfig(
    budget: Duration(milliseconds: 300),
    cancelGrace: Duration(milliseconds: 60),
  ),
  int Function()? pendingSteeringCount,
  QueuedMessagesSource? getSteeringMessages,
}) {
  final fake = _FakeStreamFunction([
    _toolTurn(calls),
    _textTurn('done answering'),
  ]);
  final events = <AgentEvent>[];
  final done = runAgentLoop(
    prompts: [UserMessage.text('run the long thing')],
    context: Context(
      systemPrompt: 'test system prompt',
      messages: const [],
      tools: [_tool('bash')],
    ),
    config: AgentLoopConfig(
      model: _model,
      foregroundCallBudget: budget,
      pendingSteeringCount: pendingSteeringCount,
      getSteeringMessages: getSteeringMessages,
    ),
    streamFunction: fake.call,
    toolExecutor: (toolCall, cancelToken, onUpdate) =>
        executor(1, onUpdate, cancelToken),
    emit: (event) async {
      if (event is ToolCallBudgetEvent) _allBudgetEvents.add(event);
      events.add(event);
    },
  );
  return _LoopRun(done, events, fake);
}

Iterable<ToolCallBudgetEvent> _budgetEvents(_LoopRun run) =>
    run.events.whereType<ToolCallBudgetEvent>();

String _resultText(List<Message> messages, {String toolCallId = 'c1'}) {
  final result = messages.whereType<ToolResultMessage>().firstWhere(
    (m) => m.toolCallId == toolCallId,
  );
  return [
    for (final block in result.content)
      if (block is TextContent) block.text,
  ].join('\n');
}

/// An [Agent]-level supervised turn, cloned from stuck_tool_test's
/// `runSupervisedTurn`: one tool turn, one text turn, event collectors.
final class _AgentRun {
  _AgentRun(this.agent, this.fake, this.budgetEvents, this.stuckEvents);

  final Agent agent;
  final _FakeStreamFunction fake;
  final List<ToolCallBudgetEvent> budgetEvents;
  final List<ToolCallStuckEvent> stuckEvents;
}

Future<_AgentRun> _runBudgetTurn({
  required _TestExecutor executor,
  List<ToolCall> calls = const [_c1Bash],
  ForegroundCallBudgetConfig? budget,
  StuckToolConfig? stuck,
}) async {
  final fake = _FakeStreamFunction([
    _toolTurn(calls),
    _textTurn('done answering'),
  ]);
  final agent = Agent(
    model: _model,
    streamFunction: fake.call,
    stuckTool: stuck,
    foregroundCall: budget,
    toolExecutor: (toolCall, cancelToken, onUpdate) =>
        executor(1, onUpdate, cancelToken),
  );
  agent.state.tools = [_tool('bash')];
  final budgetEvents = <ToolCallBudgetEvent>[];
  final stuckEvents = <ToolCallStuckEvent>[];
  agent.subscribe((event, token) async {
    if (event is ToolCallBudgetEvent) {
      budgetEvents.add(event);
      _allBudgetEvents.add(event);
    }
    if (event is ToolCallStuckEvent) stuckEvents.add(event);
  });
  await agent.prompt('run the long thing');
  return _AgentRun(agent, fake, budgetEvents, stuckEvents);
}

/// Foreground tool-call budget (issue #1786): the Escalation Ladder over the
/// wall-clock budget B for every running foreground tool call. Config is
/// strict, rung 1 (B/2) needs silence + pending steering, rung 2 (B) fires
/// regardless, escalation picks background hand-back over abort when the
/// tool is yield-aware, a user abort always wins (E3), and every action is
/// announced with the `[foreground-budget]` REG-1 mark.
void main() {
  group('config parsing (UT-2)', () {
    test('defaults: B is 600s, offerAt is B/2, autoConvert is off', () {
      final config = ForegroundCallBudgetConfig.fromLeaves();
      expect(config.budget, const Duration(seconds: 600));
      expect(config.offerAt, const Duration(seconds: 300));
      expect(config.autoConvert, isFalse);
    });

    test('explicit leaves parse: 300 seconds and auto', () {
      final config = ForegroundCallBudgetConfig.fromLeaves(
        budgetSeconds: 300,
        autoConvert: 'auto',
      );
      expect(config.budget, const Duration(seconds: 300));
      expect(config.autoConvert, isTrue);
      expect(
        ForegroundCallBudgetConfig.fromLeaves(autoConvert: 'offer').autoConvert,
        isFalse,
      );
    });

    test('rejects 0 / negative / non-int / map budgets with the '
        'positive-integer message (per-tool map is the second-tier shape)', () {
      for (final bad in [
        0,
        -5,
        1.5,
        <String, Object>{'bash': 60},
      ]) {
        expect(
          () => ForegroundCallBudgetConfig.fromLeaves(budgetSeconds: bad),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('must be a positive integer'),
            ),
          ),
          reason: 'rejected: $bad',
        );
      }
    });

    test('rejects unknown autoConvert strings and non-string autoConvert', () {
      expect(
        () => ForegroundCallBudgetConfig.fromLeaves(autoConvert: ' Automatic '),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('must be "offer" or "auto"'),
          ),
        ),
        reason: 'the strict parse does not trim or case-fold',
      );
      expect(
        () => ForegroundCallBudgetConfig.fromLeaves(autoConvert: 'sometimes'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => ForegroundCallBudgetConfig.fromLeaves(autoConvert: true),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('must be a string'),
          ),
        ),
      );
    });
  });

  group('ladder timing (UT-1, real ms timers)', () {
    test('UT-1a: silent call + steering pending surfaces the offer exactly '
        'once and the call keeps running (no cancel)', () async {
      final executorStarted = Completer<void>();
      final release = Completer<void>();
      CancelToken? seenCallToken;
      final run = _startBudgetLoop(
        pendingSteeringCount: () => 1,
        getSteeringMessages: () async => [UserMessage.text('are you stuck?')],
        executor: (attempt, onUpdate, cancelToken) async {
          executorStarted.complete();
          seenCallToken = cancelToken;
          await release.future;
          return ToolExecutionResult.text('finished after the offer');
        },
      );
      await executorStarted.future;
      await waitForIt(
        () => _budgetEvents(
          run,
        ).any((e) => e.action == ForegroundBudgetAction.offer),
        reason: 'rung-1 offer event',
      );
      // Purely advisory: the call is still running, untouched.
      expect(seenCallToken!.isCancelled, isFalse);
      final offers = _budgetEvents(
        run,
      ).where((e) => e.action == ForegroundBudgetAction.offer).toList();
      expect(offers, hasLength(1));
      expect(offers.single.rung, ForegroundBudgetRung.offer);
      expect(offers.single.steeringCount, 1);
      expect(offers.single.toolName, 'bash');

      release.complete();
      final messages = await run.done;
      // The offer never touched the result: clean, unmarked.
      expect(_resultText(messages), 'finished after the offer');
      expect(_budgetEvents(run), hasLength(1));
    });

    test('E8: output activity kills the offer condition, but rung 2 still '
        'fires at B regardless of output', () async {
      final run = _startBudgetLoop(
        pendingSteeringCount: () => 1,
        executor: (attempt, onUpdate, cancelToken) async {
          onUpdate?.call(ToolExecutionResult.text('partial progress line'));
          await Completer<void>().future;
          throw StateError('zombie');
        },
      );
      final messages = await run.done;
      final events = _budgetEvents(run).toList();
      expect(
        events.any((e) => e.action == ForegroundBudgetAction.offer),
        isFalse,
        reason: 'E8: a call with output is never offered',
      );
      expect(events, hasLength(1));
      expect(events.single.rung, ForegroundBudgetRung.force);
      expect(events.single.action, ForegroundBudgetAction.abort);
      final text = _resultText(messages);
      expect(text, contains('[foreground-budget]'));
      expect(text, contains('partial progress line'));
    });

    test('E2: an empty steering FIFO skips rung 1 entirely; rung 2 still '
        'escalates at B', () async {
      final run = _startBudgetLoop(
        pendingSteeringCount: () => 0,
        executor: (attempt, onUpdate, cancelToken) async {
          await Completer<void>().future;
          throw StateError('zombie');
        },
      );
      final messages = await run.done;
      final events = _budgetEvents(run).toList();
      expect(
        events.any((e) => e.action == ForegroundBudgetAction.offer),
        isFalse,
        reason: 'E2: no steering pending, no offer',
      );
      expect(events, hasLength(1));
      expect(events.single.rung, ForegroundBudgetRung.force);
      expect(events.single.action, ForegroundBudgetAction.abort);
      expect(_resultText(messages), contains('[foreground-budget]'));
      expect(_resultText(messages), isNot(contains('Partial output so far')));
    });

    test('autoConvert converts at B/2 instead of offering: a yield-obeying '
        'call is backgrounded with a rung-offer background record', () async {
      final run = _startBudgetLoop(
        budget: const ForegroundCallBudgetConfig(
          budget: Duration(milliseconds: 300),
          cancelGrace: Duration(milliseconds: 60),
          autoConvert: true,
        ),
        pendingSteeringCount: () => 1,
        executor: (attempt, onUpdate, cancelToken) async {
          // Bash shape over a jobs-capable env: the yield cancel asks the
          // call to hand back as a background job.
          final yieldToken = currentYieldToken();
          if (yieldToken != null) await yieldToken.onCancel;
          return ToolExecutionResult.text(
            stuckBackgroundHandbackText(
              jobId: 'sh-b1',
              logPath: '/tmp/sh-b1.log',
              supervisorMoved: false,
            ),
          );
        },
      );
      final messages = await run.done;
      final events = _budgetEvents(run).toList();
      expect(
        events.any((e) => e.action == ForegroundBudgetAction.offer),
        isFalse,
        reason: 'autoConvert converts instead of asking',
      );
      expect(events, hasLength(1));
      expect(events.single.rung, ForegroundBudgetRung.offer);
      expect(events.single.action, ForegroundBudgetAction.background);
      final text = _resultText(messages);
      expect(text, contains('[foreground-budget]'));
      expect(text, contains(stuckBackgroundHandbackSentence));
      expect(text, contains('sh-b1'));
    });

    test('rung 2 fires at B regardless (IT-3): a zombie call is aborted '
        'with the captured partial output on the error result', () async {
      final run = _startBudgetLoop(
        pendingSteeringCount: () => 1,
        executor: (attempt, onUpdate, cancelToken) async {
          onUpdate?.call(ToolExecutionResult.text('boot log line'));
          await Completer<void>().future;
          throw StateError('zombie');
        },
      );
      final messages = await run.done;
      final events = _budgetEvents(run).toList();
      expect(events, hasLength(1));
      expect(events.single.rung, ForegroundBudgetRung.force);
      expect(events.single.action, ForegroundBudgetAction.abort);
      final text = _resultText(messages);
      expect(text, contains('[foreground-budget]'));
      expect(text, contains('Partial output so far'));
      expect(text, contains('boot log line'));
    });

    test('E1: a call that returns before B leaves no budget events at all '
        'and a clean result', () async {
      final run = _startBudgetLoop(
        pendingSteeringCount: () => 0,
        executor: (attempt, onUpdate, cancelToken) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return ToolExecutionResult.text('clean result');
        },
      );
      final messages = await run.done;
      expect(_budgetEvents(run), isEmpty);
      expect(_resultText(messages), 'clean result');
    });
  });

  group('fallback selection (UT-3)', () {
    test('a yield-obeying tool hands back at B: background record + the '
        'hand-back result marked', () async {
      final run = _startBudgetLoop(
        executor: (attempt, onUpdate, cancelToken) async {
          final yieldToken = currentYieldToken();
          if (yieldToken != null) await yieldToken.onCancel;
          return ToolExecutionResult.text(
            stuckBackgroundHandbackText(
              jobId: 'sh-f1',
              logPath: '/tmp/sh-f1.log',
              supervisorMoved: false,
            ),
          );
        },
      );
      final messages = await run.done;
      final events = _budgetEvents(run).toList();
      expect(events, hasLength(1));
      expect(events.single.rung, ForegroundBudgetRung.force);
      expect(events.single.action, ForegroundBudgetAction.background);
      final text = _resultText(messages);
      expect(text, contains(stuckBackgroundHandbackSentence));
      expect(text, contains('[foreground-budget]'));
      final result = messages.whereType<ToolResultMessage>().firstWhere(
        (m) => m.toolCallId == 'c1',
      );
      expect(result.isError, isFalse);
    });

    test('a token-ignoring tool cannot hand back at B: abort record + the '
        'StateError-derived error result', () async {
      final run = _startBudgetLoop(
        executor: (attempt, onUpdate, cancelToken) async {
          await Completer<void>().future;
          throw StateError('zombie');
        },
      );
      final messages = await run.done;
      final events = _budgetEvents(run).toList();
      expect(events, hasLength(1));
      expect(events.single.rung, ForegroundBudgetRung.force);
      expect(events.single.action, ForegroundBudgetAction.abort);
      final text = _resultText(messages);
      expect(text, contains('Tool error (bash)'));
      expect(text, contains('[foreground-budget]'));
      final result = messages.whereType<ToolResultMessage>().firstWhere(
        (m) => m.toolCallId == 'c1',
      );
      expect(result.isError, isTrue);
    });

    test('a rewrite-notice-prefixed hand-back still classifies as a '
        'background conversion (gh-1835 review)', () async {
      // The secret-shape interceptor prepends its notice to the hand-back
      // text (issue #1408): the anchor classification must skip that one
      // leading notice line, or the budget ladder reads a real conversion
      // as an ordinary completion (the stuck supervisor's reclassification
      // uses the same predicate).
      final run = _startBudgetLoop(
        executor: (attempt, onUpdate, cancelToken) async {
          final yieldToken = currentYieldToken();
          if (yieldToken != null) await yieldToken.onCancel;
          return ToolExecutionResult.text(
            '[bash interceptor rewrote 1 secret-shaped value in the '
            'command (GitHub Token) — the executed command carries the '
            '[REDACTED:GitHub Token] marker.]\n'
            '${stuckBackgroundHandbackText(
              jobId: 'sh-rw1',
              logPath: '/tmp/sh-rw1.log',
              supervisorMoved: false,
            )}',
          );
        },
      );
      final messages = await run.done;
      final events = _budgetEvents(run).toList();
      expect(events, hasLength(1));
      expect(events.single.rung, ForegroundBudgetRung.force);
      expect(events.single.action, ForegroundBudgetAction.background);
      final text = _resultText(messages);
      expect(text, contains(stuckBackgroundHandbackSentence));
      final result = messages.whereType<ToolResultMessage>().firstWhere(
        (m) => m.toolCallId == 'c1',
      );
      expect(result.isError, isFalse);
    });
  });

  group('token propagation (UT-5/IT-5, AC5 + E3)', () {
    test(
      'AC5: agent.abort() cancels the in-flight call token within the '
      'cancel grace, and E3: no budget event fires after the abort',
      () async {
        final fake = _FakeStreamFunction([
          _toolTurn(const [_c1Bash]),
        ]);
        CancelToken? seenCallToken;
        final cancelObserved = Completer<Duration>();
        final agent = Agent(
          model: _model,
          streamFunction: fake.call,
          foregroundCall: const ForegroundCallBudgetConfig(
            budget: Duration(milliseconds: 400),
            cancelGrace: Duration(milliseconds: 200),
          ),
          toolExecutor: (toolCall, cancelToken, onUpdate) async {
            seenCallToken = cancelToken;
            final sinceStart = Stopwatch()..start();
            cancelToken!.onCancel.then((_) {
              cancelObserved.complete(sinceStart.elapsed);
            });
            await cancelObserved.future;
            return ToolExecutionResult.text('wrapped up after cancel');
          },
        );
        agent.state.tools = [_tool('bash')];
        final budgetEvents = <ToolCallBudgetEvent>[];
        agent.subscribe((event, token) async {
          if (event is ToolCallBudgetEvent) budgetEvents.add(event);
        });
        final run = agent.prompt('run the long thing');
        await waitForIt(
          () => seenCallToken != null,
          reason: 'executor started with a call token',
        );
        agent.abort();
        final observed = await cancelObserved.future;
        // The run token → call token link fires the call's cancel well inside
        // the budget's cancel grace — not at some later stage boundary.
        expect(observed.inMilliseconds, lessThan(200));
        expect(seenCallToken!.isCancelled, isTrue);
        await run;
        // E3: esc wins — the ladder is disarmed with the run; no offer, no
        // post-abort auto-convert, no budget record of any kind.
        expect(budgetEvents, isEmpty);
      },
    );
  });

  group('accept offer (IT-2, AC2)', () {
    test('the one-key accept escalates the offered call and the queued '
        'steering is delivered into the next turn', () async {
      final fake = _FakeStreamFunction([
        _toolTurn(const [_c1Bash]),
        _textTurn('answering the user now'),
      ]);
      final controls = ForegroundCallBudgetControls();
      final executorStarted = Completer<void>();
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        foregroundCall: const ForegroundCallBudgetConfig(
          budget: Duration(milliseconds: 300),
          cancelGrace: Duration(milliseconds: 60),
        ),
        // Token-ignoring on purpose: the soft-yield from steer() must not
        // resolve the call, so the ladder's accept path is what ends it.
        toolExecutor: (toolCall, cancelToken, onUpdate) async {
          executorStarted.complete();
          await Completer<void>().future;
          throw StateError('unreachable zombie');
        },
      );
      agent.state.tools = [_tool('bash')];
      agent.foregroundBudgetControls = controls;
      final budgetEvents = <ToolCallBudgetEvent>[];
      agent.subscribe((event, token) async {
        if (event is ToolCallBudgetEvent) {
          budgetEvents.add(event);
          _allBudgetEvents.add(event);
        }
      });
      final run = agent.prompt('go');
      await executorStarted.future;
      agent.steer(UserMessage.text('are you stuck?'));
      await waitForIt(
        () => budgetEvents.any((e) => e.action == ForegroundBudgetAction.offer),
        reason: 'rung-1 offer',
      );
      final offer = budgetEvents.firstWhere(
        (e) => e.action == ForegroundBudgetAction.offer,
      );
      expect(offer.rung, ForegroundBudgetRung.offer);
      expect(offer.steeringCount, 1);
      expect(controls.acceptOffer(offer.toolCallId), isTrue);
      await run;

      // The zombie ignored its tokens: the accept-classified escalation is
      // the abort path, at the offer rung.
      expect(
        budgetEvents.any(
          (e) =>
              e.action == ForegroundBudgetAction.abort &&
              e.rung == ForegroundBudgetRung.offer,
        ),
        isTrue,
      );
      // The queued steering drained into the next model turn.
      expect(fake.calls, 2);
      expect(
        (fake.contexts[1].messages.last as UserMessage).content,
        'are you stuck?',
      );
      expect(
        agent.state.messages.whereType<UserMessage>().any(
          (m) => m.content == 'are you stuck?',
        ),
        isTrue,
      );
      // The offer is gone once the call ended.
      expect(controls.acceptOffer('c1'), isFalse);
    });
  });

  group('watchdog hook (rung 3)', () {
    test('steering pending + silent call: requestOffer surfaces a '
        'watchdog-rung offer and returns true', () async {
      final fake = _FakeStreamFunction([
        _toolTurn(const [_c1Bash]),
        _textTurn('done'),
      ]);
      final controls = ForegroundCallBudgetControls();
      final executorStarted = Completer<void>();
      final release = Completer<void>();
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        foregroundCall: const ForegroundCallBudgetConfig(
          budget: Duration(milliseconds: 300),
          cancelGrace: Duration(milliseconds: 60),
        ),
        toolExecutor: (toolCall, cancelToken, onUpdate) async {
          executorStarted.complete();
          await release.future;
          return ToolExecutionResult.text('ok');
        },
      );
      agent.state.tools = [_tool('bash')];
      agent.foregroundBudgetControls = controls;
      final budgetEvents = <ToolCallBudgetEvent>[];
      agent.subscribe((event, token) async {
        if (event is ToolCallBudgetEvent) {
          budgetEvents.add(event);
          _allBudgetEvents.add(event);
        }
      });
      final run = agent.prompt('go');
      await executorStarted.future;
      agent.steer(UserMessage.text('status?'));
      expect(controls.requestOffer(), isTrue);
      await waitForIt(
        () => budgetEvents.any((e) => e.rung == ForegroundBudgetRung.watchdog),
        reason: 'watchdog-rung offer',
      );
      expect(budgetEvents.single.action, ForegroundBudgetAction.offer);
      // The hook acted, so the B/2 timer has nothing left to offer.
      release.complete();
      await run;
      expect(budgetEvents, hasLength(1));
      expect(_resultText(agent.state.messages), 'ok');
    });

    test('empty FIFO or output seen: requestOffer returns false and fires '
        'no event', () async {
      // (a) FIFO empty.
      var fake = _FakeStreamFunction([
        _toolTurn(const [_c1Bash]),
        _textTurn('done'),
      ]);
      var controls = ForegroundCallBudgetControls();
      var executorStarted = Completer<void>();
      var release = Completer<void>();
      var agent = Agent(
        model: _model,
        streamFunction: fake.call,
        foregroundCall: const ForegroundCallBudgetConfig(
          budget: Duration(milliseconds: 300),
          cancelGrace: Duration(milliseconds: 60),
        ),
        toolExecutor: (toolCall, cancelToken, onUpdate) async {
          executorStarted.complete();
          await release.future;
          return ToolExecutionResult.text('ok');
        },
      );
      agent.state.tools = [_tool('bash')];
      agent.foregroundBudgetControls = controls;
      var budgetEvents = <ToolCallBudgetEvent>[];
      agent.subscribe((event, token) async {
        if (event is ToolCallBudgetEvent) {
          budgetEvents.add(event);
          _allBudgetEvents.add(event);
        }
      });
      var run = agent.prompt('go');
      await executorStarted.future;
      expect(controls.requestOffer(), isFalse, reason: 'no steering pending');
      expect(budgetEvents, isEmpty);
      release.complete();
      await run;

      // (b) Output seen: the E8 condition also gates the manual path.
      fake = _FakeStreamFunction([
        _toolTurn(const [_c1Bash]),
        _textTurn('done'),
      ]);
      controls = ForegroundCallBudgetControls();
      executorStarted = Completer<void>();
      release = Completer<void>();
      agent = Agent(
        model: _model,
        streamFunction: fake.call,
        foregroundCall: const ForegroundCallBudgetConfig(
          budget: Duration(milliseconds: 300),
          cancelGrace: Duration(milliseconds: 60),
        ),
        toolExecutor: (toolCall, cancelToken, onUpdate) async {
          executorStarted.complete();
          onUpdate?.call(ToolExecutionResult.text('some output'));
          await release.future;
          return ToolExecutionResult.text('ok');
        },
      );
      agent.state.tools = [_tool('bash')];
      agent.foregroundBudgetControls = controls;
      budgetEvents = <ToolCallBudgetEvent>[];
      agent.subscribe((event, token) async {
        if (event is ToolCallBudgetEvent) {
          budgetEvents.add(event);
          _allBudgetEvents.add(event);
        }
      });
      run = agent.prompt('go');
      await executorStarted.future;
      agent.steer(UserMessage.text('status?'));
      expect(
        controls.requestOffer(),
        isFalse,
        reason: 'a call with output is never offered',
      );
      expect(budgetEvents, isEmpty);
      release.complete();
      await run;
      expect(budgetEvents, isEmpty);
    });
  });

  group('budget preempts stuck retry', () {
    test('a budget force inside the stuck grace leaves no retry: one '
        'executor invocation, the result is the budget abort', () async {
      // The stuck ladder fires its cancel at 200ms and would retry; the
      // budget force at 230ms lands inside the stuck cancel grace, so the
      // ladder has acted by the time the abandoned attempt reports — no
      // stuck retry may restart the call.
      final outcome = await _runBudgetTurn(
        stuck: const StuckToolConfig(
          floor: Duration(milliseconds: 200),
          declaredTimeoutFactor: 2,
          heartbeatInterval: Duration(hours: 1),
          cancelGrace: Duration(milliseconds: 60),
        ),
        budget: const ForegroundCallBudgetConfig(
          budget: Duration(milliseconds: 230),
          cancelGrace: Duration(milliseconds: 80),
        ),
        executor: (attempt, onUpdate, cancelToken) async {
          await Completer<void>().future;
          throw StateError('zombie');
        },
      );
      final result = outcome.agent.state.messages
          .whereType<ToolResultMessage>()
          .firstWhere((m) => m.toolCallId == 'c1');
      final text = [
        for (final block in result.content)
          if (block is TextContent) block.text,
      ].join('\n');
      expect(result.isError, isTrue);
      expect(text, contains('[foreground-budget]'));
      expect(text, isNot(contains('[stuck-call')));
      // The budget preempted the stage machine: no stuck record, no retry.
      expect(outcome.stuckEvents, isEmpty);
      expect(outcome.budgetEvents, hasLength(1));
      expect(outcome.budgetEvents.single.rung, ForegroundBudgetRung.force);
      expect(outcome.budgetEvents.single.action, ForegroundBudgetAction.abort);
    });
  });

  group('announcement formatter (UT-6)', () {
    test('rung numbers are 1 / 2 / 3', () {
      expect(foregroundBudgetRungNumber(ForegroundBudgetRung.offer), '1');
      expect(foregroundBudgetRungNumber(ForegroundBudgetRung.force), '2');
      expect(foregroundBudgetRungNumber(ForegroundBudgetRung.watchdog), '3');
    });

    test('the announcement names rung, tool, elapsed, and the steering '
        'count (singular / plural)', () {
      final offer = foregroundBudgetAnnouncement(
        rung: ForegroundBudgetRung.offer,
        action: ForegroundBudgetAction.offer,
        toolName: 'bash',
        elapsed: const Duration(minutes: 2, seconds: 30),
        steeringCount: 1,
      );
      expect(offer, startsWith('[foreground-budget] rung 1: bash after 2m30s'));
      expect(offer, contains('deliver 1 steering message now'));
      expect(offer, isNot(contains('1 steering messages')));

      final abort = foregroundBudgetAnnouncement(
        rung: ForegroundBudgetRung.force,
        action: ForegroundBudgetAction.abort,
        toolName: 'bash',
        elapsed: const Duration(minutes: 4, seconds: 5),
        steeringCount: 2,
      );
      expect(abort, startsWith('[foreground-budget] rung 2: bash after 4m05s'));
      expect(abort, contains('2 steering messages'));

      final background = foregroundBudgetAnnouncement(
        rung: ForegroundBudgetRung.watchdog,
        action: ForegroundBudgetAction.background,
        toolName: 'grep',
        elapsed: Duration.zero,
        steeringCount: 0,
      );
      expect(
        background,
        startsWith('[foreground-budget] rung 3: grep after 0m00s'),
      );
      expect(background, contains('0 steering messages'));

      final withDetail = foregroundBudgetAnnouncement(
        rung: ForegroundBudgetRung.force,
        action: ForegroundBudgetAction.abort,
        toolName: 'bash',
        elapsed: Duration.zero,
        steeringCount: 1,
        detail: 'zombie handle logged',
      );
      expect(withDetail, contains(' — zombie handle logged — '));
    });

    test('every budget event raised by the other groups carries the REG-1 '
        'announcement prefix', () {
      expect(_allBudgetEvents, isNotEmpty);
      expect(
        _allBudgetEvents.every(
          (e) => e.detail.startsWith('[foreground-budget] rung '),
        ),
        isTrue,
        reason: 'no escalation may ever be silent (AC6)',
      );
    });
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
