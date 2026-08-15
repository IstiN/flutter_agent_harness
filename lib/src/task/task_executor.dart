/// The child-run engine of the `task` tool: builds a restricted child
/// [Agent] per batch item, drives it to completion, validates structured
/// output, and assembles the per-item result.
///
/// Ported (reduced) from oh-my-pi `packages/coding-agent/src/task/executor.ts`
/// (`runSubprocess`) and `structured-subagent.ts`. v1 deliberately drops:
///
/// - the `yield` tool and its reminder loop — the child's final assistant
///   text is the output;
/// - workspace isolation (`isolated`, worktrees, patch capture) — the card's
///   follow-up adds copy-based sandboxes;
/// - the agent lifecycle registry (idle/parked/revival), artifacts dirs on
///   disk, IRC peer messaging, plan-mode swap, and usage-cost plumbing;
/// - omp's `schemaMode` permissive/strict split — per the card, an invalid
///   final output gets exactly ONE fix retry, then the item becomes an error
///   entry (omp's strict outcome).
library;

import 'dart:async';
import 'dart:convert';

import '../agent/agent.dart';
import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../agent/param_validator.dart';
import '../agent/tool_registry.dart';
import '../a2a/a2a_client.dart';
import '../a2a/a2a_manager.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../json_parse.dart';
import '../model.dart';
import '../model_roles/model_resolver.dart';
import '../model_roles/roles_config.dart';
import '../prompts/prompts.g.dart';
import '../session/session_tree.dart';
import '../types.dart';
import 'agent_registry.dart';
import 'output_manager.dart';
import 'parallel.dart';
import 'subagent.dart';
import 'subagent_manager.dart';
import 'subagent_tools.dart';
import 'task_types.dart';

/// Lifecycle phases reported through [TaskSpawnProgressCallback].
enum TaskSpawnPhase { running, completed, failed, aborted }

/// Progress sink for spawn lifecycle transitions. Items without a report are
/// still waiting on the session semaphore.
typedef TaskSpawnProgressCallback =
    void Function(int index, String id, TaskSpawnPhase phase);

/// Runs `task` batch items as child [Agent]s under a session [Semaphore].
///
/// Guards (card §4): the child tool surface never contains `task` (no
/// nested task calls — [TaskAgentRegistry.toolSurfaceFor]); the parent
/// [CancelToken] aborts every in-flight child and every semaphore waiter; a
/// child failure becomes a per-item error entry, never a batch failure
/// ([runSpawn] never throws).
final class TaskExecutor {
  /// Creates a [TaskExecutor]. [childTools] is the parent tool pool children
  /// draw their restricted surface from; [streamFunction]/[model] are the
  /// parent model wiring children inherit unless their agent type's
  /// [TaskAgentDefinition.modelRole] resolves through [rolesResolver].
  TaskExecutor({
    required this.childTools,
    required this.streamFunction,
    required this.model,
    required this.registry,
    required this.semaphore,
    required this.store,
    this.rolesResolver,
    this.subagentManager,
    this.a2aManager,
    this.childSessionFactory,
  });

  /// The parent tool pool (already minus any host-hidden tools).
  final List<AgentTool> childTools;

  /// Inherited provider adapter (see [StreamFunction]).
  final StreamFunction streamFunction;

  /// Inherited model.
  final Model model;

  /// Agent-type resolution.
  final TaskAgentRegistry registry;

  /// The session semaphore bounding concurrent children.
  final Semaphore semaphore;

  /// The session output store (`agent://` backing).
  final AgentOutputStore store;

  /// Optional role resolver supplying cheap models per role (omp's `@smol`).
  final ModelRolesResolver? rolesResolver;

  /// Optional retained-subagent registry (Phase 3a). When present, every
  /// spawn registers/updates a [SubagentHandle].
  final SubagentManager? subagentManager;

  /// Optional A2A remote-agent manager (Phase 5a). When present, items
  /// whose agent type is `a2a:<name>` run against the remote agent instead
  /// of a local child.
  final A2aManager? a2aManager;

  /// Optional child-session factory (Phase 3a+): when present,
  /// [_persistChildSession] creates a real JSONL session for each completed
  /// child and writes its transcript into it.
  final Future<Session> Function(String parentSessionId, String childId)?
  childSessionFactory;

