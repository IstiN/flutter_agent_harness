import 'package:fa/network/models.dart' as network;
import 'package:fa/network/network_session_manager.dart';

import 'chat_list_entry.dart';
import 'network_inbox_adapter.dart';

/// Production HTTP transport for the account-scoped aggregate inbox.
///
/// Every operation obtains a fresh account client from the session manager.
/// The adapter owns no HTTP client, channel sessions, WebSockets, or wallet
/// state. Signed-out users (including an unusable refreshed session) get a
/// [NetworkInboxUnavailableException] before any relay request; an empty or
/// fabricated inbox is never substituted for authentication.
final class NetworkInboxHttpAdapter implements NetworkInboxAdapter {
  const NetworkInboxHttpAdapter({required this.sessionManager});

  final NetworkSessionManager sessionManager;

  @override
  Future<NetworkInboxPage> fetchInbox({
    int? limit,
    String? cursor,
    Set<ChatListEntryKind>? kinds,
  }) async {
    final client = await sessionManager.accountClient();
    if (client == null) throw _signedOut;
    final page = await client.listInbox(limit: limit, cursor: cursor);
    return NetworkInboxPage(
      items: [
        for (final item in page.items)
          if (kinds == null || kinds.contains(_kind(item.kind))) _item(item),
      ],
      nextCursor: page.nextCursor,
    );
  }

  @override
  Future<void> markChannelRead(
    String channelId, {
    int? seq,
    String? envelopeId,
    bool all = false,
  }) async {
    final client = await sessionManager.accountClient();
    if (client == null) throw _signedOut;
    await client.markChannelRead(
      channelId,
      seq: seq,
      envelopeId: envelopeId,
      all: all,
    );
  }

  static const _signedOut = NetworkInboxUnavailableException(
    'Sign in with a network account to use the aggregate inbox.',
  );

  static ChatListEntryKind _kind(String kind) => kind == 'channel'
      ? ChatListEntryKind.networkChannel
      : ChatListEntryKind.networkAgent;

  static NetworkInboxItem _item(network.InboxItem item) => NetworkInboxItem(
    kind: _kind(item.kind),
    networkId: item.networkId,
    id: item.id,
    title: item.title,
    lastActivity: item.lastActivity,
    unreadCount: item.unreadCount,
    lastEnvelope: item.lastEnvelope == null
        ? null
        : _envelope(item.lastEnvelope!),
    presence: switch (item.presence) {
      network.Presence.live => ChatPresence.live,
      network.Presence.busy => ChatPresence.busy,
      network.Presence.offline => ChatPresence.offline,
      _ => null,
    },
  );

  static NetworkEnvelopeRef _envelope(network.Envelope envelope) =>
      NetworkEnvelopeRef(
        id: envelope.id,
        createdAt: envelope.createdAt?.toIso8601String() ?? '',
        senderId: envelope.senderId,
        senderName: envelope.senderName ?? '',
        senderKey: envelope.senderKey ?? '',
        payload: envelope.payload,
        mentions: envelope.mentions ?? const [],
      );
}
