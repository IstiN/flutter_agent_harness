/// Gate-level load-mode tests (issue #680 L2): the omp preset boots an
/// essential-only schema (byte-level), discoverable tools answer with a
/// tombstone that names the discovery path and never execute, a mount
/// puts the tool back into the schema mid-session, and the mount state
/// survives resolution re-applies.
library;

import 'dart:convert';

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

AgentTool _tool(String name, String description) {
  return AgentTool(
    name: name,
    description: description,
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
    },
    execute: (args, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('$name ok'),
  );
}

ToolCall _call(String id, String name, [Map<String, dynamic> args = const {}]) {
  return ToolCall(id: id, name: name, arguments: args);
}

/// The omp essential set plus a few discoverable stand-ins.
final _toolsById = <String, List<AgentTool>>{
  for (final id in essentialToolIdsByLoadMode[AgentLoadMode.omp]!)
    id: [_tool(id, '$id tool\nlonger doc')],
  'lsp': [_tool('lsp', 'lsp diagnostics\nlonger doc')],
  'web_search': [_tool('web_search', 'web search\nlonger doc')],
};

ToolAvailabilityResolution _ompResolution() {
  return resolveToolAvailability(
    capabilities: {
      for (final id in _toolsById.keys) id: const ToolCapability.available(),
    },
    scopes: const [(ToolScope.session, ToolsConfig())],
    essentialToolIds: essentialToolIdsByLoadMode[AgentLoadMode.omp],
  );
}

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

/// The byte-level wire schema of [registry] in a stable order.
String _schemaBytes(ToolRegistry registry) {
  final names = registry.names.toList()..sort();
  return jsonEncode([
    for (final name in names)
      {
        'name': name,
        'description': registry.lookup(name)!.description,
        'parameters': registry.lookup(name)!.parameters,
      },
  ]);
}

