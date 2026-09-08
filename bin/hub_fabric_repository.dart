/// The hub as the messaging fabric's primary transport (issue #27 phase 1):
/// a [MessagingRepository] over the DAP hub client, composed with the file
/// fabric through `FallbackMessagingRepository`.
///
/// Lives in `bin/` on purpose — `package:fa_hub_client` pulls `dart:io`
/// (WebSocket, key files) and `lib/src/**` stays web-pure, exactly like the
/// `hub` plugin host in `fah_hub_plugin.dart`. The harness's pure
/// `RoutingMessagingRepository` capability is what lets the composition
/// route without knowing anything about DAP.
///
/// Mapping to the hub model:
/// * presence/registration ride the signed hello (`register`/`touch` are
///   deliberate no-ops — the display name is the DAP identity, stable
///   across restarts);
/// * `send` targets are resolved against the hub roster BEFORE the call
///   ([resolveTarget] — exact 16-hex id, unique display name, or `#channel`);
/// * inbound frames land in the package repository's in-memory inbox keyed
///   by OUR hub agent id, so `peek`/`drain` ignore the fabric agentId (the
///   composition guards that only the wired `primaryMailbox` reaches here);
/// * `directory` maps the hub roster (online AND offline — the hub keeps
///   offline mailboxes and flushes them on the peer's next connect) onto
///   mailbox entries.
library;

import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Hub-backed [MessagingRepository] over a [hub.HubPlugin].
final class HubFabricRepository
    implements MessagingRepository, RoutingMessagingRepository {
  HubFabricRepository(this._plugin);

  final hub.HubPlugin _plugin;

  hub.HubMessagingRepository? get _repo => _plugin.repository;

  String? get _agentId => _plugin.agentId;

  @override
  bool get isConnected => _repo?.client.connected ?? false;

  @override
  Future<String?> resolveTarget(String toId) async {
    if (!isConnected) return null;
    // Channels are always hub-shaped (the package client routes the send
    // and auto-creates unknown channels on first use).
    if (toId.startsWith('#')) return toId;
    final me = _agentId;
    if (me != null && toId == me) return null; // our own fabric mailbox
    final roster = await _repo!.client.presenceQuery();
    for (final agent in roster) {
      if (agent.agentId == toId) return toId; // exact id wins
    }
    final byName = roster.where((agent) => agent.name == toId).toList();
    // A display name resolves only when it is unambiguous — matches the
    // dap_dm resolver; an ambiguous name falls through to the file fabric
    // where the session-name resolution owns it.
    return byName.length == 1 ? byName.single.agentId : null;
  }

  @override
  Future<void> send(AgentMessage message) async {
    final repo = _repo;
    final agentId = _agentId;
    if (repo == null || agentId == null) {
      throw StateError('hub fabric not connected — no hub client');
    }
    await repo.send(
      hub.AgentMessage(
        id: message.id,
        fromId: agentId,
        toId: message.toId,
        text: message.text,
        sentAt: message.sentAt,
      ),
    );
  }

  @override
  Future<List<AgentMessage>> peek(String agentId) async {
    final repo = _repo;
    final inbox = _agentId;
    if (repo == null || inbox == null) return const [];
    try {
      return _fromHub(await repo.peek(inbox));
    } on Object {
      return const [];
    }
  }

  @override
  Future<List<AgentMessage>> drain(String agentId) async {
    final repo = _repo;
    final inbox = _agentId;
    if (repo == null || inbox == null) return const [];
    try {
      return _fromHub(await repo.drain(inbox));
    } on Object {
      return const [];
    }
  }

  /// Maps the package's mirrored AgentMessage onto the harness type. The
  /// recipient is OUR hub inbox — reported as the hub agent id so the
  /// steering attribution reads the true sender.
  List<AgentMessage> _fromHub(List<hub.AgentMessage> messages) => [
    for (final message in messages)
      AgentMessage(
        id: message.id,
        fromId: message.fromId,
        toId: _agentId ?? message.toId,
        text: message.text,
        sentAt: message.sentAt,
        hops: message.hops,
      ),
  ];

  @override
  Future<void> register(String agentId, {String? sessionName}) async {
    // Presence rides the signed hello; the hub display name is the DAP
    // identity (stable across restarts), not the per-session fabric name.
  }

  @override
  Future<void> touch(String agentId) async {
    // Hub liveness is the connection itself; the hub dates peers by their
    // last authenticated frame (lastSeen), not by client heartbeats.
  }

  @override
  Future<List<MailboxEntry>> directory() async {
    final repo = _repo;
    if (repo == null) return const [];
    final roster = await repo.client.presenceQuery();
    return [
      for (final agent in roster)
        MailboxEntry(
          id: agent.agentId,
          name: agent.name,
          lastActivity: agent.lastSeen,
        ),
    ];
  }
}
