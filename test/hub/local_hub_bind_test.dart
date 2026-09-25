/// Hub bind hygiene REG tests (gh-936): on the 2026-09-24/25 night two
/// overlapping CI runs raced the same loopback ports and four PTY legs
/// went red — "hub: cannot bind 127.0.0.1:… (Shared flag to bind() needs
/// to be true if binding multiple times)" twice per run.
///
/// The contract under test:
/// 1. two hubs on the SAME port coexist (shared bind) instead of
///    hard-failing — overlapping runs degrade calmly;
/// 2. a port held by a DYING non-shared process is ridden out by the
///    bind retry and the start succeeds;
/// 3. a port held by a LIVE non-shared process exhausts the retry and
///    surfaces a SocketException (an honest named failure, bounded).
@TestOn('vm')
@Tags(['io', 'integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/io.dart' show LocalHub;
import 'package:test/test.dart';

import 'test_ports.dart';

void main() {
  test('two hubs on the same port both start (shared bind, gh-936)',
      () async {
    final port = claimTestPort();
    final first = LocalHub(port: port);
    await first.start();
    addTearDown(first.stop);
    expect(await _healthz(port), isTrue, reason: 'the first hub answers');

    // The old bind (shared: false) threw
    // "Shared flag to bind() needs to be true if binding multiple times"
    // here — the exact red-leg signature. The shared bind coexists.
    final second = LocalHub(port: port);
    await second.start();
    addTearDown(second.stop);
    expect(await _healthz(port), isTrue,
        reason: 'the port keeps answering with both hubs bound');
  });

  test('bind onto a port released mid-retry succeeds (retry rides out a '
      'dying holder)', () async {
    final port = claimTestPort();
    // A non-shared holder: the shared bind cannot coexist with it, so
    // every attempt fails until it goes away.
    final blocker = await ServerSocket.bind('127.0.0.1', port);
    final sub = blocker.listen((socket) => socket.destroy());
    addTearDown(() async {
      await sub.cancel();
      await blocker.close();
    });

    final hub = LocalHub(port: port);
    final start = hub.start();
    // Release while the hub is inside its retry backoff.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    await blocker.close();
    await start.timeout(const Duration(seconds: 10));
    addTearDown(hub.stop);
    expect(await _healthz(port), isTrue, reason: 'the retry won the port');
  });

  test('bind onto a persistently held port exhausts the retry and throws '
      'SocketException', () async {
    final port = claimTestPort();
    final blocker = await ServerSocket.bind('127.0.0.1', port);
    final sub = blocker.listen((socket) => socket.destroy());
    addTearDown(() async {
      await sub.cancel();
      await blocker.close();
    });

    final hub = LocalHub(
      port: port,
      bindMaxAttempts: 2,
      bindBackoff: const Duration(milliseconds: 1),
    );
    await expectLater(hub.start(), throwsA(isA<SocketException>()));
  });
}

/// `/healthz` probe against the hub on [port].
Future<bool> _healthz(int port) async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    final response = await (await client.get('127.0.0.1', port, '/healthz'))
        .close();
    await response.drain<void>();
    client.close();
    return response.statusCode == 200;
  } on Object {
    return false;
  }
}
