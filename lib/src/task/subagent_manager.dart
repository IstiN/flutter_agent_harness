/// Session-scoped manager for retained subagent handles. Phase 3a of the
/// subagents 2.0 plan.
///
/// Owns the [SubagentHandle] registry, persists it into the parent session
/// as a `subagent_registry` record, and rehydrates on restart. The manager
/// itself is transport-neutral: session creation/resumption is injected
/// through callbacks so the CLI and the app can wire their own session
/// backends.
library;

import 'dart:async';

import 'subagent.dart';

/// One observable event from a subagent (status transition, output preview,
/// or an inbound message — Phase 3b).
final class SubagentEvent {
  const SubagentEvent({required this.handle, this.message});
  final SubagentHandle handle;
  final SubagentMessage? message;
}

typedef ChildSessionFactory =
    Future<String> Function(String parentSessionId, String childId);

/// Callback to record the subagent registry into the parent session.
typedef SubagentRegistrySink =
    Future<void> Function(List<Map<String, dynamic>> registry);

/// Callback to rehydrate the registry from the parent session.
typedef SubagentRegistrySource = Future<List<Map<String, dynamic>>> Function();

/// Session-scoped subagent manager.
final class SubagentManager {
  SubagentManager({
    required this.parentSessionId,
    this.createChildSession,
    this.sink,
    this.source,
    this.maxPendingMessages = 16,
    this.maxReplyChars = 8000,
  });

  /// The parent session id (used to derive child session paths).
  final String parentSessionId;

  /// Injected: creates a new child session, returns its id.
  final ChildSessionFactory? createChildSession;

  /// Injected: persists the registry into the parent session.
  final SubagentRegistrySink? sink;

  /// Injected: reads the persisted registry from the parent session.
  final SubagentRegistrySource? source;

  /// Size guard: messages queued to one child before new ones are rejected
  /// (Phase 3b pending-queue guard).
  final int maxPendingMessages;

  /// Size guard: reply/message body cap in characters.
  final int maxReplyChars;

  final _handles = <String, SubagentHandle>{};
  final _events = StreamController<SubagentEvent>.broadcast();
  var _rehydrated = false;

  /// All handles in registration order.
  List<SubagentHandle> get handles => List.unmodifiable(_handles.values);

  /// Broadcast stream of subagent events.
  Stream<SubagentEvent> get events => _events.stream;

  /// Looks up a handle by id.
  SubagentHandle? operator [](String id) => _handles[id];

  /// Rehydrates the registry from the parent session (idempotent).
  Future<void> rehydrate() async {
    if (_rehydrated) return;
    _rehydrated = true;
    final raw = await source?.call() ?? const [];
    for (final entry in raw) {
      final handle = SubagentHandle.fromJson(entry);
      _handles[handle.id] = handle;
    }
  }

  /// Registers a new subagent, optionally creating a child session.
  Future<SubagentHandle> register({
    required String id,
    required String name,
    required String agentType,
    required String task,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    String? sessionId;
    if (createChildSession != null) {
      sessionId = await createChildSession!(parentSessionId, id);
    } else {
      sessionId = '$parentSessionId/$id';
    }
    final handle = SubagentHandle(
      id: id,
      name: name,
      agentType: agentType,
      sessionId: sessionId,
      createdAt: now,
      task: task,
    )..lastActivity = now;
    _handles[id] = handle;
    _emit(handle);
    await _persist();
    return handle;
  }

  /// Updates a handle's status and emits an event.
  Future<void> update(
    String id, {
    SubagentStatus? status,
    int? tokens,
    int? requests,
    String? modelId,
    String? error,
  }) async {
    final handle = _handles[id];
    if (handle == null) return;
    if (status != null) handle.status = status;
    if (tokens != null) handle.tokens += tokens;
    if (requests != null) handle.requests += requests;
    if (modelId != null) handle.modelId = modelId;
    if (error != null) handle.error = error;
    handle.lastActivity = DateTime.now().toUtc().toIso8601String();
    _emit(handle);
    await _persist();
  }

  /// Removes a handle (dispose).
  Future<void> dispose(String id) async {
    _handles.remove(id);
    await _persist();
  }

  /// Queues [message] for [id] (Phase 3b `agent_message` / parent steering).
  /// Throws [StateError] for an unknown id or a full pending queue; caps the
  /// body at [maxReplyChars]. Aborted children refuse new messages.
  Future<void> enqueueMessage(String id, SubagentMessage message) async {
    final handle = _handles[id];
    if (handle == null) {
      throw StateError(
        'unknown subagent "$id" — available: ${_handles.keys.join(', ')}',
      );
    }
    if (handle.status == SubagentStatus.aborted) {
      throw StateError('subagent "$id" is aborted and takes no messages');
    }
    if (handle.pendingMessages.length >= maxPendingMessages) {
      throw StateError(
        'subagent "$id" pending queue is full ($maxPendingMessages) — '
        'the child must consume its messages first',
      );
    }
    final capped = message.text.length > maxReplyChars
        ? SubagentMessage(
            fromId: message.fromId,
            text: '${message.text.substring(0, maxReplyChars)}…[truncated]',
            sentAt: message.sentAt,
            hops: message.hops,
          )
        : message;
    handle.pendingMessages.add(capped);
    handle.lastActivity = DateTime.now().toUtc().toIso8601String();
    _events.add(SubagentEvent(handle: handle, message: capped));
    await _persist();
  }

  /// Drains [id]'s pending queue (delivered messages leave the registry).
  List<SubagentMessage> drainMessages(String id) {
    final handle = _handles[id];
    if (handle == null) return const [];
    final drained = List<SubagentMessage>.of(handle.pendingMessages);
    handle.pendingMessages.clear();
    return drained;
  }

  /// Records the child's explicit `reply` (Phase 3b) on its handle.
  Future<void> recordReply(String id, String text) async {
    final handle = _handles[id];
    if (handle == null) return;
    handle.lastReply = text.length > maxReplyChars
        ? '${text.substring(0, maxReplyChars)}…[truncated]'
        : text;
    handle.lastActivity = DateTime.now().toUtc().toIso8601String();
    _events.add(SubagentEvent(handle: handle));
    await _persist();
  }

  /// Attaches the child's real session file to its handle (called by the
  /// executor at child completion when a session factory is wired). The
  /// handle's placeholder id becomes the real JSONL path used by
  /// `/agents open <id>` and `task_observe`.
  Future<void> attachSession(String id, String sessionPath) async {
    final handle = _handles[id];
    if (handle == null) return;
    handle.sessionId = sessionPath;
    handle.lastActivity = DateTime.now().toUtc().toIso8601String();
    _events.add(SubagentEvent(handle: handle));
    await _persist();
  }

  /// Closes the event stream.
  Future<void> close() => _events.close();

  void _emit(SubagentHandle handle) {
    _events.add(SubagentEvent(handle: handle));
  }

  Future<void> _persist() async {
    await sink?.call([for (final h in _handles.values) h.toJson()]);
  }
}
