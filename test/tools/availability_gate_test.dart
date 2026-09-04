// Contract tests for the [ToolAvailabilityGate] (issue #19): apply-time
// hiding/restoring of tools in a real [ToolRegistry] + [Agent], executor
// tombstoning for disabled tools, and dynamic (MCP) family registration.
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

/// A scripted turn ending with tool calls.
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

/// A scripted turn: stream start, text delta, done.
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

/// Fake [StreamFunction]: replays scripted turns.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];

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

AgentTool _tool(String name) {
  return AgentTool(
    name: name,
    description: '$name tool',
    execute: (args, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('$name ok'),
  );
}

ToolCall _call(String id, String name, [Map<String, dynamic> args = const {}]) {
  return ToolCall(id: id, name: name, arguments: args);
}

/// Every known id available; intent supplied per test.
ToolAvailabilityResolution _resolution(Map<String, bool> tools) {
  return resolveToolAvailability(
    capabilities: {
      for (final id in knownToolIds) id: const ToolCapability.available(),
    },
    scopes: [(ToolScope.session, ToolsConfig(tools: tools))],
  );
}

void main() {
  final toolsById = <String, List<AgentTool>>{
    'web_search': [_tool('web_search')],
    'bash': [_tool('bash')],
  };

  group('ToolAvailabilityGate.apply', () {
    test('registers enabled and unregisters disabled tools', () {
      final gate = ToolAvailabilityGate(toolsById: toolsById);
      final registry = ToolRegistry([_tool('bash'), _tool('web_search')]);

      gate.apply(
        _resolution({'bash': false}),
        registry,
        _agent(registry),
        rebuildPrompt: () {},
      );

      expect(registry.contains('bash'), isFalse);
      expect(registry.contains('web_search'), isTrue);
      expect(registry.tools.single.name, 'web_search');
    });

    test('updates agent.state.tools and rebuilds the prompt', () {
      final gate = ToolAvailabilityGate(toolsById: toolsById);
      var rebuilds = 0;
      final registry = ToolRegistry([...toolsById.values.expand((t) => t)]);
      final agent = _agent(registry);

      gate.apply(
        _resolution(const {}),
        registry,
        agent,
        rebuildPrompt: () => rebuilds++,
      );

      expect(agent.state.tools.map((t) => t.name), containsAll(toolsById.keys));

      gate.apply(
        _resolution({'bash': false}),
        registry,
        agent,
        rebuildPrompt: () => rebuilds++,
      );

      expect(agent.state.tools.map((t) => t.name), ['web_search']);
      expect(rebuilds, 2);
    });

    test('restores a previously disabled tool', () {
      final gate = ToolAvailabilityGate(toolsById: toolsById);
      final registry = ToolRegistry([...toolsById.values.expand((t) => t)]);
      final agent = _agent(registry);

      gate.apply(
        _resolution({'bash': false}),
        registry,
        agent,
        rebuildPrompt: () {},
      );
      expect(registry.contains('bash'), isFalse);

      gate.apply(
        _resolution({'bash': true}),
        registry,
        agent,
        rebuildPrompt: () {},
      );
      expect(registry.contains('bash'), isTrue);
      expect(registry.lookup('bash')!.name, 'bash');
    });

    test('is idempotent: applying the same resolution twice is a no-op', () {
      final gate = ToolAvailabilityGate(toolsById: toolsById);
      final registry = ToolRegistry([...toolsById.values.expand((t) => t)]);
      final agent = _agent(registry);
      final resolution = _resolution(const {});

      gate.apply(resolution, registry, agent, rebuildPrompt: () {});
      gate.apply(resolution, registry, agent, rebuildPrompt: () {});

      expect(registry.names.toSet(), toolsById.keys);
    });

    test('skips tools that are already registered', () {
      final gate = ToolAvailabilityGate(toolsById: toolsById);
      // Same instances as the gate owns: register() would throw on a
      // duplicate, so the contains-check must prevent re-registration.
      final registry = ToolRegistry([...toolsById.values.expand((t) => t)]);
      final agent = _agent(registry);

      expect(
        () => gate.apply(
          _resolution(const {}),
          registry,
          agent,
          rebuildPrompt: () {},
        ),
        returnsNormally,
      );
      expect(registry.length, 2);
    });
  });

  group('ToolAvailabilityGate.hiddenToolNames', () {
    test('empty before any apply', () {
      final gate = ToolAvailabilityGate(toolsById: toolsById);
      expect(gate.resolution, isNull);
      expect(gate.hiddenToolNames, isEmpty);
    });

    test('lists names of disabled ids after apply', () {
      final gate = ToolAvailabilityGate(toolsById: toolsById);
      final registry = ToolRegistry([...toolsById.values.expand((t) => t)]);

      gate.apply(
        _resolution({'bash': false}),
        registry,
        _agent(registry),
        rebuildPrompt: () {},
      );

      expect(gate.hiddenToolNames, ['bash']);
    });
  });

  group('ToolAvailabilityGate.noteHiddenNames', () {
    test('records dynamic family names for hiding and the executor', () async {
      final gate = ToolAvailabilityGate(
        toolsById: {
          'bash': [_tool('bash')],
        },
      );
      gate.noteHiddenNames('mcp:my-server', ['mcp__echo', 'mcp__ping']);

      final registry = ToolRegistry([
        _tool('bash'),
        _tool('mcp__echo'),
        _tool('mcp__ping'),
      ]);
      final agent = _agent(registry);

      gate.apply(
        resolveToolAvailability(
          capabilities: {'bash': const ToolCapability.available()},
          scopes: [
            (
              ToolScope.project,
              const ToolsConfig(tools: {'mcp:my-server': false}),
            ),
          ],
        ),
        registry,
        agent,
        rebuildPrompt: () {},
      );

      // The disabled MCP family's dynamic names are tombstoned.
      expect(registry.contains('mcp__echo'), isFalse);
      expect(registry.contains('mcp__ping'), isFalse);
      expect(registry.contains('bash'), isTrue);
      expect(gate.hiddenToolNames, containsAll(['mcp__echo', 'mcp__ping']));

      // The executor maps the dynamic names to their family id.
      final wrapped = gate.wrapExecutor(
        (call, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('inner ${call.name}'),
      );
      final result = await wrapped(_call('c1', 'mcp__echo'), null, null);
      expect(
        result.content.single,
        isA<TextContent>().having(
          (c) => c.text,
          'text',
          contains('Tool `mcp__echo` is disabled'),
        ),
      );
    });

    test(
      'kill-switch tombstones noted families with the aggregate reason',
      () async {
        final gate = ToolAvailabilityGate(toolsById: const {});
        gate.noteHiddenNames('mcp:my-server', ['mcp__echo']);

        final registry = ToolRegistry([_tool('mcp__echo')]);
        final agent = _agent(registry);
        final wrapped = gate.wrapExecutor(registry.executor);

        final killSwitch = resolveToolAvailability(
          capabilities: {'mcp': const ToolCapability.available()},
          scopes: [
            (ToolScope.runtime, const ToolsConfig(tools: {'mcp': false})),
          ],
        );
        gate.apply(killSwitch, registry, agent, rebuildPrompt: () {});
        expect(registry.contains('mcp__echo'), isFalse);

        final result = await wrapped(_call('c1', 'mcp__echo'), null, null);
        expect(
          (result.content.single as TextContent).text,
          contains('(`disabled by runtime`)'),
        );

        // Re-enabling (no mcp intent) leaves nothing to re-register: the
        // family has no static tools of its own.
        gate.apply(
          _resolution(const {}),
          registry,
          agent,
          rebuildPrompt: () {},
        );
        expect(gate.hiddenToolNames, isEmpty);
      },
    );
  });

  group('ToolAvailabilityGate.wrapExecutor', () {
    test('delegates for an enabled tool', () async {
      final gate = ToolAvailabilityGate(toolsById: toolsById);
      final registry = ToolRegistry([...toolsById.values.expand((t) => t)]);
      gate.apply(
        _resolution(const {}),
        registry,
        _agent(registry),
        rebuildPrompt: () {},
      );

      final wrapped = gate.wrapExecutor(
        (call, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('inner ${call.name}'),
      );
      final result = await wrapped(_call('c1', 'web_search'), null, null);
      expect((result.content.single as TextContent).text, 'inner web_search');
    });

    test('returns a plain tombstone for a disabled tool', () async {
      final gate = ToolAvailabilityGate(toolsById: toolsById);
      gate.apply(
        _resolution({'bash': false}),
        registryStub(),
        _agent(registryStub()),
        rebuildPrompt: () {},
      );

      final wrapped = gate.wrapExecutor(
        (call, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('inner ${call.name}'),
      );
      final result = await wrapped(_call('c1', 'bash'), null, null);

      expect(result.terminate, isFalse);
      expect(
        (result.content.single as TextContent).text,
        'Tool `bash` is disabled (`disabled by session`) — ask the user '
        'to enable it via /tools or settings.',
      );
    });

    test('tombstone carries the capability absence reason', () async {
      final gate = ToolAvailabilityGate(
        toolsById: {
          'transcribe_audio': [_tool('transcribe_audio')],
        },
      );
      gate.apply(
        resolveToolAvailability(
          capabilities: {
            'transcribe_audio': const ToolCapability.absent(
              'not wired by this host',
            ),
          },
          scopes: const [],
        ),
        registryStub(),
        _agent(registryStub()),
        rebuildPrompt: () {},
      );

      final wrapped = gate.wrapExecutor(
        (call, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('inner ${call.name}'),
      );
      final result = await wrapped(_call('c1', 'transcribe_audio'), null, null);
      expect(
        (result.content.single as TextContent).text,
        contains('(`not wired by this host`)'),
      );
    });

    test('delegates for names the gate does not know', () async {
      final gate = ToolAvailabilityGate(toolsById: toolsById);
      final wrapped = gate.wrapExecutor(
        (call, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('inner ${call.name}'),
      );
      final result = await wrapped(_call('c1', 'custom_tool'), null, null);
      expect((result.content.single as TextContent).text, 'inner custom_tool');
    });
  });

  group('Agent integration', () {
    test('hidden tool leaves the provider context; enabled tool runs through '
        'the wrapped executor', () async {
      final gate = ToolAvailabilityGate(toolsById: toolsById);
      final registry = ToolRegistry([...toolsById.values.expand((t) => t)]);
      final fake = _FakeStreamFunction([
        _toolTurn([_call('c1', 'web_search')]),
        _textTurn('done'),
      ]);
      final agent = Agent(
        model: _model,
        toolRegistry: registry,
        toolExecutor: gate.wrapExecutor(registry.executor),
        streamFunction: fake.call,
      );

      gate.apply(
        _resolution({'bash': false}),
        registry,
        agent,
        rebuildPrompt: () {},
      );
      await agent.prompt('go');

      // The provider context never saw the disabled tool.
      expect(fake.contexts.first.tools!.map((t) => t.name), ['web_search']);

      // The enabled tool executed through the wrapped executor.
      final toolResult = agent.state.messages[2] as ToolResultMessage;
      expect(toolResult.toolName, 'web_search');
      expect((toolResult.content.single as TextContent).text, 'web_search ok');
    });
  });
}

ToolRegistry registryStub() => ToolRegistry();

Agent _agent(ToolRegistry registry) {
  return Agent(
    model: _model,
    toolRegistry: registry,
    streamFunction: (model, context, {cancelToken}) {
      final stream = AssistantMessageEventStream();
      stream.end();
      return stream;
    },
  );
}
