// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Two-client eviction simulation against the fake device server's
/// one-socket-per-device rule (contract §10 / production incident): two
/// upstream clients for ONE `deviceId` ping-pong — every dial evicts the
/// other socket — and the reconnect loop must DECAY instead of dialing
/// ~once per second per client. Everything runs on a virtual clock.
library;

import 'package:flutter_agent_harness/src/network/connector/upstream_client.dart';
import 'package:test/test.dart';

import 'fake_connector_time.dart';
import 'fake_device_server.dart';

/// Runs the two-client ping-pong for [minutes] and returns the dial count
/// per minute.
Future<List<int>> simulateEvictionStorm({
  required Duration stableWindow,
  double Function()? jitter,
  int minutes = 6,
}) async {
  final clock = FakeConnectorClock();
  final timers = FakeConnectorTimers(clock);
  final server = FakeDeviceServer()..seedDevice('dev-mac-1');
  ConnectorUpstreamClient build(String name) => ConnectorUpstreamClient(
    url: Uri.parse('wss://network.fa1.dev/ws'),
    transport: server.transport,
    ticketProvider: () async => 'ticket-$name',
    deviceId: 'dev-mac-1',
    deviceToken: 'tok-1',
    stableWindow: stableWindow,
    jitterFraction: jitter,
    clock: clock,
    timers: timers,
  );
  final first = build('a');
  final second = build('b');
  addTearDown(() async {
    await first.stop();
    await second.stop();
    first.dispose();
    second.dispose();
  });
  await first.start();
  await settleAsync();
  await second.start(); // displaces the first socket
  await settleAsync();

  final perMinute = <int>[];
  for (var minute = 0; minute < minutes; minute++) {
    final before = server.connectionCount;
    await timers.elapse(const Duration(minutes: 1));
    perMinute.add(server.connectionCount - before);
  }
  return perMinute;
}

void main() {
  test('two clients on one device: dial rate decays (eviction ping-pong → '
      'trickle) instead of ~1 dial/s per client', () async {
    final perMinute = await simulateEvictionStorm(
      stableWindow: upstreamStableWindow,
      jitter: () => 0.5,
    );
    // ignore: avoid_print
    print('eviction simulation dials/minute (hardened): $perMinute');
    final total = perMinute.fold(0, (sum, count) => sum + count);
    expect(
      perMinute.first,
      lessThanOrEqualTo(14),
      reason: 'minute 1 carries the ladder climb 0.75 s → 22.5 s',
    );
    expect(
      perMinute[2],
      lessThanOrEqualTo(4),
      reason: 'by minute 3 both clients sit at the capped step',
    );
    expect(perMinute.last, lessThanOrEqualTo(2));
    expect(total, lessThan(30));
  });

  test('control: with the counter reset on every welcome (pre-fix behaviour) '
      'the same ping-pong is a storm', () async {
    final perMinute = await simulateEvictionStorm(
      stableWindow: Duration.zero,
      jitter: () => 0.5,
      minutes: 2,
    );
    // ignore: avoid_print
    print(
      'eviction simulation dials/minute (control, no stable window): '
      '$perMinute',
    );
    // ~0.75 s per reconnect per client ⇒ ~80 dials each of the minutes.
    expect(perMinute.first, greaterThanOrEqualTo(60));
    expect(perMinute.last, greaterThanOrEqualTo(60));
  });
}
