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
    final definition = registry.resolve(agentName);
    if (definition == null) {
      throw StateError(
        'Unknown agent type "$agentName" — available: '
        '${registry.agents.map((a) => a.name).join(', ')}',
      );
    }
    onProgress?.call(index, id, TaskSpawnPhase.running);

    final toolRegistry = ToolRegistry(
      registry.toolSurfaceFor(definition, childTools),
    );

    // Cheap-role resolution (omp's agent `model` frontmatter): a configured
    // role wins; anything else inherits the parent wiring.
    var childModel = model;
    var childStream = streamFunction;
    final role = definition.modelRole;
    final rolesResolver = this.rolesResolver;
    if (role != null && rolesResolver != null) {
      final resolved = rolesResolver.resolveRole(role);
      if (resolved != null) {
        childModel = resolved.model;
        childStream = resolved.stream;
      }
    }

    final systemPrompt = StringBuffer(definition.systemPrompt.trim());
    if (context.trim().isNotEmpty) {
      systemPrompt
        ..writeln()
        ..writeln()
        ..writeln('# CONTEXT')
        ..write(context.trim());
    }

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

    final child = Agent(
      model: childModel,
      systemPrompt: systemPrompt.toString(),
      streamFunction: childStream,
      toolRegistry: toolRegistry,
    );
    if (cancelToken != null) {
      unawaited(cancelToken.onCancel.then((_) => child.abort()));
    }
    await child.prompt(userPrompt.toString());
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
      tokens: tokens,
      requests: requests,
      model: childModel.id,
      error: failed ? 'schema_violation: ${structured!.error}' : null,
      structuredOutput: structured,
    );
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

    var text = finalText;
    var retried = false;
    while (true) {
      final data = _extractJsonValue(text);
      final List<String> errors;
      if (data == null) {
        errors = const ['the final output contains no JSON document'];
      } else if (outputSchema is Map) {
        errors = validateJsonValue(
          value: data,
          schema: outputSchema.cast<String, dynamic>(),
        );
      } else {
        // outputSchema == true: any parseable JSON document is accepted.
        errors = const [];
      }
      if (errors.isEmpty) {
        return (
          structured: StructuredTaskOutput(
            status: StructuredValidationStatus.valid,
            data: data,
          ),
          // Store the typed object itself so its fields stay addressable
          // via `agent://<id>/<dot.path>` (omp stores the finalized JSON).
          outputContent: const JsonEncoder.withIndent('  ').convert(data),
        );
      }
      if (retried) {
        return (
          structured: StructuredTaskOutput(
            status: StructuredValidationStatus.invalid,
            data: data,
            error: errors.join('; '),
          ),
          outputContent: text,
        );
      }
      retried = true;
      await child.prompt(
        taskSchemaFixPrompt.replaceAll(
          '{{errors}}',
          errors.map((e) => '- $e').join('\n'),
        ),
      );
      cancelToken?.throwIfCancelled();
      text = _finalAssistantText(child);
    }
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
    final direct = _tryParseJson(trimmed);
    if (direct != null) return direct;
    final fence = RegExp('```(?:json|JSON)?\\s*\\r?\\n([\\s\\S]*?)```');
    final matches = fence.allMatches(trimmed).toList();
    for (final match in matches.reversed) {
      final value = _tryParseJson(match.group(1)!.trim());
      if (value != null) return value;
    }
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
