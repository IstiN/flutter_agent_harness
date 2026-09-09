/// `LocalHub` (the production hub behind `fa hub serve`): fixed-port
/// binding, `/healthz`, and the hello handshake on the bound port.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  group('LocalHub', () {
    test('binds the requested fixed port and answers /healthz', () async {
      final hub = LocalHub(port: 0);
      await hub.start();
      final freePort = hub.url.port;
      await hub.stop();

      final fixed = LocalHub(port: freePort);
      await fixed.start();
      addTearDown(fixed.stop);
      expect(fixed.url.port, freePort);

      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.get('127.0.0.1', freePort, '/healthz');
      final response = await request.close();
      expect(response.statusCode, 200);
      await response.drain<void>();
    });

    test('binding a taken port throws (the serve command probes first)',
        () async {
      final first = LocalHub(port: 0);
      await first.start();
      addTearDown(first.stop);
      final second = LocalHub(port: first.url.port);
      await expectLater(second.start(), throwsA(isA<SocketException>()));
    });
  });
}
