/// The `discover_tools` meta tool (issue #680): the discovery surface of
/// the essential/discoverable load modes, after oh-my-pi's xd:// model —
/// one tiny entry that lists the tools NOT loaded into the schema (with
/// one-line docs) and mounts them on demand. Mounting re-applies the
/// availability resolution, so the tool enters the registry and the
/// provider-facing prompt rebuilds.
///
/// Registered only in non-default load modes (`pi`, `omp`); the default
/// mode never sees it (byte-identical behavior). Pure Dart: no `dart:io`.
library;

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';

/// Builds the `discover_tools` tool.
///
/// [discoverableDocs] — name → one-line doc of the currently
/// discoverable-and-unmounted tools (the gate's live view).
/// [onMount] — mounts the requested names through the gate and returns
/// the user-facing result text (it reports unknown names itself).
AgentTool discoverToolsTool({
  required Map<String, String> Function() discoverableDocs,
  required String Function(List<String> requested) onMount,
}) {
  return AgentTool(
    name: 'discover_tools',
    description:
        'List tools not loaded in this mode, or mount tools by name. '
        'Pass no arguments to list every discoverable tool with a '
        'one-line doc; pass `mount` to load tools into the schema for '
        'the rest of the session.',
    parameters: {
      'type': 'object',
      'properties': {
        'mount': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Tool NAMES to mount (as listed without arguments). '
              'Omit to only list what is available.',
        },
      },
    },
    execute: (args, cancelToken, onUpdate) async {
      final requested = args['mount'];
      if (requested is! List) {
        final docs = discoverableDocs();
        if (docs.isEmpty) {
          return ToolExecutionResult.text(
            'No discoverable tools — everything available is already '
            'loaded.',
          );
        }
        final listing = [
          for (final entry in docs.entries) '- ${entry.key}: ${entry.value}',
        ].join('\n');
        return ToolExecutionResult.text(
          'Discoverable tools (not loaded; mount with `discover_tools` '
          'mount: [name]):\n$listing',
        );
      }
      final names = [
        for (final item in requested)
          if (item is String && item.trim().isNotEmpty) item.trim(),
      ];
      if (names.isEmpty) {
        return ToolExecutionResult.text(
          'error: mount needs at least one tool name',
        );
      }
      return ToolExecutionResult.text(onMount(names));
    },
  );
}
