// Part of hub.dart — whois directory, presence query/broadcast.
//
// Port of the Go presence.go.

part of 'hub.dart';

extension _DapHubPresence on DapHub {
  /// Answers with the target agent's public identity.
  void _handleWhois(ClientSession session, DapFrame frame) {
    final entry = agents[frame.agentId];
    if (entry == null) {
      _sendErr(
        session,
        DapCodes.unknownAgent,
        'no such agent: ${frame.agentId}',
      );
      return;
    }
    session.sendFrame({
      'op': 'agent_info',
      'agentId': frame.agentId,
      'pubkey': entry.pubkey,
      if (entry.x25519.isNotEmpty) 'x25519': entry.x25519,
      if (entry.name.isNotEmpty) 'name': entry.name,
      'online': entry.online,
      if (entry.lastSeen > 0) 'lastSeen': entry.lastSeen,
    });
  }

  /// Lists every known agent with online state. The answer echoes a
  /// request frame id as replyTo (absent when the query carried none);
  /// broadcast pushes NEVER carry replyTo — clients complete a pending
  /// query only on a replyTo match, so a concurrent broadcast cannot
  /// satisfy it with a partial roster.
  void _handlePresenceQuery(ClientSession session, DapFrame frame) {
    session.sendFrame({
      'op': 'presence',
      if (frame.id.isNotEmpty) 'replyTo': frame.id,
      'agents': [for (final e in agents.entries) _agentInfo(e.key, e.value)],
    });
  }

  /// Announces one agent's state change to the given peers (connected
  /// members sharing a channel with the agent).
  void _sendPresence(
    List<ClientSession> peers,
    String agentId,
    AgentEntry entry, {
    required bool online,
  }) {
    if (peers.isEmpty) return;
    final frame = {
      'op': 'presence',
      'agents': [
        _agentInfo(agentId, entry, online: online, lastSeen: _now),
      ],
    };
    for (final peer in peers) {
      peer.sendFrame(frame);
    }
  }

  Map<String, Object?> _agentInfo(
    String agentId,
    AgentEntry entry, {
    bool? online,
    int? lastSeen,
  }) =>
      {
        'agentId': agentId,
        'pubkey': entry.pubkey,
        if (entry.x25519.isNotEmpty) 'x25519': entry.x25519,
        if (entry.name.isNotEmpty) 'name': entry.name,
        'online': online ?? entry.online,
        'lastSeen': lastSeen ?? entry.lastSeen,
      };
}
