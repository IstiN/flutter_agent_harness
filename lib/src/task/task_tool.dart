/// The `task` tool: parallel subagents with schema-validated results.
///
/// Ported (reduced) from oh-my-pi `packages/coding-agent/src/task/index.ts`
/// (see `docs/tools/task.md`). The batch wire shape `{context, tasks[]}` is
/// omp's `task.batch=on` form — v1 has no flat single-spawn shape and no
/// `isolated` item field (workspace isolation is a follow-up).
///
/// Execution model (omp, reduced):
///
/// - **Blocking** (default): the call fans out under the session
///   [Semaphore] and the tool result carries every per-item output (previews
///   capped at [taskOutputPreviewChars]; full outputs stay addressable as
///   `agent://<id>`).
/// - **Background** (`background: true`, or [TaskToolConfig.defaultBackground]):
///   ids are allocated up front, one [TaskJob] per item is registered in the
///   session [TaskJobManager], and the call returns immediately. omp delivers
///   completions as async-result injections into the parent conversation; v1
///   exposes [TaskJobManager.completions] (plus per-job [TaskJob.settled] and
///   status polling) for the host to wire that injection — see AGENTS.md.
///
/// omp gates background execution on the global `async.enabled` setting; the
/// card's per-call `background` parameter (over [TaskToolConfig.defaultBackground])
/// is the host-neutral equivalent.
library;

import 'dart:async';

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../cancel_token.dart';
import '../model.dart';
import '../model_roles/model_resolver.dart';
import '../prompts/prompts.g.dart';
import 'agent_registry.dart';
import 'output_manager.dart';
import 'parallel.dart';
import 'task_executor.dart';
import 'task_types.dart';

/// Background job states (omp's async job states, reduced).
enum TaskJobStatus { queued, running, completed, failed, aborted }

/// One background subagent job (omp's `type: "task"` async job, reduced).
/// The job id IS the allocated agent id (omp semantics), so a settling job's
/// result stays addressable as `agent://<id>`.
final class TaskJob {
  TaskJob._({
    required this.id,
    required this.index,
    required this.agent,
    required this.task,
  });

  /// The job id (== the agent id).
  final String id;

  /// Position of this item in its batch call.
  final int index;

  /// The agent type running.
  final String agent;

  /// The assigned task.
  final String task;

  TaskJobStatus _status = TaskJobStatus.queued;
  TaskSingleResult? _result;
  final _cancelSource = CancelTokenSource();
  final _settled = Completer<void>();

  /// Current state.
  TaskJobStatus get status => _status;

  /// The per-item result once settled (present for every terminal state —
  /// a failed child is a failed job carrying its error entry, not a throw).
  TaskSingleResult? get result => _result;

  /// The token cancelling this job's child run.
  CancelToken get cancelToken => _cancelSource.token;

  /// Completes when the job reaches a terminal state.
  Future<void> get settled => _settled.future;

  /// Cancels the job's child run (omp's hub cancel); a queued job cancels
  /// while waiting on the session semaphore.
  void cancel() => _cancelSource.cancel();
}

/// Session-scoped registry of background `task` jobs (reduced port of omp's
/// `AsyncJobManager` role for task spawns).
///
/// Completion delivery: omp injects an async-result message into the parent
/// conversation when a job settles. v1 surfaces the same event through
/// [completions]; hosts inject the message (CLI wiring is a follow-up).
final class TaskJobManager {
  final _jobs = <String, TaskJob>{};
  final _completions = StreamController<TaskJob>.broadcast();

  /// Every job of the session, in registration order.
  List<TaskJob> get jobs => List.unmodifiable(_jobs.values);

  /// Looks a job up by id; `null` when unknown.
  TaskJob? job(String id) => _jobs[id];

  /// Broadcast stream of jobs as they settle (omp's async-result event).
  Stream<TaskJob> get completions => _completions.stream;

  /// Resolves when every registered job has settled.
  Future<void> get settled =>
      Future.wait([for (final job in _jobs.values) job.settled]);

  /// Closes the completions stream (session teardown).
  Future<void> close() => _completions.close();

  TaskJob _register({
    required String id,
    required int index,
    required String agent,
    required String task,
  }) {
    final job = TaskJob._(id: id, index: index, agent: agent, task: task);
    _jobs[id] = job;
    return job;
  }

