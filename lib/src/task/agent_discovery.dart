/// Agent-type discovery from the filesystem (Phase 4): scans project and
/// user roots for `<name>.md` (and Copilot's `<name>.agent.md`) files with
/// YAML frontmatter, mirroring the skill discovery pattern. Discovered types
/// merge into the [TaskAgentRegistry] alongside the built-in types.
///
/// Format: one file per agent type, YAML frontmatter + body:
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
import '../skills/skills.dart';
import '../utils/frontmatter_parser.dart';
import 'agent_registry.dart';

/// The result of discovering agent types: the definitions plus any parse
/// notes (skipped files, unknown keys).
final class AgentDiscoveryResult {
  const AgentDiscoveryResult({required this.agents, this.notes = const []});
  final List<TaskAgentDefinition> agents;
  final List<String> notes;
}

/// One agent discovery root: a directory to scan plus its [SkillSource]
/// (which host's convention the directory follows).
final class AgentRoot {
  const AgentRoot(this.path, this.source);

  final String path;
  final SkillSource source;
}

/// Discovers agent types from the agent directories under [projectRoots]
/// then [userRoots] (project wins on name clash, first-name-wins
/// case-insensitively). Missing roots are silently skipped. [allowedSources]
/// restricts which root sources are scanned (`null` = all).
Future<AgentDiscoveryResult> discoverTaskAgents(
  ExecutionEnv env, {
  List<AgentRoot> projectRoots = const [],
  List<AgentRoot> userRoots = const [],
  Set<SkillSource>? allowedSources,
}) async {
  final agents = <TaskAgentDefinition>[];
  final notes = <String>[];
  final seen = <String>{};
  for (final roots in [projectRoots, userRoots]) {
    for (final root in roots) {
      if (allowedSources != null && !allowedSources.contains(root.source)) {
        continue;
      }
      final dirResult = await env.listDir(root.path);
      final entries = dirResult.valueOrNull;
      if (entries == null) continue;
      for (final entry in entries) {
        if (entry.kind != FileKind.file) continue;
        final name = _agentNameFromFile(entry.name);
        if (name == null) continue;
        if (!seen.add(name.toLowerCase())) continue;
        final textResult = await env.readTextFile(entry.path);
        final text = textResult.valueOrNull;
        if (text == null) continue;
        final parsed = _parseAgentFile(name, text);
        notes.addAll(parsed.notes);
        if (parsed.definition != null) agents.add(parsed.definition!);
      }
    }
  }
  return AgentDiscoveryResult(agents: agents, notes: notes);
}

/// The fallback agent type name from a file name: `<name>.md` or Copilot's
/// `<name>.agent.md`; `null` for non-markdown files.
String? _agentNameFromFile(String fileName) {
  const copilotSuffix = '.agent.md';
  if (fileName.endsWith(copilotSuffix)) {
    return fileName.substring(0, fileName.length - copilotSuffix.length);
  }
  if (fileName.endsWith('.md')) {
    return fileName.substring(0, fileName.length - 3);
  }
  return null;
}

/// The default agent roots for a host.
({List<AgentRoot> projectRoots, List<AgentRoot> userRoots}) defaultAgentRoots({
  required String cwd,
  String? homeDir,
}) {
  return (
    projectRoots: [
      AgentRoot('$cwd/.fah/agents', SkillSource.fah),
      AgentRoot('$cwd/.agents/agents', SkillSource.agents),
      AgentRoot('$cwd/.claude/agents', SkillSource.claude), // Claude Code
      AgentRoot('$cwd/.github/agents', SkillSource.copilot), // Copilot
      AgentRoot('$cwd/.codex/agents', SkillSource.codex),
    ],
    userRoots: homeDir == null
        ? const <AgentRoot>[]
        : [
            AgentRoot('$homeDir/.fah/agents', SkillSource.fah),
            AgentRoot('$homeDir/.agents/agents', SkillSource.agents),
            AgentRoot('$homeDir/.claude/agents', SkillSource.claude),
            AgentRoot('$homeDir/.copilot/agents', SkillSource.copilot),
            AgentRoot('$homeDir/.codex/agents', SkillSource.codex),
          ],
  );
}

