/// The tool-call execution half of the agent loop: batch executors
/// (sequential/parallel per [ToolExecutionMode]), call preparation
/// (existence check, `beforeToolCall` hook, abort checks), executor relay,
/// result finalization, and the model-visible error-result builders, plus
/// the private result carriers they share. Split out of `agent_loop.dart`
/// to keep it under the repo's 2800-line size gate (same library — a
/// `part of` — so the moved functions see the loop's private core).
part of 'agent_loop.dart';

/// Fails all tool calls from an assistant message that was truncated by the
/// output token limit. Streamed tool-call arguments are finalized with a
/// best-effort JSON salvage parser, so a truncated message can yield tool
/// calls whose arguments parse but are silently incomplete. None of them are
/// safe to execute; report each as an error so the model can re-issue them.
///
/// Port of pi's `failToolCallsFromTruncatedMessage`.
Future<_ExecutedToolCallBatch> _failToolCallsFromTruncatedMessage(
  List<ToolCall> toolCalls,
  AgentEventSink emit, {
  AgentLoopConfig? config,
}) async {
  final messages = <ToolResultMessage>[];
  for (final toolCall in toolCalls) {
    // Issue #1829 Core flow B: a non-executing capture side path may
    // persist salvage-parsed deliverable text BEFORE the failure is
    // reported (fail-closed: still failed unexecuted; awaited so the
    // capture re-seeds the durable ids before its persist, gh-1956).
    await config?.onTruncatedToolCall?.call(toolCall);
    await emit(
      ToolExecutionStartEvent(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        args: toolCall.arguments,
        timestamp: DateTime.now(),
      ),
    );
    final finalized = _FinalizedToolCall(
      toolCall,
      _errorToolResult(
        'Tool call "${toolCall.name}" was not executed: the response hit '
        'the output token limit, so its arguments may be truncated. '
        'Re-issue the tool call with complete arguments.',
      ),
      true,
    );
    await _emitToolExecutionEnd(finalized, emit);
    messages.add(await _emitToolResultMessage(finalized, emit));
  }
  return _ExecutedToolCallBatch(messages, terminate: false);
}

/// Executes the tool calls of one assistant message. Port of pi's
/// `executeToolCalls`, including the per-tool `executionMode` override: if
/// any called tool is an [AgentTool] with
/// [AgentTool.executionMode] == [ToolExecutionMode.sequential], the whole
/// batch runs sequentially (pi semantics).
Future<_ExecutedToolCallBatch> _executeToolCalls(
  Context context,
  AssistantMessage assistantMessage,
  List<ToolCall> toolCalls,
  AgentLoopConfig config,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  AgentEventSink emit,
) async {
  // GOAL #28 (issue #2416 CI round 3): the manifest partition keeps
  // deferred tools OUT of [context.tools], so a batch of FIRST calls to a
  // sequential-only deferred tool (e.g. five `config` calls in one turn)
  // must consult the deferred-mount resolver for the mode decision too —
  // otherwise the batch runs parallel and same-file writers race. The
  // resolver mounts idempotently; the later preparation reuses the
  // mounted tool through the live registry.
  var hasSequentialToolCall =
      config.toolExecution == ToolExecutionMode.sequential;
  if (!hasSequentialToolCall) {
    for (final toolCall in toolCalls) {
      var tool = _findTool(context, toolCall.name, config);
      if (tool == null && config.missingToolResolver != null) {
        tool = await config.missingToolResolver!(toolCall.name);
      }
      if (tool is AgentTool &&
          tool.executionMode == ToolExecutionMode.sequential) {
        hasSequentialToolCall = true;
        break;
      }
    }
  }
  return config.toolExecution == ToolExecutionMode.sequential ||
          hasSequentialToolCall
      ? _executeToolCallsSequential(
          context,
          assistantMessage,
          toolCalls,
          config,
          toolExecutor,
          cancelToken,
          emit,
        )
      : _executeToolCallsParallel(
          context,
          assistantMessage,
          toolCalls,
          config,
          toolExecutor,
          cancelToken,
          emit,
        );
}