  void _finish(TaskJob job, TaskSingleResult result) {
    job._result = result;
    job._status = switch (result.status) {
      TaskSpawnStatus.completed => TaskJobStatus.completed,
      TaskSpawnStatus.failed => TaskJobStatus.failed,
      TaskSpawnStatus.aborted => TaskJobStatus.aborted,
    };
    if (!job._settled.isCompleted) job._settled.complete();
    _completions.add(job);
  }
}

/// Configuration for [taskTool]. One config per session: the [semaphore],
/// [outputs] store, and [jobManager] are session-scoped through it, so
/// repeated (and concurrent) `task` calls share the concurrency bound and
/// the `agent://` id space (omp's session-scoped `TaskTool` instance).
final class TaskToolConfig {
  /// Creates a [TaskToolConfig].
  TaskToolConfig({
    required this.childTools,
    required this.streamFunction,
    required this.model,
    this.rolesResolver,
    this.agentTypes = const [],
    int maxConcurrent = defaultTaskMaxConcurrent,
    this.defaultBackground = false,
    AgentOutputStore? outputs,
    TaskJobManager? jobManager,
  }) : semaphore = Semaphore(normalizeConcurrencyLimit(maxConcurrent)),
       outputs = outputs ?? AgentOutputStore(),
       jobManager = jobManager ?? TaskJobManager();

  /// The parent tool pool children draw their restricted surface from.
  /// The `task` tool itself is always excluded from child surfaces (no
  /// nested task calls in v1).
  final List<AgentTool> childTools;

  /// The parent's provider adapter, inherited by children without a
  /// resolvable model role.
  final StreamFunction streamFunction;

  /// The parent's model, inherited the same way.
  final Model model;

  /// Optional role resolver; agent types with a
  /// [TaskAgentDefinition.modelRole] (e.g. the built-in `explore` on `smol`)
  /// resolve their model + stream through it, falling back to the parent
  /// wiring when the role is unconfigured.
  final ModelRolesResolver? rolesResolver;

  /// Host-provided agent types; a name colliding with a built-in replaces it
  /// (omp's project-over-bundled precedence).
  final List<TaskAgentDefinition> agentTypes;

  /// The session concurrency bound (omp's `task.maxConcurrency`; `0` means
  /// unbounded). Sized once — later changes need a new config (omp semantics).
  final Semaphore semaphore;

  /// Default execution mode when a call omits `background` (omp's
  /// `async.enabled`, made host-neutral per the card).
  final bool defaultBackground;

  /// The session output store backing `agent://` resolution.
  final AgentOutputStore outputs;

  /// The session background job registry.
  final TaskJobManager jobManager;
}