  /// Runs one batch item to completion. Never throws: cancellation and
  /// failure are reported as [TaskSingleResult] error entries.
  Future<TaskSingleResult> runSpawn({
    required TaskItem item,
    required int index,
    required String context,
    String? preallocatedId,
    CancelToken? cancelToken,
    TaskSpawnProgressCallback? onProgress,
  }) async {
    final id = preallocatedId ?? store.allocateId(taskItemNameBase(item));
    final agentName = taskItemAgentName(item);
    final stopwatch = Stopwatch();
    try {
      await semaphore.acquire(cancelToken);
    } on CancelledException catch (error) {
      return _failure(
        index,
        id,
        agentName,
        item,
        stopwatch,
        'aborted while waiting for a concurrency slot: $error',
        aborted: true,
      );
    }
    // Per-spawn "current subagent" scope: the child-only reply/agent_message
    // tools resolve their handle through it (Phase 3b). Re-entrant when the
    // same executor runs children sequentially (blocking batch mode).
    _currentSubagentIds.add(id);
    try {
      stopwatch.start();
      return await _run(
        item,
        index,
        id,
        agentName,
        context,
        cancelToken,
        stopwatch,
        onProgress,
      );
    } on CancelledException catch (error) {
      onProgress?.call(index, id, TaskSpawnPhase.aborted);
      await _updateSubagentStatus(
        id,
        SubagentStatus.aborted,
        error: 'aborted: ${error.reason ?? 'cancelled'}',
      );
      return _failure(
        index,
        id,
        agentName,
        item,
        stopwatch,
        'aborted: ${error.reason ?? 'cancelled'}',
        aborted: true,
      );
    } on Object catch (error) {
      onProgress?.call(index, id, TaskSpawnPhase.failed);
      await _updateSubagentStatus(id, SubagentStatus.failed, error: '$error');
      return _failure(index, id, agentName, item, stopwatch, '$error');
    } finally {
      _currentSubagentIds.remove(id);
      stopwatch.stop();
      semaphore.release();
    }
  }

  /// Stack of in-flight child ids for this executor. The LAST entry is the
  /// innermost running child; children run sequentially inside one executor
  /// call, and concurrent runSpawn calls each push/pop their own id.
  final _currentSubagentIds = <String>[];

  /// Resolves the innermost running child id (for the child-only tools).
  String? currentSubagentId() =>
      _currentSubagentIds.isEmpty ? null : _currentSubagentIds.last;

