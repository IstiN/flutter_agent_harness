/// The `task` tool: parallel subagents with schema-validated results
/// (ported, reduced, from oh-my-pi's task tool).
///
/// See the file-level docs for the per-piece mapping:
///
/// - [task_tool.dart](task_tool.dart) — `taskTool` + `TaskToolConfig`, the
///   background [TaskJobManager], and blocking/background execution.
/// - [task_executor.dart](task_executor.dart) — the per-item child [Agent]
///   engine with schema validation (one fix retry, then an error entry).
/// - [agent_registry.dart](agent_registry.dart) — the agent-type registry
///   (built-in `task`/`explore`/`review` + host overrides) and per-type
///   tool-surface restriction.
/// - [parallel.dart](parallel.dart) — the session [Semaphore].
/// - [output_manager.dart](output_manager.dart) — `agent://` id allocation,
///   the session output store, and the URL resolver.
/// - [task_types.dart](task_types.dart) — the wire and result types.
library;

export 'agent_registry.dart';
export 'output_manager.dart';
export 'parallel.dart';
export 'task_executor.dart';
export 'task_tool.dart';
export 'task_types.dart';