Future<_ExecutedToolCallBatch> _executeToolCallsSequential(
  Context context,
  AssistantMessage assistantMessage,
  List<ToolCall> toolCalls,
  AgentLoopConfig config,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  AgentEventSink emit,
) async {
  final finalizedCalls = <_FinalizedToolCall>[];
  final messages = <ToolResultMessage>[];

  for (final toolCall in toolCalls) {
    await emit(
      ToolExecutionStartEvent(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        args: toolCall.arguments,
        timestamp: DateTime.now(),
      ),
    );

    final finalized = switch (await _prepareToolCall(
      context,
      assistantMessage,
      toolCall,
      config,
      cancelToken,
    )) {
      _ImmediateToolCall(:final result, :final isError) => _FinalizedToolCall(
        toolCall,
        result,
        isError,
      ),
      _PreparedToolCall() => await _finalizeExecutedToolCall(
        context,
        assistantMessage,
        toolCall,
        await _executePreparedToolCall(
          toolCall,
          toolExecutor,
          cancelToken,
          emit,
          stuckTool: config.stuckTool,
          foregroundCallBudget: config.foregroundCallBudget,
          foregroundBudgetControls: config.foregroundBudgetControls,
          pendingSteeringCount: config.pendingSteeringCount,
        ),
        config,
        cancelToken,
      ),
    };

    await _emitToolExecutionEnd(finalized, emit);
    finalizedCalls.add(finalized);
    messages.add(await _emitToolResultMessage(finalized, emit));

    if (cancelToken != null && cancelToken.isCancelled) break;
  }

  return _ExecutedToolCallBatch(
    messages,
    terminate: _shouldTerminateToolBatch(finalizedCalls),
  );
}

Future<_ExecutedToolCallBatch> _executeToolCallsParallel(
  Context context,
  AssistantMessage assistantMessage,
  List<ToolCall> toolCalls,
  AgentLoopConfig config,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  AgentEventSink emit,
) async {
  // One entry per started tool call, in assistant source order.
  final pending = <Future<_FinalizedToolCall>>[];

  for (final toolCall in toolCalls) {
    await emit(
      ToolExecutionStartEvent(
        toolCallId: toolCall.id,
        toolName: toolCall.name,
        args: toolCall.arguments,
        timestamp: DateTime.now(),
      ),
    );

    switch (await _prepareToolCall(
      context,
      assistantMessage,
      toolCall,
      config,
      cancelToken,
    )) {
      case _ImmediateToolCall(:final result, :final isError):
        final finalized = _FinalizedToolCall(toolCall, result, isError);
        await _emitToolExecutionEnd(finalized, emit);
        pending.add(Future.value(finalized));
      case _PreparedToolCall():
        // Executes concurrently; tool_execution_end is emitted in completion
        // order as each call settles.
        pending.add(() async {
          final executed = await _executePreparedToolCall(
            toolCall,
            toolExecutor,
            cancelToken,
            emit,
            stuckTool: config.stuckTool,
            foregroundCallBudget: config.foregroundCallBudget,
            foregroundBudgetControls: config.foregroundBudgetControls,
            pendingSteeringCount: config.pendingSteeringCount,
          );
          final finalized = await _finalizeExecutedToolCall(
            context,
            assistantMessage,
            toolCall,
            executed,
            config,
            cancelToken,
          );
          await _emitToolExecutionEnd(finalized, emit);
          return finalized;
        }());
    }

    if (cancelToken != null && cancelToken.isCancelled) break;
  }

  final finalizedCalls = await Future.wait(pending);
  final messages = <ToolResultMessage>[];
  for (final finalized in finalizedCalls) {
    messages.add(await _emitToolResultMessage(finalized, emit));
  }

  return _ExecutedToolCallBatch(
    messages,
    terminate: _shouldTerminateToolBatch(finalizedCalls),
  );
}

