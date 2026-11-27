/// gh-2458: a tool mounted from the deferred `others` partition MID-RUN
/// must actually become callable:
///
/// (a) the NEXT provider request's tools array carries the mounted tool
///     (the request-build path must read the live tool list, not the
///     run-start snapshot);
/// (b) an assistant `tool_use` naming it routes to its real executor —
///     no deferred tombstone, no unknown-tool swallow;
/// (c) REG: the keep-12 name-level partition mount works for every
///     demoted tool family (agent_message, agent_directory, task,
///     memory) and the #680 honesty rule still tombstones un-mounted
///     discoverables.
library;

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

/// A scripted turn that ends with tool calls.
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

/// A scripted plain-text turn.
List<AssistantMessageEvent> _textTurn(String text) {
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: _assistant()),
    TextStartEvent(contentIndex: 0, partial: partial),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// Fake stream function: replays scripted turns, records every request
/// context (the outbound tool list included).
class _RecordingStream {
  _RecordingStream(this.turns);

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

int _seq = 0;

ToolCall _call(String name, [Map<String, dynamic>? args]) {
  return ToolCall(
    id: 'call-${_seq++}-$name',
    name: name,
    arguments: args ?? const {},
  );
}

/// A deferred-family tool with a recording executor.
AgentTool _deferredTool(String name, Set<String> executed) {
  return AgentTool(
    name: name,
    description: 'Deferred family tool $name.\nlonger doc line',
    parameters: const {'type': 'object', 'properties': {}},
    execute: (args, cancelToken, onUpdate) async {
      executed.add(name);
      return ToolExecutionResult.text('$name executed');
    },
  );
}

/// The gh-2458 rig: a real gate over a keep-12-shaped name-level
/// partition (`read` essential; the deferred families split per name),
/// a registry carrying `read` + the `others` stub, and the CLI-shaped
/// mount + routing wiring. Mirrors `AgentCliTools._mountDeferred` and
/// `resolveDeferredToolForCall` (live-registry routing).
class _MountRig {
  _MountRig(List<String> deferredNames) {
    for (final name in deferredNames) {
      deferred[name] = _deferredTool(name, executed);
    }
    final gate = ToolAvailabilityGate(
      toolsById: {
        'read': [
          AgentTool(
            name: 'read',
            description: 'read a file',
            parameters: const {'type': 'object', 'properties': {}},
            execute: (_, _, _) async => ToolExecutionResult.text('read ok'),
          ),
        ],
        'task': [
          for (final name in deferredNames.where(
            (n) => n.startsWith('task') || n.startsWith('agent_'),
          ))
            deferred[name]!,
        ],
        'memory': [
          if (deferred.containsKey('memory_search')) deferred['memory_search']!,
        ],
      },
    );
    gate.discoveryEnabled = true;
    this.gate = gate;

    registry.register(readTool);
    registry.register(
      othersTool(
        description:
            'Deferred tools (not loaded): ${deferredNames.join(', ')}.',
        discoverableDocs: gate.discoverableDocs,
        onMount: mount,
      ),
    );
    // The CLI boots with every registry tool in the state.
    mountTarget.state.tools = registry.tools;
  }

  final registry = ToolRegistry([]);
  final executed = <String>{};
  final Map<String, AgentTool> deferred = {};

  /// The agent the mount re-syncs (`gate.mount` → `apply` →
  /// `agent.state.tools`). Defaults to the rig's own agent; the
  /// Agent-level test re-points it at the agent under test.
  Agent mountTarget = _rigAgent();

  late ToolAvailabilityGate gate;
  late final ToolExecutor executor = gate.wrapExecutor(registry.executor);

  final AgentTool readTool = AgentTool(
    name: 'read',
    description: 'read a file',
    parameters: const {'type': 'object', 'properties': {}},
    execute: (_, _, _) async => ToolExecutionResult.text('read ok'),
  );

  static Agent _rigAgent() {
    return Agent(
      model: _model,
      streamFunction: (_, _, {cancelToken}) =>
          throw StateError('rig agent has no scripted LM'),
      toolRegistry: ToolRegistry(const []),
    );
  }

