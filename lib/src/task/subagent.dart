/// A retained, addressable subagent handle. Phase 3a of the subagents 2.0
/// plan: every spawned child gets a real JSONL session, its handle persists
/// in the parent session, and the child can be inspected and resumed.
library;

/// The lifecycle state of a retained subagent.
enum SubagentStatus { queued, running, idle, completed, failed, aborted }

/// A retained subagent handle: the parent (and the user) can query status,
/// send follow-up messages, and observe the child's transcript at any time.
final class SubagentHandle {
  SubagentHandle({
    required this.id,
    required this.name,
    required this.agentType,
    required this.sessionId,
    required this.createdAt,
    this.task = '',
  }) : status = SubagentStatus.queued,
       lastActivity = createdAt,
       tokens = 0,
       requests = 0;

  /// Unique id (== agent:// id == the id allocated by TaskExecutor).
  final String id;

  /// Display name (from the agent type or item description).
  final String name;

  /// The agent type (`task`/`explore`/`review`/discovered type).
  final String agentType;

  /// The child session id (JSONL path in the parent's session repo).
  final String sessionId;

  /// Creation timestamp (ISO 8601).
  final String createdAt;

  /// The initial task prompt.
  final String task;

  /// Current lifecycle state.
  SubagentStatus status;

  /// Last activity timestamp (ISO 8601), updated on each spawn/message.
  String lastActivity;

  /// Error message when status is [SubagentStatus.failed].
  String? error;

  /// Token usage (input, output, total).
  int tokens;

  /// Number of model requests made.
  int requests;

  /// The model id used for this child.
  String? modelId;

  /// True when the child is waiting for input (e.g. an ask tool answer).
  bool get isWaitingForInput => status == SubagentStatus.idle;

  /// True when the child has finished (success or failure).
  bool get isTerminal =>
      status == SubagentStatus.completed ||
      status == SubagentStatus.failed ||
      status == SubagentStatus.aborted;

  /// Converts to a JSON map for persistence in the parent session.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'agentType': agentType,
    'sessionId': sessionId,
    'createdAt': createdAt,
    'task': task,
    'status': status.name,
    'lastActivity': lastActivity,
    'error': error,
    'tokens': tokens,
    'requests': requests,
    'modelId': modelId,
  };

  /// Reconstructs a handle from a persisted JSON map.
  factory SubagentHandle.fromJson(Map<String, dynamic> json) {
    final handle = SubagentHandle(
      id: json['id'] as String,
      name: json['name'] as String? ?? json['id'] as String,
      agentType: json['agentType'] as String? ?? 'task',
      sessionId: json['sessionId'] as String,
      createdAt: json['createdAt'] as String? ?? '',
      task: json['task'] as String? ?? '',
    );
    handle.status = SubagentStatus.values.byName(
      json['status'] as String? ?? 'completed',
    );
    handle.lastActivity = json['lastActivity'] as String? ?? handle.createdAt;
    handle.error = json['error'] as String?;
    handle.tokens = json['tokens'] as int? ?? 0;
    handle.requests = json['requests'] as int? ?? 0;
    handle.modelId = json['modelId'] as String?;
    return handle;
  }

  /// A short status line for display in `/tasks` or the app UI.
  String get statusLine {
    final parts = <String>['$id ($agentType)'];
    switch (status) {
      case SubagentStatus.queued:
        parts.add('⏳ queued');
      case SubagentStatus.running:
        parts.add('🔄 running');
      case SubagentStatus.idle:
        parts.add('✋ idle');
      case SubagentStatus.completed:
        parts.add('✅ completed');
      case SubagentStatus.failed:
        parts.add('❌ failed');
      case SubagentStatus.aborted:
        parts.add('🛑 aborted');
    }
    if (tokens > 0) parts.add('${tokens}t');
    if (modelId != null) parts.add(modelId!);
    return parts.join(' · ');
  }
}