  Future<TaskSingleResult> _run(
    TaskItem item,
    int index,
    String id,
    String agentName,
    String context,
    CancelToken? cancelToken,
    Stopwatch stopwatch,
    TaskSpawnProgressCallback? onProgress,
  ) async {
    // Phase 5a: `a2a:<name>` items run against the remote agent.
    if (agentName.startsWith('a2a:')) {
      return _runA2a(
        item,
        index,
        id,
        agentName.substring(4),
        stopwatch,
        cancelToken,
        onProgress,
      );
    }
    final definition = _resolveDefinition(agentName);
    onProgress?.call(index, id, TaskSpawnPhase.running);

    // Register in the retained-subagent manager (Phase 3a).
    if (subagentManager != null) {
      await subagentManager!.register(
        id: id,
        name: taskItemNameBase(item),
        agentType: agentName,
        task: item.task,
      );
      await subagentManager!.update(id, status: SubagentStatus.running);
    }

    final toolRegistry = _childToolRegistry(definition);
    final wiring = _resolveChildWiring(definition);

    final child = Agent(
      model: wiring.model,
      systemPrompt: _buildSystemPrompt(definition, context),
      streamFunction: wiring.stream,
      toolRegistry: toolRegistry,
      // The child's inbox: messages from the parent/siblings (and other Fa
      // instances sharing the messaging root) arrive at turn boundaries.
      externalSteeringSource: subagentManager == null
          ? null
          : () => _inboxSteeringMessages(id),
    );
    if (cancelToken != null) {
      unawaited(cancelToken.onCancel.then((_) => child.abort()));
    }
    // Crash-resilient transcript: the real session is created in the
    // background at spawn time (never blocking the spawn), and turns are
    // flushed incrementally — a mid-run crash keeps everything written so
    // far (Phase 3a+). All persistence is fire-and-forget: transcript
    // durability must never slow the completion delivery.
    unawaited(_ensureChildSession(id));
    try {
      await child.prompt(await _buildUserPrompt(item, id));
      unawaited(_flushChildTranscript(id, child));
      cancelToken?.throwIfCancelled();

      final finalText = _finalAssistantText(child);
      final (storedContent, structured) = await _applyOutputSchema(
        child,
        item,
        finalText,
        cancelToken,
      );

      final capped = _capOutput(storedContent);
      store.put(id, capped.$1);
      final usage = _usageStats(child);

      final failed = structured?.status == StructuredValidationStatus.invalid;
      onProgress?.call(
        index,
        id,
        failed ? TaskSpawnPhase.failed : TaskSpawnPhase.completed,
      );

      // Phase 3b: the child's explicit reply (if any) rides the result; a
      // missing reply is surfaced via completedWithoutReply.
      final reply = subagentManager?[id]?.lastReply;

      // Update the retained-subagent handle with final status + usage.
      if (subagentManager != null) {
        await subagentManager!.update(
          id,
          status: failed ? SubagentStatus.failed : SubagentStatus.completed,
          tokens: usage.tokens,
          requests: usage.requests,
          modelId: wiring.model.id,
          error: failed ? 'schema_violation: ${structured!.error}' : null,
        );
      }

      return TaskSingleResult(
        index: index,
        id: id,
        agent: agentName,
        task: item.task,
        status: failed ? TaskSpawnStatus.failed : TaskSpawnStatus.completed,
        output: capped.$1,
        truncated: capped.$2,
        duration: stopwatch.elapsed,
        tokens: usage.tokens,
        requests: usage.requests,
        model: wiring.model.id,
        error: failed ? 'schema_violation: ${structured!.error}' : null,
        structuredOutput: structured,
        reply: reply,
      );
    } finally {
      // Last-chance flush: whatever the child produced before an
      // abort/failure lands in its session file. Fire-and-forget — the
      // completion must reach the parent without waiting on file writes.
      unawaited(_flushChildTranscript(id, child));
    }
  }

  /// Builds the child's tool registry from the agent-type surface plus the
  /// child-only reply/agent_message tools (Phase 3b) when a manager backs
  /// this executor. Extracted from [_run] to keep its CRAP in budget.
  ToolRegistry _childToolRegistry(TaskAgentDefinition definition) {
    final toolRegistry = ToolRegistry(
      registry.toolSurfaceFor(definition, childTools),
    );
    if (subagentManager != null) {
      for (final tool in subagentMonitoringTools(
        manager: subagentManager,
        currentSubagentId: currentSubagentId,
      ).where((t) => t.name == 'reply' || t.name == 'agent_message')) {
        toolRegistry.register(tool);
      }
    }
    return toolRegistry;
  }

  /// Runs one `a2a:<name>` item against a remote agent (Phase 5a). Maps the
  /// A2A task lifecycle onto the local result shape; registers the child in
  /// the retained-subagent registry so `task_status`/`task_send` work
  /// uniformly.
  Future<TaskSingleResult> _runA2a(
    TaskItem item,
    int index,
    String id,
    String serverName,
    Stopwatch stopwatch,
    CancelToken? cancelToken,
    TaskSpawnProgressCallback? onProgress,
  ) async {
    final manager = a2aManager;
    if (manager == null || manager[serverName] == null) {
      final available =
          manager?.servers.keys.join(', ') ?? 'a2a not configured';
      return _failure(
        index,
        id,
        'a2a:$serverName',
        item,
        stopwatch,
        'unknown a2a server "$serverName" — available: $available',
      );
    }
    onProgress?.call(index, id, TaskSpawnPhase.running);
    if (subagentManager != null) {
      await subagentManager!.register(
        id: id,
        name: taskItemNameBase(item),
        agentType: 'a2a:$serverName',
        task: item.task,
      );
      await subagentManager!.update(id, status: SubagentStatus.running);
    }
    try {
      final remoteTask = await manager.send(
        serverName,
        await _a2aPrompt(item, id),
      );
      // Poll to a terminal state (input-required also settles — the parent
      // can task_send the answer).
      final settled = await manager.waitForTask(
        serverName,
        remoteTask.id,
        onUpdate: (task) => cancelToken?.throwIfCancelled(),
      );
      return await _a2aResult(
        item,
        index,
        id,
        serverName,
        settled,
        stopwatch,
        onProgress,
      );
    } on CancelledException {
      rethrow;
    } on Object catch (error) {
      onProgress?.call(index, id, TaskSpawnPhase.failed);
      await _updateSubagentStatus(id, SubagentStatus.failed, error: '$error');
      return _failure(index, id, 'a2a:$serverName', item, stopwatch, '$error');
    }
  }