/// Port of pi's `prepareToolCall`, reduced to the pieces available without a
/// tool registry: existence check against [Context.tools], the
/// `beforeToolCall` hook, and the abort checks. Schema validation and
/// argument preparation arrive with the tool registry.
Future<_ToolCallPreparation> _prepareToolCall(
  Context context,
  AssistantMessage assistantMessage,
  ToolCall toolCall,
  AgentLoopConfig config,
  CancelToken? cancelToken,
) async {
  var tool = _findTool(context, toolCall.name, config);
  if (tool == null) {
    // GOAL #28 (issue #2416 review round 2): a direct call to a
    // deferred-but-enabled tool routes to the deferred-mount path — the
    // host resolver mounts it live and the call proceeds natively.
    final resolver = config.missingToolResolver;
    tool = resolver == null ? null : await resolver(toolCall.name);
    if (tool == null) {
      return _ImmediateToolCall(
        _errorToolResult('Tool ${toolCall.name} not found'),
        true,
      );
    }
  }

  // Issue #862: after 6 consecutive identical failures the loop refuses to
  // execute this exact call again in this run — an honest error naming the
  // misuse instead of another silent loop turn.
  final refusal = config.toolMisuseBreaker?.refusalFor(
    toolCall.name,
    toolCall.arguments,
  );
  if (refusal != null) {
    return _ImmediateToolCall(_errorToolResult(refusal), true);
  }

  try {
    return await _runBeforeToolCallHook(
      context,
      assistantMessage,
      toolCall,
      config,
      cancelToken,
    );
  } catch (error) {
    return _ImmediateToolCall(
      _errorToolResult(error, toolName: toolCall.name),
      true,
    );
  }
}

/// Runs the `beforeToolCall` hook (when configured) with the abort checks.
/// A throw propagates to [_prepareToolCall], which converts it into an error
/// tool result (pi semantics).
Future<_ToolCallPreparation> _runBeforeToolCallHook(
  Context context,
  AssistantMessage assistantMessage,
  ToolCall toolCall,
  AgentLoopConfig config,
  CancelToken? cancelToken,
) async {
  final beforeToolCall = config.beforeToolCall;
  if (beforeToolCall != null) {
    final beforeResult = await beforeToolCall(
      BeforeToolCallContext(
        assistantMessage: assistantMessage,
        toolCall: toolCall,
        context: context,
      ),
      cancelToken,
    );
    final abortedAfterHook = _abortIfCancelled(cancelToken);
    if (abortedAfterHook != null) return abortedAfterHook;
    if (beforeResult != null && beforeResult.block) {
      return _ImmediateToolCall(
        _errorToolResult(beforeResult.reason ?? 'Tool execution was blocked'),
        true,
      );
    }
  }
  final aborted = _abortIfCancelled(cancelToken);
  if (aborted != null) return aborted;
  return _PreparedToolCall();
}

/// The abort check shared by the tool-call preparation paths: an immediate
/// error result when [cancelToken] is already cancelled, `null` otherwise.
_ToolCallPreparation? _abortIfCancelled(CancelToken? cancelToken) {
  if (cancelToken != null && cancelToken.isCancelled) {
    return _ImmediateToolCall(_errorToolResult('Operation aborted'), true);
  }
  return null;
}

/// Whether [tools] contains a tool named [name] — the shared name probe
/// for both [_findTool] lookups (review round 2 digest: the snapshot and
/// live-list search loops were textually identical).
bool _nameIn(List<Tool> tools, String name) {
  for (final tool in tools) {
    if (tool.name == name) return true;
  }
  return false;
}

Tool? _findTool(Context context, String name, [AgentLoopConfig? config]) {
  final snapshot = context.tools ?? const <Tool>[];
  if (_nameIn(snapshot, name)) {
    return snapshot.firstWhere((tool) => tool.name == name);
  }
  // gh-2458 (review round 2): a mid-loop `others` mount lands in the LIVE
  // tool list (`agent.state.tools` via the gate apply), never in this
  // run-start snapshot. When the host wires `toolsProvider` — the same
  // provider the schema half already consults per request — fall back to
  // it so routing agrees with what the schema advertised. Un-mounted
  // discoverables are in neither list: the honest not-found (and the
  // #680 tombstone contract) is unchanged; `missingToolResolver` stays
  // the last resort with its mount side effect.
  final liveTools = config?.toolsProvider?.call();
  if (liveTools == null) return null;
  if (!_nameIn(liveTools, name)) return null;
  return liveTools.firstWhere((tool) => tool.name == name);
}

