// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-2410: the daemon host's periodic session-catalog pass is single-flight
// and gated on the upstream link. Ticks are fired by hand through the
// host's timer seam; the store parks loads to stretch a pass past its
// interval — exactly the production overlap that burned CPU on large
// stores.

import 'package:flutter_agent_harness/src/network/connector/multi_session_connector_host.dart';
import 'package:flutter_agent_harness/src/network/connector/upstream_client.dart';
import 'package:flutter_agent_harness/src/network/network_account.dart';
import 'package:test/test.dart';

import 'fake_catalog_poll.dart';
import 'fake_device_server.dart';

const _device = NetworkDeviceCredentials(
  deviceId: 'dev-mac-1',
  deviceToken: 'tok-device-1',
  personalNetworkId: 'net-personal',
);

MultiSessionConnectorHost _build({
  required FakeDeviceServer server,
  required GatedCatalogStore store,
  required FakeTimers timers,
}) => MultiSessionConnectorHost(
  device: _device,
  baseUrl: 'https://network.fa1.dev',
  ticketProvider: () async => 'ticket-1',
  transport: server.transport,
  catalogStore: store,
  catalogPollTimerFactory: timers.call,
  rosterDebounce: const Duration(milliseconds: 10),
);

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

void main() {
  test('a tick landing during a running refresh starts no second load; the '
      'piled-up ticks re-run once; the schedule is one 30 s timer', () async {
    final server = FakeDeviceServer()
      ..seedDevice(_device.deviceId, networks: const ['net-personal']);
    final store = GatedCatalogStore();
    final timers = FakeTimers();
    final host = _build(server: server, store: store, timers: timers);
    addTearDown(host.dispose);

    await host.start();
    await _waitFor(() => host.phase == ConnectorLinkState.connected);
    expect(timers.created, hasLength(1));
    expect(timers.live.interval, const Duration(seconds: 30));
    expect(store.loads, 1, reason: 'the initial full refresh at start');

    // The pass outlasts its interval: ticks pile up while it runs.
    store.gate = true;
    timers.fire();
    await pumpEventQueue();
    expect(store.loads, 2);
    timers.fire(3);
    await pumpEventQueue();
    expect(store.loads, 2, reason: 'no overlapping loadSessions');

    store.gate = false;
    await store.release();
    expect(store.loads, 3, reason: 'the coalesced ticks re-run once');

    timers.fire();
    await pumpEventQueue();
    expect(store.loads, 4, reason: 'the cadence resumes');
  });

  test('ticks while the link is down never load the store; reconnect refreshes '
      'exactly once', () async {
    final server = FakeDeviceServer()
      ..seedDevice(_device.deviceId, networks: const ['net-personal']);
    final store = GatedCatalogStore();
    final timers = FakeTimers();
    final host = _build(server: server, store: store, timers: timers);
    addTearDown(host.dispose);

    await host.start();
    expect(store.loads, 1, reason: 'the initial full refresh at start');
    // Still dialing: ticks are no-ops.
    timers.fire(2);
    await pumpEventQueue();
    expect(store.loads, 1);

    await _waitFor(() => host.phase == ConnectorLinkState.connected);
    await pumpEventQueue();
    expect(store.loads, 1, reason: 'a clean first connect needs no refresh');
    timers.fire();
    await pumpEventQueue();
    expect(store.loads, 2);

    server.dropAll();
    await _waitFor(() => host.phase != ConnectorLinkState.connected);
    timers.fire(2);
    await pumpEventQueue();
    expect(store.loads, 2, reason: 'disconnected ticks are no-ops');

    await _waitFor(() => host.phase == ConnectorLinkState.connected);
    await pumpEventQueue();
    expect(store.loads, 3, reason: 'one refresh on reconnect');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(store.loads, 3);
  });
}