  /// Maps a settled remote task onto the per-item result: stores the
  /// rendered artifacts, updates the retained-subagent handle, and renders
  /// the [TaskSingleResult]. Extracted from [_runA2a] to keep its CRAP
  /// within the ratchet budget.
  Future<TaskSingleResult> _a2aResult(
    TaskItem item,
    int index,
    String id,
    String serverName,
    A2aTask settled,
    Stopwatch stopwatch,
    TaskSpawnProgressCallback? onProgress,
  ) async {
    final failed = settled.state == A2aTaskState.failed;
    final aborted = settled.state == A2aTaskState.canceled;
    final capped = _capOutput(A2aManager.renderArtifacts(settled));
    store.put(id, capped.$1);
    onProgress?.call(
      index,
      id,
      failed || aborted ? TaskSpawnPhase.failed : TaskSpawnPhase.completed,
    );
    if (subagentManager != null) {
      await subagentManager!.update(
        id,
        status: _a2aSubagentStatus(settled.state),
        modelId: 'a2a:$serverName',
        error: failed ? 'remote task failed' : null,
      );
    }
    return TaskSingleResult(
      index: index,
      id: id,
      agent: 'a2a:$serverName',
      task: item.task,
      status: _a2aSpawnStatus(settled.state),
      output: capped.$1,
      truncated: capped.$2,
      duration: stopwatch.elapsed,
      tokens: 0,
      requests: 1,
      model: 'a2a:$serverName',
      error: failed ? 'remote task failed' : null,
    );
  }

  /// The A2A task state → spawn status mapping (result shape).
  static TaskSpawnStatus _a2aSpawnStatus(A2aTaskState state) {
    if (state == A2aTaskState.canceled) return TaskSpawnStatus.aborted;
    if (state == A2aTaskState.failed) return TaskSpawnStatus.failed;
    return TaskSpawnStatus.completed;
  }

  /// The A2A task state → retained-subagent status mapping (registry shape).
  static SubagentStatus _a2aSubagentStatus(A2aTaskState state) {
    if (state == A2aTaskState.inputRequired) return SubagentStatus.idle;
    if (state == A2aTaskState.canceled) return SubagentStatus.aborted;
    if (state == A2aTaskState.failed) return SubagentStatus.failed;
    return SubagentStatus.completed;
  }

  /// The remote agent's prompt: the item task plus the pending inter-agent
  /// messages, mirroring the local child's user prompt.
  Future<String> _a2aPrompt(TaskItem item, String subagentId) async {
    final buffer = StringBuffer(item.task.trim());
    if (subagentManager != null) {
      final queued = await subagentManager!.drainMessages(subagentId);
      for (final message in queued) {
        buffer.writeln();
        buffer.writeln('from ${message.fromId}: ${message.text.trim()}');
      }
    }
    return buffer.toString();
  }

  /// Schema validation when the item carries an `outputSchema`: the content
  /// to store plus the structured output (both pass-through when the item
  /// has no schema). Extracted from [_run] to keep its CRAP in budget.
  Future<(String, StructuredTaskOutput?)> _applyOutputSchema(
    Agent child,
    TaskItem item,
    String finalText,
    CancelToken? cancelToken,
  ) async {
    if (item.outputSchema == null) return (finalText, null);
    final validation = await _validateStructured(
      child: child,
      outputSchema: item.outputSchema!,
      finalText: finalText,
      cancelToken: cancelToken,
    );
    return (validation.outputContent, validation.structured);
  }