/// Port of pi's `executePreparedToolCall`: run the executor, relay partial
/// updates, convert a throw into an error result. When a [StuckToolConfig]
/// is configured (and the tool is not excluded) the execution runs under
/// the stuck-call supervisor (gh-1054): liveness heartbeats past half the
/// threshold, then the autonomous cancel/retry/convert follow-up.
Future<_ExecutedToolCallOutcome> _executePreparedToolCall(
  ToolCall toolCall,
  ToolExecutor toolExecutor,
  CancelToken? cancelToken,
  AgentEventSink emit, {
  StuckToolConfig? stuckTool,
  ForegroundCallBudgetConfig? foregroundCallBudget,
  ForegroundCallBudgetControls? foregroundBudgetControls,
  int Function()? pendingSteeringCount,
}) async {
  final updateEvents = <Future<void>>[];
  var acceptingUpdates = true;
  void onPartial(ToolExecutionResult partialResult) {
    if (!acceptingUpdates) return;
    updateEvents.add(
      Future<void>(
        () => emit(
          ToolExecutionUpdateEvent(
            toolCallId: toolCall.id,
            toolName: toolCall.name,
            args: toolCall.arguments,
            partialResult: partialResult,
          ),
        ),
      ),
    );
  }

  Future<ToolExecutionResult> run(
    CancelToken? token, [
    void Function(ToolExecutionResult partialResult)? observe,
  ]) => toolExecutor(toolCall, token, (partialResult) {
    observe?.call(partialResult);
    onPartial(partialResult);
  });

  final supervised =
      stuckTool != null &&
      stuckTool.enabled &&
      !stuckTool.excludes(toolCall.name);
  // Issue #1786: the foreground budget supervises every call the stuck
  // supervisor's exclusion list does not exempt (human-blocking tools,
  // subagents) — it is the unconditional outer bound, on by default.
  final budgetApplies = _budgetAppliesTo(toolCall.name, stuckTool);
  final execution = supervised || budgetApplies
      ? _superviseToolExecution(
          toolCall: toolCall,
          run: run,
          runToken: cancelToken,
          stuck: supervised ? stuckTool : null,
          emit: emit,
          budget: budgetApplies
              ? (foregroundCallBudget ?? const ForegroundCallBudgetConfig())
              : null,
          controls: foregroundBudgetControls,
          pendingSteeringCount: pendingSteeringCount,
        )
      : run(cancelToken);
  try {
    final result = await execution;
    acceptingUpdates = false;
    await Future.wait(updateEvents);
    return _ExecutedToolCallOutcome(result, false);
  } catch (error) {
    acceptingUpdates = false;
    await Future.wait(updateEvents);
    return _ExecutedToolCallOutcome(
      _errorToolResult(error, toolName: toolCall.name),
      true,
      validationRejection:
          error is ToolValidationException || error is ToolNotFoundException,
    );
  }
}

/// Port of pi's `finalizeExecutedToolCall`: apply the `afterToolCall` hook's
/// field-by-field overrides; a throwing hook turns the result into an error.
Future<_FinalizedToolCall> _finalizeExecutedToolCall(
  Context context,
  AssistantMessage assistantMessage,
  ToolCall toolCall,
  _ExecutedToolCallOutcome executed,
  AgentLoopConfig config,
  CancelToken? cancelToken,
) async {
  var result = executed.result;
  var isError = executed.isError;

  // Issue #862: feed the breaker. Only call-shape VALIDATION rejections
  // count toward the identical-call thresholds; a success clears the
  // tool's consecutive-failure state. Operational failures (bash exits,
  // refused writes) are invisible to the breaker — a deterministic failing
  // command must stay runnable (issue #862 review). The stuck-call
  // supervisor's marked results (gh-1054) ride the same rule: an
  // escalation throws a plain StateError (operational), so a hung call
  // never poisons the breaker's counters.
  final breaker = config.toolMisuseBreaker;
  if (breaker != null) {
    if (isError && !executed.validationRejection) {
      // Operational failure: neither counts nor resets.
    } else if (isError) {
      breaker.observeFailure(
        toolCall.name,
        toolCall.arguments,
        result.content
            .whereType<TextContent>()
            .map((block) => block.text)
            .join('\n'),
        toolDescription: _findTool(context, toolCall.name, config)?.description,
      );
    } else {
      breaker.observeSuccess(toolCall.name);
    }
  }

  final afterToolCall = config.afterToolCall;
  if (afterToolCall != null) {
    try {
      final afterResult = await afterToolCall(
        AfterToolCallContext(
          assistantMessage: assistantMessage,
          toolCall: toolCall,
          result: result,
          isError: isError,
          context: context,
        ),
        cancelToken,
      );
      if (afterResult != null) {
        result = ToolExecutionResult(
          content: afterResult.content ?? result.content,
          terminate: afterResult.terminate ?? result.terminate,
        );
        isError = afterResult.isError ?? isError;
      }
    } catch (error) {
      result = _errorToolResult(error, toolName: toolCall.name);
      isError = true;
    }
  }

  return _FinalizedToolCall(toolCall, result, isError);
}

