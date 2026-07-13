/// Executable tool definition: a provider-facing [Tool] plus the Dart
/// callback that runs when the model calls it.
///
/// Ported from pi-mono `packages/agent/src/types.ts` (`AgentTool`).
/// Deliberate divergences from the TypeScript original:
///
/// - `AbortSignal` is [CancelToken]; [ToolUpdateCallback] and
///   [ToolExecutionResult] come from the low-level loop.
/// - pi's `execute(toolCallId, params, signal, onUpdate)` drops the
///   `toolCallId` parameter here: the loop already correlates calls and
///   results, and pi tools that need the id can capture it from the call
///   site. The callback receives the *validated and coerced* argument map.
/// - pi's `prepareArguments` compatibility shim is not ported: transform
///   arguments in [execute] instead, or fix them in a [BeforeToolCallHook].
/// - pi's `details` generic on results is absent ([ToolExecutionResult] is
///   the ported subset).
library;

import 'dart:async';

import '../cancel_token.dart';
import '../context.dart';
import 'agent_loop.dart';

/// Runs one invocation of an [AgentTool].
///
/// [arguments] are the tool-call arguments after schema validation and
/// coercion (see `param_validator.dart`). Throw on failure instead of
/// encoding errors in the result content (pi semantics): the loop converts
/// the throw into an error tool result. [cancelToken] should abort in-flight
/// work promptly; [onUpdate] streams partial results, which the loop relays
/// as [ToolExecutionUpdateEvent]s.
typedef AgentToolExecute =
    Future<ToolExecutionResult> Function(
      Map<String, dynamic> arguments,
      CancelToken? cancelToken,
      ToolUpdateCallback? onUpdate,
    );

/// A tool the model may invoke: name, description, JSON-schema parameters,
/// and the Dart callback that executes it.
///
/// Extends [Tool], so instances go directly into [AgentState.tools] /
/// [Context.tools]. Register tools in a [ToolRegistry] to get lookup,
/// argument validation, and a [ToolExecutor] adapter for the agent loop.
final class AgentTool extends Tool {
  /// Creates an [AgentTool]. [parameters] is the JSON Schema for the
  /// arguments; see `param_validator.dart` for the enforced subset.
  const AgentTool({
    required super.name,
    required super.description,
    super.parameters = const <String, dynamic>{},
    required this.execute,
    this.executionMode,
    this.label,
  });

  /// Executes one tool call with validated arguments. See [AgentToolExecute].
  final AgentToolExecute execute;

  /// Per-tool execution mode override (ported from pi):
  /// [ToolExecutionMode.sequential] forces the whole tool-call batch that
  /// contains this tool to execute one call at a time, even when the loop
  /// default is [ToolExecutionMode.parallel]. `null` keeps the loop default.
  final ToolExecutionMode? executionMode;

  /// Human-readable label for UI display (ported from pi). Optional.
  final String? label;
}
