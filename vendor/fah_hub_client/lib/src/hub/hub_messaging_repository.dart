/// [MessagingRepository] over a DAP/1 hub connection — the "future
/// database/network implementation" the upstream interface doc invites.
///
/// Mapping to the hub model:
/// * `register`/`connect` announce presence via the signed hello.
/// * `send` routes on [AgentMessage.toId]: `#channel` → channel send,
///   anything else → E2E DM (whois resolves the peer key first).
/// * Inbound `msg` frames land in per-agent inboxes, drained at the next
///   turn boundary by [drain] (wired to `Agent.externalSteeringSource`).
/// * `directory` maps a hub presence query onto [MailboxEntry]es.
library;

import 'dart:async';

import '../fah/messaging.dart';
import 'hub_client.dart';

class HubMessagingRepository implements MessagingRepository {
  HubMessagingRepository(this.client);

  final HubClient client;
  final _inboxes = <String, List<AgentMessage>>{};
  StreamSubscription<InboundMessage>? _subscription;

  /// Connects to the hub and starts delivering inbound messages. Must be
  /// called before [send]/[peek]/[drain].
  Future<void> start() async {
    await client.connect();
    await _subscription?.cancel();
    _subscription = client.inbound.listen(_deliver);
  }

  void _deliver(InboundMessage message) {
    // Undecryptable payloads (key mismatch across a retarget, tampered
    // frame) still surface — never silent.
    final text = message.plaintext ??
        '[hub] undecryptable message from '
        '${message.from.isEmpty ? 'unknown' : message.from}';
    final toId = _inboxIdFor(message);
    _inboxes.putIfAbsent(toId, () => []).add(AgentMessage(
          id: message.id,
          fromId: message.from,
          toId: toId,
          text: text,
          sentAt: DateTime.fromMillisecondsSinceEpoch(message.ts)
              .toUtc()
              .toIso8601String(),
        ));
  }

  String _inboxIdFor(InboundMessage message) =>
      message.channel != null ? '#${message.channel}' : (client.agentId ?? '');

  @override
  Future<void> send(AgentMessage message) async {
    final toId = message.toId;
    if (toId.startsWith('#')) {
      await client.sendToChannel(toId.substring(1), message.text);
    } else {
      await client.sendDm(toId, message.text);
    }
  }


  /// `dap_status` passthrough (see [HubClient.status]): connection state,
  /// identity, known channels, and hello/welcome counters.
  HubStatus status() => client.status();

  /// `dap_peers` passthrough (see [HubClient.peers]): online-only hub
  /// presence list unless [includeOffline] is true.
  Future<List<AgentInfo>> peers({bool includeOffline = false}) =>
      client.peers(includeOffline: includeOffline);

  /// dap_connect passthrough (see [HubClient.connectTo]): runtime move
  /// of the live connection to another hub, optionally under a new
  /// name-derived identity, with an optional default room.
  Future<DapConnection> connectTo(String host,
          {String? name, String? channel, String? home}) =>
      client.connectTo(host, name: name, channel: channel, home: home);

  @override
  Future<void> register(String agentId) => start();

  @override
  Future<List<AgentMessage>> peek(String agentId) =>
      Future.value(List.of(_inboxes[agentId] ?? const []));

  @override
  Future<List<AgentMessage>> drain(String agentId) =>
      Future.value(List.of(_inboxes.remove(agentId) ?? const []));

  @override
  Future<List<MailboxEntry>> directory() async {
    final agents = await client.presenceQuery();
    return [
      for (final agent in agents)
        MailboxEntry(id: agent.agentId, slug: agent.name),
    ];
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await client.disconnect();
  }
}