  /// `_mountDeferred` core (agent_cli_tools.dart): mount through the gate
  /// into the registry + live agent, report the schema text.
  String mount(List<String> requested) {
    final mounted = gate.mount(
      requested,
      registry,
      mountTarget,
      rebuildPrompt: () {},
    );
    return [
      for (final name in requested)
        mounted.contains(name)
            ? 'Loaded `$name` (now in the schema).'
            : 'no such deferred tool: $name',
    ].join('\n');
  }

  /// `resolveDeferredToolForCall` core (agent_cli_tools.dart): a mounted
  /// tool resolves through the LIVE registry membership.
  Future<Tool?> resolve(String name) async {
    return registry.tools.where((tool) => tool.name == name).firstOrNull;
  }
}

/// keep-12 shape: only `read` essential; every other enabled tool demotes
/// per NAME (the default partition, GOAL #28).
ToolAvailabilityResolution _keep12Resolution() {
  return resolveToolAvailability(
    capabilities: {
      'read': const ToolCapability.available(),
      'task': const ToolCapability.available(),
      'memory': const ToolCapability.available(),
    },
    scopes: const [(ToolScope.session, ToolsConfig())],
    essentialNames: const {'read'},
  );
}

/// Drives one run: turn 1 mounts [mountName] via `others`, turn 2 calls
/// [callName], turn 3 ends with text. The config installs the same
/// per-request tools provider the Agent wires (gh-2458), plus the
/// CLI-shaped missing-tool routing. Returns the recording fake and the
/// run's messages.
Future<(_RecordingStream, List<Message>)> _runMountThenCall({
  required _MountRig rig,
  required String mountName,
  required String callName,
}) async {
  rig.gate.apply(
    _keep12Resolution(),
    rig.registry,
    rig.mountTarget,
    rebuildPrompt: () {},
  );
  final fake = _RecordingStream([
    _toolTurn([
      _call('others', {'tool_name': mountName}),
    ]),
    _toolTurn([_call(callName)]),
    _textTurn('done'),
  ]);
  final messages = await agentLoop(
    prompts: [UserMessage.text('mount and call $callName')],
    context: Context(messages: const [], tools: rig.registry.tools),
    config: AgentLoopConfig(
      model: _model,
      toolsProvider: () => rig.mountTarget.state.tools,
      missingToolResolver: rig.resolve,
    ),
    streamFunction: fake.call,
    toolExecutor: rig.executor,
  ).result;
  return (fake, messages);
}

void main() {
  setUp(() => _seq = 0);

  group('gh-2458 mid-loop mount', () {
    test('(a) the NEXT request tools array carries the mounted tool', () async {
      final rig = _MountRig(['agent_message']);
      final (fake, _) = await _runMountThenCall(
        rig: rig,
        mountName: 'agent_message',
        callName: 'agent_message',
      );

      expect(fake.calls, 3);
      // Request 1: the deferred tool is still out of the schema.
      expect(
        fake.contexts[0].tools!.map((t) => t.name),
        isNot(contains('agent_message')),
      );
      // Request 2: the mid-loop mount must be visible to the provider.
      expect(
        fake.contexts[1].tools!.map((t) => t.name),
        contains('agent_message'),
        reason:
            'the mount ran mid-loop; the next request in the SAME run '
            'must advertise the mounted tool, not the run-start snapshot',
      );
    });

    test('(b) an assistant tool_use naming the mounted tool routes to its '
        'executor — no tombstone, no unknown-tool swallow', () async {
      final rig = _MountRig(['agent_message']);
      final (_, messages) = await _runMountThenCall(
        rig: rig,
        mountName: 'agent_message',
        callName: 'agent_message',
      );

      expect(rig.executed, contains('agent_message'));
      final result = messages.whereType<ToolResultMessage>().firstWhere(
        (r) => r.toolName == 'agent_message',
      );
      expect(result.isError, isFalse);
      expect(
        (result.content.single as TextContent).text,
        equals('agent_message executed'),
      );
    });

    test('(c) REG: every keep-12 demoted family mounts and is immediately '
        'usable mid-loop', () async {
      for (final name in const [
        'agent_message',
        'agent_directory',
        'task_send',
        'memory_search',
      ]) {
        final rig = _MountRig([name]);
        final (fake, _) = await _runMountThenCall(
          rig: rig,
          mountName: name,
          callName: name,
        );
        expect(
          fake.contexts[1].tools!.map((t) => t.name),
          contains(name),
          reason: '$name mounted mid-loop must ride the next request',
        );
        expect(rig.executed, contains(name), reason: '$name must execute');
      }
    });

    test('GOAL #28 honesty: a DIRECT call to an UN-mounted discoverable '
        'mounts live and executes natively; the executor-level deferred '
        'tombstone stays the no-resolver contract', () async {
      // The CLI resolves a direct call to a discoverable name through the
      // deferred-mount path (resolveDeferredToolForCall → _mountDeferred):
      // the call proceeds natively instead of dead-ending. Rig-side the
      // resolver mounts on miss, exactly like the CLI's live-registry +
      // discoverable-name routing.
      final rig = _MountRig(['agent_message', 'agent_directory']);
      Future<Tool?> mountOnResolve(String name) async {
        final live = await rig.resolve(name);
        if (live != null) return live;
        rig.mount([name]);
        return rig.resolve(name);
      }

      rig.gate.apply(
        _keep12Resolution(),
        rig.registry,
        rig.mountTarget,
        rebuildPrompt: () {},
      );
      final fake = _RecordingStream([
        _toolTurn([_call('agent_directory')]),
        _textTurn('done'),
      ]);
      final messages = await agentLoop(
        prompts: [UserMessage.text('call the deferred tool directly')],
        context: Context(messages: const [], tools: rig.registry.tools),
        config: AgentLoopConfig(
          model: _model,
          toolsProvider: () => rig.mountTarget.state.tools,
          missingToolResolver: mountOnResolve,
        ),
        streamFunction: fake.call,
        toolExecutor: rig.executor,
      ).result;

      expect(rig.executed, contains('agent_directory'));
      final result = messages.whereType<ToolResultMessage>().firstWhere(
        (r) => r.toolName == 'agent_directory',
      );
      expect(result.isError, isFalse);
      expect(
        (result.content.single as TextContent).text,
        equals('agent_directory executed'),
      );

      // The #680 executor-level tombstone (un-mounted discoverable never
      // executes, names the discovery path) is pinned at the gate layer by
      // test/tools/availability_load_mode_test.dart; here we pin the loop
      // layer's no-resolver fallback: the plain honest not-found, never a
      // wrong-tool execution.
      final plainRig = _MountRig(['agent_directory']);
      plainRig.gate.apply(
        _keep12Resolution(),
        plainRig.registry,
        plainRig.mountTarget,
        rebuildPrompt: () {},
      );
      final plainFake = _RecordingStream([
        _toolTurn([_call('agent_directory')]),
        _textTurn('done'),
      ]);
      final plainMessages = await agentLoop(
        prompts: [UserMessage.text('direct call, no resolver')],
        context: Context(messages: const [], tools: plainRig.registry.tools),
        config: AgentLoopConfig(model: _model),
        streamFunction: plainFake.call,
        toolExecutor: plainRig.executor,
      ).result;
      expect(plainRig.executed, isNot(contains('agent_directory')));
      final plainResult = plainMessages
          .whereType<ToolResultMessage>()
          .firstWhere((r) => r.toolName == 'agent_directory');
      expect(plainResult.isError, isTrue);
      expect(
        (plainResult.content.single as TextContent).text,
        contains('not found'),
      );
    });

    test(
      'Agent wiring: the loop config reads state.tools per request',
      () async {
        // The host-facing seam: an Agent whose config is built by
        // _createLoopConfig must resolve the mounted tool into the NEXT
        // request — this pins the _createLoopConfig wiring, not just the
        // loop mechanism.
        final rig = _MountRig(['agent_message']);
        final fake = _RecordingStream([
          _toolTurn([
            _call('others', {'tool_name': 'agent_message'}),
          ]),
          _toolTurn([_call('agent_message')]),
          _textTurn('done'),
        ]);
        final agent = Agent(
          model: _model,
          streamFunction: fake.call,
          toolExecutor: rig.executor,
          toolRegistry: rig.registry,
        );
        rig.mountTarget = agent;
        rig.gate.apply(
          _keep12Resolution(),
          rig.registry,
          agent,
          rebuildPrompt: () {},
        );
        agent.state.tools = rig.registry.tools;
        agent.missingToolResolver = rig.resolve;

        await agent.prompt('mount and call agent_message');

        expect(fake.calls, 3);
        expect(
          fake.contexts[1].tools!.map((t) => t.name),
          contains('agent_message'),
        );
        expect(rig.executed, contains('agent_message'));
      },
    );
  });
}
