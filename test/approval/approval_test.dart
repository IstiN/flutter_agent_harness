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

/// Scripted [StreamFunction] replaying pre-recorded turns.
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

/// An [AgentTool] that records executions and answers with a fixed text.
class _RecorderTool {
  _RecorderTool({this.tier = ApprovalTier.exec});

  final ApprovalTier tier;
  final executions = <Map<String, dynamic>>[];

  AgentTool get tool => AgentTool(
    name: 'recorder',
    description: 'Records calls.',
    tier: tier,
    execute: (arguments, cancelToken, onUpdate) async {
      executions.add(arguments);
      return ToolExecutionResult.text('executed');
    },
  );
}

Agent _agent({
  required List<List<AssistantMessageEvent>> turns,
  required List<AgentTool> tools,
  ApprovalManager? approval,
  BeforeToolCallHook? beforeToolCall,
}) {
  final agent = Agent(
    model: _model,
    streamFunction: _FakeStreamFunction(turns).call,
    toolRegistry: ToolRegistry(tools),
    beforeToolCall: beforeToolCall,
  );
  if (approval != null) attachApproval(agent, approval);
  return agent;
}

List<ToolResultMessage> _toolResults(Agent agent) {
  return agent.state.messages.whereType<ToolResultMessage>().toList();
}

String _resultText(ToolResultMessage message) {
  return message.content.whereType<TextContent>().map((b) => b.text).join();
}

