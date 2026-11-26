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

/// An omp resolution with live MCP server families (issue #680 review:
/// the demotion must cover `mcp:<server>` too — the card lists mcp__*
/// among the discoverable, and they carry the heaviest schemas).
ToolAvailabilityResolution _ompResolutionWithMcp(Iterable<String> servers) {
  return resolveToolAvailability(
    capabilities: {
      ...{
        for (final id in _toolsById.keys) id: const ToolCapability.available(),
      },
      'mcp': const ToolCapability.available(),
    },
    scopes: const [(ToolScope.session, ToolsConfig())],
    essentialToolIds: essentialToolIdsByLoadMode[AgentLoadMode.omp],
    mcpServerIds: servers,
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
  final essentialNames = essentialToolIdsByLoadMode[AgentLoadMode.omp]!.toList()
    ..sort();

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
      gate.apply(_ompResolution(), registry, agent, rebuildPrompt: () {});
      await agent.prompt('go');
      expect(
        contexts.single.tools!.map((t) => t.name).toList()..sort(),
        essentialNames,
      );
    });
  });

  group('discoverable tombstone (issue #680 L2)', () {
    test(
      'unmounted call never executes and names the discovery path',
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

        // omp boots the discovery surface, so the tombstone names it.
        gate.discoveryEnabled = true;
        final result = await wrapped(_call('c1', 'lsp'), null, null);

        expect(innerCalls, 0, reason: 'an unmounted discoverable never runs');
        expect(result.terminate, isFalse);
        expect(
          (result.content.single as TextContent).text,
          'Tool `lsp` is deferred (not loaded) — call `others` with '
          '`tool_name: "lsp"` to load its full description and schema, '
          'then call it again normally.',
        );

        // Discovery off (pi's shape, issue #679): the pointer must be
        // the /settings load-mode switch, never the `discover_tools`
        // tool that mode does not register (issue #680 review — the
        // dead-end tombstone).
        gate.discoveryEnabled = false;
        final piResult = await wrapped(_call('c2', 'lsp'), null, null);
        expect(innerCalls, 0);
        expect(
          (piResult.content.single as TextContent).text,
          'Tool `lsp` is deferred (not loaded) in this mode — this '
          'mode ships no discovery surface; ask the user to switch '
          'the load mode via /settings (agent.mode) — see '
          'docs/tool-availability.md §Load modes.',
        );
      },
    );
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
        gate.apply(_ompResolution(), registry, agent, rebuildPrompt: () {});
        expect(registry.contains('lsp'), isFalse);
        expect(gate.discoverableToolNames, containsAll(['lsp', 'web_search']));

        var rebuilds = 0;
        final mounted = gate.mount(
          ['lsp'],
          registry,
          agent,
          rebuildPrompt: () => rebuilds++,
        );

        expect(mounted, {'lsp'});
        expect(registry.contains('lsp'), isTrue);
        expect(gate.discoverableToolNames, isNot(contains('lsp')));
        expect(gate.discoverableToolNames, contains('web_search'));
        expect(rebuilds, 1);
      },
    );

    test('others stub re-registration replaces the frozen description '
        'in place (issue #2416 review round 2)', () {
      // The sync path re-registers the stub with a FRESH deferred list on
      // every rebuild: after a mount the mounted name must stop being
      // advertised as "not loaded" in the schema the provider serializes.
      AgentTool stub(String description) => othersTool(
        description: description,
        discoverableDocs: () => const <String, String>{},
        onMount: (requested) => requested.join(', '),
      );
      final registry = ToolRegistry([
        stub('Deferred tools (not loaded): lsp, web_search.'),
      ]);
      final before = registry.tools.singleWhere((t) => t.name == 'others');
      expect(before.description, contains('lsp'));
      registry.register(stub('Deferred tools (not loaded): web_search.'));
      final after = registry.tools.singleWhere((t) => t.name == 'others');
      expect(registry.tools.where((t) => t.name == 'others'), hasLength(1));
      expect(after.description, isNot(contains('lsp')));
      expect(after.description, contains('web_search'));
    });

    test('mount state survives a resolution re-apply', () {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      final agent = _agent(registry);
      gate.apply(_ompResolution(), registry, agent, rebuildPrompt: () {});
      gate.mount(['lsp'], registry, agent, rebuildPrompt: () {});

      gate.apply(_ompResolution(), registry, agent, rebuildPrompt: () {});

      expect(registry.contains('lsp'), isTrue);
    });

    test(
      'mounted discoverable executes through the wrapped executor',
      () async {
        final gate = ToolAvailabilityGate(toolsById: _toolsById);
        final registry = ToolRegistry([
          for (final tools in _toolsById.values) ...tools,
        ]);
        final agent = _agent(registry);
        gate.apply(_ompResolution(), registry, agent, rebuildPrompt: () {});
        gate.mount(['web_search'], registry, agent, rebuildPrompt: () {});

        final wrapped = gate.wrapExecutor(
          (call, cancelToken, onUpdate) async =>
              ToolExecutionResult.text('inner ${call.name}'),
        );
        final result = await wrapped(_call('c1', 'web_search'), null, null);
        expect((result.content.single as TextContent).text, 'inner web_search');
      },
    );

    test('mount ignores unknown and already-mounted ids', () {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      final agent = _agent(registry);
      gate.apply(_ompResolution(), registry, agent, rebuildPrompt: () {});
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

  group('MCP family demotion (issue #680 review)', () {
    // The dynamic family surface, as the manager reports it.
    final ctxTools = [
      _tool('mcp__ctx__get', 'read a doc\nlonger doc'),
      _tool('mcp__ctx__put', 'write a doc\nlonger doc'),
    ];

    /// Boots the gate + registry the way the CLI does: static tools at
    /// construction, the MCP family noted (names AND instances) and
    /// registered when its server connects, then the omp resolution
    /// applied — which must prune the demoted family back out.
    (ToolAvailabilityGate, ToolRegistry) boot() {
      // A COPY of the groups map: the gate stores it by reference and
      // noteFamilyTools writes into it, and the shared `_toolsById`
      // fixture must stay pristine for the next test (the CLI builds a
      // fresh groups map per rebuild, same isolation).
      final gate = ToolAvailabilityGate(
        toolsById: {
          for (final entry in _toolsById.entries) entry.key: [...entry.value],
        },
      );
      // omp boots with the discovery surface live.
      gate.discoveryEnabled = true;
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      gate.noteFamilyTools('mcp:ctx', ctxTools);
      registry.registerAll(ctxTools);
      gate.apply(
        _ompResolutionWithMcp(const ['ctx']),
        registry,
        _agent(registry),
        rebuildPrompt: () {},
      );
      return (gate, registry);
    }

    test('a demoted family is out of the schema but discoverable', () {
      final (gate, registry) = boot();
      expect(registry.contains('mcp__ctx__get'), isFalse);
      expect(registry.contains('mcp__ctx__put'), isFalse);
      expect(gate.familyVisible('mcp:ctx'), isFalse);
      expect(
        gate.discoverableToolNames,
        containsAll(['mcp__ctx__get', 'mcp__ctx__put']),
      );
      // The listing documents dynamic family tools like static ones.
      expect(gate.discoverableDocs()['mcp__ctx__get'], 'read a doc');
    });

    test('an unmounted family member tombstones, naming the path', () async {
      final (gate, _) = boot();
      final wrapped = gate.wrapExecutor((call, cancelToken, onUpdate) async {
        return ToolExecutionResult.text('inner ${call.name}');
      });
      final result = await wrapped(_call('c1', 'mcp__ctx__get'), null, null);
      expect(
        (result.content.single as TextContent).text,
        'Tool `mcp__ctx__get` is deferred (not loaded) — call `others` '
        'with `tool_name: "mcp__ctx__get"` to load its full description '
        'and schema, then call it again normally.',
      );
    });

    test('mounting the family registers its noted tools', () {
      final (gate, registry) = boot();
      final agent = _agent(registry);
      expect(gate.availabilityIdOf('mcp__ctx__get'), 'mcp:ctx');

      // GOAL #2416: the model mounts by NAME — mounting one member of a
      // dynamic family loads the whole id-level family.
      final mounted = gate.mount(
        ['mcp__ctx__get'],
        registry,
        agent,
        rebuildPrompt: () {},
      );

      expect(mounted, {'mcp__ctx__get'});
      expect(registry.contains('mcp__ctx__get'), isTrue);
      expect(registry.contains('mcp__ctx__put'), isTrue);
      expect(gate.familyVisible('mcp:ctx'), isTrue);
      expect(gate.discoverableToolNames, isNot(contains('mcp__ctx__get')));
    });

    test('a mounted family member executes through the executor', () async {
      final (gate, registry) = boot();
      final agent = _agent(registry);
      gate.mount(['mcp__ctx__put'], registry, agent, rebuildPrompt: () {});
      final wrapped = gate.wrapExecutor(
        (call, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('inner ${call.name}'),
      );
      final result = await wrapped(_call('c1', 'mcp__ctx__put'), null, null);
      expect(
        (result.content.single as TextContent).text,
        'inner mcp__ctx__put',
      );
    });
  });

  group('others discovery surface (issue #680 L2 + GOAL #2416)', () {
    test('lists discoverable tools with first-line docs', () async {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
        othersTool(
          description: 'Deferred tools (not loaded): lsp, web_search.',
          discoverableDocs: gate.discoverableDocs,
          onMount: (_) => '',
        ),
      ]);
      final agent = _agent(registry);
      gate.apply(_ompResolution(), registry, agent, rebuildPrompt: () {});

      final docs = gate.discoverableDocs();
      expect(docs.keys, containsAll(['lsp', 'web_search']));
      expect(docs['lsp'], 'lsp diagnostics', reason: 'first line only');
      expect(
        registry.lookup(othersToolName),
        isNotNull,
        reason:
            'the discovery tool carries no availability id and is never gated',
      );
    });

    test('listing reports nothing when everything is mounted', () async {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      final agent = _agent(registry);
      gate.apply(_ompResolution(), registry, agent, rebuildPrompt: () {});
      gate.mount(['lsp', 'web_search'], registry, agent, rebuildPrompt: () {});

      final tool = othersTool(
        description: 'Deferred tools.',
        discoverableDocs: gate.discoverableDocs,
        onMount: (_) => 'mounted',
      );
      final result = await tool.execute({}, CancelTokenSource().token, null);
      expect(
        (result.content.single as TextContent).text,
        contains('No deferred tools'),
      );
    });

    test('tool_name routes through onMount by name', () async {
      final gate = ToolAvailabilityGate(toolsById: _toolsById);
      final registry = ToolRegistry([
        for (final tools in _toolsById.values) ...tools,
      ]);
      final agent = _agent(registry);
      gate.apply(_ompResolution(), registry, agent, rebuildPrompt: () {});

      final requested = <String>[];
      final tool = othersTool(
        description: 'Deferred tools.',
        discoverableDocs: gate.discoverableDocs,
        onMount: (names) {
          requested.addAll(names);
          return 'Mounted (now in the schema): ${names.join(', ')}';
        },
      );
      final result = await tool.execute(
        {'tool_name': '  lsp  '},
        CancelTokenSource().token,
        null,
      );

      expect(requested, ['lsp']);
      expect(
        (result.content.single as TextContent).text,
        contains('Mounted (now in the schema): lsp'),
      );
    });
  });

  group('default partition: name-level demotion (GOAL #2416 UT-2)', () {
    // The keep-12 fixture: the memory family SPLITS (add/search keep,
    // list/delete defer) and reply (a task-family member) stays.
    final partitionTools = <String, List<AgentTool>>{
      'read': [_tool('read', 'read a file\nlonger doc')],
      'write': [_tool('write', 'write a file\nlonger doc')],
      'edit': [_tool('edit', 'edit a file\nlonger doc')],
      'ls': [_tool('ls', 'list a dir\nlonger doc')],
      'bash': [_tool('bash', 'run a command\nlonger doc')],
      'bash_job': [_tool('bash_job', 'job board\nlonger doc')],
      'lsp': [_tool('lsp', 'lsp diagnostics\nlonger doc')],
      'web_search': [
        _tool('web_search', 'web search\nlonger doc'),
        _tool('web_fetch', 'web fetch\nlonger doc'),
      ],
      'memory': [
        _tool('memory_add', 'add a memory\nlonger doc'),
        _tool('memory_search', 'search memories\nlonger doc'),
        _tool('memory_list', 'list memories\nlonger doc'),
        _tool('memory_delete', 'delete a memory\nlonger doc'),
      ],
      'task': [
        _tool('task', 'spawn a subagent\nlonger doc'),
        _tool('task_status', 'task status\nlonger doc'),
        _tool('reply', 'reply to the parent\nlonger doc'),
      ],
      'config': [_tool('config', 'read settings\nlonger doc')],
    };

    ToolAvailabilityResolution partitionResolution({
      Map<String, bool> tools = const {},
      Iterable<String> mcpServerIds = const [],
    }) => resolveToolAvailability(
      capabilities: {
        for (final id in partitionTools.keys)
          id: const ToolCapability.available(),
        'mcp': const ToolCapability.available(),
      },
      scopes: [(ToolScope.session, ToolsConfig(tools: tools))],
      essentialNames: essentialToolNamesByLoadMode[AgentLoadMode.defaultMode],
      conditionalNames: conditionalCapabilityToolNames,
      mcpServerIds: mcpServerIds,
    );

    test('the memory family splits per name', () {
      final r = partitionResolution();
      expect(
        r.discoverableNames,
        containsAll(['memory_list', 'memory_delete']),
      );
      expect(r.discoverableNames, isNot(contains('memory_add')));
      expect(r.discoverableNames, isNot(contains('memory_search')));
      expect(r.discoverableIds, isNot(contains('memory')));
    });

    test('reply stays loaded inside the deferred task family', () {
      final r = partitionResolution();
      expect(r.discoverableNames, containsAll(['task', 'task_status']));
      expect(r.discoverableNames, isNot(contains('reply')));
    });

    test('the keep-12 and conditional names never defer', () {
      final r = partitionResolution();
      for (final name in [
        ...essentialToolNamesByLoadMode[AgentLoadMode.defaultMode]!,
        ...conditionalCapabilityToolNames,
      ]) {
        expect(r.discoverableNames, isNot(contains(name)), reason: name);
      }
    });

    test('off beats demotion: the family leaves schema AND listing', () {
      final r = partitionResolution(tools: {'task': false});
      expect(r.byId['task']!.enabled, isFalse);
      expect(r.discoverableNames, isNot(contains('task')));
      expect(r.discoverableNames, isNot(contains('task_status')));
    });

    test('a standing mount keeps the family loaded', () {
      final r = partitionResolution(tools: {'memory': true});
      expect(r.discoverableNames, isNot(contains('memory_list')));
      expect(r.discoverableNames, isNot(contains('memory_delete')));
    });

    test('MCP servers demote at id level under the default partition', () {
      final r = partitionResolution(mcpServerIds: const ['ctx']);
      expect(r.discoverableIds, contains('mcp:ctx'));
      // Static tools demote per NAME alongside the id-level families.
      expect(r.discoverableNames, contains('memory_list'));
    });

    test('registry visibility follows the name-level mounts', () {
      final gate = ToolAvailabilityGate(toolsById: partitionTools);
      final registry = ToolRegistry([
        for (final tools in partitionTools.values) ...tools,
      ]);
      final agent = _agent(registry);
      gate.discoveryEnabled = true;
      gate.apply(partitionResolution(), registry, agent, rebuildPrompt: () {});

      // keep: memory_add/memory_search/reply; deferred: the rest.
      expect(registry.contains('memory_add'), isTrue);
      expect(registry.contains('memory_search'), isTrue);
      expect(registry.contains('reply'), isTrue);
      expect(registry.contains('memory_list'), isFalse);
      expect(registry.contains('task'), isFalse);
      expect(registry.contains('config'), isFalse);
      expect(
        gate.discoverableToolNames,
        containsAll(['memory_list', 'memory_delete', 'task', 'config']),
      );
      expect(gate.discoverableToolNames, isNot(contains('reply')));

      // Mount ONE name of the split family — only that name loads.
      final mounted = gate.mount(
        ['memory_list'],
        registry,
        agent,
        rebuildPrompt: () {},
      );
      expect(mounted, {'memory_list'});
      expect(registry.contains('memory_list'), isTrue);
      expect(registry.contains('memory_delete'), isFalse);
      expect(registry.contains('memory_add'), isTrue);
    });

    test('a direct call to a hidden name tombstones toward others', () async {
      final gate = ToolAvailabilityGate(toolsById: partitionTools);
      final registry = ToolRegistry([
        for (final tools in partitionTools.values) ...tools,
      ]);
      final agent = _agent(registry);
      gate.discoveryEnabled = true;
      gate.apply(partitionResolution(), registry, agent, rebuildPrompt: () {});
      final wrapped = gate.wrapExecutor(
        (call, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('inner ${call.name}'),
      );
      final result = await wrapped(_call('c1', 'config'), null, null);
      expect(
        (result.content.single as TextContent).text,
        contains('deferred (not loaded)'),
      );
      expect((result.content.single as TextContent).text, contains('others'));
    });
  });
}