  /// The child's inbox as steering messages (the agent loop polls this at
  /// every turn boundary): each pending inter-agent message becomes a user
  /// message attributed to its sender, so the transcript reads like a chat.
  Future<List<Message>> _inboxSteeringMessages(String subagentId) async {
    final manager = subagentManager;
    if (manager == null) return const [];
    final queued = await manager.drainMessages(subagentId);
    return [
      for (final message in queued)
        UserMessage.text('from ${message.fromId}: ${message.text.trim()}'),
    ];
  }

  /// Resolves [agentName] to its definition or throws listing the available
  /// agent types.
  TaskAgentDefinition _resolveDefinition(String agentName) {
    final definition = registry.resolve(agentName);
    if (definition == null) {
      throw StateError(
        'Unknown agent type "$agentName" — available: '
        '${registry.agents.map((a) => a.name).join(', ')}',
      );
    }
    return definition;
  }

  /// Cheap-role resolution (omp's agent `model` frontmatter): a configured
  /// role wins; a definition without a specialist role resolves through the
  /// `subagent` delegation role when configured; anything else inherits the
  /// parent wiring.
  ({Model model, StreamFunction stream}) _resolveChildWiring(
    TaskAgentDefinition definition,
  ) {
    final rolesResolver = this.rolesResolver;
    if (rolesResolver == null) return (model: model, stream: streamFunction);
    final role = definition.modelRole ?? subagentModelRole;
    final resolved = rolesResolver.resolveRole(role);
    if (resolved != null) {
      return (model: resolved.model, stream: resolved.stream);
    }
    return (model: model, stream: streamFunction);
  }

  /// The child's system prompt: the definition's prompt plus the shared
  /// batch context under a `# CONTEXT` heading.
  String _buildSystemPrompt(TaskAgentDefinition definition, String context) {
    final systemPrompt = StringBuffer(definition.systemPrompt.trim());
    if (context.trim().isNotEmpty) {
      systemPrompt
        ..writeln()
        ..writeln()
        ..writeln('# CONTEXT')
        ..write(context.trim());
    }
    return systemPrompt.toString();
  }

  /// The child's assignment prompt, with the schema instructions appended
  /// when the item carries an `outputSchema`, and any queued inter-agent
  /// messages (Phase 3b) delivered as a `# MESSAGES` section.
  Future<String> _buildUserPrompt(TaskItem item, [String? subagentId]) async {
    final userPrompt = StringBuffer(
      taskAssignmentPrompt.replaceAll('{{task}}', item.task.trim()),
    );
    if (subagentId != null && subagentManager != null) {
      final queued = await subagentManager!.drainMessages(subagentId);
      if (queued.isNotEmpty) {
        userPrompt
          ..writeln()
          ..writeln()
          ..writeln('# MESSAGES');
        for (final message in queued) {
          userPrompt.writeln('from ${message.fromId}: ${message.text.trim()}');
        }
      }
    }
    if (item.outputSchema != null) {
      userPrompt
        ..writeln()
        ..writeln()
        ..write(
          taskSchemaOutputPrompt.replaceAll(
            '{{schema}}',
            const JsonEncoder.withIndent('  ').convert(item.outputSchema),
          ),
        );
    }
    return userPrompt.toString();
  }

  /// Token/request totals across the child's assistant messages.
  static ({int tokens, int requests}) _usageStats(Agent child) {
    var tokens = 0;
    var requests = 0;
    for (final message in child.state.messages) {
      if (message is AssistantMessage) {
        requests++;
        tokens +=
            message.usage.input +
            message.usage.output +
            message.usage.cacheWrite;
      }
    }
    return (tokens: tokens, requests: requests);
  }

  /// Parses the child's final output as JSON and validates it against
  /// [outputSchema]. On failure the child gets exactly ONE fix retry with
  /// the full issue list (omp gives the model every problem at once), then
  /// the outcome is terminal (card §3).
  Future<({StructuredTaskOutput structured, String outputContent})>
  _validateStructured({
    required Agent child,
    required Object outputSchema,
    required String finalText,
    CancelToken? cancelToken,
  }) async {
    final rejected = _rejectUnusableSchema(outputSchema, finalText);
    if (rejected != null) return rejected;

    var text = finalText;
    var retried = false;
    while (true) {
      final attempt = _validateOnce(text, outputSchema);
      if (attempt.errors.isEmpty) {
        return (
          structured: StructuredTaskOutput(
            status: StructuredValidationStatus.valid,
            data: attempt.data,
          ),
          // Store the typed object itself so its fields stay addressable
          // via `agent://<id>/<dot.path>` (omp stores the finalized JSON).
          outputContent: const JsonEncoder.withIndent(
            '  ',
          ).convert(attempt.data),
        );
      }
      if (retried) {
        return (
          structured: StructuredTaskOutput(
            status: StructuredValidationStatus.invalid,
            data: attempt.data,
            error: attempt.errors.join('; '),
          ),
          outputContent: text,
        );
      }
      retried = true;
      await child.prompt(
        taskSchemaFixPrompt.replaceAll(
          '{{errors}}',
          attempt.errors.map((e) => '- $e').join('\n'),
        ),
      );
      cancelToken?.throwIfCancelled();
      text = _finalAssistantText(child);
    }
  }

