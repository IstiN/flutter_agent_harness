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

import '../messaging/agent_message.dart';
import '../messaging/messaging_repository.dart';
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
    this.messaging,
    this.selfId = 'main',
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

  /// Injected: the messaging fabric. When present, inter-agent messages go
  /// through per-agent inboxes (visible across processes sharing the
  /// messaging root) instead of the in-process pending queue.
  final MessagingRepository? messaging;

  /// This host's own agent id in the messaging fabric (`main` for the
  /// orchestrator). Inbox drains for the loop use it.
  final String selfId;

  /// Namespace prefix for every mailbox this manager touches (e.g. the
  /// parent session id): two Fa instances sharing one messaging root never
  /// drain each other's inboxes. Mutable — the host sets it once the
  /// session (and thus its id) exists. Empty = single-instance mode.
  String mailboxPrefix = '';

  /// The fabric mailbox for a local agent id. An id containing `/` is
  /// already an absolute mailbox (cross-instance addressing like
  /// `<sessionId>/main`) and passes through unprefixed.
  String mailboxOf(String id) {
    if (id.contains('/')) return id;
    return mailboxPrefix.isEmpty ? id : '$mailboxPrefix/$id';
  }

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

  /// Drops the registry view so the next [rehydrate] loads afresh — used
  /// when the host switches to a different parent session (each session owns
  /// its own registry).
  void reset() {
    _handles.clear();
    _rehydrated = false;
  }

  /// Registers a new subagent — NEVER creates a child session eagerly.
  ///
  /// The handle's [SubagentHandle.sessionId] is a synthetic
  /// `<parentSessionId>/<id>` placeholder until the executor calls
  /// [attachSession] with the real JSONL path (at completion). This keeps the
  /// session repo free of empty `.jsonl` files for subagents that never run
  /// to completion (fast-register path, steering aborts, etc.).
  Future<SubagentHandle> register({
    required String id,
    required String name,
    required String agentType,
    required String task,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final handle = SubagentHandle(
      id: id,
      name: name,
      agentType: agentType,
      // Placeholder until the executor does the real attachSession call.
      sessionId: '$parentSessionId/$id',
      createdAt: now,
      task: task,
    )..lastActivity = now;
    _handles[id] = handle;
    _emit(handle);
    _persist();
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
    _persist();
  }

  /// Removes a handle (dispose).
  Future<void> dispose(String id) async {
    _handles.remove(id);
    _persist();
  }

  /// Queues [message] for [id] (Phase 3b `agent_message` / parent steering).
  /// Throws [StateError] for an unknown id or a full pending queue; caps the
  /// body at [maxReplyChars]. Aborted children refuse new messages.
  ///
  /// With a [messaging] fabric the message is DELIVERED to the recipient's
  /// inbox (cross-process visible); otherwise it sits in the in-process
  /// pending queue. `main` ([selfId]) is a valid recipient — that is how
  /// children message the parent.
  Future<void> enqueueMessage(String id, SubagentMessage message) async {
    final handle = _handles[id];
    _guardRecipient(id, handle);
    final capped = _capMessage(message);
    if (messaging != null) {
      await _deliverViaFabric(id, handle, capped);
      return;
    }
    if (handle!.pendingMessages.length >= maxPendingMessages) {
      throw StateError(
        'subagent "$id" pending queue is full ($maxPendingMessages) — '
        'the child must consume its messages first',
      );
    }
    handle.pendingMessages.add(capped);
    _touchWithMessage(handle, capped);
  }

  /// Recipient validation for [enqueueMessage]: known local handle, the
  /// [selfId] inbox (fabric only), or an absolute cross-instance mailbox
  /// (fabric only). Aborted children refuse messages.
  void _guardRecipient(String id, SubagentHandle? handle) {
    final absolute = id.contains('/');
    final deliverable =
        handle != null || (id == selfId || absolute) && messaging != null;
    if (!deliverable) {
      throw StateError(
        'unknown subagent "$id" — available: ${_handles.keys.join(', ')}',
      );
    }
    if (handle?.status == SubagentStatus.aborted) {
      throw StateError('subagent "$id" is aborted and takes no messages');
    }
  }

  /// The body cap: overlong messages are truncated with a marker.
  SubagentMessage _capMessage(SubagentMessage message) {
    if (message.text.length <= maxReplyChars) return message;
    return SubagentMessage(
      fromId: message.fromId,
      text: '${message.text.substring(0, maxReplyChars)}…[truncated]',
      sentAt: message.sentAt,
      hops: message.hops,
    );
  }

  /// Fabric delivery: bounded by the recipient's unread inbox size.
  Future<void> _deliverViaFabric(
    String id,
    SubagentHandle? handle,
    SubagentMessage message,
  ) async {
    final mailbox = mailboxOf(id);
    final pending = await messaging!.peek(mailbox);
    if (pending.length >= maxPendingMessages) {
      throw StateError(
        'subagent "$id" pending queue is full ($maxPendingMessages) — '
        'the child must consume its messages first',
      );
    }
    await messaging!.send(
      AgentMessage(
        id: newMessageId(),
        fromId: mailboxOf(message.fromId),
        toId: mailbox,
        text: message.text,
        sentAt: message.sentAt,
        hops: message.hops,
      ),
    );
    if (handle != null) _touchWithMessage(handle, message);
  }

  /// Shared bookkeeping after a message is accepted for [handle].
  void _touchWithMessage(SubagentHandle handle, SubagentMessage message) {
    handle.lastActivity = DateTime.now().toUtc().toIso8601String();
    _events.add(SubagentEvent(handle: handle, message: message));
    _persist();
  }

  /// Drains [id]'s pending queue (delivered messages leave the registry).
  /// With a [messaging] fabric this consumes the agent's file inbox.
  Future<List<SubagentMessage>> drainMessages(String id) async {
    final fabric = messaging;
    if (fabric != null) {
      final drained = await fabric.drain(mailboxOf(id));
      return [
        for (final m in drained)
          SubagentMessage(
            fromId: m.fromId,
            text: m.text,
            sentAt: m.sentAt,
            hops: m.hops,
          ),
      ];
    }
    final handle = _handles[id];
    if (handle == null) return const [];
    final drained = List<SubagentMessage>.of(handle.pendingMessages);
    handle.pendingMessages.clear();
    return drained;
  }

  /// Counts the unread inbox messages of [id] (0 without a fabric) — the
  /// `mail:N` indicator in the agents panel.
  Future<int> pendingInboxCount(String id) async =>
      (await messaging?.peek(mailboxOf(id)) ?? const []).length;

  /// The unread inbox messages of [id] (empty without a fabric) — the
  /// pending-inbox block of the observe/detail views.
  Future<List<AgentMessage>> pendingInbox(String id) async =>
      await messaging?.peek(mailboxOf(id)) ?? const [];

  /// Records the child's explicit `reply` (Phase 3b) on its handle.
  Future<void> recordReply(String id, String text) async {
    final handle = _handles[id];
    if (handle == null) return;
    handle.lastReply = text.length > maxReplyChars
        ? '${text.substring(0, maxReplyChars)}…[truncated]'
        : text;
    handle.lastActivity = DateTime.now().toUtc().toIso8601String();
    _events.add(SubagentEvent(handle: handle));
    _persist();
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
    _persist();
  }

  /// Closes the event stream.
  Future<void> close() => _events.close();

  void _emit(SubagentHandle handle) {
    _events.add(SubagentEvent(handle: handle));
  }

  var _persistChain = Future<void>.value();

  /// Persists a registry snapshot best-effort: serialized (writes never
  /// interleave) and fire-and-forget — the spawn path must NEVER wait on
  /// session I/O (an awaited write breaks the background-task steering
  /// race), and a failed write must never break a spawn. Every mutation
  /// writes a full fresh snapshot, so a lost write is healed by the next
  /// one.
  void _persist() {
    final write = sink;
    if (write == null) return;
    final snapshot = [for (final h in _handles.values) h.toJson()];
    _persistChain = _persistChain.then((_) async {
      try {
        await write(snapshot);
      } on Object {
        // Best-effort — the next mutation rewrites the full snapshot.
      }
    });
  }
}
