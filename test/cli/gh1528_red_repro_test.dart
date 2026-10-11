// TEMPORARY gh-1528 RED artifact — exact copy of the pre-fix racy test.
// Deleted after the A/B run; not part of the suite.
@Tags(['io'])
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cli/chatgpt_oauth_server.dart';
import 'package:test/test.dart';

void main() {
  test('RED repro: old binds/falls-back test under theft', () async {
    Future<int> freePort() async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      return port;
    }

    final first = await freePort();
    final second = await freePort();

    final firstServer = ChatGptOAuthLocalCallbackServer();
    var url = await firstServer.start(
      timeout: const Duration(seconds: 5),
      ports: [first, second],
    );
    expect(Uri.parse(url).port, first);
    await firstServer.close();

    final occupant = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      first,
    );
    final secondServer = ChatGptOAuthLocalCallbackServer();
    url = await secondServer.start(
      timeout: const Duration(seconds: 5),
      ports: [first, second],
    );
    expect(Uri.parse(url).port, second);
    await secondServer.close();
    await occupant.close();
  });
}
