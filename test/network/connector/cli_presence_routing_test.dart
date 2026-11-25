// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Single upstream per machine (contract §3/§10) — the CLI routing seam:
/// every CLI network-presence construction site resolves its presence
/// source through [resolveCliNetworkPresence] (and roster reads through
/// [readRosterFromSharedConnector]): with the per-machine daemon alive for
/// THIS device a CLI process gets the loopback client and performs ZERO
/// upstream dials (the eviction storm of N direct sockets per device
/// cannot happen); without one, the direct controller remains the
/// fallback and works exactly as before.
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/cli/network_store.dart';
import 'package:flutter_agent_harness/src/network/network_account.dart';
import 'package:flutter_agent_harness/src/network/network_account_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'fake_device_server.dart';

const _device = NetworkDeviceCredentials(
  deviceId: 'dev-mac-1',
  deviceToken: 'tok-device-1',
  personalNetworkId: 'net-personal',
);

/// Builds the PRODUCTION fallback ([directCliNetworkPresence]) over the fake
/// upstream and counts how many direct controllers a routing decision made.
final class DirectProbe {
  DirectProbe(this.server);

  final FakeDeviceServer server;
  int built = 0;
  late NetworkPresenceController last;

  NetworkPresenceController build() {
    built++;
    return last = directCliNetworkPresence(
      device: _device,
      baseUrl: 'https://network.fa1.dev',
      // The REST client answers the ws-ticket mint and the roster PATCH.
      devices: DeviceEnrollmentClient(
        httpClient: MockClient(
          (request) async => http.Response(
            request.url.path.endsWith('/ws-ticket')
                ? '{"ticket":"ticket-cli"}'
                : '{"patched":"dev-mac-1"}',
            200,
          ),
        ),
      ),
      store: MemoryNetworkStore()..device = _device,
      transport: server.transport,
    );
  }
}

