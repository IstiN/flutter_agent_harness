import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/network_inbox_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exact OpenAPI inbox fixture parses createdAt and opaque base64', () {
    final page = NetworkInboxPage.fromJson({
      'items': [
        {
          'kind': 'channel',
          'networkId': 'net',
          'id': 'general',
          'title': 'General',
          'lastActivity': '2026-08-01T12:00:00Z',
          'unreadCount': 3,
          'lastEnvelope': {
            'id': 'env-1',
            'channelId': 'general',
            'createdAt': '2026-08-01T12:00:00Z',
            'senderId': 'sender',
            'senderName': 'Sender',
            'senderKey': 'key',
            'payload': 'aGVsbG8=',
            'mentions': <String>[],
          },
        },
      ],
      'nextCursor': null,
    });

    expect(page.items.single.unreadCount, 3);
    expect(page.items.single.lastEnvelope?.createdAt, '2026-08-01T12:00:00Z');
    expect(page.items.single.lastEnvelope?.payload, 'aGVsbG8=');
  });

  test('fixture kind filtering is local and transport-independent', () async {
    final adapter = FixtureNetworkInboxAdapter(
      items: [
        const NetworkInboxItem(
          kind: ChatListEntryKind.networkChannel,
          networkId: 'net',
          id: 'channel',
          title: 'Channel',
          unreadCount: 0,
        ),
        const NetworkInboxItem(
          kind: ChatListEntryKind.networkAgent,
          networkId: 'net',
          id: 'agent',
          title: 'Agent',
        ),
      ],
    );
    final page = await adapter.fetchInbox(
      kinds: {ChatListEntryKind.networkAgent},
    );
    expect(page.items.single.id, 'agent');
    expect(page.items.single.unreadCount, isNull);
  });
}
