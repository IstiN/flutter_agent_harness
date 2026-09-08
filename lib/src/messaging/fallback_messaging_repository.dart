/// Hub-primary, file-fallback composition for the agent messaging fabric
/// (issue #27 phase 1): the hub is the live transport, the file inboxes
/// remain the offline fallback. Both implementations stay behind the
/// existing [MessagingRepository] contract — the agent-loop seams
/// (`externalSteeringSource`, idle wake, `mailboxPrefix`) are untouched.
///
/// Routing:
/// * `send` asks the primary whether it can deliver the recipient
///   ([RoutingMessagingRepository.resolveTarget]); a hub-shaped recipient
///   goes hub-ward, everything else (and every hub failure) lands in the
///   file fabric exactly as before. While the hub is down, file-bound mail
///   is tracked and FORWARDED on the next connected call (at-least-once;
///   recipients dedupe by message id).
/// * `peek`/`drain` merge the primary's inbox into [primaryMailbox]'s drain
///   only — the one fabric mailbox the hub identity owns. Subagent drains
///   never touch the hub, so a child cannot steal hub mail.
/// * `directory` merges both views; a file entry wins on id collision.
library;

import 'agent_message.dart';
import 'messaging_repository.dart';

/// Capability of a primary repository that routes by recipient: it can say
/// whether [toId] is deliverable through it and return the CANONICAL target
/// id (a display name resolved to the peer id, a channel passed through).
/// Null means "not mine" — the recipient belongs to the file fabric (or the
/// primary is not connected). Implementations must be cheap to call and
/// never throw for a null answer.
abstract interface class RoutingMessagingRepository {
  /// Whether the live transport is currently usable. A false answer routes
  /// everything to the fallback.
  bool get isConnected;

  /// The canonical target id for [toId] on this transport, or null when
  /// [toId] is not deliverable here (unknown recipient, transport down).
  Future<String?> resolveTarget(String toId);
}

/// A [MessagingRepository] composing a primary (hub) transport with a
/// fallback (file) fabric. See the library docs for the routing rules.
// ignore_for_file: prefer_initializing_formals
final class FallbackMessagingRepository implements MessagingRepository {
  FallbackMessagingRepository({
    required MessagingRepository primary,
    required MessagingRepository fallback,
  }) : _primary = primary,
       _fallback = fallback;
  final MessagingRepository _primary;
  final MessagingRepository _fallback;

  /// The fabric mailbox whose drain merges hub mail — the hub identity's
  /// own address (`<sessionId>/main`). The host wires it after construction
  /// (the mailbox prefix exists only once a session does). Null or a null
  /// answer = pure-file drains.
  String? Function()? primaryMailbox;

  /// Recipient -> message ids this repository queued into the file fabric
  /// while the hub path was unavailable, pending forward-on-reconnect.
  final _pendingForward = <String, Set<String>>{};

  /// The primary as a router, when it advertises the capability.
  RoutingMessagingRepository? get _router =>
      _primary is RoutingMessagingRepository
      ? _primary as RoutingMessagingRepository
      : null;

  @override
  Future<void> send(AgentMessage message) async {
    await _flushQueued();
    final target = await _safeResolve(message.toId);
    if (target != null) {
      try {
        await _primary.send(_retarget(message, target));
        return;
      } on Object {
        // Hub delivery failed (whois race, evicted socket) — the file
        // fallback below keeps the message; the forwarder retries later.
      }
    } else if (message.toId.startsWith('#')) {
      // Channels exist only on the hub; a file mailbox nobody polls would
      // be a silent dead drop. Honest failure instead.
      throw StateError(
        'hub not connected — channel ${message.toId} is undeliverable',
      );
    }
    await _fallback.send(message);
    _trackForForward(message);
  }

  /// Rewrites [message]'s recipient to the resolved [target], keeping the
  /// identity (id) stable so recipients dedupe across retried deliveries.
  AgentMessage _retarget(AgentMessage message, String target) => AgentMessage(
    id: message.id,
    fromId: message.fromId,
    toId: target,
    text: message.text,
    sentAt: message.sentAt,
    hops: message.hops,
    kind: message.kind,
  );

  Future<String?> _safeResolve(String toId) async {
    final router = _router;
    if (router == null || !router.isConnected) return null;
    try {
      return await router.resolveTarget(toId);
    } on Object {
      return null;
    }
  }

  void _trackForForward(AgentMessage message) => _pendingForward
      .putIfAbsent(message.toId, () => <String>{})
      .add(message.id);