void main() {
  late FakeDeviceServer server;
  late Directory tmp;
  late File stateFile;

  setUp(() async {
    // The roster snapshot lists one sibling device, so every read path
    // has a non-empty `fa network devices` answer to prove it worked.
    server =
        FakeDeviceServer(
          rosterPayloadFor: (_) => {
            'devices': [
              {
                'deviceId': 'dev-peer',
                'name': 'Peer Mac',
                'presence': 'online',
              },
            ],
          },
        )..seedDevice(
          _device.deviceId,
          deviceToken: _device.deviceToken,
          networks: const ['net-personal'],
        );
    tmp = await Directory.systemTemp.createTemp('fa_cli_routing_test_');
    stateFile = File('${tmp.path}/connector.json');
  });

  tearDown(() async {
    server.dropAll();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// A daemon host over the fake upstream; [ticketProvider] lets a test
  /// keep the daemon's own link down (empty cached roster).
  MultiSessionConnectorHost daemonHost({
    Future<String> Function()? ticketProvider,
    String? deviceId,
  }) => MultiSessionConnectorHost(
    device: NetworkDeviceCredentials(
      deviceId: deviceId ?? _device.deviceId,
      deviceToken: _device.deviceToken,
      personalNetworkId: 'net-personal',
    ),
    baseUrl: 'https://network.fa1.dev',
    ticketProvider: ticketProvider ?? () async => 'ticket-1',
    transport: server.transport,
    rosterDebounce: Duration.zero,
    catalogPollInterval: Duration.zero,
  );

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }

  test(
    'with the daemon up for this device the CLI factory returns the '
    'loopback client and the CLI path performs zero upstream dials',
    () async {
      final host = daemonHost();
      final daemon = ConnectorDaemonServer(host: host, stateFile: stateFile);
      await daemon.start();
      addTearDown(daemon.stop);
      await waitFor(() => host.phase == ConnectorLinkState.connected);
      expect(server.connectionCount, 1, reason: 'only the daemon dials');

      final direct = DirectProbe(server);
      final presence = await resolveCliNetworkPresence(
        stateFile: stateFile,
        deviceId: _device.deviceId,
        ensureDaemonRunning: () async => daemon.state,
        directController: () => direct.build(),
      );
      expect(presence, isA<SharedConnectorPresenceClient>());
      expect(direct.built, 0);
      addTearDown(presence.stop);

      // An interactive CLI session (same path a mailbox-woken one takes).
      await presence.startSession(
        const CliNetworkSession(sessionId: 'sess-cli', mailboxPrefix: 'cli'),
      );
      await waitFor(() => host.activeSessionIds.contains('sess-cli'));
      presence.setBusy(true);
      // setBusy is an unawaited loopback RPC — give it a turn.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await waitFor(() => host.activeSessionIds.contains('sess-cli'));
      expect(
        server.connectionCount,
        1,
        reason: 'the CLI session must not open its own upstream WS',
      );

      // The roster read (`fa network list`, hub plugin) rides the cache.
      final rows = await readRosterFromSharedConnector(
        stateFile: stateFile,
        deviceId: _device.deviceId,
        directController: () => direct.build(),
      );
      expect(rows.single.deviceId, 'dev-peer');
      expect(direct.built, 0, reason: 'no direct controller anywhere');
      expect(server.connectionCount, 1);
    },
  );

  test(
    'a daemon alive for ANOTHER device is not used: the state file + '
    'probe guarantee is per deviceId, the direct fallback dials once',
    () async {
      final host = daemonHost(deviceId: 'dev-other');
      final daemon = ConnectorDaemonServer(host: host, stateFile: stateFile);
      await daemon.start();
      addTearDown(daemon.stop);
      await waitFor(() => host.phase == ConnectorLinkState.connected);
      expect(server.connectionCount, 1);

      final direct = DirectProbe(server);
      final presence = await resolveCliNetworkPresence(
        stateFile: stateFile,
        deviceId: _device.deviceId,
        ensureDaemonRunning: () async {
          final state = await readConnectorDaemonState(stateFile);
          return state != null &&
                  await probeConnectorDaemon(
                    state,
                    expectedDeviceId: _device.deviceId,
                  )
              ? state
              : null;
        },
        directController: () => direct.build(),
      );
      expect(presence, isA<NetworkPresenceController>());
      await presence.startSession(
        const CliNetworkSession(sessionId: 'sess-cli', mailboxPrefix: 'cli'),
      );
      await waitFor(() => server.connectionCount == 2);
      expect(direct.built, 1);
      await presence.stop();

      final rows = await readRosterFromSharedConnector(
        stateFile: stateFile,
        deviceId: _device.deviceId,
        directController: () => direct.build(),
      );
      expect(rows.single.deviceId, 'dev-peer');
      expect(direct.built, 2);
      expect(server.connectionCount, 3);
    },
  );

  test('without the daemon the fallback works: the direct controller dials '
      'once, the roster read connects, collects and disposes', () async {
    expect(await readConnectorDaemonState(stateFile), isNull);
    final direct = DirectProbe(server);
    final presence = await resolveCliNetworkPresence(
      stateFile: stateFile,
      deviceId: _device.deviceId,
      ensureDaemonRunning: () async => null,
      directController: () => direct.build(),
    );
    expect(presence, isA<NetworkPresenceController>());
    await presence.startSession(
      const CliNetworkSession(sessionId: 'sess-cli', mailboxPrefix: 'cli'),
    );
    await waitFor(() => server.connectionCount == 1);
    await waitFor(() => direct.last.phase == ConnectorLinkState.connected);
    await presence.stop();

    final rows = await readRosterFromSharedConnector(
      stateFile: stateFile,
      deviceId: _device.deviceId,
      directController: () => direct.build(),
    );
    expect(rows, isNotEmpty);
    expect(direct.built, 2);
    expect(server.connectionCount, 2);
    expect(
      direct.last.phase,
      ConnectorLinkState.disconnected,
      reason: 'the one-shot read disposes its controller',
    );
  });

  test('not enrolled: readCliNetworkRoster raises the enroll hint without '
      'touching the daemon state or dialing', () async {
    await expectLater(
      readCliNetworkRoster(
        store: MemoryNetworkStore(),
        devices: DeviceEnrollmentClient(
          httpClient: MockClient((_) async {
            fail('no REST call may happen before enrollment');
          }),
        ),
        baseUrl: 'https://network.fa1.dev',
        stateFile: stateFile,
      ),
      throwsA(isA<NetworkAuthException>()),
    );
    expect(server.connectionCount, 0);
  });

  test(
    'daemon up but its cached roster is empty (link down): the roster '
    'read falls back to a direct controller instead of returning nothing',
    () async {
      final host = daemonHost(
        ticketProvider: () async => throw StateError('no ticket'),
      );
      final daemon = ConnectorDaemonServer(host: host, stateFile: stateFile);
      await daemon.start();
      addTearDown(daemon.stop);
      expect(await probeConnectorDaemon(daemon.state), isTrue);
      expect(server.connectionCount, 0);

      final direct = DirectProbe(server);
      final rows = await readRosterFromSharedConnector(
        stateFile: stateFile,
        deviceId: _device.deviceId,
        directController: () => direct.build(),
      );
      expect(rows.single.deviceId, 'dev-peer');
      expect(direct.built, 1);
      expect(server.connectionCount, 1);
    },
  );
}
