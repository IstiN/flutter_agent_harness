// Part of hub.dart — the admin REST API as pure request/response
// functions (the io binding maps HTTP onto them).
//
// Port of the Go admin.go. Bearer token from DapHubConfig.adminToken,
// verified with a constant-time compare.

part of 'hub.dart';

/// One admin API response: HTTP status plus the body text.
typedef DapAdminResponse = ({int status, String body});

/// The admin REST API as pure request/response functions (the io
/// binding maps HTTP onto them).
extension DapHubAdminApi on DapHub {
  /// Whether [bearer] authorizes an admin call (constant-time compare;
  /// empty configured token disables the API entirely).
  bool _adminOk(String bearer) =>
      bearer.isNotEmpty &&
      _config.adminToken.isNotEmpty &&
      constEq(bearer, _config.adminToken);

  DapAdminResponse _unauthorized(String what) {
    _log('admin $what result=denied');
    return (status: 401, body: 'unauthorized');
  }

  /// `GET /api/channels` → `[{"name","members":N,"aclSize":N}]`.
  DapAdminResponse adminChannelsList(String bearer) {
    if (!_adminOk(bearer)) return _unauthorized('channels');
    final rows = [
      for (final channel in channels.values)
        {
          'name': channel.name,
          'members': channel.members.length,
          'aclSize': channel.allowed.length,
        },
    ];
    _log('admin channels result=ok channels=${rows.length}');
    return (status: 200, body: jsonEncode(rows));
  }

  /// `PUT /api/channels/{name}/acl` body `{"allowed":[...]}` — replaces
  /// the channel's ACL, upserting the channel. Empty list = any
  /// authenticated agent.
  DapAdminResponse adminSetAcl(String bearer, String name, String body) {
    if (!_adminOk(bearer)) return _unauthorized('set_acl');
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on Object catch (e) {
      _log('admin set_acl result=bad_request');
      return (status: 400, body: '$e');
    }
    if (decoded is! Map<String, Object?> || decoded['allowed'] is! List) {
      _log('admin set_acl result=bad_request');
      return (status: 400, body: 'body must be {"allowed":[...]}');
    }
    final allowed = [for (final a in decoded['allowed'] as List) '$a'];
    final channel = channels.putIfAbsent(name, () => HubChannel(name: name));
    channel.allowed = allowed;
    _persistChannels();
    _log('admin set_acl result=ok channel=$name acl=${allowed.length}');
    return (status: 204, body: '');
  }

  /// `GET /api/agents` → the presence list.
  DapAdminResponse adminAgentsList(String bearer) {
    if (!_adminOk(bearer)) return _unauthorized('agents');
    final rows = [
      for (final e in agents.entries)
        {
          'agentId': e.key,
          'pubkey': e.value.pubkey,
          if (e.value.x25519.isNotEmpty) 'x25519': e.value.x25519,
          if (e.value.name.isNotEmpty) 'name': e.value.name,
          'online': e.value.online,
          if (e.value.lastSeen > 0) 'lastSeen': e.value.lastSeen,
        },
    ];
    _log('admin agents result=ok agents=${rows.length}');
    return (status: 200, body: jsonEncode(rows));
  }

  /// `DELETE /api/agents/{agentId}` — evicts one identity from the
  /// registry (explicit admin action only — never automatic). Refused
  /// with 409 while the agent is connected; the agent's queued mailbox
  /// frames go with the identity.
  DapAdminResponse adminEvict(String bearer, String agentId) {
    if (!_adminOk(bearer)) return _unauthorized('evict');
    final entry = agents[agentId];
    if (entry == null) {
      return (status: 404, body: 'no such agent');
    }
    if (clients[agentId] != null) {
      return (status: 409, body: 'agent is online');
    }
    _evictIdentity(agentId, entry);
    _log('admin evict result=ok agent=$agentId');
    return (status: 204, body: '');
  }

  /// Removes the identity and its mailbox; purges the issued secret only
  /// when no surviving registry entry shares the name (duplicate
  /// enrollments can share one name — purging then would break the
  /// survivor's dial-in).
  void _evictIdentity(String agentId, AgentEntry entry) {
    agents.remove(agentId);
    mailbox.remove(agentId);
    mailboxDropped.remove(agentId);
    final name = entry.name;
    if (!secrets.containsKey(name)) return;
    final shared = agents.values.any((e) => e.name == name);
    if (shared) {
      _log('admin evict agent=$agentId name=$name secret_purge=skipped');
      return;
    }
    secrets.remove(name);
    _persistSecrets();
  }
}