/// Creates the `task` tool bound to [config] (omp's `TaskTool`).
AgentTool taskTool({required TaskToolConfig config}) {
  final registry = TaskAgentRegistry(config.agentTypes);
  final executor = TaskExecutor(
    childTools: config.childTools,
    streamFunction: config.streamFunction,
    model: config.model,
    registry: registry,
    semaphore: config.semaphore,
    store: config.outputs,
    rolesResolver: config.rolesResolver,
  );

  final description = taskToolDescriptionPrompt
      .replaceAll('{{defaultAgent}}', defaultTaskAgentName)
      .replaceAll(
        '{{agents}}',
        registry.agents
            .map(
              (agent) =>
                  '### ${agent.name}${agent.readOnly ? ' (READ-ONLY)' : ''}\n'
                  '${agent.description}',
            )
            .join('\n'),
      );

  return AgentTool(
    name: taskToolName,
    label: 'task',
    tier: ApprovalTier.exec,
    description: description,
    parameters: const {
      'type': 'object',
      'properties': {
        'context': {
          'type': 'string',
          'description':
              'Shared background (project state, constraints, contracts) '
              'rendered into every spawned subagent\'s system prompt',
        },
        'tasks': {
          'type': 'array',
          'description': 'One subagent per item',
          'items': {
            'type': 'object',
            'properties': {
              'name': {
                'type': 'string',
                'description':
                    'Stable id base ([A-Za-z0-9_-]); uniquified per session',
              },
              'agent': {
                'type': 'string',
                'description':
                    'Agent type for this item (see the tool description); '
                    'omit for the general-purpose worker',
              },
              'task': {
                'type': 'string',
                'description':
                    'Complete, self-contained instructions for the subagent',
              },
              'outputSchema': {
                'description':
                    'JSON Schema the subagent\'s final output must satisfy; '
                    'invalid output gets one fix retry, then the item fails',
              },
            },
            'required': ['task'],
          },
        },
        'background': {
          'type': 'boolean',
          'description':
              'Run items as background jobs and return job ids immediately '
              '(default: host configuration)',
        },
      },
      'required': ['context', 'tasks'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final items = _parseItems(arguments, registry);
      final context = (arguments['context'] as String).trim();
      final background =
          (arguments['background'] as bool?) ?? config.defaultBackground;
      return background
          ? _spawnBackground(config, executor, items, context, cancelToken)
          : _runBlocking(
              config,
              executor,
              items,
              context,
              cancelToken,
              onUpdate,
            );
    },
  );
}

/// Validates the raw call arguments into [TaskItem]s (omp's batch
/// validation, reduced). Failures throw — the agent loop converts them into
/// an error tool result the model can fix and retry.
List<TaskItem> _parseItems(
  Map<String, dynamic> arguments,
  TaskAgentRegistry registry,
) {
  final context = (arguments['context'] as String?)?.trim() ?? '';
  if (context.isEmpty) {
    throw ArgumentError(
      'context must not be empty — it carries the shared background for '
      'every item in the batch.',
    );
  }
  final rawTasks = arguments['tasks'] as List? ?? const [];
  if (rawTasks.isEmpty) {
    throw ArgumentError('tasks must contain at least one item.');
  }
  final items = <TaskItem>[];
  final seenNames = <String>{};
  for (var i = 0; i < rawTasks.length; i++) {
    final raw = (rawTasks[i] as Map).cast<String, dynamic>();
    final taskText = (raw['task'] as String?)?.trim() ?? '';
    if (taskText.isEmpty) {
      throw ArgumentError('tasks[$i].task must not be empty.');
    }
    final name = (raw['name'] as String?)?.trim();
    if (name != null && name.isNotEmpty && !seenNames.add(name.toLowerCase())) {
      throw ArgumentError(
        'duplicate task name "$name" (names are case-insensitive within a call).',
      );
    }
    final agent = (raw['agent'] as String?)?.trim();
    if (agent != null && agent.isNotEmpty && registry.resolve(agent) == null) {
      throw ArgumentError(
        'Unknown agent type "$agent" — available: '
        '${registry.agents.map((a) => a.name).join(', ')}',
      );
    }
    items.add(
      TaskItem(
        task: taskText,
        name: name,
        agent: agent,
        outputSchema: raw['outputSchema'],
      ),
    );
  }
  return items;
}

/// Blocking execution: fan out under the session semaphore, stream progress
/// through [onUpdate], and return every per-item output (omp's settled
/// response, reduced to the text block — our `ToolExecutionResult` has no
/// `details` side channel).
Future<ToolExecutionResult> _runBlocking(
  TaskToolConfig config,
  TaskExecutor executor,
  List<TaskItem> items,
  String context,
  CancelToken? cancelToken,
  ToolUpdateCallback? onUpdate,
) async {
  final stopwatch = Stopwatch()..start();
  final phases = List<TaskSpawnPhase?>.filled(items.length, null);
  final ids = <int, String>{};
  void emitProgress() {
    onUpdate?.call(
      ToolExecutionResult.text(_renderProgress(items, phases, ids)),
    );
  }

  final results = await Future.wait([
    for (var i = 0; i < items.length; i++)
      executor.runSpawn(
        item: items[i],
        index: i,
        context: context,
        cancelToken: cancelToken,
        onProgress: (index, id, phase) {
          ids[index] = id;
          phases[index] = phase;
          emitProgress();
        },
      ),
  ]);
  stopwatch.stop();
  return ToolExecutionResult.text(_renderResults(results, stopwatch.elapsed));
}

/// Background execution: allocate ids up front, register one job per item,
/// and return immediately (omp's async response). Job bodies run detached
/// under the same session semaphore; the parent cancel token cancels every
/// job of the call (omp's parent-abort cancel).
ToolExecutionResult _spawnBackground(
  TaskToolConfig config,
  TaskExecutor executor,
  List<TaskItem> items,
  String context,
  CancelToken? cancelToken,
) {
  final types = <String>{};
  final lines = <String>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final agentName = taskItemAgentName(item);
    final id = config.outputs.allocateId(taskItemNameBase(item));
    final job = config.jobManager._register(
      id: id,
      index: i,
      agent: agentName,
      task: item.task,
    );
    types.add(agentName);
    lines.add('- `$id` ($agentName, job `$id`)');
    if (cancelToken != null) {
      unawaited(cancelToken.onCancel.then((_) => job.cancel()));
    }
    unawaited(
      executor
          .runSpawn(
            item: item,
            index: i,
            context: context,
            preallocatedId: id,
            cancelToken: job.cancelToken,
            onProgress: (index, id, phase) {
              if (phase == TaskSpawnPhase.running &&
                  job._status == TaskJobStatus.queued) {
                job._status = TaskJobStatus.running;
              }
            },
          )
          .then((result) => config.jobManager._finish(job, result)),
    );
  }
  return ToolExecutionResult.text(
    'Spawned ${items.length} background '
    '${items.length == 1 ? 'agent' : 'agents'} using ${types.join(', ')}.\n'
    '${lines.join('\n')}\n\n'
    'Each result is delivered when its job settles and stays addressable as '
    'agent://<id>.',
  );
}

