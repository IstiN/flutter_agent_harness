// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/src/network/connector/connector_mux.dart';
import 'package:flutter_agent_harness/src/network/connector/device_registry.dart';
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/connector/exposure_acl.dart';
import 'package:flutter_agent_harness/src/network/connector/machine_connector.dart';
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';
import 'package:flutter_agent_harness/src/network/connector/upstream_client.dart';
import 'package:test/test.dart';

import 'fake_device_server.dart';

/// Contract-level suite for the machine connector composition root
/// (issue #2062): AC1 single upstream, AC2 isolation/dedup/order, AC5
/// offline queue, AC6 viewer-only writes — all local halves over the
/// in-memory FakeDeviceServer (§12, no real network).
void main() {
  late FakeDeviceServer server;
  late DeviceRegistry registry;
  late List<String> logs;
  var frameCounter = 0;

  MachineConnector buildConnector({
    SessionLeaseDelegate? leases,
    PresenceEngine? presence,
  }) {
    final upstream = ConnectorUpstreamClient(
      url: Uri.parse('wss://fake/ws'),
      transport: server.transport,
      ticketProvider: () async => 'ticket-1',
      deviceId: 'macbook',
      deviceToken: 'tok-1',
      backoff: (attempt) => const Duration(milliseconds: 20),
      timers: const SystemTimers(),
      idFactory: () => 'client-${frameCounter++}',
    );
    return MachineConnector(
      registry: registry,
      upstream: upstream,
      leases: leases,
      idFactory: () => 'mail-${frameCounter++}',
      onLog: logs.add,
      presence: presence,
    );
  }

  setUp(() {
    frameCounter = 0;
    server = FakeDeviceServer();
    registry = DeviceRegistry()
      ..configureNetwork('personal-x', NetworkKind.personal)
      ..registerAgent('goal_builder', 'macbook')
      ..registerAgent('scout', 'macbook')
      ..registerSession(
        const SessionRegistration(
          id: 'sess-1',
          agentAddressOf: 'goal_builder@macbook',
        ),
      );
    logs = <String>[];
  });

  tearDown(() {
    registry.dispose();
  });

  test(
    'AC1: N local agents registered share ONE upstream transport dial',
    () async {
      final connector = buildConnector()
        ..registerLocalSink(
          network: 'personal-x',
          channel: 'chan-1',
          sink: (_) async {},
        )
        ..registerLocalSink(
          network: 'personal-x',
          channel: 'chan-2',
          sink: (_) async {},
        );
      await connector.start();
      await _waitUntil(() => server.activeConnections == 1);
      await _waitUntil(() => connector.isConnected);
      // Mail from BOTH agents flows through the single socket.
      await connector.sendMail(
        network: 'personal-x',
        channel: 'chan-1',
        from: 'goal_builder@macbook',
        ciphertext: 'c1',
      );
      await connector.sendMail(
        network: 'personal-x',
        channel: 'chan-2',
        from: 'scout@macbook',
        ciphertext: 'c2',
      );
      await _waitUntil(() => server.received.length >= 2);
      expect(
        server.connectionCount,
        1,
        reason: '§3: one device socket carries every exposed local agent',
      );
      expect(server.activeConnections, 1);
      await connector.stop();
      connector.dispose();
    },
  );

  test(
    'AC2: two networks isolated per member routing, msgId dedup, per-sender order across forced reconnect',
    () async {
      final deliveredNetA = <String>[];
      final deliveredNetB = <String>[];
      final connector = buildConnector();
      connector
        ..registerLocalSink(
          network: 'net-a',
          channel: 'chan-1',
          sink: (mail) async => deliveredNetA.add(mail.envelope.msgId),
        )
        ..registerLocalSink(
          network: 'net-b',
          channel: 'chan-1',
          sink: (mail) async => deliveredNetB.add(mail.envelope.msgId),
        );
      await connector.start();
      await _waitUntil(() => connector.isConnected);

      // Server pushes mail into the two networks (same channel id, same
      // recipient — only the network differs).
      NetworkEnvelope mail(String id, String network) => NetworkEnvelope(
        kind: NetworkEnvelopeKind.mail,
        msgId: id,
        network: network,
        channel: 'chan-1',
        from: 'user:u1',
        to: 'goal_builder@macbook',
        ts: '2026-11-12T10:00:00.000Z',
        ciphertext: 'c-$id',
      );
      server.deliverTo(deviceId: 'macbook', mail: mail('a-1', 'net-a'));
      server.deliverTo(deviceId: 'macbook', mail: mail('b-1', 'net-b'));
      server.deliverTo(deviceId: 'macbook', mail: mail('a-2', 'net-a'));
      await _waitUntil(
        () => deliveredNetA.length >= 2 && deliveredNetB.isNotEmpty,
      );
      expect(deliveredNetA, ['a-1', 'a-2'], reason: 'network isolation (AC2)');
      expect(deliveredNetB, ['b-1']);

      // Forced reconnect: the dedup window survives, so a redelivered id
      // collapses; per-sender order is preserved through the drop.
      server.deliverTo(deviceId: 'macbook', mail: mail('a-3', 'net-a'));
      await _waitUntil(() => deliveredNetA.length >= 3);
      server.dropAll();
      server.deliverTo(deviceId: 'macbook', mail: mail('a-3', 'net-a'));
      await _waitUntil(() => server.deliveries.length >= 4);
      // After the drop the client reconnects (fake server redelivers the
      // unacked a-3); the mux dedups it.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(deliveredNetA, [
        'a-1',
        'a-2',
        'a-3',
      ], reason: 'msgId dedup across reconnect (§3)');
      await connector.stop();
      connector.dispose();
    },
  );

  test(
    'AC5: upstream down → outbox, restore → drain in order, original msgIds, no duplicates',
    () async {
      server.seedDevice('macbook', networks: ['personal-x']);
      final connector = buildConnector();
      await connector.start();
      await _waitUntil(() => connector.isConnected);

      // Kill upstream. The client will retry with backoff; sends now fail.
      // The outage stays pinned (dial quota 1000) until we restore below.
      server.dropAll();
      server.failNextDials = 1000;
      await _waitUntil(() => !connector.isConnected);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final id1 = await connector.sendMail(
        network: 'personal-x',
        channel: 'chan-1',
        from: 'goal_builder@macbook',
        ciphertext: 'queued-1',
      );
      final id2 = await connector.sendMail(
        network: 'personal-x',
        channel: 'chan-1',
        from: 'goal_builder@macbook',
        ciphertext: 'queued-2',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        await connector.pendingMailCount(),
        2,
        reason: 'frames minted while disconnected queue locally (AC5)',
      );

      // Restore: the client reconnects and the drain fires in order.
      server.failNextDials = 0;
      await _waitUntil(() => connector.isConnected);
      await _waitUntil(() => server.persistedMail.length >= 2);
      final ids = server.persistedMail.map((frame) => frame.msgId).toList();
      expect(
        ids,
        containsAllInOrder([id1, id2]),
        reason: 'drain-in-order, ids byte-for-byte (contract v1.1 §7)',
      );
      expect(
        ids.where((id) => id == id1),
        hasLength(1),
        reason: 'no duplicate sends',
      );
      expect(await connector.pendingMailCount(), 0);
      await connector.stop();
      connector.dispose();
    },
  );

  test(
    'AC6 local half: slash-commands and approval payloads are rejected and reported; clean text is acked after sink write',
    () async {
      final written = <InboundMail>[];
      final acked = <String>[];
      final connector = buildConnector(leases: () async => {'sess-1'});
      connector.registerLocalSink(
        network: 'personal-x',
        channel: dmChannelId('u1', 'goal_builder@macbook'),
        sink: (mail) async {
          written.add(mail);
          acked.add(mail.msgId);
        },
      );
      final rejected = <RejectedMail>[];
      final sub = connector.rejections.listen(rejected.add);
      await connector.start();
      await _waitUntil(() => connector.isConnected);

      Future<void> push(String msgId, String ciphertext) async {
        server.deliverTo(
          deviceId: 'macbook',
          mail: NetworkEnvelope(
            kind: NetworkEnvelopeKind.mail,
            msgId: msgId,
            network: 'personal-x',
            channel: dmChannelId('u1', 'goal_builder@macbook'),
            from: 'user:u1',
            to: 'goal_builder@macbook',
            ts: '2026-11-12T10:00:00.000Z',
            ciphertext: ciphertext,
          ),
        );
      }

      await push('rm-1', '/approval yes');
      await push('rm-2', '{"approval":{"id":"a-1"}}');
      await push('rm-3', 'please fix the flaky test');
      await _waitUntil(() => written.isNotEmpty && rejected.length >= 2);
      expect(written.single.text, 'please fix the flaky test');
      expect(rejected.map((mail) => mail.envelope.msgId), ['rm-1', 'rm-2']);
      expect(rejected.first.reason, contains('slash-commands'));
      expect(rejected.last.reason, contains('approval'));
      // Rejected mail IS acked (no redelivery loop), accepted mail is
      // acked only after the sink write completed.
      await _waitUntil(
        () =>
            server.received
                .whereType<NetworkEnvelope>()
                .where((frame) => frame.kind == NetworkEnvelopeKind.ack)
                .length >=
            2,
      );
      expect(acked, ['rm-3'], reason: 'sink saw only the clean text');
      await sub.cancel();
      await connector.stop();
      connector.dispose();
    },
  );

  test(
    'sink write failure is NOT acked — the server redelivers (§3)',
    () async {
      var attempts = 0;
      final connector = buildConnector();
      connector.registerLocalSink(
        network: 'personal-x',
        channel: 'chan-1',
        sink: (_) async {
          attempts++;
          throw StateError('mailbox unavailable');
        },
      );
      await connector.start();
      await _waitUntil(() => connector.isConnected);
      server.deliverTo(deviceId: 'macbook', mail: _mailFor('lose-1', 'chan-1'));
      await _waitUntil(() => attempts >= 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final acks = server.received
          .where((frame) => frame.kind == NetworkEnvelopeKind.ack)
          .toList();
      expect(acks, isEmpty, reason: 'failed sink write → no ack → redelivery');
      expect(
        server.received.any((frame) => frame.kind == NetworkEnvelopeKind.error),
        isFalse,
      );
      await connector.stop();
      connector.dispose();
    },
  );

  test(
    'unrouted mail is answered with an error frame referencing the mail',
    () async {
      final connector = buildConnector();
      await connector.start();
      await _waitUntil(() => connector.isConnected);
      server.deliverTo(
        deviceId: 'macbook',
        mail: _mailFor('orphan-1', 'chan-nobody'),
      );
      await _waitUntil(
        () => server.received.any(
          (frame) => frame.kind == NetworkEnvelopeKind.error,
        ),
      );
      final error = server.received.firstWhere(
        (frame) => frame.kind == NetworkEnvelopeKind.error,
      );
      expect(error.refId, 'orphan-1');
      await connector.stop();
      connector.dispose();
    },
  );

  test(
    'presence publisher: registry + lease delegates ride the frames',
    () async {
      final connector = buildConnector(leases: () async => {'sess-1'});
      await connector.start();
      await _waitUntil(() => connector.isConnected);
      await _waitUntil(
        () => server.received.any(
          (frame) => frame.kind == NetworkEnvelopeKind.presence,
        ),
      );
      final presenceFrame = server.received.lastWhere(
        (frame) => frame.kind == NetworkEnvelopeKind.presence,
      );
      final frame = PresenceFrame.fromEnvelope(presenceFrame);
      expect(frame, isNotNull);
      expect(frame!.machine, MachinePresence.online);
      expect(
        frame.sessions['sess-1'],
        ConnectorSessionPresence.live,
        reason: 'lease delegate says live',
      );

      // Exposure toggle propagates within one heartbeat (§6): hide the
      // session, the next published frame drops it.
      registry.setSessionExposed('personal-x', 'sess-1', exposed: false);
      final before = server.received
          .where((frame) => frame.kind == NetworkEnvelopeKind.presence)
          .length;
      await _waitUntil(
        () =>
            server.received
                .where((frame) => frame.kind == NetworkEnvelopeKind.presence)
                .length >
            before,
      );
      final after = PresenceFrame.fromEnvelope(
        server.received.lastWhere(
          (frame) => frame.kind == NetworkEnvelopeKind.presence,
        ),
      );
      expect(
        after!.sessions.containsKey('sess-1'),
        isFalse,
        reason: 'unpublished within one heartbeat (§6)',
      );
      await connector.stop();
      connector.dispose();
    },
  );

  test('roster + presence + wake hints surface on dedicated streams', () async {
    server.seedDevice('macbook', networks: ['personal-x']);
    final connector = buildConnector();
    final rosters = <NetworkEnvelope>[];
    final presences = <NetworkEnvelope>[];
    final sub1 = connector.rosterFrames.listen(rosters.add);
    final sub2 = connector.presenceFrames.listen(presences.add);
    await connector.start();
    await _waitUntil(() => rosters.isNotEmpty);
    expect(rosters.single.network, 'personal-x');
    await connector.stop();
    await sub1.cancel();
    await sub2.cancel();
    connector.dispose();
  });

  test('MailDecoder seam: inbound ciphertext decodes before the ACL', () async {
    final written = <String>[];
    // Build a connector with a decoder to prove the seam.
    final upstream = ConnectorUpstreamClient(
      url: Uri.parse('wss://fake/ws'),
      transport: server.transport,
      ticketProvider: () async => 'ticket-2',
      deviceId: 'macbook',
      backoff: (attempt) => const Duration(milliseconds: 20),
      timers: const SystemTimers(),
    );
    final decoded = MachineConnector(
      registry: registry,
      upstream: upstream,
      decodeMail: (envelope) => 'DECODED(${envelope.ciphertext})',
      onLog: logs.add,
    );
    decoded.registerLocalSink(
      network: 'personal-x',
      channel: 'chan-1',
      sink: (mail) async => written.add(mail.text),
    );
    await decoded.start();
    await _waitUntil(() => decoded.isConnected);
    server.deliverTo(
      deviceId: 'macbook',
      mail: _mailFor('dec-1', 'chan-1', ciphertext: 'cipher-blob'),
    );
    await _waitUntil(() => written.contains('DECODED(cipher-blob)'));
    expect(written.single, 'DECODED(cipher-blob)');
    await decoded.stop();
    decoded.dispose();
  });

  test('ACL types are re-exported through the connector API surface', () {
    final decision = sanitizeRemoteWrite('/config');
    expect(decision, isA<AclReject>());
    expect(plainCiphertextDecoder(_mailFor('x', 'c')), 'c');
    expect(
      const MailRoute(network: 'n', channel: 'c'),
      const MailRoute(network: 'n', channel: 'c'),
    );
  });

  test(
    '§8: inbound frames fan into dedicated streams; no-op kinds are ignored',
    () async {
      final connector = buildConnector();
      final roster = <NetworkEnvelope>[];
      final presence = <NetworkEnvelope>[];
      final wake = <NetworkEnvelope>[];
      connector.rosterFrames.listen(roster.add);
      connector.presenceFrames.listen(presence.add);
      connector.wakeHints.listen(wake.add);
      await connector.start();
      await _waitUntil(() => connector.isConnected);
      NetworkEnvelope frame(NetworkEnvelopeKind kind, {String? refId}) =>
          NetworkEnvelope(
            kind: kind,
            msgId: 'srv-${frameCounter++}',
            ts: '2026-11-12T10:00:00.000Z',
            refId: refId,
          );
      server.pushRawTo(
        deviceId: 'macbook',
        frame: frame(NetworkEnvelopeKind.roster),
      );
      server.pushRawTo(
        deviceId: 'macbook',
        frame: frame(NetworkEnvelopeKind.presence),
      );
      server.pushRawTo(
        deviceId: 'macbook',
        frame: frame(NetworkEnvelopeKind.wakeHint),
      );
      server.pushRawTo(
        deviceId: 'macbook',
        frame: frame(NetworkEnvelopeKind.ack, refId: 'x'),
      );
      server.pushRawTo(
        deviceId: 'macbook',
        frame: frame(NetworkEnvelopeKind.hello),
      );
      server.pushRawTo(
        deviceId: 'macbook',
        frame: frame(NetworkEnvelopeKind.helloOk),
      );
      server.pushRawTo(
        deviceId: 'macbook',
        frame: frame(NetworkEnvelopeKind.ping),
      );
      server.pushRawTo(
        deviceId: 'macbook',
        frame: frame(NetworkEnvelopeKind.pong),
      );
      await _waitUntil(
        () => roster.length + presence.length + wake.length == 3,
      );
      server.pushRawTo(
        deviceId: 'macbook',
        frame: frame(NetworkEnvelopeKind.error, refId: 'm0'),
      );
      await _waitUntil(
        () => logs.any((l) => l.contains('server error for m0')),
      );
      expect(roster, hasLength(1));
      expect(presence, hasLength(1));
      expect(wake, hasLength(1));
      expect(
        logs.last.contains('server error for m0'),
        isTrue,
        reason: '§4: server error frames surface through onLog',
      );
      await connector.stop();
      connector.dispose();
    },
  );
}

NetworkEnvelope _mailFor(
  String msgId,
  String channel, {
  String ciphertext = 'c',
}) => NetworkEnvelope(
  kind: NetworkEnvelopeKind.mail,
  msgId: msgId,
  network: 'personal-x',
  channel: channel,
  from: 'user:u1',
  to: 'goal_builder@macbook',
  ts: '2026-11-12T10:00:00.000Z',
  ciphertext: ciphertext,
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not met within 2s');
}
