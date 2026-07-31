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
import '../cancel_token.dart';
import '../json_parse.dart';
import '../model.dart';
import '../model_roles/model_resolver.dart';
import '../prompts/prompts.g.dart';
import '../types.dart';
import 'agent_registry.dart';
import 'output_manager.dart';
import 'parallel.dart';
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
      return _failure(index, id, agentName, item, stopwatch, '$error');
    } finally {
      stopwatch.stop();
      semaphore.release();
    }
  }

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
    final definition = _resolveDefinition(agentName);
    onProgress?.call(index, id, TaskSpawnPhase.running);

    final toolRegistry = ToolRegistry(
      registry.toolSurfaceFor(definition, childTools),
    );
    final wiring = _resolveChildWiring(definition);

    final child = Agent(
      model: wiring.model,
      systemPrompt: _buildSystemPrompt(definition, context),
      streamFunction: wiring.stream,
      toolRegistry: toolRegistry,
    );
    if (cancelToken != null) {
      unawaited(cancelToken.onCancel.then((_) => child.abort()));
    }
    await child.prompt(_buildUserPrompt(item));
    cancelToken?.throwIfCancelled();

    final finalText = _finalAssistantText(child);
    var storedContent = finalText;
    StructuredTaskOutput? structured;
    if (item.outputSchema != null) {
      final validation = await _validateStructured(
        child: child,
        outputSchema: item.outputSchema!,
        finalText: finalText,
        cancelToken: cancelToken,
      );
      structured = validation.structured;
      storedContent = validation.outputContent;
    }

    final capped = _capOutput(storedContent);
    store.put(id, capped.$1);
    final usage = _usageStats(child);

    final failed = structured?.status == StructuredValidationStatus.invalid;
    onProgress?.call(
      index,
      id,
      failed ? TaskSpawnPhase.failed : TaskSpawnPhase.completed,
    );
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
    );
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
  /// role wins; anything else inherits the parent wiring.
  ({Model model, StreamFunction stream}) _resolveChildWiring(
    TaskAgentDefinition definition,
  ) {
    final role = definition.modelRole;
    final rolesResolver = this.rolesResolver;
    if (role != null && rolesResolver != null) {
      final resolved = rolesResolver.resolveRole(role);
      if (resolved != null) {
        return (model: resolved.model, stream: resolved.stream);
      }
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
  /// when the item carries an `outputSchema`.
  String _buildUserPrompt(TaskItem item) {
    final userPrompt = StringBuffer(
      taskAssignmentPrompt.replaceAll('{{task}}', item.task.trim()),
    );
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
}