String _renderProgress(
  List<TaskItem> items,
  List<TaskSpawnPhase?> phases,
  Map<int, String> ids,
) {
  final settled = phases
      .where(
        (phase) =>
            phase == TaskSpawnPhase.completed ||
            phase == TaskSpawnPhase.failed ||
            phase == TaskSpawnPhase.aborted,
      )
      .length;
  final lines = StringBuffer('task: $settled/${items.length} settled');
  for (var i = 0; i < items.length; i++) {
    final id = ids[i] ?? taskItemNameBase(items[i]);
    final agent = taskItemAgentName(items[i]);
    final marker = switch (phases[i]) {
      TaskSpawnPhase.completed => '✓',
      TaskSpawnPhase.failed || TaskSpawnPhase.aborted => '✗',
      TaskSpawnPhase.running => '…',
      null => '·',
    };
    final label = switch (phases[i]) {
      TaskSpawnPhase.completed => 'done',
      TaskSpawnPhase.failed => 'failed',
      TaskSpawnPhase.aborted => 'aborted',
      TaskSpawnPhase.running => 'running',
      null => 'waiting',
    };
    lines.write('\n  $marker $id ($agent) — $label');
  }
  return lines.toString();
}

String _renderResults(List<TaskSingleResult> results, Duration total) {
  final failed = results
      .where((result) => result.status != TaskSpawnStatus.completed)
      .length;
  final seconds = (total.inMilliseconds / 1000).toStringAsFixed(1);
  final buffer = StringBuffer(
    '${results.length} '
    '${results.length == 1 ? 'subagent' : 'subagents'} finished in '
    '${seconds}s${failed == 0 ? '' : ' — $failed failed'}.',
  );
  for (final result in results) {
    final label = switch (result.status) {
      TaskSpawnStatus.completed => 'ok',
      TaskSpawnStatus.failed => 'failed',
      TaskSpawnStatus.aborted => 'aborted',
    };
    buffer.write('\n\n## ${result.id} (${result.agent}) — $label');
    final structured = result.structuredOutput;
    if (structured != null) {
      buffer.write(
        ' [schema: ${switch (structured.status) {
          StructuredValidationStatus.valid => 'valid',
          StructuredValidationStatus.invalid => 'invalid',
          StructuredValidationStatus.unavailable => 'unvalidated',
        }}]',
      );
    }
    final error = result.error;
    if (error != null) {
      buffer.write('\nerror: $error');
    }
    if (result.output.isNotEmpty) {
      final preview = result.output.length > taskOutputPreviewChars
          ? '${result.output.substring(0, taskOutputPreviewChars)}\n…'
          : result.output;
      buffer.write('\n$preview');
    }
    buffer.write(
      '\n[${result.truncated ? 'Truncated output' : 'Full output'}: '
      'agent://${result.id}]',
    );
  }
  return buffer.toString();
}