void main() {
  final essentialNames =
      essentialToolIdsByLoadMode[AgentLoadMode.omp]!.toList()..sort();

  group('essential-only boot schema (issue #680 L2)', () {
    test('registry holds exactly the omp essentials, byte-level', () {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      final expected = _schemaBytes(registry);

      gate.apply(
        _ompResolution(),
        registry,
        _agent(registry),
        rebuildPrompt: () {},
      );

      expect(_schemaBytes(registry), isNot(equals(expected)));
      expect(registry.names.toList()..sort(), essentialNames);
      // Byte-level: every schema byte comes from an essential tool.
      final bytes = _schemaBytes(registry);
      for (final name in ['lsp', 'web_search']) {
        expect(bytes, isNot(contains('"$name"')));
      }
    });

    test('provider context never sees a discoverable tool', () async {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      final contexts = <Context>[];
      final agent = Agent(
        model: _model,
        toolRegistry: registry,
        toolExecutor: gate.wrapExecutor(registry.executor),
        streamFunction: (model, context, {cancelToken}) {
          contexts.add(
            Context(
              systemPrompt: context.systemPrompt,
              messages: List.of(context.messages),
              tools: context.tools,
            ),
          );
          final stream = AssistantMessageEventStream();
          stream.end();
          return stream;
        },
      );
      gate.apply(
        _ompResolution(),
        registry,
        agent,
        rebuildPrompt: () {},
      );
      await agent.prompt('go');
      expect(
        contexts.single.tools!.map((t) => t.name).toList()..sort(),
        essentialNames,
      );
    });
  });

  group('discoverable tombstone (issue #680 L2)', () {
    test('unmounted call never executes and names the discovery path',
        () async {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      gate.apply(
        _ompResolution(),
        registry,
        _agent(registry),
        rebuildPrompt: () {},
      );
      var innerCalls = 0;
      final wrapped = gate.wrapExecutor((call, cancelToken, onUpdate) async {
        innerCalls++;
        return ToolExecutionResult.text('inner ${call.name}');
      });

      final result = await wrapped(_call('c1', 'lsp'), null, null);

      expect(innerCalls, 0, reason: 'an unmounted discoverable never runs');
      expect(result.terminate, isFalse);
      expect(
        (result.content.single as TextContent).text,
        'Tool `lsp` is discoverable and not loaded — call `discover_tools` '
        'to list available tools, then mount it by name.',
      );
    });
  });

  group('mid-session mount (issue #680 L2)', () {
    test(
      'mount re-applies the resolution: tool enters schema, prompt rebuilds',
      () {
        final gate = ToolAvailabilityGate(toolsById: _toolsById);
        final registry = ToolRegistry([
          for (final tools in _toolsById.values) ...tools,
        ]);
        final agent = _agent(registry);
        gate.apply(
          _ompResolution(),
          registry,
          agent,
          rebuildPrompt: () {},
        );
        expect(registry.contains('lsp'), isFalse);
        expect(gate.discoverableToolNames, containsAll(['lsp', 'web_search']));

        var rebuilds = 0;
        final mounted = gate.mount([
          'lsp',
        ], registry, agent, rebuildPrompt: () => rebuilds++);

        expect(mounted, {'lsp'});
        expect(registry.contains('lsp'), isTrue);
        expect(gate.discoverableToolNames, isNot(contains('lsp')));
        expect(gate.discoverableToolNames, contains('web_search'));
        expect(rebuilds, 1);
      },
    );

    test('mount state survives a resolution re-apply', () {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      final agent = _agent(registry);
      gate.apply(
        _ompResolution(),
        registry,
        agent,
        rebuildPrompt: () {},
      );
      gate.mount(['lsp'], registry, agent, rebuildPrompt: () {});

      gate.apply(
        _ompResolution(),
        registry,
        agent,
        rebuildPrompt: () {},
      );

      expect(registry.contains('lsp'), isTrue);
    });

    test('mounted discoverable executes through the wrapped executor',
        () async {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      final agent = _agent(registry);
      gate.apply(
        _ompResolution(),
        registry,
        agent,
        rebuildPrompt: () {},
      );
      gate.mount(['web_search'], registry, agent, rebuildPrompt: () {});

      final wrapped = gate.wrapExecutor(
        (call, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('inner ${call.name}'),
      );
      final result = await wrapped(_call('c1', 'web_search'), null, null);
      expect((result.content.single as TextContent).text, 'inner web_search');
    });

    test('mount ignores unknown and already-mounted ids', () {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      final agent = _agent(registry);
      gate.apply(
        _ompResolution(),
        registry,
        agent,
        rebuildPrompt: () {},
      );
      gate.mount(['lsp'], registry, agent, rebuildPrompt: () {});

      final mounted = gate.mount(
        ['lsp', 'not_a_tool'],
        registry,
        agent,
        rebuildPrompt: () {},
      );

      expect(mounted, isEmpty);
    });
  });

  group('discover_tools meta tool (issue #680 L2)', () {
    test('lists discoverable tools with first-line docs', () async {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
        discoverToolsTool(
          discoverableDocs: gate.discoverableDocs,
          onMount: (_) => '',
        ),
      ]);
      final agent = _agent(registry);
      gate.apply(
        _ompResolution(),
        registry,
        agent,
        rebuildPrompt: () {},
      );

      final docs = gate.discoverableDocs();
      expect(docs.keys, containsAll(['lsp', 'web_search']));
      expect(docs['lsp'], 'lsp diagnostics', reason: 'first line only');
      expect(
        registry.lookup('discover_tools'),
        isNotNull,
        reason: 'the meta tool carries no availability id and is never gated',
      );
    });

    test('listing reports nothing when everything is mounted', () async {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      final agent = _agent(registry);
      gate.apply(
        _ompResolution(),
        registry,
        agent,
        rebuildPrompt: () {},
      );
      gate.mount(
        ['lsp', 'web_search'],
        registry,
        agent,
        rebuildPrompt: () {},
      );

      final tool = discoverToolsTool(
        discoverableDocs: gate.discoverableDocs,
        onMount: (_) => 'mounted',
      );
      final result = await tool.execute({}, CancelTokenSource().token, null);
      expect(
        (result.content.single as TextContent).text,
        contains('No discoverable tools'),
      );
    });

    test('mount argument routes through onMount by name', () async {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      final agent = _agent(registry);
      gate.apply(
        _ompResolution(),
        registry,
        agent,
        rebuildPrompt: () {},
      );

      final requested = <String>[];
      final tool = discoverToolsTool(
        discoverableDocs: gate.discoverableDocs,
        onMount: (names) {
          requested.addAll(names);
          return 'Mounted (now in the schema): ${names.join(', ')}';
        },
      );
      final result = await tool.execute({
        'mount': ['lsp', '  ', 'web_search'],
      }, CancelTokenSource().token, null);

      expect(requested, ['lsp', 'web_search']);
      expect(
        (result.content.single as TextContent).text,
        contains('Mounted (now in the schema): lsp, web_search'),
      );
    });
  });
}
