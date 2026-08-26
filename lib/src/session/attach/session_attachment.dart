/// Attached-session transport: how a client (the Flutter app, a remote
/// viewer) watches a session owned by another process and hands it user
/// input. Two small interfaces — a later network impl (`fa serve
/// --attach`: SSE/WebSocket) drops in without touching any consumer.
library;

import '../../messaging/agent_message.dart';

/// A broadcast of the messages appended to a watched session. The
/// session JSONL is the single source of truth; an implementation tails
/// it (poll or push) and emits what changed.
abstract interface class SessionEventSource {
  /// Starts following the session; the stream emits the initial backlog
  /// and every message appended afterwards. Never emits an error — a
  /// dead watch ends with a done event.
  Stream<AttachedSessionEvent> watch(String sessionId);

  /// Stops all watches and releases resources.
  Future<void> dispose();
}

/// One batch of appended session content.
final class AttachedSessionEvent {
  /// Creates the event.
  const AttachedSessionEvent({required this.appended});

  /// The messages appended since the previous event, in order.
  final List<AttachedMessage> appended;
}

/// One rendered transcript row of an attached session: enough for a
/// client to render 1:1 what the owning process (the CLI) shows.
final class AttachedMessage {
  /// Creates the row.
  const AttachedMessage({
    required this.role,
    required this.text,
    this.toolName,
  });

  /// Who produced the row.
  final AttachedMessageRole role;

  /// The user/assistant text (empty for tool-only rows).
  final String text;

  /// The tool name for tool rows, else null.
  final String? toolName;
}

/// The roles an attached view renders.
enum AttachedMessageRole { user, assistant, tool, system }

/// The channel a client hands user input through to the process owning
/// the session. The file impl rides the agent messaging fabric (an
/// [AgentMessage] with [AgentMessageKind.user]); a network impl later
/// carries the same semantics over the wire.
abstract interface class SessionInputChannel {
  /// Hands [text] to the session's owning process as user input. The
  /// awaiting future completes when the input is durable (queued), not
  /// when the process has seen it.
  Future<void> send(String sessionId, String text);
}
