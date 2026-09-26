// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Regression for the silent-auth bug behind the 401 loop (issue #955):
/// the platform WS connector must actually carry the `Authorization`
/// header into the handshake — the generic `WebSocketChannel.connect`
/// API drops it. Verified against a real loopback upgrade.
library;

import 'dart:io';

import 'package:fa/network/fa_network_ws.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('platform connector carries the Authorization header', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    String? capturedAuth;
    final upgraded = Future.sync(() async {
      final request = await server.first;
      capturedAuth = request.headers.value('authorization');
      final socket = await WebSocketTransformer.upgrade(request);
      await socket.close();
    });
    addTearDown(() => server.close(force: true));

    final connector = const WebSocketChannelConnector();
    final channel = await connector.connect(
      Uri.parse('ws://127.0.0.1:${server.port}/ws'),
      {'Authorization': 'Bearer st-1'},
    );
    await channel.sink.close();
    await upgraded;

    expect(capturedAuth, 'Bearer st-1');
  });

  test('handshake failure (401) surfaces as a catchable error', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final answered = Future.sync(() async {
      final request = await server.first;
      request.response.statusCode = 401;
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final connector = const WebSocketChannelConnector();
    await expectLater(
      connector.connect(
        Uri.parse('ws://127.0.0.1:${server.port}/ws'),
        const {},
      ),
      throwsA(isA<Object>()),
    );
    await answered;
  });
}
