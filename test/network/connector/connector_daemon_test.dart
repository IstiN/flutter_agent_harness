// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/messaging/hub_crypto.dart';
import 'package:flutter_agent_harness/src/network/network_account.dart';
import 'package:test/test.dart';

import 'fake_device_server.dart';

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

void main() {
  test(
    'ConnectorDaemonState validates JSON round-trip and rejects bad input',
    () {
      const state = ConnectorDaemonState(
        pid: 1234,
        port: 49210,
        token: 'tok-123',
        deviceId: 'dev-1',
        baseUrl: 'https://network.fa1.dev',
      );
      final parsed = ConnectorDaemonState.tryFromJson(state.toJson());
      expect(parsed, isNotNull);
      expect(parsed!.pid, 1234);
      expect(parsed.port, 49210);
      expect(parsed.token, 'tok-123');
      expect(parsed.deviceId, 'dev-1');
      expect(parsed.wsUri.toString(), 'ws://127.0.0.1:49210/ws');
      expect(parsed.healthzUri.toString(), 'http://127.0.0.1:49210/healthz');

      expect(ConnectorDaemonState.tryFromJson(null), isNull);
      expect(ConnectorDaemonState.tryFromJson({'pid': 0}), isNull);
      expect(
        ConnectorDaemonState.tryFromJson({
          'pid': 1,
          'port': 99999,
          'token': 't',
          'deviceId': 'd',
          'baseUrl': 'u',
        }),
        isNull,
      );
    },
  );

  test(
    'multiple local CLI clients share ONE upstream WS through ConnectorDaemonServer',
    () async {
      final server = FakeDeviceServer()
        ..seedDevice(
          'dev-mac-1',
          deviceToken: 'tok-device-1',
          networks: const ['net-personal'],
        );
      final tmp = await Directory.systemTemp.createTemp('fa_connector_test_');
      addTearDown(() async {
        server.dropAll();
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      const device = NetworkDeviceCredentials(
        deviceId: 'dev-mac-1',
        deviceToken: 'tok-device-1',
        personalNetworkId: 'net-personal',
      );
      final keyStore = MemoryDeviceDmKeyStore();
      final host = MultiSessionConnectorHost(
        device: device,
        baseUrl: 'https://network.fa1.dev',
        ticketProvider: () async => 'ticket-1',
        transport: server.transport,
        dmKeyStore: keyStore,
        rosterDebounce: const Duration(milliseconds: 20),
        catalogPollInterval: Duration.zero,
      );
      final stateFile = File('${tmp.path}/connector.json');
      final daemon = ConnectorDaemonServer(host: host, stateFile: stateFile);
      await daemon.start();
      addTearDown(daemon.stop);

      await _waitFor(() => host.phase == ConnectorLinkState.connected);
      expect(server.connectionCount, 1);

      // Probe healthz succeeds for matching deviceId, rejects mismatch.
      expect(
        await probeConnectorDaemon(daemon.state, expectedDeviceId: 'dev-mac-1'),
        isTrue,
      );
      expect(
        await probeConnectorDaemon(
          daemon.state,
          expectedDeviceId: 'other-device',
        ),
        isFalse,
      );

      // Attach TWO concurrent local CLI clients to the SAME daemon.
      final receivedA = <CliNetworkDm>[];
      final receivedB = <CliNetworkDm>[];
      final clientA = SharedConnectorPresenceClient(
        stateFile: stateFile,
        deviceId: 'dev-mac-1',
      );
      final clientB = SharedConnectorPresenceClient(
        stateFile: stateFile,
        deviceId: 'dev-mac-1',
      );
      addTearDown(clientA.stop);
      addTearDown(clientB.stop);

      await clientA.startSession(
        CliNetworkSession(
          sessionId: 'sess-alpha',
          mailboxPrefix: 'alpha',
          displayName: 'Alpha Session',
          cwd: '/tmp/alpha',
          dmSink: (dm) async => receivedA.add(dm),
        ),
      );
      await clientB.startSession(
        CliNetworkSession(
          sessionId: 'sess-beta',
          mailboxPrefix: 'beta',
          displayName: 'Beta Session',
          cwd: '/tmp/beta',
          dmSink: (dm) async => receivedB.add(dm),
        ),
      );

      // Still EXACTLY ONE upstream WebSocket connection!
      expect(server.connectionCount, 1);
      expect(host.activeSessionIds, containsAll(['sess-alpha', 'sess-beta']));

      // Flipping busy on clientA updates the shared presence engine without
      // opening a second upstream connection.
      clientA.setBusy(true);
      await _waitFor(
        () =>
            host.connector!.presence.snapshot().agents['alpha@dev-mac-1'] ==
            AgentRunState.busy,
      );
      expect(
        host.connector!.presence.snapshot().agents['beta@dev-mac-1'],
        AgentRunState.live,
      );

      // Inbound DM targeted at sess-beta routes ONLY to clientB, sends an
      // accepted receipt, and clientB's reply goes out over the same single WS.
      final userKey = await X25519().newKeyPair();
      final dmKeys = DeviceDmKeyProvider(keyStore);
      final betaKey = await dmKeys.loadExisting('beta@dev-mac-1');
      expect(betaKey, isNotNull);

      const channel = 'dm:user:u-1:beta@dev-mac-1';
      final ciphertext = await hubSealFanet1(
        senderDhKeyPair: userKey,
        recipientDhPubkey: await betaKey!.keyPair.extractPublicKey(),
        frameId: 'dm-in-1',
        aadTarget: channel,
        plaintext: wrapDeviceDmText(
          'hello beta',
          sessionId: 'sess-beta',
          threaded: true,
        ),
      );
      server.deliverTo(
        deviceId: 'dev-mac-1',
        mail: NetworkEnvelope(
          kind: NetworkEnvelopeKind.mail,
          msgId: 'dm-in-1',
          network: 'net-personal',
          channel: channel,
          from: 'user:u-1',
          to: 'beta@dev-mac-1',
          ts: '2026-11-24T12:00:00.000Z',
          ciphertext: ciphertext,
        ),
      );

      await _waitFor(() => receivedB.length == 1);
      expect(receivedA, isEmpty);
      expect(receivedB.single.mail.text, 'hello beta');

      // Wait for the accepted receipt to land on the upstream server.
      await _waitFor(
        () => server.received.any(
          (e) =>
              e.kind == NetworkEnvelopeKind.mail &&
              e.channel == channel &&
              e.from == 'beta@dev-mac-1',
        ),
      );

      // ClientB sends an agent reply through the shared daemon.
      final replyId = await clientB.sendNetworkDmReply(
        address: receivedB.single.replyAddress,
        text: 'hi from beta',
      );
      expect(replyId, isNotEmpty);
      await _waitFor(
        () => server.received.any(
          (e) => e.kind == NetworkEnvelopeKind.mail && e.msgId == replyId,
        ),
      );
      expect(server.connectionCount, 1);

      // Unregistering clientA leaves clientB live on the same upstream WS.
      await clientA.stop();
      await _waitFor(() => !host.activeSessionIds.contains('sess-alpha'));
      expect(host.activeSessionIds, ['sess-beta']);
      expect(server.connectionCount, 1);
    },
  );
}