bool _shouldTerminateToolBatch(List<_FinalizedToolCall> finalizedCalls) {
  return finalizedCalls.isNotEmpty &&
      finalizedCalls.every((finalized) => finalized.result.terminate);
}

/// Prefixes Dart core exceptions prepend in `toString()` — class noise, not
/// information (issue #118: every failed bash surfaced as
/// "Bad state: <output>"). Checked repeatedly, so wrapped errors
/// ("Invalid argument(s): Bad state: …") strip recursively.
const _coreErrorPrefixes = <String>[
  'Bad state: ', // StateError
  'Invalid argument(s): ', // ArgumentError
  'FormatException: ', // FormatException
  'Unsupported operation: ', // UnsupportedError
  'UnimplementedError: ', // UnimplementedError
  'Exception: ', // base Exception
];

/// Renders a caught error for a model-visible tool result: the bare message
/// without the core-exception class prefixes. Errors with their own clean
/// `toString()` pass through untouched.
String _toolErrorText(Object error) {
  var text = '$error';
  var stripped = true;
  while (stripped) {
    stripped = false;
    for (final prefix in _coreErrorPrefixes) {
      if (text.startsWith(prefix)) {
        text = text.substring(prefix.length);
        stripped = true;
      }
    }
  }
  return text;
}

/// Builds an error tool result. A [String] is taken as-is (authored
/// messages are already structured); anything else is a caught error
/// routed through the gh-1393 AC9 invariant — a tool result is NEVER a
/// bare leaked exception string. The model always sees the tool name and
/// the stripped error message; the "uncaught harness exception" hint is
/// appended ONLY for errors that are not the harness's own operational
/// carriers (gh-1393 rework): a bash `StateError("…Command exited with
/// code N"/"…Command aborted")` (the issue-#118 non-zero-exit carrier)
/// and `ToolValidationException`/`ToolNotFoundException` rejections ARE
/// command/validation failures — labeling them "the tool may be
/// unavailable; skip it" would push the model to route around a healthy
/// tool. The no-bare-exception guarantee holds on every path; only the
/// hint line is conditional.
ToolExecutionResult _errorToolResult(Object message, {String? toolName}) {
  if (message is String) {
    return ToolExecutionResult(content: [TextContent(text: message)]);
  }
  final name = toolName ?? 'unknown tool';
  if (message is CancelledException) {
    return _cancelledToolResult(name, message);
  }
  return _exceptionToolResult(name, message);
}

// gh-1455: a CancelledException escaping a tool call is the run's
// deliberate shutdown (the shell tool's own first-line guard, the
// stuck-call supervisor, a tool's throwIfCancelled) — not a tool failure
// and not a harness defect. It must not wear the "uncaught exception
// inside the harness tool implementation" hint: that told the model its
// bash tool was broken and to route around it. The cancel reason (when
// present — e.g. the run-idle watchdog's summary) stays on the record.
ToolExecutionResult _cancelledToolResult(String name, CancelledException e) {
  final reason = e.reason;
  return ToolExecutionResult(
    content: [
      TextContent(
        text:
            'Tool error ($name): run was aborted — tool not started'
            '${reason == null ? '' : ' (cancel reason: $reason)'}',
      ),
    ],
  );
}