const _nativeAgentKeys = {
  'name',
  'description',
  'tools',
  'readOnly',
  'modelRole',
};
const _claudeAgentCompatKeys = {
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
const _copilotAgentCompatKeys = {
  'mcp-servers', // reported with a note below
  'target', // `vscode` targets VS Code only — the agent is skipped
  'argument-hint', // documented IDE-only key, ignored
  'handoffs', // documented IDE-only key, ignored
};

({TaskAgentDefinition? definition, List<String> notes}) _parseAgentFile(
  String fallbackName,
  String text,
) {
  final (frontmatter, body) = parseFrontmatterTyped(text);
  final name = '${frontmatter['name'] ?? fallbackName}'.trim();
  final description = '${frontmatter['description'] ?? ''}'.trim();
  final systemPrompt = body.trim();

  final validation = _validateAgentFrontmatter(name, frontmatter);
  if (validation.error != null) {
    return (definition: null, notes: [validation.error!]);
  }

  final notes = validation.notes;
  final readOnly = _parseAgentReadOnly(frontmatter['readOnly']);
  final toolNames = _parseAgentTools(frontmatter['tools']);
  final modelRole = _resolveAgentModelRole(
    frontmatter['modelRole'],
    frontmatter['model'],
    name,
    notes,
  );

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
    notes: notes,
  );
}

({String? error, List<String> notes}) _validateAgentFrontmatter(
  String name,
  Map<String, Object?> frontmatter,
) {
  final unknown = frontmatter.keys.where(
    (k) =>
        !_nativeAgentKeys.contains(k) &&
        !_claudeAgentCompatKeys.contains(k) &&
        !_copilotAgentCompatKeys.contains(k),
  );
  if (unknown.isNotEmpty) {
    return (
      error:
          'agent "$name": unknown frontmatter keys: ${unknown.join(', ')} '
          '— skipped',
      notes: const <String>[],
    );
  }

  // Copilot's `target: vscode` profiles only apply inside VS Code.
  final target = '${frontmatter['target'] ?? ''}'.trim();
  if (target == 'vscode') {
    return (
      error: 'agent "$name": target "vscode" targets VS Code only — skipped',
      notes: const <String>[],
    );
  }

  final notes = <String>[];
  if (frontmatter.containsKey('mcp-servers')) {
    notes.add(
      'agent "$name": mcp-servers in agent profiles not supported yet '
      '— ignored',
    );
  }
  return (error: null, notes: notes);
}

bool _parseAgentReadOnly(Object? value) => switch (value) {
  true => true,
  final other => '$other' == 'true',
};

/// `tools` accepts a YAML list (`[read, "grep"]`) or the comma-separated
/// string form (`read, grep`); `*` (either form) means the full parent tool
/// surface (`null`), an empty list means no tools.
Set<String>? _parseAgentTools(Object? toolsValue) {
  if (toolsValue == null) return null;
  final Iterable<String> entries;
  if (toolsValue is List) {
    entries = toolsValue.map((item) => '$item'.trim());
  } else {
    entries = '$toolsValue'.split(',').map((s) => s.trim());
  }
  final names = entries.where((s) => s.isNotEmpty).toSet();
  if (names.contains('*')) return null;
  return names.isEmpty ? null : names;
}

/// `modelRole` wins; `model` (Claude Code) acts as its alias when it names
/// a known role. Anything else is ignored (we cannot map arbitrary model
/// ids onto roles).
String? _resolveAgentModelRole(
  Object? modelRoleValue,
  Object? modelValue,
  String name,
  List<String> notes,
) {
  final explicit = modelRoleValue == null ? null : '$modelRoleValue';
  if (explicit != null) return explicit;
  final model = modelValue == null ? '' : '$modelValue'.trim();
  if (model.isEmpty) return null;
  if (modelRoleIds.contains(model)) return model;
  notes.add(
    'agent "$name": model "$model" is not a known role '
    '(${modelRoleIds.join(', ')}) — using the parent model',
  );
  return null;
}