  /// Rejects schemas that are neither a JSON Schema object nor `true`
  /// (`false` rejects every output, anything else is unsupported). Returns
  /// the terminal outcome, or `null` when the schema is usable.
  static ({StructuredTaskOutput structured, String outputContent})?
  _rejectUnusableSchema(Object outputSchema, String finalText) {
    if (outputSchema is! Map && outputSchema != true) {
      if (outputSchema == false) {
        return (
          structured: const StructuredTaskOutput(
            status: StructuredValidationStatus.invalid,
            error: 'boolean false schema rejects all outputs',
          ),
          outputContent: finalText,
        );
      }
      return (
        structured: StructuredTaskOutput(
          status: StructuredValidationStatus.unavailable,
          error:
              'unsupported outputSchema (${outputSchema.runtimeType}); '
              'expected a JSON Schema object or true',
        ),
        outputContent: finalText,
      );
    }
    return null;
  }

  /// One parse + validate pass over [text] (omp's per-attempt validation).
  static ({Object? data, List<String> errors}) _validateOnce(
    String text,
    Object outputSchema,
  ) {
    final data = _extractJsonValue(text);
    if (data == null) {
      return (
        data: null,
        errors: const ['the final output contains no JSON document'],
      );
    }
    if (outputSchema is Map) {
      return (
        data: data,
        errors: validateJsonValue(
          value: data,
          schema: outputSchema.cast<String, dynamic>(),
        ),
      );
    }
    // outputSchema == true: any parseable JSON document is accepted.
    return (data: data, errors: const []);
  }

  /// The concatenated text of the child's last assistant message.
  /// Stop-reason mapping (omp's abort/error handling): `error` throws, and
  /// the caller turns it into a per-item error entry; an empty transcript
  /// throws as well.
  String _finalAssistantText(Agent child) {
    AssistantMessage? last;
    for (final message in child.state.messages) {
      if (message is AssistantMessage) last = message;
    }
    if (last == null) {
      throw StateError('subagent produced no assistant message');
    }
    switch (last.stopReason) {
      case StopReason.aborted:
        throw CancelledException(last.errorMessage ?? 'subagent aborted');
      case StopReason.error:
        throw StateError(last.errorMessage ?? 'subagent failed');
      default:
        break;
    }
    return [
      for (final block in last.content)
        if (block is TextContent) block.text,
    ].join('\n').trim();
  }

  TaskSingleResult _failure(
    int index,
    String id,
    String agentName,
    TaskItem item,
    Stopwatch stopwatch,
    String error, {
    bool aborted = false,
  }) {
    return TaskSingleResult(
      index: index,
      id: id,
      agent: agentName,
      task: item.task,
      status: aborted ? TaskSpawnStatus.aborted : TaskSpawnStatus.failed,
      output: '',
      truncated: false,
      duration: stopwatch.elapsed,
      tokens: 0,
      requests: 0,
      model: model.id,
      error: error,
    );
  }

  /// Caps raw output at [maxTaskOutputLines] / [maxTaskOutputBytes] (omp's
  /// per-subagent truncation; omp writes the uncapped output to disk, our
  /// in-memory store keeps the capped form).
  static (String, bool) _capOutput(String content) {
    var result = content;
    var truncated = false;
    final lines = result.split('\n');
    if (lines.length > maxTaskOutputLines) {
      result = lines.take(maxTaskOutputLines).join('\n');
      truncated = true;
    }
    final bytes = utf8.encode(result);
    if (bytes.length > maxTaskOutputBytes) {
      result = utf8.decode(
        bytes.sublist(0, maxTaskOutputBytes),
        allowMalformed: true,
      );
      truncated = true;
    }
    return (result, truncated);
  }

