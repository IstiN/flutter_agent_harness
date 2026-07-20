/// Shared types for the `task` tool (parallel subagents): the wire-facing
/// [TaskItem], per-spawn [TaskSingleResult], and structured-output metadata.
///
/// Ported (reduced) from oh-my-pi `packages/coding-agent/src/task/types.ts`:
/// keeps the batch wire shape and the `SingleResult`/`StructuredSubagentOutput`
/// essentials; drops omp's progress-render payloads, isolation/worktree
/// fields, usage-cost plumbing, and the `yield`-tool extraction surface
/// (v1 has no `yield` tool — the child's final assistant text is the output).
library;

/// The `task` tool name.
const taskToolName = 'task';

/// Default agent type when an item omits `agent` (omp's `DEFAULT_SPAWN_AGENT`).
const defaultTaskAgentName = 'task';

/// Default session concurrency cap (omp's `task.maxConcurrency` default; `0`
/// means unbounded — see [normalizeConcurrencyLimit]).
const defaultTaskMaxConcurrent = 32;

/// Maximum bytes of a subagent's raw output kept in the in-memory store and
/// the per-item result (omp's `MAX_OUTPUT_BYTES`).
const maxTaskOutputBytes = 500000;

/// Maximum lines of a subagent's raw output (omp's `MAX_OUTPUT_LINES`).
const maxTaskOutputLines = 5000;

/// Per-item output preview cap inside the blocking tool result text; the full
/// output stays addressable as `agent://<id>` (omp's `fullOutputThreshold`).
const taskOutputPreviewChars = 5000;

/// The internal URL scheme addressing subagent outputs.
const agentUrlScheme = 'agent';

/// One unit of work in a `task` batch call (omp's `TaskItem`, reduced: no
/// `isolated`, no `schemaMode`).
final class TaskItem {
  /// Creates a [TaskItem].
  const TaskItem({
    required this.task,
    this.name,
    this.agent,
    this.outputSchema,
  });

  /// Stable id base for the spawned agent ([A-Za-z0-9_-], ≤48 chars after
  /// sanitization). Uniquified per session (`Name`, `Name-2`, …). Defaults
  /// to the capitalized agent type name.
  final String? name;

  /// Agent type to run this item; `null` resolves to [defaultTaskAgentName].
  final String? agent;

  /// The work — complete, self-contained instructions.
  final String task;

  /// Caller-provided JSON Schema for the child's final output (omp's
  /// `outputSchema`). A map is enforced with the param-validation subset;
  /// `true` accepts any parseable JSON document; anything else disables
  /// validation ([StructuredTaskOutput] reports `unavailable`).
  final Object? outputSchema;
}

/// The agent type [item] runs as: its `agent`, or [defaultTaskAgentName]
/// when omitted (omp's spawn-policy default).
String taskItemAgentName(TaskItem item) {
  final agent = item.agent?.trim();
  return agent == null || agent.isEmpty ? defaultTaskAgentName : agent;
}

/// The requested id base for [item] (omp's `sanitizeAgentId`): its `name`
/// scrubbed to [A-Za-z0-9_-] (≤48 chars), defaulting to the capitalized
/// agent type name (omp's AdjectiveNoun name-generator is not ported).
String taskItemNameBase(TaskItem item) {
  final sanitized = item.name?.trim().replaceAll(RegExp('[^A-Za-z0-9_-]+'), '');
  if (sanitized != null && sanitized.isNotEmpty) {
    return sanitized.length > 48 ? sanitized.substring(0, 48) : sanitized;
  }
  final agent = taskItemAgentName(item);
  return agent[0].toUpperCase() + agent.substring(1);
}

/// Terminal state of one spawn (omp's `exitCode`/`aborted` pair as an enum:
/// `completed` ↔ 0, `failed` ↔ 1, `aborted` ↔ caller cancellation).
enum TaskSpawnStatus { completed, failed, aborted }

/// Final validation state of a schema-bearing spawn (omp's
/// `StructuredSubagentValidationStatus`).
enum StructuredValidationStatus {
  /// The final output parsed and satisfied the schema.
  valid,

  /// The output stayed invalid after the single fix retry (omp's exhausted
  /// retry budget; here always terminal — see `task_executor.dart`).
  invalid,

  /// The schema could not be honored (unsupported form), so nothing was
  /// enforced (omp's loose-acceptance diagnostics case).
  unavailable,
}

/// Parsed structured completion plus its validation metadata (omp's
/// `StructuredSubagentOutput`, reduced: no source/mode — v1 schemas always
/// come from the call item).
final class StructuredTaskOutput {
  /// Creates a [StructuredTaskOutput].
  const StructuredTaskOutput({required this.status, this.data, this.error});

  /// Validation outcome.
  final StructuredValidationStatus status;

  /// The parsed JSON document when one could be extracted (present for both
  /// [StructuredValidationStatus.valid] and `.invalid`, like omp).
  final Object? data;

  /// Why validation failed or was unavailable.
  final String? error;
}

/// Result of a single subagent execution (omp's `SingleResult`, reduced).
final class TaskSingleResult {
  /// Creates a [TaskSingleResult].
  const TaskSingleResult({
    required this.index,
    required this.id,
    required this.agent,
    required this.task,
    required this.status,
    required this.output,
    required this.truncated,
    required this.duration,
    required this.tokens,
    required this.requests,
    required this.model,
    this.error,
    this.structuredOutput,
  });

  /// Position of this item in the batch call.
  final int index;

  /// Allocated agent id — the `agent://<id>` address and background job id.
  final String id;

  /// The agent type that ran.
  final String agent;

  /// The assigned task text.
  final String task;

  /// Terminal state; a child failure is a per-item error entry, never a
  /// batch failure.
  final TaskSpawnStatus status;

  /// Text output (capped at [maxTaskOutputLines]/[maxTaskOutputBytes]); the
  /// full output lives in the `AgentOutputStore` under [id].
  final String output;

  /// Whether [output] was truncated.
  final bool truncated;

  /// Wall-clock duration of the child run (excluding semaphore wait).
  final Duration duration;

  /// Cumulative input + output + cacheWrite tokens across the child's turns
  /// (omp's `tokens` semantics).
  final int tokens;

  /// Count of assistant turns (omp's `requests`).
  final int requests;

  /// Resolved model id the child ran on (omp's `resolvedModel`, reduced to
  /// the bare id).
  final String model;

  /// Failure/abort detail when [status] is not [TaskSpawnStatus.completed].
  final String? error;

  /// Structured completion metadata when the item carried an `outputSchema`.
  final StructuredTaskOutput? structuredOutput;

  /// Convenience: omp's `exitCode` mapping of [status].
  int get exitCode => status == TaskSpawnStatus.completed ? 0 : 1;
}