  /// Forwards file-queued hub mail on a live primary. Cheap no-op when
  /// nothing is tracked or the hub is down; called opportunistically from
  /// every send — the CLI's 2s inbox probe makes the post-reconnect flush
  /// immediate without any timer or stream wiring.
  Future<void> _flushQueued() async {
    if (_pendingForward.isEmpty) return;
    for (final entry in _pendingForward.entries.toList()) {
      final recipient = entry.key;
      final target = await _safeResolve(recipient);
      if (target == null) {
        // Not a hub peer (or still disconnected): the file fabric owns this
        // mail — stop tracking, never forward it.
        _pendingForward.remove(recipient);
        continue;
      }
      final pending = await _safePeek(recipient);
      final ours = [
        for (final message in pending)
          if (entry.value.contains(message.id)) message,
      ];
      var forwarded = 0;
      for (final message in ours) {
        try {
          await _primary.send(_retarget(message, target));
          forwarded++;
        } on Object {
          break; // keep the rest queued; the next connected call retries
        }
      }
      if (forwarded == 0) continue;
      final forwardedIds = ours.take(forwarded).map((m) => m.id).toSet();
      await _removeFromFileInbox(recipient, forwardedIds);
      entry.value.removeAll(forwardedIds);
      if (entry.value.isEmpty) _pendingForward.remove(recipient);
    }
  }

  /// Removes the forwarded copies from the recipient's file inbox so a
  /// file-polling peer never sees the mail twice. Drain-and-rewrite: the
  /// message id is the file name, so survivors come back unchanged and in
  /// order. A crash between hub-send and removal duplicates the message —
  /// recipients dedupe by id (at-least-once).
  Future<void> _removeFromFileInbox(
    String recipient,
    Set<String> forwardedIds,
  ) async {
    try {
      final all = await _fallback.drain(recipient);
      for (final message in all) {
        if (!forwardedIds.contains(message.id)) await _fallback.send(message);
      }
    } on Object {
      // Best-effort cleanup; the copy left behind dedupes by id anyway.
    }
  }

  Future<List<AgentMessage>> _safePeek(String agentId) async {
    try {
      return await _fallback.peek(agentId);
    } on Object {
      return const [];
    }
  }

  /// Whether [agentId] is the hub identity's fabric mailbox (the one drain
  /// that merges hub mail).
  bool _isPrimaryMailbox(String agentId) =>
      primaryMailbox != null && primaryMailbox!() == agentId;

  @override
  Future<List<AgentMessage>> peek(String agentId) async {
    final fileMessages = await _safePeek(agentId);
    if (!_isPrimaryMailbox(agentId)) return fileMessages;
    final hubMessages = await _safeInbox(agentId, consume: false);
    return _merge(hubMessages, fileMessages);
  }

  @override
  Future<List<AgentMessage>> drain(String agentId) async {
    final fileMessages = await _fallback.drain(agentId);
    if (!_isPrimaryMailbox(agentId)) return fileMessages;
    final hubMessages = await _safeInbox(agentId, consume: true);
    return _merge(hubMessages, fileMessages);
  }

  /// The primary inbox, never throwing — the steering contract requires an
  /// empty-list answer over a broken transport.
  Future<List<AgentMessage>> _safeInbox(
    String agentId, {
    required bool consume,
  }) async {
    try {
      return consume
          ? await _primary.drain(agentId)
          : await _primary.peek(agentId);
    } on Object {
      return const [];
    }
  }

  /// Oldest-first merge of both transports' inboxes, deduped by message id
  /// (at-least-once forwarding can deliver a message twice).
  List<AgentMessage> _merge(
    List<AgentMessage> hubMessages,
    List<AgentMessage> fileMessages,
  ) {
    final seen = <String>{};
    return [
      for (final message in [...hubMessages, ...fileMessages])
        if (seen.add(message.id)) message,
    ]..sort((a, b) {
      final byTime = a.sentAt.compareTo(b.sentAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  }

  @override
  Future<void> register(String agentId, {String? sessionName}) async {
    await _fallback.register(agentId, sessionName: sessionName);
    try {
      await _primary.register(agentId, sessionName: sessionName);
    } on Object {
      // Best-effort: hub presence rides the signed hello, a failed
      // announce must not break session startup.
    }
  }

  @override
  Future<void> touch(String agentId) async {
    await _fallback.touch(agentId);
    try {
      await _primary.touch(agentId);
    } on Object {
      // Best-effort heartbeat.
    }
  }

  @override
  Future<List<MailboxEntry>> directory() async {
    final entries = await _fallback.directory();
    try {
      final ids = {for (final entry in entries) entry.id};
      for (final entry in await _primary.directory()) {
        // File truth wins on collision: a local mailbox is drained locally.
        if (!ids.add(entry.id)) continue;
        entries.add(entry);
      }
    } on Object {
      // A broken primary hides only its own peers.
    }
    return entries;
  }
}