  /// Extracts the first parseable JSON document from [text]: the whole text,
  /// then the last fenced code block, then the outermost `{…}`/`[…]` span
  /// (omp's yield payload assembly, reduced to text output).
  static Object? _extractJsonValue(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    return _tryParseJson(trimmed) ??
        _jsonFromLastFence(trimmed) ??
        _jsonFromOutermostSpan(trimmed);
  }

  /// The first parseable JSON document inside a fenced code block, trying
  /// the last fence first.
  static Object? _jsonFromLastFence(String trimmed) {
    final fence = RegExp('```(?:json|JSON)?\\s*\\r?\\n([\\s\\S]*?)```');
    final matches = fence.allMatches(trimmed).toList();
    for (final match in matches.reversed) {
      final value = _tryParseJson(match.group(1)!.trim());
      if (value != null) return value;
    }
    return null;
  }

  /// The first parseable JSON document spanning the outermost `{…}` or
  /// `[…]` of [trimmed].
  static Object? _jsonFromOutermostSpan(String trimmed) {
    for (final pair in const [('{', '}'), ('[', ']')]) {
      final start = trimmed.indexOf(pair.$1);
      final end = trimmed.lastIndexOf(pair.$2);
      if (start >= 0 && end > start) {
        final value = _tryParseJson(trimmed.substring(start, end + 1));
        if (value != null) return value;
      }
    }
    return null;
  }

  static Object? _tryParseJson(String text) {
    try {
      return parseJsonWithRepair(text);
    } on FormatException {
      return null;
    }
  }

  /// Sessions of in-flight children (id → session once created). Fire-and-
  /// forget creation via [_ensureChildSession]; flushes append incrementally.
  final _childSessions = <String, Session>{};

  /// How many transcript messages were flushed per child id (incremental
  /// appends only new messages beyond this counter).
  final _childSessionWrites = <String, int>{};

  /// Per-child serialization chain for transcript flushes — concurrent
  /// fire-and-forget flushes would otherwise interleave session records.
  final _childFlushChains = <String, Future<void>>{};

  /// Creates the child's real JSONL session in the BACKGROUND at spawn time
  /// (fire-and-forget — the spawn never waits on it, keeping the completion
  /// steering race away) and attaches the path to the retained handle.
  /// Crash resilience: any later [_flushChildTranscript] lands in this file.
  Future<void> _ensureChildSession(String id) async {
    final factory = childSessionFactory;
    final manager = subagentManager;
    if (factory == null || manager == null) return;
    try {
      final session = await factory(manager.parentSessionId, id);
      _childSessions[id] = session;
      manager.attachSession(id, (await session.getMetadata()).path);
    } on Object {
      // Session creation is best-effort; flushes become no-ops when it fails.
    }
  }

  /// Appends the child's NEW transcript messages (beyond the flush counter)
  /// to its session file, serialized per child so concurrent flushes never
  /// interleave records. Idempotent — safe to call at every turn boundary
  /// and in a finally block (the last-chance flush for aborts/failures).
  Future<void> _flushChildTranscript(String id, Agent child) async {
    final chain = _childFlushChains[id] ?? Future<void>.value();
    final next = chain.then((_) => _flushChildTranscriptNow(id, child));
    _childFlushChains[id] = next;
    await next;
  }

  Future<void> _flushChildTranscriptNow(String id, Agent child) async {
    final session = _childSessions[id];
    if (session == null) return;
    final messages = child.state.messages;
    final written = _childSessionWrites[id] ?? 0;
    try {
      for (var i = written; i < messages.length; i++) {
        await session.appendMessage(messages[i]);
      }
      _childSessionWrites[id] = messages.length;
    } on Object {
      // A failed flush must not affect the child's result.
    }
  }

  /// Best-effort subagent status update (no-op when no manager).
  Future<void> _updateSubagentStatus(
    String id,
    SubagentStatus status, {
    String? error,
  }) async {
    if (subagentManager != null) {
      await subagentManager!.update(id, status: status, error: error);
    }
  }
}
