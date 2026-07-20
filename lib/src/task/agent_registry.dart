/// Agent-type registry for the `task` tool: the built-in agent types plus
/// host-provided definitions, and the per-type child tool-surface
/// restriction.
///
/// Ported (reduced) from oh-my-pi's bundled agents
/// (`packages/coding-agent/src/task/agents.ts`) and discovery precedence
/// (`discovery.ts`): omp discovers `*.md` agent definitions from project /
/// user / plugin dirs with first-wins precedence over the bundled set; v1
/// keeps the bundled set (ported as `task`/`explore`/`review`) and lets
/// host config override or extend it — filesystem discovery is a follow-up.
///
/// omp's bundled `scout` (read-only research on the `@smol` role) is ported
/// as [builtinExploreAgent], `reviewer` as [builtinReviewAgent] (omp gives it
/// `bash`/`lsp`/`ast_grep`; our port is read-only on the `@slow` role), and
/// omp's general-purpose `task` worker is [builtinTaskAgent]. omp's
/// `designer`, `librarian`, and `sonic` agents are not ported.
library;

import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../model_roles/roles_config.dart';
import '../prompts/prompts.g.dart';
import 'task_types.dart';

/// Definition of a subagent type spawnable through the `task` tool (omp's
/// `AgentDefinition`, reduced: no `spawns`, `thinkingLevel`, frontmatter
/// `output`, or file source).
final class TaskAgentDefinition {
  /// Creates a [TaskAgentDefinition].
  const TaskAgentDefinition({
    required this.name,
    required this.description,
    required this.systemPrompt,
    this.toolNames,
    this.readOnly = false,
    this.modelRole,
  });

  /// The type name items reference via `agent`.
  final String name;

  /// One-line description rendered into the tool's agent list.
  final String description;

  /// System prompt seed for the child; the batch `context` is appended as a
  /// `# CONTEXT` section per spawn (omp's CONTEXT section).
  final String systemPrompt;

  /// Explicit allowlist of tool names from the parent pool (omp's `tools`
  /// frontmatter). `null` means no name restriction. The `task` tool itself
  /// is always excluded (no nested task calls in v1).
  final Set<String>? toolNames;

  /// When true, only [ApprovalTier.read] tools from the parent pool survive
  /// (omp's read-only agent kinds, generalized to host tools).
  final bool readOnly;

  /// Model role resolved through the host's `ModelRolesResolver` (exact omp
  /// role names: `smol`/`slow`/…). `null` — or an unconfigured role —
  /// inherits the parent model and stream.
  final String? modelRole;
}

/// omp's general-purpose worker (`prompts/agents/task.md`): full tool
/// surface, inherits the parent model.
final builtinTaskAgent = TaskAgentDefinition(
  name: defaultTaskAgentName,
  description:
      'General-purpose subagent with full capabilities for delegated '
      'multi-step tasks',
  systemPrompt: taskAgentTaskPrompt,
);

/// omp's `scout` ported under the name `explore`: read-only research on the
/// `smol` role.
final builtinExploreAgent = TaskAgentDefinition(
  name: 'explore',
  description:
      'Read-only codebase research: rapid analysis, pattern searches, and '
      'compressed findings for handoff (uses the smol model role when '
      'configured)',
  systemPrompt: taskAgentExplorePrompt,
  readOnly: true,
  modelRole: smolModelRole,
);

/// omp's `reviewer` ported under the name `review`: read-only code review on
/// the `slow` role.
final builtinReviewAgent = TaskAgentDefinition(
  name: 'review',
  description:
      'Read-only code review specialist for quality and security analysis '
      '(uses the slow model role when configured)',
  systemPrompt: taskAgentReviewPrompt,
  readOnly: true,
  // omp's reviewer runs on `@slow`; roles_config.dart only exports named
  // constants for `default`/`smol`, so the exact omp role name is literal here.
  modelRole: 'slow',
);

/// The built-in agent types, in registry order.
final builtinTaskAgentTypes = [
  builtinTaskAgent,
  builtinExploreAgent,
  builtinReviewAgent,
];

/// Resolves agent types for `task` calls: [TaskAgentRegistry.resolve] finds a
/// type by name, [TaskAgentRegistry.toolSurfaceFor] computes a type's
/// restricted child tool surface.
final class TaskAgentRegistry {
  /// Creates a registry of the built-in types plus [overrides]. A host
  /// definition whose name collides with a built-in replaces it (omp's
  /// project-over-bundled precedence).
  TaskAgentRegistry([Iterable<TaskAgentDefinition> overrides = const []]) {
    for (final agent in builtinTaskAgentTypes) {
      _agents[agent.name] = agent;
    }
    for (final agent in overrides) {
      if (agent.name.trim().isEmpty) {
        throw ArgumentError.value(agent.name, 'agentTypes', 'empty agent name');
      }
      _agents[agent.name] = agent;
    }
  }

  final _agents = <String, TaskAgentDefinition>{};

  /// All registered types, built-ins first, in registration order.
  List<TaskAgentDefinition> get agents => List.unmodifiable(_agents.values);

  /// Looks up a type by [name]; `null` when unknown.
  TaskAgentDefinition? resolve(String name) => _agents[name];

  /// Computes [agent]'s child tool surface from the parent [pool]
  /// (omp's child-tool wiring, reduced): the `task` tool is ALWAYS stripped
  /// (no nested task calls), then [TaskAgentDefinition.toolNames] and
  /// [TaskAgentDefinition.readOnly] filters apply. Pool order is preserved.
  List<AgentTool> toolSurfaceFor(
    TaskAgentDefinition agent,
    List<AgentTool> pool,
  ) {
    return [
      for (final tool in pool)
        if (tool.name != taskToolName &&
            (agent.toolNames == null || agent.toolNames!.contains(tool.name)) &&
            (!agent.readOnly || tool.tier == ApprovalTier.read))
          tool,
    ];
  }
}