void main() {
  group('ApprovalTier defaults', () {
    test('builtin tools carry sensible tiers', () {
      final tools = {
        for (final tool in builtinTools(MemoryExecutionEnv())) tool.name: tool,
      };
      expect(tools['read']!.tier, ApprovalTier.read);
      expect(tools['ls']!.tier, ApprovalTier.read);
      expect(tools['write']!.tier, ApprovalTier.write);
      expect(tools['edit']!.tier, ApprovalTier.write);
      expect(tools['bash']!.tier, ApprovalTier.exec);
    });

    test('inspect_image is read-tier', () {
      final tool = inspectImageTool(
        MemoryExecutionEnv(),
        InspectImageConfig(modelId: 'vision', apiKey: 'key'),
      );
      expect(tool.tier, ApprovalTier.read);
    });

    test('transcribe_audio is read-tier', () {
      final tool = transcribeAudioTool(
        MemoryExecutionEnv(),
        const TranscribeAudioConfig(apiKey: 'key'),
      );
      expect(tool.tier, ApprovalTier.read);
    });

    test('custom tools default to exec (safe default)', () {
      final tool = AgentTool(
        name: 'custom',
        description: 'No tier declared.',
        execute: (arguments, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('ok'),
      );
      expect(tool.tier, ApprovalTier.exec);
    });
  });

  group('policy resolution', () {
    test('per-tool deny override wins, even under yolo', () async {
      final manager = ApprovalManager(
        mode: ApprovalMode.yolo,
        overrides: const {'bash': ApprovalPolicy.deny},
      );
      final outcome = await manager.authorize(
        toolName: 'bash',
        tier: ApprovalTier.exec,
        arguments: const {'command': 'ls'},
      );
      expect(outcome.allowed, isFalse);
      expect(
        outcome.reason,
        contains('denied by the configured approval policy'),
      );
    });

    test('per-tool allow override wins over always-ask', () async {
      final manager = ApprovalManager(
        mode: ApprovalMode.alwaysAsk,
        overrides: const {'write': ApprovalPolicy.allow},
      );
      final outcome = await manager.authorize(
        toolName: 'write',
        tier: ApprovalTier.write,
        arguments: const {},
      );
      expect(outcome.allowed, isTrue);
    });

    test('per-tool prompt override forces a prompt under yolo', () async {
      final requests = <ApprovalRequest>[];
      final manager = ApprovalManager(
        mode: ApprovalMode.yolo,
        overrides: const {'bash': ApprovalPolicy.prompt},
        prompt: (request) {
          requests.add(request);
          return ApprovalDecision.approveOnce;
        },
      );
      final outcome = await manager.authorize(
        toolName: 'bash',
        tier: ApprovalTier.exec,
        arguments: const {'command': 'ls'},
      );
      expect(outcome.allowed, isTrue);
      expect(requests, hasLength(1));
      expect(requests.single.toolName, 'bash');
    });

    test('mode resolution: always-ask prompts even read-tier tools', () async {
      var prompts = 0;
      final manager = ApprovalManager(
        mode: ApprovalMode.alwaysAsk,
        prompt: (request) {
          prompts++;
          return ApprovalDecision.deny;
        },
      );
      final outcome = await manager.authorize(
        toolName: 'read',
        tier: ApprovalTier.read,
        arguments: const {},
      );
      expect(outcome.allowed, isFalse);
      expect(prompts, 1);
    });

    test(
      'mode resolution: write allows read, prompts write and exec',
      () async {
        final prompted = <String>[];
        final manager = ApprovalManager(
          mode: ApprovalMode.write,
          prompt: (request) {
            prompted.add(request.toolName);
            return ApprovalDecision.approveOnce;
          },
        );
        Future<bool> allowed(String name, ApprovalTier tier) async {
          final outcome = await manager.authorize(
            toolName: name,
            tier: tier,
            arguments: const {},
          );
          return outcome.allowed;
        }

        expect(await allowed('read', ApprovalTier.read), isTrue);
        expect(prompted, isEmpty);
        expect(await allowed('write', ApprovalTier.write), isTrue);
        expect(await allowed('bash', ApprovalTier.exec), isTrue);
        expect(prompted, ['write', 'bash']);
      },
    );

    test('mode resolution: yolo allows everything', () async {
      final manager = ApprovalManager(mode: ApprovalMode.yolo);
      for (final tier in ApprovalTier.values) {
        final outcome = await manager.authorize(
          toolName: 'tool-${tier.name}',
          tier: tier,
          arguments: const {},
        );
        expect(outcome.allowed, isTrue, reason: 'tier ${tier.name}');
      }
    });

    test(
      'approve always adds the tool to the session always-allow set',
      () async {
        var prompts = 0;
        final manager = ApprovalManager(
          mode: ApprovalMode.write,
          prompt: (request) {
            prompts++;
            return ApprovalDecision.approveAlways;
          },
        );
        Future<ApprovalOutcome> call() => manager.authorize(
          toolName: 'write',
          tier: ApprovalTier.write,
          arguments: const {},
        );

        expect((await call()).allowed, isTrue);
        expect(prompts, 1);
        expect(manager.isAlwaysAllowed('write'), isTrue);
        expect(manager.alwaysAllowedTools, ['write']);
        // Second call is auto-allowed without prompting.
        expect((await call()).allowed, isTrue);
        expect(prompts, 1);
      },
    );

    test(
      'null prompt callback denies with a "no approval UI" reason',
      () async {
        final manager = ApprovalManager(mode: ApprovalMode.write);
        final outcome = await manager.authorize(
          toolName: 'write',
          tier: ApprovalTier.write,
          arguments: const {},
        );
        expect(outcome.allowed, isFalse);
        expect(outcome.reason, contains('no approval UI'));
      },
    );

    test('mode label round-trip', () {
      for (final mode in ApprovalMode.values) {
        expect(approvalModeFromLabel(mode.label), mode);
      }
      expect(approvalModeFromLabel('nope'), isNull);
      expect(approvalModeFromLabel(null), isNull);
    });
  });

  group('bash critical-pattern escalation', () {
    test(
      'critical commands prompt even under yolo with always-allow',
      () async {
        final requests = <ApprovalRequest>[];
        final manager = ApprovalManager(
          mode: ApprovalMode.yolo,
          alwaysAllow: const {'bash'},
          prompt: (request) {
            requests.add(request);
            return ApprovalDecision.deny;
          },
        );
        final outcome = await manager.authorize(
          toolName: 'bash',
          tier: ApprovalTier.exec,
          arguments: const {'command': 'rm -rf /'},
        );
        expect(outcome.allowed, isFalse);
        expect(requests, hasLength(1));
        expect(requests.single.reason, contains('Critical pattern detected'));
        expect(requests.single.tier, ApprovalTier.exec);
        expect(requests.single.arguments['command'], 'rm -rf /');
      },
    );

    test('safe bash commands do not escalate under yolo', () async {
      final manager = ApprovalManager(
        mode: ApprovalMode.yolo,
        prompt: (request) => fail('must not prompt for a safe command'),
      );
      final outcome = await manager.authorize(
        toolName: 'bash',
        tier: ApprovalTier.exec,
        arguments: const {'command': 'ls -la && git status'},
      );
      expect(outcome.allowed, isTrue);
    });

    test('an explicit deny override outranks the interceptor', () async {
      final manager = ApprovalManager(
        mode: ApprovalMode.yolo,
        overrides: const {'bash': ApprovalPolicy.deny},
        prompt: (request) => fail('must not prompt when denied'),
      );
      final outcome = await manager.authorize(
        toolName: 'bash',
        tier: ApprovalTier.exec,
        arguments: const {'command': 'rm -rf /'},
      );
      expect(outcome.allowed, isFalse);
      expect(
        outcome.reason,
        contains('denied by the configured approval policy'),
      );
    });

    test(
      'non-bash tools with a command argument are not intercepted',
      () async {
        final manager = ApprovalManager(mode: ApprovalMode.yolo);
        final outcome = await manager.authorize(
          toolName: 'ssh',
          tier: ApprovalTier.exec,
          arguments: const {'command': 'rm -rf /'},
        );
        expect(outcome.allowed, isTrue);
      },
    );
  });

  group('agent loop integration', () {
    test('deny produces an error tool result and the loop continues', () async {
      final recorder = _RecorderTool();
      final approval = ApprovalManager(
        mode: ApprovalMode.yolo,
        overrides: const {'recorder': ApprovalPolicy.deny},
      );
      final agent = _agent(
        turns: [
          _toolTurn(const [
            ToolCall(id: 'tc-1', name: 'recorder', arguments: {'x': 1}),
          ]),
          _textTurn('adapted'),
        ],
        tools: [recorder.tool],
        approval: approval,
      );
      await agent.prompt('go');
      await agent.waitForIdle();

      expect(recorder.executions, isEmpty);
      final results = _toolResults(agent);
      expect(results, hasLength(1));
      expect(results.single.isError, isTrue);
      expect(_resultText(results.single), contains('denied'));
      // The model saw the error and the run completed with its next turn.
      expect(
        agent.state.messages
            .whereType<AssistantMessage>()
            .last
            .content
            .whereType<TextContent>()
            .map((b) => b.text)
            .join(),
        'adapted',
      );
    });

    test(
      'prompt approve-once executes the tool with the raw arguments',
      () async {
        final recorder = _RecorderTool(tier: ApprovalTier.write);
        final requests = <ApprovalRequest>[];
        final approval = ApprovalManager(
          mode: ApprovalMode.write,
          prompt: (request) {
            requests.add(request);
            return ApprovalDecision.approveOnce;
          },
        );
        final agent = _agent(
          turns: [
            _toolTurn(const [
              ToolCall(id: 'tc-1', name: 'recorder', arguments: {'path': 'a'}),
            ]),
            _textTurn('done'),
          ],
          tools: [recorder.tool],
          approval: approval,
        );
        await agent.prompt('go');
        await agent.waitForIdle();

        expect(recorder.executions, [
          {'path': 'a'},
        ]);
        expect(requests, hasLength(1));
        expect(requests.single.toolName, 'recorder');
        expect(requests.single.tier, ApprovalTier.write);
        final results = _toolResults(agent);
        expect(results.single.isError, isFalse);
        expect(_resultText(results.single), 'executed');
      },
    );

    test('prompt deny turns the call into an error result', () async {
      final recorder = _RecorderTool();
      final approval = ApprovalManager(
        mode: ApprovalMode.alwaysAsk,
        prompt: (request) => ApprovalDecision.deny,
      );
      final agent = _agent(
        turns: [
          _toolTurn(const [
            ToolCall(id: 'tc-1', name: 'recorder', arguments: {}),
          ]),
          _textTurn('done'),
        ],
        tools: [recorder.tool],
        approval: approval,
      );
      await agent.prompt('go');
      await agent.waitForIdle();

      expect(recorder.executions, isEmpty);
      final results = _toolResults(agent);
      expect(results.single.isError, isTrue);
      expect(_resultText(results.single), contains('user denied'));
    });

    test('no prompt callback denies the call and names the tool', () async {
      final recorder = _RecorderTool();
      final approval = ApprovalManager(mode: ApprovalMode.alwaysAsk);
      final agent = _agent(
        turns: [
          _toolTurn(const [
            ToolCall(id: 'tc-1', name: 'recorder', arguments: {}),
          ]),
          _textTurn('done'),
        ],
        tools: [recorder.tool],
        approval: approval,
      );
      await agent.prompt('go');
      await agent.waitForIdle();

      final results = _toolResults(agent);
      expect(results.single.isError, isTrue);
      expect(_resultText(results.single), contains('recorder'));
      expect(_resultText(results.single), contains('no approval UI'));
    });

    test('a plain Tool without a tier is treated as exec', () async {
      // Tool (not AgentTool) in the context list: the loop's existence check
      // finds it, the registry refuses execution — but approval runs first
      // and must classify it as exec-tier (prompt in write mode).
      final requests = <ApprovalRequest>[];
      final approval = ApprovalManager(
        mode: ApprovalMode.write,
        prompt: (request) {
          requests.add(request);
          return ApprovalDecision.approveOnce;
        },
      );
      final recorder = _RecorderTool();
      final agent = Agent(
        model: _model,
        streamFunction: _FakeStreamFunction([
          _toolTurn(const [
            ToolCall(id: 'tc-1', name: 'recorder', arguments: {}),
          ]),
          _textTurn('done'),
        ]).call,
        toolRegistry: ToolRegistry([recorder.tool]),
        tools: const [
          Tool(name: 'recorder', description: 'plain shadow', parameters: {}),
        ],
      );
      attachApproval(agent, approval);
      await agent.prompt('go');
      await agent.waitForIdle();

      // Write mode + exec tier → prompted once (then execution fails in the
      // registry, which is irrelevant to the approval assertion).
      expect(requests, hasLength(1));
      expect(requests.single.tier, ApprovalTier.exec);
    });

    test('approval composes with a user-registered beforeToolCall', () async {
      final recorder = _RecorderTool();
      var userHookCalls = 0;
      final approval = ApprovalManager(mode: ApprovalMode.yolo);
      final agent = _agent(
        turns: [
          _toolTurn(const [
            ToolCall(id: 'tc-1', name: 'recorder', arguments: {}),
          ]),
          _textTurn('done'),
        ],
        tools: [recorder.tool],
        approval: approval,
        beforeToolCall: (context, cancelToken) {
          userHookCalls++;
          return null;
        },
      );
      await agent.prompt('go');
      await agent.waitForIdle();

      expect(userHookCalls, 1);
      expect(recorder.executions, hasLength(1));
    });

    test('a denied call never reaches the user beforeToolCall hook', () async {
      final recorder = _RecorderTool();
      var userHookCalls = 0;
      final approval = ApprovalManager(
        mode: ApprovalMode.yolo,
        overrides: const {'recorder': ApprovalPolicy.deny},
      );
      final agent = _agent(
        turns: [
          _toolTurn(const [
            ToolCall(id: 'tc-1', name: 'recorder', arguments: {}),
          ]),
          _textTurn('done'),
        ],
        tools: [recorder.tool],
        approval: approval,
        beforeToolCall: (context, cancelToken) {
          userHookCalls++;
          return null;
        },
      );
      await agent.prompt('go');
      await agent.waitForIdle();

      expect(userHookCalls, 0);
      expect(recorder.executions, isEmpty);
    });

    test(
      'a user hook block still works after approval allows the call',
      () async {
        final recorder = _RecorderTool();
        final approval = ApprovalManager(mode: ApprovalMode.yolo);
        final agent = _agent(
          turns: [
            _toolTurn(const [
              ToolCall(id: 'tc-1', name: 'recorder', arguments: {}),
            ]),
            _textTurn('done'),
          ],
          tools: [recorder.tool],
          approval: approval,
          beforeToolCall: (context, cancelToken) {
            return const BeforeToolCallResult(
              block: true,
              reason: 'user block',
            );
          },
        );
        await agent.prompt('go');
        await agent.waitForIdle();

        expect(recorder.executions, isEmpty);
        expect(_resultText(_toolResults(agent).single), 'user block');
      },
    );
  });
}
