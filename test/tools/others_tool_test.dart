/// The `others` discovery surface (GOAL #28, issue #2416 UT-3): the
/// listing (no tool_name) shows every deferred tool with a one-line doc;
/// a mount returns the tool's own description plus the compact schema —
/// the SAME bytes the ledger's `TrajectoryToolManifestEntry` captures
/// (I4); unknown, disabled, and already-mounted inputs each answer their
/// pinned text and never throw.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

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

void main() {
  final deferred = _tool(
    'config',
    'Read or change session settings.\nlonger doc line',
  );
  // A fresh gate per call: mount state is gate-scoped, so tests must not
  // share one instance.
  ToolAvailabilityGate mkGate() {
    final gate = ToolAvailabilityGate(
      toolsById: {
        'read': [_tool('read', 'read a file')],
        'config': [deferred],
      },
    );
    gate.discoveryEnabled = true;
    return gate;
  }

  final resolution = resolveToolAvailability(
    capabilities: {
      'read': const ToolCapability.available(),
      'config': const ToolCapability.available(),
    },
    scopes: const [(ToolScope.session, ToolsConfig())],
    essentialNames: const {'read'},
  );

  AgentTool build(ToolAvailabilityGate gate) => othersTool(
    description: 'Deferred tools (not loaded): config.',
    discoverableDocs: gate.discoverableDocs,
    onMount: (requested) {
      final name = requested.single;
      final tool = gate.originalTool(name);
      if (tool == null) {
        return 'no such deferred tool: $name; available: '
            '${gate.discoverableToolNames.join(', ')}';
      }
      final doc = '${tool.description}\n${jsonEncode(tool.parameters)}';
      final mounted = gate.mount(
        [name],
        ToolRegistry([]),
        _noopAgent(),
        rebuildPrompt: () {},
      );
      return mounted.isEmpty
          ? '`$name` is already loaded.\n$doc'
          : 'Loaded `$name` (now in the schema):\n$doc';
    },
  );

  group('listing (no tool_name)', () {
    test('lists every deferred tool with a first-line doc', () async {
      final gate = mkGate();
      gate.apply(
        resolution,
        ToolRegistry([]),
        _noopAgent(),
        rebuildPrompt: () {},
      );
      final result = await build(
        gate,
      ).execute({}, CancelTokenSource().token, null);
      final text = (result.content.single as TextContent).text;
      expect(text, contains('Deferred tools'));
      expect(text, contains('- config: Read or change session settings.'));
    });

    test(
      'an empty deferred set answers the pinned nothing-loaded text',
      () async {
        final emptyGate = ToolAvailabilityGate(
          toolsById: {
            'read': [_tool('read', 'read a file')],
          },
        );
        final allMounted = resolveToolAvailability(
          capabilities: {'read': const ToolCapability.available()},
          scopes: const [(ToolScope.session, ToolsConfig())],
          essentialNames: const {'read'},
        );
        emptyGate.apply(
          allMounted,
          ToolRegistry([]),
          _noopAgent(),
          rebuildPrompt: () {},
        );
        final tool = othersTool(
          description: 'Deferred tools.',
          discoverableDocs: emptyGate.discoverableDocs,
          onMount: (_) => '',
        );
        final result = await tool.execute({}, CancelTokenSource().token, null);
        expect(
          (result.content.single as TextContent).text,
          contains('No deferred tools'),
        );
      },
    );
  });

  group('mount (tool_name)', () {
    test(
      'returns description + compact schema — the ledger bytes (I4)',
      () async {
        final gate = mkGate();
        gate.apply(
          resolution,
          ToolRegistry([]),
          _noopAgent(),
          rebuildPrompt: () {},
        );
        final result = await build(
          gate,
        ).execute({'tool_name': 'config'}, CancelTokenSource().token, null);
        final text = (result.content.single as TextContent).text;
        expect(text, startsWith('Loaded `config`'));
        final doc = text.split('\n').skip(1).join('\n');
        expect(
          doc,
          '${deferred.description}\n${jsonEncode(deferred.parameters)}',
        );
        // The I4 pin: the schema bytes equal the ledger entry's capture.
        final entry = TrajectoryToolManifestEntry.of(deferred);
        expect(doc.endsWith(jsonEncode(deferred.parameters)), isTrue);
        expect(entry.name, 'config');
      },
    );

    test('an unknown name answers the available list, never throws', () async {
      final gate = mkGate();
      gate.apply(
        resolution,
        ToolRegistry([]),
        _noopAgent(),
        rebuildPrompt: () {},
      );
      final result = await build(
        gate,
      ).execute({'tool_name': 'nope'}, CancelTokenSource().token, null);
      final text = (result.content.single as TextContent).text;
      expect(text, contains('no such deferred tool: nope'));
      expect(text, contains('config'));
    });

    test('an already-mounted name answers docs again (E10)', () async {
      final gate = mkGate();
      final registry = ToolRegistry([_tool('read', 'read a file'), deferred]);
      gate.apply(resolution, registry, _noopAgent(), rebuildPrompt: () {});
      // Mount once.
      await build(
        gate,
      ).execute({'tool_name': 'config'}, CancelTokenSource().token, null);
      // Again: docs, no throw.
      final result = await build(
        gate,
      ).execute({'tool_name': 'config'}, CancelTokenSource().token, null);
      final text = (result.content.single as TextContent).text;
      expect(text, contains('already loaded'));
      expect(text, contains(deferred.description));
    });

    test('a disabled name is not discoverable and never mounts (I3)', () {
      final disabled = resolveToolAvailability(
        capabilities: {
          'read': const ToolCapability.available(),
          'config': const ToolCapability.available(),
        },
        scopes: const [
          (ToolScope.session, ToolsConfig(tools: {'config': false})),
        ],
        essentialNames: const {'read'},
      );
      expect(disabled.byId['config']!.enabled, isFalse);
      expect(disabled.discoverableNames, isNot(contains('config')));
    });
  });
}

Agent _noopAgent() {
  return Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test-provider',
      baseUrl: 'https://example.test',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    toolRegistry: ToolRegistry(const []),
    streamFunction: (model, context, {cancelToken}) {
      final stream = AssistantMessageEventStream();
      stream.end();
      return stream;
    },
  );
}
