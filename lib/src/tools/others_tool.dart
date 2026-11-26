/// The `others` discovery surface (GOAL #28, issue #2416; replaces
/// #680's `discover_tools`): ONE tiny entry that lists the tools NOT
/// loaded into the schema (with one-line docs) and mounts one on demand.
/// Mounting re-applies the availability resolution, so the tool enters
/// the registry and the provider-facing prompt rebuilds — the model then
/// calls the real tool natively (`others` never executes anything; its
/// schema has no arguments to forward, issue #2416 I2).
///
/// Registered iff discovery is on for the load mode AND at least one
/// deferred tool exists ([discoveryEnabledByLoadMode]: the default
/// partition and omp; pi keeps pi-mono's exact benchmark shape with
/// discovery off, issue #679). The tool carries no availability id, so it
/// sits outside the gate's groups and no resolution can hide it.
/// Pure Dart: no `dart:io`.
library;

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import 'availability.dart';

/// The `others` tool name.
const othersToolName = 'others';

/// The availability family label of a deferred tool name, for the
/// `others` listing's grouping: the host-agnostic family id, or the name
/// itself when the tool carries no family (host-wired and dynamic MCP
/// tools).
String _familyLabelOf(String name) => toolAvailabilityIdOf(name) ?? name;

/// Builds the `others` tool.
///
/// [description] — the stub's own manifest text (built by the wiring from
/// the live deferred names; AC9 pins its wire size).
/// [discoverableDocs] — name → one-line doc of the currently
/// discoverable-and-unmounted tools (the gate's live view).
/// [onMount] — mounts the requested name through the gate and returns the
/// user-facing result text (it reports unknown, disabled, and
/// already-mounted names itself, and carries the I4 doc bytes).
AgentTool othersTool({
  required String description,
  required Map<String, String> Function() discoverableDocs,
  required String Function(List<String> requested) onMount,
}) {
  return AgentTool(
    name: othersToolName,
    description: description,
    parameters: const {
      'type': 'object',
      'properties': {
        'tool_name': {
          'type': 'string',
          'description':
              'A deferred tool name from the list above; omit to list '
              'every deferred tool with a one-line doc.',
        },
      },
    },
    execute: (args, cancelToken, onUpdate) async {
      final requested = args['tool_name'];
      if (requested is! String || requested.trim().isEmpty) {
        final docs = discoverableDocs();
        if (docs.isEmpty) {
          return ToolExecutionResult.text(
            'No deferred tools — everything available is already loaded.',
          );
        }
        final lines = <String>[];
        var family = '';
        for (final MapEntry(key: name, value: doc) in docs.entries) {
          final label = _familyLabelOf(name);
          if (label != family) {
            family = label;
            lines.add('$family:');
          }
          lines.add('- $name: $doc');
        }
        return ToolExecutionResult.text(
          'Deferred tools (not loaded; call `others` with tool_name to '
          'load one):\n${lines.join('\n')}',
        );
      }
      return ToolExecutionResult.text(onMount([requested.trim()]));
    },
  );
}