ToolExecutionResult _exceptionToolResult(String name, Object message) {
  final text = _toolErrorText(message);
  final isOperational =
      message is ToolValidationException ||
      message is ToolNotFoundException ||
      (message is StateError &&
          (text.contains('Command exited with code') ||
              text.contains('Command aborted') ||
              // gh-1444 AC5: a shell timeout is the command's verdict, not
              // a harness fault — the honest "timed out after Ns" carrier
              // must not wear the "uncaught exception" hint.
              text.contains('Command timed out') ||
              // Issue #2415: fd-table exhaustion is the environment's
              // state, not a harness defect — the typed "fd pressure"
              // carrier (spawn EMFILE, retried once by the tool layer)
              // must not tell the model its bash tool is broken.
              text.contains('fd pressure')));
  final rendered = text.isEmpty ? '<no error message>' : text;
  return ToolExecutionResult(
    content: [
      TextContent(
        text: isOperational
            ? 'Tool error ($name): $rendered'
            : 'Tool error ($name): $rendered\n'
                  'This is an uncaught exception inside the harness tool '
                  'implementation - not a command failure. The tool may be '
                  'unavailable in this environment; skip it or use a different '
                  'approach.',
      ),
    ],
  );
}

Future<void> _emitToolExecutionEnd(
  _FinalizedToolCall finalized,
  AgentEventSink emit,
) async {
  await emit(
    ToolExecutionEndEvent(
      toolCallId: finalized.toolCall.id,
      toolName: finalized.toolCall.name,
      result: finalized.result,
      isError: finalized.isError,
    ),
  );
}

Future<ToolResultMessage> _emitToolResultMessage(
  _FinalizedToolCall finalized,
  AgentEventSink emit,
) async {
  final message = ToolResultMessage(
    toolCallId: finalized.toolCall.id,
    toolName: finalized.toolCall.name,
    content: finalized.result.content,
    isError: finalized.isError,
    timestamp: DateTime.now(),
  );
  await emit(MessageStartEvent(message));
  await emit(MessageEndEvent(message));
  return message;
}

final class _ExecutedToolCallBatch {
  const _ExecutedToolCallBatch(this.messages, {required this.terminate});

  final List<ToolResultMessage> messages;
  final bool terminate;
}

final class _ExecutedToolCallOutcome {
  const _ExecutedToolCallOutcome(
    this.result,
    this.isError, {
    this.validationRejection = false,
  });

  final ToolExecutionResult result;
  final bool isError;

  /// True when the failure was a call-shape rejection thrown by the
  /// registry BEFORE any tool body ran — in practice
  /// [ToolValidationException] (schema mismatch). Only these count toward
  /// the misuse breaker; an operational failure (a non-zero bash exit, a
  /// refused write) is the environment's answer, not the model misusing
  /// the tool (issue #862 review).
  ///
  /// Scope note: the loop's IMMEDIATE tool outcomes (unknown tool —
  /// caught by the `_prepareToolCall` `_findTool` check, breaker refusals,
  /// `beforeToolCall` denials such as approval rejections) bypass
  /// [_finalizeExecutedToolCall] entirely and never reach the breaker. In
  /// the wired CLI, `context.tools` mirrors the registry surface, so a
  /// registry-thrown [ToolNotFoundException] is nearly unreachable; the
  /// counted class is effectively validation rejections only.
  final bool validationRejection;
}

sealed class _ToolCallPreparation {
  const _ToolCallPreparation();
}

/// The tool call resolved to a result without executing (unknown tool,
/// aborted).
final class _ImmediateToolCall extends _ToolCallPreparation {
  const _ImmediateToolCall(this.result, this.isError);

  final ToolExecutionResult result;
  final bool isError;
}

/// The tool call is cleared to execute.
final class _PreparedToolCall extends _ToolCallPreparation {
  const _PreparedToolCall();
}

final class _FinalizedToolCall {
  const _FinalizedToolCall(this.toolCall, this.result, this.isError);

  final ToolCall toolCall;
  final ToolExecutionResult result;
  final bool isError;
}
