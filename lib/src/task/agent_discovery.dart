/// Agent-type discovery from the filesystem (Phase 4): scans project and
/// user roots for `<name>.md` files with YAML frontmatter, mirroring the
/// skill discovery pattern. Discovered types merge into the
/// [TaskAgentRegistry] alongside the built-in types.
///
/// Format: one `<name>.md` per agent type, YAML frontmatter + body:
/// ```markdown
/// ---
/// name: security-review
/// description: Reviews diffs for security issues; read-only.
/// tools: [read, grep, glob, bash]
/// readOnly: true
/// modelRole: slow
/// ---
/// You are a security reviewer… (system prompt body)
/// ```
library;

import '../env/execution_env.dart';
import '../model_roles/roles_config.dart';
import '../utils/frontmatter_parser.dart';
import 'agent_registry.dart';

/// The result of discovering agent types: the definitions plus any parse
/// notes (skipped files, unknown keys).
final class AgentDiscoveryResult {
  const AgentDiscoveryResult({required this.agents, this.notes = const []});
  final List<TaskAgentDefinition> agents;
  final List<String> notes;
}

/// Discovers agent types from `.fah/agents/` and `.agents/agents/`
/// directories under [projectRoots] then [userRoots] (project wins on name
/// clash, first-name-wins case-insensitively). Missing roots are silently
/// skipped.
Future<AgentDiscoveryResult> discoverTaskAgents(
  ExecutionEnv env, {
  List<String> projectRoots = const [],
  List<String> userRoots = const [],
}) async {
  final agents = <TaskAgentDefinition>[];
  final notes = <String>[];
  final seen = <String>{};
  for (final roots in [projectRoots, userRoots]) {
    for (final root in roots) {
      final dirResult = await env.listDir(root);
      final entries = dirResult.valueOrNull;
      if (entries == null) continue;
      for (final entry in entries) {
        if (entry.kind != FileKind.file || !entry.name.endsWith('.md'))
          continue;
        final name = entry.name.substring(0, entry.name.length - 3);
        if (!seen.add(name.toLowerCase())) continue;
        final textResult = await env.readTextFile(entry.path);
        final text = textResult.valueOrNull;
        if (text == null) continue;
        final parsed = _parseAgentFile(name, text);
        if (parsed.note != null) notes.add(parsed.note!);
        if (parsed.definition != null) agents.add(parsed.definition!);
      }
    }
  }
  return AgentDiscoveryResult(agents: agents, notes: notes);
}

/// The default agent roots for a host.
({List<String> projectRoots, List<String> userRoots}) defaultAgentRoots({
  required String cwd,
  String? homeDir,
}) {
  return (
    projectRoots: [
      '$cwd/.fah/agents',
      '$cwd/.agents/agents',
      '$cwd/.claude/agents', // Claude Code convention (compat)
    ],
    userRoots: homeDir == null
        ? const <String>[]
        : [
            '$homeDir/.fah/agents',
            '$homeDir/.agents/agents',
            '$homeDir/.claude/agents', // Claude Code convention (compat)
          ],
  );
}

({TaskAgentDefinition? definition, String? note}) _parseAgentFile(
  String fallbackName,
  String text,
) {
  final (frontmatter, body) = parseFrontmatter(text);
  final name = (frontmatter['name'] ?? fallbackName).trim();
  final description = (frontmatter['description'] ?? '').trim();
  final systemPrompt = body.trim();

  // Validate known keys. The Claude Code frontmatter vocabulary
  // (`.claude/agents/*.md`) is accepted for compatibility: `model` maps onto
  // our `modelRole` when it names a known role; the rest is ignored.
  const nativeKeys = {'name', 'description', 'tools', 'readOnly', 'modelRole'};
  const claudeCompatKeys = {
    'model', // alias of modelRole when it names a known role
    'disallowedTools',
    'permissionMode',
    'mcpServers',
    'hooks',
    'maxTurns',
    'skills',
    'initialPrompt',
    'memory',
    'effort',
    'background',
    'isolation',
  };
  final unknown = frontmatter.keys.where(
    (k) => !nativeKeys.contains(k) && !claudeCompatKeys.contains(k),
  );
  if (unknown.isNotEmpty) {
    return (
      definition: null,
      note:
          'agent "$name": unknown frontmatter keys: ${unknown.join(', ')} '
          '— skipped',
    );
  }

  final readOnlyStr = frontmatter['readOnly'];
  final readOnly = readOnlyStr == 'true';

  final toolsStr = frontmatter['tools'];
  Set<String>? toolNames;
  if (toolsStr != null) {
    final list = toolsStr.toString();
    toolNames = list
        .replaceAll('[', '')
        .replaceAll(']', '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  // `modelRole` wins; `model` (Claude Code) acts as its alias when it names
  // a known role. Anything else is ignored (we cannot map arbitrary model
  // ids onto roles).
  var modelRole = frontmatter['modelRole'];
  String? compatNote;
  if (modelRole == null) {
    final model = frontmatter['model']?.trim();
    if (model != null && model.isNotEmpty) {
      if (modelRoleIds.contains(model)) {
        modelRole = model;
      } else {
        compatNote =
            'agent "$name": model "$model" is not a known role '
            '(${modelRoleIds.join(', ')}) — using the parent model';
      }
    }
  }

  return (
    definition: TaskAgentDefinition(
      name: name,
      description: description.isEmpty
          ? 'Discovered agent type: $name'
          : description,
      systemPrompt: systemPrompt.isEmpty ? 'You are $name.' : systemPrompt,
      toolNames: toolNames,
      readOnly: readOnly,
      modelRole: modelRole,
    ),
    note: compatNote,
  );
}
