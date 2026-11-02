import 'dart:convert';

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/network_inbox_adapter.dart';
import 'package:fa/ui/chats/network_inbox_http_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../network/fakes.dart';

Future<NetworkSessionManager> _manager(
  FakeHttpClient httpClient, {
  String? jwt,
}) async => NetworkSessionManager(
  baseUrl: testBase,
  wallet: await KeyWallet.load(MemoryWalletBackend()),
  httpClient: httpClient,
  wsConnector: FakeWsConnector(),
  jwtToken: jwt,
);

const _inboxBody =
    '{"items":['
    '{"kind":"channel","networkId":"net1","id":"c1","title":"general",'
    '"lastActivity":"2026-08-01T12:00:00Z","unreadCount":3,'
    '"lastEnvelope":{"id":"env1","channelId":"c1","senderId":"m1",'
    '"senderName":"Alice","senderKey":"key","payload":"aGVsbG8=",'
    '"mentions":["agent1"],"createdAt":"2026-08-01T12:00:00Z"}},'
    '{"kind":"agent","networkId":"net1","id":"agent1","title":"Helper",'
    '"lastActivity":"2026-08-01T11:00:00Z","presence":"busy"}],'
    '"nextCursor":"next-page"}';

void main() {
  test(
    'maps production DTOs including envelope createdAt and opaque base64',
    () async {
      final httpClient = FakeHttpClient()..respond(200, body: _inboxBody);
      final adapter = NetworkInboxHttpAdapter(
        sessionManager: await _manager(httpClient, jwt: 'jwt-dev'),
      );

      final page = await adapter.fetchInbox(limit: 50, cursor: 'current');

      expect(page.items, hasLength(2));
      final channel = page.items.first;
      expect(channel.kind, ChatListEntryKind.networkChannel);
      expect(channel.lastActivity, DateTime.utc(2026, 8, 1, 12));
      expect(channel.unreadCount, 3);
      expect(channel.lastEnvelope?.id, 'env1');
      expect(channel.lastEnvelope?.createdAt, '2026-08-01T12:00:00.000Z');
      expect(channel.lastEnvelope?.payload, 'aGVsbG8=');
      expect(channel.lastEnvelope?.mentions, ['agent1']);
      expect(page.items.last.presence, ChatPresence.busy);
      expect(page.nextCursor, 'next-page');
      final request = httpClient.requests.single;
      expect(request.url.path, '/api/inbox');
      expect(request.url.queryParameters, {'limit': '50', 'cursor': 'current'});
      expect(request.headers['authorization'], 'Bearer jwt-dev');
    },
  );

  test(
    'filters kinds client-side without adding a kinds query parameter',
    () async {
      final httpClient = FakeHttpClient()..respond(200, body: _inboxBody);
      final adapter = NetworkInboxHttpAdapter(
        sessionManager: await _manager(httpClient, jwt: 'jwt-dev'),
      );

      final page = await adapter.fetchInbox(
        kinds: const {ChatListEntryKind.networkChannel},
      );

      expect(page.items.single.id, 'c1');
      expect(page.nextCursor, 'next-page');
      expect(httpClient.requests.single.url.query, isEmpty);
      expect(
        httpClient.requests.single.url.queryParameters.containsKey('kinds'),
        isFalse,
      );
    },
  );

  test(
    'markChannelRead awaits an account client and uses its fresh JWT',
    () async {
      final httpClient = FakeHttpClient()..respond(204);
      final adapter = NetworkInboxHttpAdapter(
        sessionManager: await _manager(httpClient, jwt: 'jwt-dev'),
      );

      await adapter.markChannelRead('c/1', envelopeId: 'env1');

      final request = httpClient.requests.single;
      expect(request.method, 'PATCH');
      expect(request.url.toString(), '$testBase/api/channels/c%2F1/read');
      expect(request.headers['authorization'], 'Bearer jwt-dev');
      expect(jsonDecode(request.body), {'envelopeId': 'env1'});
    },
  );

  test('signed-out fetch and read-mark throw the documented seam without '
      'anonymous HTTP or fabricated data', () async {
    final httpClient = FakeHttpClient();
    final adapter = NetworkInboxHttpAdapter(
      sessionManager: await _manager(httpClient),
    );

    await expectLater(
      adapter.fetchInbox(),
      throwsA(isA<NetworkInboxUnavailableException>()),
    );
    await expectLater(
      adapter.markChannelRead('c1', all: true),
      throwsA(isA<NetworkInboxUnavailableException>()),
    );
    expect(httpClient.requests, isEmpty);
  });
}
