// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/showcase_viewer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  group('showcase client', () {
    test('getShowcase parses the listing; 404 → null (no oracle)', () async {
      final httpClient = FakeHttpClient()
        ..respond(
          200,
          body:
              '{"id":"net9","name":"Agents Live","channels":'
              '[{"id":"c1","name":"lobby"},{"id":"c2","name":"builds"}]}',
        )
        ..respond(404, body: '{"error":{"code":"not_found","message":"nf"}}');
      final client = FaNetworkClient(baseUrl: testBase, httpClient: httpClient);

      final showcase = await client.getShowcase('net9');
      expect(showcase!.id, 'net9');
      expect(showcase.name, 'Agents Live');
      expect(showcase.channels.map((c) => c.name), ['lobby', 'builds']);
      expect(showcase.channels.every((c) => c.isPublic), isTrue);

      expect(await client.getShowcase('nope'), isNull);
      // Anonymous: no bearer on either call.
      expect(
        httpClient.requests.every((r) => r.headers['authorization'] == null),
        isTrue,
      );
    });

    test('anonymous listMessages sends no bearer', () async {
      final httpClient = FakeHttpClient()
        ..respond(200, body: '{"items":[],"nextCursor":""}');
      final client = FaNetworkClient(
        baseUrl: testBase,
        httpClient: httpClient,
        sessionToken: 'st-1',
        jwtToken: 'jwt-1',
      );
      await client.listMessages('c1', anonymous: true);
      expect(httpClient.requests.single.headers['authorization'], isNull);
    });
  });

  group('public channel payload codec', () {
    test('app convention: base64(json {text}) round-trips', () {
      final encoded = encodePublicChannelText('hello visitors');
      expect(decodePublicChannelPayload(encoded), 'hello visitors');
    });

    test('foreign raw utf8 payload decodes as plain text', () {
      final encoded = base64Encode(utf8.encode('hello-visitor'));
      expect(decodePublicChannelPayload(encoded), 'hello-visitor');
    });

    test('garbage → null (placeholder upstream, never a crash)', () {
      expect(decodePublicChannelPayload('!!not-base64!!'), isNull);
    });
  });

  group('ShowcaseViewer', () {
    test('load + paged messages, dedupe by envelope id', () async {
      final payload = encodePublicChannelText('agent A: hello');
      final httpClient = FakeHttpClient()
        ..respond(
          200,
          body:
              '{"id":"net9","name":"Agents Live","channels":'
              '[{"id":"c1","name":"lobby"}]}',
        )
        ..respond(
          200,
          body: jsonEncode({
            'items': [
              {
                'id': 'm1',
                'channelId': 'c1',
                'senderId': 'bot-1',
                'payload': payload,
              },
              {
                'id': 'm2',
                'channelId': 'c1',
                'senderId': 'bot-2',
                'payload': payload,
              },
            ],
            'nextCursor': '',
          }),
        )
        // A duplicate replay of m1 is dropped by id.
        ..respond(
          200,
          body: jsonEncode({
            'items': [
              {
                'id': 'm1',
                'channelId': 'c1',
                'senderId': 'bot-1',
                'payload': payload,
              },
            ],
            'nextCursor': '',
          }),
        );
      final viewer = ShowcaseViewer(
        networkId: 'net9',
        client: FaNetworkClient(baseUrl: testBase, httpClient: httpClient),
      );

      await viewer.load();
      expect(viewer.showcase!.channels.single.name, 'lobby');

      await viewer.loadMessages('c1');
      expect(viewer.messages['c1'], hasLength(2));
      expect(viewer.messages['c1']!.first.id, 'm1'); // oldest-first
      expect(viewer.messages['c1']!.first.text, 'agent A: hello');
      expect(viewer.hasMore('c1'), isFalse);

      await viewer.loadMessages('c1');
      expect(viewer.messages['c1'], hasLength(2)); // deduped
    });
  });

  group('showcase mode transitions', () {
    test('viewShowcase sets the preview; backToNetworks clears it; '
        'enterNetwork clears it', () async {
      final controller = NetworkModeController.inMemory(mode: AppMode.network);
      await controller.viewShowcase('net9');
      expect(controller.showcaseNetworkId, 'net9');
      expect(controller.networkId, isNull);
      expect(controller.mode, AppMode.network);

      await controller.viewShowcase('net9');
      await controller.backToNetworks();
      expect(controller.showcaseNetworkId, isNull);

      await controller.viewShowcase('net9');
      await controller.enterNetwork('net1');
      expect(controller.showcaseNetworkId, isNull);
      expect(controller.networkId, 'net1');
    });
  });
}
