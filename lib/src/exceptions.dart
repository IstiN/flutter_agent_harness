/// Sealed exception hierarchy for non-provider errors.
///
/// Shaped after agenix's `AgenixException` (see GOAL.md): a sealed base with
/// `cause`/`causeStack` so consumers can exhaustively switch on the exception
/// type and still unwrap the original failure.
///
/// These are for harness-level failures — configuration, tool registration
/// and validation, session storage. Provider failures never throw: they
/// arrive as `ErrorEvent`s (errors-as-events invariant).
library;

/// Base class for all harness exceptions. Sealed so consumers can
/// exhaustively switch on the exception type.
sealed class AgentHarnessException implements Exception {
  /// Creates an [AgentHarnessException] with a [message] and optional
  /// [cause]/[causeStack].
  const AgentHarnessException(this.message, {this.cause, this.causeStack});

  /// Human-readable description of what went wrong.
  final String message;

  /// The original error that caused this exception, if any.
  final Object? cause;

  /// The stack trace of the original error, if any.
  final StackTrace? causeStack;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when harness configuration is invalid (e.g. malformed config files
/// or missing required settings).
class ConfigException extends AgentHarnessException {
  /// Creates a [ConfigException].
  const ConfigException(super.message, {super.cause, super.causeStack});
}

/// Thrown when a tool referenced by the model is not registered.
class ToolNotFoundException extends AgentHarnessException {
  /// Creates a [ToolNotFoundException] for [toolName].
  ToolNotFoundException(this.toolName)
    : super('Tool $toolName not found in registry');

  /// The name of the missing tool.
  final String toolName;
}

/// Thrown when tool call arguments fail validation against the tool's
/// declared parameter schema.
class ToolValidationException extends AgentHarnessException {
  /// Creates a [ToolValidationException] for [toolName].
  const ToolValidationException(
    this.toolName,
    super.message, {
    super.cause,
    super.causeStack,
  });

  /// The name of the tool whose arguments failed validation.
  final String toolName;
}

/// Stable error codes for [SessionException], ported from pi's
/// `SessionErrorCode` union.
enum SessionErrorCode {
  /// The addressed session or record does not exist.
  notFound,

  /// The session file is structurally invalid (e.g. bad header).
  invalidSession,

  /// A JSONL entry line is invalid or corrupt.
  invalidEntry,

  /// A fork/navigation target is not a valid branch point.
  invalidForkTarget,

  /// The underlying filesystem operation failed.
  storage,

  /// Any other session failure.
  unknown,
}

/// Thrown when a session storage operation fails (read, write, or corrupt
/// JSONL records).
class SessionException extends AgentHarnessException {
  /// Creates a [SessionException].
  const SessionException(
    super.message, {
    this.code = SessionErrorCode.unknown,
    super.cause,
    super.causeStack,
  });

  /// Stable classification of the failure.
  final SessionErrorCode code;
}
