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
    MailDecoder? decodeMail,
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
      decodeMail: decodeMail ?? plainCiphertextDecoder,
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
      final wire = presenceFrame.toJson();
      expect(wire.containsKey('payload'), isFalse);
      expect(wire['machine'], 'online');
      expect(wire['sessions'], [
        {'id': 'sess-1', 'state': 'live'},
      ]);

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

  test(
    'DecodedMail metadata crosses the ACL; dmMail observes after sink and before ack',
    () async {
      final sinkEntered = Completer<void>();
      final releaseSink = Completer<void>();
      final written = <InboundMail>[];
      final observed = <InboundMail>[];
      final connector = buildConnector(
        decodeMail: (envelope) => DecodedMail(
          payload: envelope.ciphertext ?? '',
          sessionId: 'session-1',
          senderPubkey: 'c2VuZGVyLXB1Yg==',
          threaded: true,
        ),
      );
      connector.registerLocalSink(
        network: 'personal-x',
        channel: 'chan-1',
        sink: (mail) async {
          written.add(mail);
          sinkEntered.complete();
          await releaseSink.future;
        },
      );
      final sub = connector.dmMail.listen(observed.add);
      await connector.start();
      await _waitUntil(() => connector.isConnected);
      server.deliverTo(
        deviceId: 'macbook',
        mail: _mailFor(
          'metadata-1',
          'chan-1',
          ciphertext: '{"text":"clean steering","sessionId":"session-1"}',
        ),
      );
      await sinkEntered.future;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(observed, isEmpty, reason: 'sink has not completed');
      expect(
        server.received.where((frame) => frame.kind == NetworkEnvelopeKind.ack),
        isEmpty,
        reason: 'ack cannot precede the mailbox write',
      );

      releaseSink.complete();
      await _waitUntil(
        () =>
            observed.isNotEmpty &&
            server.received.any(
              (frame) =>
                  frame.kind == NetworkEnvelopeKind.ack &&
                  frame.refId == 'metadata-1',
            ),
      );
      expect(written.single.text, 'clean steering');
      expect(observed.single.text, 'clean steering');
      expect(observed.single.sessionId, 'session-1');
      expect(observed.single.senderPubkey, 'c2VuZGVyLXB1Yg==');
      expect(observed.single.threaded, isTrue);
      await sub.cancel();
      await connector.stop();
      connector.dispose();
    },
  );

  test(
    'permanent MailDecodeException is rejected and acked without a loop',
    () async {
      final rejected = <RejectedMail>[];
      final connector = buildConnector(
        decodeMail: (_) =>
            throw const MailDecodeException('fanet1 authentication failed'),
      );
      connector.registerLocalSink(
        network: 'personal-x',
        channel: 'chan-1',
        sink: (_) async => fail('undecryptable mail reached the sink'),
      );
      final sub = connector.rejections.listen(rejected.add);
      await connector.start();
      await _waitUntil(() => connector.isConnected);
      server.deliverTo(
        deviceId: 'macbook',
        mail: _mailFor(
          'permanent-1',
          'chan-1',
          ciphertext: 'ciphertext-secret',
        ),
      );
      await _waitUntil(
        () =>
            rejected.isNotEmpty &&
            server.received.any(
              (frame) =>
                  frame.kind == NetworkEnvelopeKind.ack &&
                  frame.refId == 'permanent-1',
            ),
      );
      expect(rejected.single.reason, 'fanet1 authentication failed');
      expect(logs.join('\n'), isNot(contains('ciphertext-secret')));
      server.dropAll();
      await _waitUntil(() => connector.isConnected);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        server.deliveries.where((delivery) => delivery.msgId == 'permanent-1'),
        hasLength(1),
        reason: 'acked permanent failures never redeliver',
      );
      await sub.cancel();
      await connector.stop();
      connector.dispose();
    },
  );

  test(
    'transient decoder failure stays unacked and is not a rejection',
    () async {
      final rejected = <RejectedMail>[];
      final connector = buildConnector(
        decodeMail: (_) =>
            throw StateError('secure store temporarily unavailable'),
      );
      connector.registerLocalSink(
        network: 'personal-x',
        channel: 'chan-1',
        sink: (_) async => fail('transient decode failure reached the sink'),
      );
      final sub = connector.rejections.listen(rejected.add);
      await connector.start();
      await _waitUntil(() => connector.isConnected);
      server.deliverTo(
        deviceId: 'macbook',
        mail: _mailFor('transient-1', 'chan-1'),
      );
      await _waitUntil(
        () => logs.any((line) => line.contains('mail decode failed')),
      );
      expect(rejected, isEmpty);
      expect(
        server.received.where((frame) => frame.kind == NetworkEnvelopeKind.ack),
        isEmpty,
      );
      await sub.cancel();
      await connector.stop();
      connector.dispose();
    },
  );

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
      decodeMail: (envelope) =>
          DecodedMail(payload: 'DECODED(${envelope.ciphertext})'),
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
    expect(plainCiphertextDecoder(_mailFor('x', 'c')).payload, 'c');
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

  test(
    'sealed send encrypts with the exact minted msgId before queueing',
    () async {
      server.seedDevice('macbook', networks: ['personal-x']);
      final connector = buildConnector();
      await connector.start();
      await _waitUntil(() => connector.isConnected);

      final id = await connector.sendMail(
        network: 'personal-x',
        channel: 'dm:user:u1:goal_builder@macbook',
        from: 'goal_builder@macbook',
        to: 'user:u1',
        ciphertextFor: (frameId) async => 'sealed-$frameId',
      );

      await _waitUntil(() => server.persistedMail.isNotEmpty);
      final sent = server.persistedMail.single;
      expect(sent.msgId, id);
      expect(sent.ciphertext, 'sealed-$id');
      await connector.stop();
      connector.dispose();
    },
  );

  test('async MailDecoder resolves before ACL and sink delivery', () async {
    final written = <String>[];
    final upstream = ConnectorUpstreamClient(
      url: Uri.parse('wss://fake/ws'),
      transport: server.transport,
      ticketProvider: () async => 'ticket-2',
      deviceId: 'macbook',
      deviceToken: 'tok-1',
      backoff: (attempt) => const Duration(milliseconds: 20),
      timers: const SystemTimers(),
    );
    final decoded =
        MachineConnector(
          registry: registry,
          upstream: upstream,
          decodeMail: (envelope) async {
            await Future<void>.delayed(Duration.zero);
            return DecodedMail(payload: 'DECODED(${envelope.ciphertext})');
          },
          onLog: logs.add,
        )..registerLocalSink(
          network: 'personal-x',
          channel: 'chan-1',
          sink: (mail) async => written.add(mail.text),
        );
    await decoded.start();
    await _waitUntil(() => decoded.isConnected);
    server.deliverTo(
      deviceId: 'macbook',
      mail: _mailFor('async-dec-1', 'chan-1', ciphertext: 'cipher-blob'),
    );
    await _waitUntil(() => written.isNotEmpty);
    expect(written.single, 'DECODED(cipher-blob)');
    await decoded.stop();
    decoded.dispose();
  });

  group('own-echo belt (incident 8ff48b96)', () {
    // The connector's decode seam classifies own-reply-echo-shaped frames
    // (DecodedMail.ownEcho + empty payload). The belt splits them by the
    // ONLY honest local signal — the frame id: an id this connector minted
    // is our echoed reply (quiet ack/drop); anything else with a rewritten
    // sender is a malformed inbound that must never disappear silently.
    test('own reply echo (id this connector minted) acks quietly', () async {
      final connector = buildConnector(
        decodeMail: (envelope) => const DecodedMail(payload: '', ownEcho: true),
      );
      final written = <InboundMail>[];
      final rejections = <RejectedMail>[];
      connector.registerLocalSink(
        network: 'personal-x',
        channel: 'chan-1',
        sink: (mail) async => written.add(mail),
      );
      connector.rejections.listen(rejections.add);
      await connector.start();
      await _waitUntil(() => connector.isConnected);
      final sentId = await connector.sendMail(
        network: 'personal-x',
        channel: 'chan-1',
        from: 'goal_builder@macbook',
        to: 'user:u1',
        ciphertext: 'c1',
      );
      await _waitUntil(
        () => server.persistedMail.any((frame) => frame.msgId == sentId),
      );
      // The server fans our own frame back to the sending device — the
      // own-reply echo shape (from == addressed agent, to elsewhere).
      final echo = server.persistedMail
          .where((frame) => frame.msgId == sentId)
          .first;
      server.deliverTo(deviceId: 'macbook', mail: echo);
      await _waitUntil(
        () => server.received.any(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.ack && frame.refId == sentId,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(written, isEmpty);
      expect(rejections, isEmpty);
      expect(logs, anyElement(contains('own reply echo')));
      expect(
        logs.where((line) => line.contains('non-echo')),
        isEmpty,
        reason: 'a frame we minted must never raise the rewrite alarm',
      );
      await connector.stop();
      connector.dispose();
    });

    test(
      'minted DM echo is suppressed by id before user-side decoding',
      () async {
        var decodeCalls = 0;
        final connector = buildConnector(
          decodeMail: (envelope) {
            decodeCalls++;
            return const DecodedMail(payload: 'must not reach the sink');
          },
        );
        final written = <InboundMail>[];
        final rejections = <RejectedMail>[];
        const channel = 'dm:user:u1:goal@macbook';
        connector.registerLocalSink(
          network: 'personal-x',
          channel: channel,
          sink: (mail) async => written.add(mail),
        );
        connector.rejections.listen(rejections.add);
        await connector.start();
        await _waitUntil(() => connector.isConnected);
        final sentId = await connector.sendMail(
          network: 'personal-x',
          channel: channel,
          from: 'user:u1',
          to: 'goal@macbook',
          ciphertext: 'sealed-request',
        );
        await _waitUntil(
          () => server.persistedMail.any((frame) => frame.msgId == sentId),
        );
        final echo = server.persistedMail.singleWhere(
          (frame) => frame.msgId == sentId,
        );
        server.deliverTo(deviceId: 'macbook', mail: echo);
        await _waitUntil(
          () => server.received.any(
            (frame) =>
                frame.kind == NetworkEnvelopeKind.ack && frame.refId == sentId,
          ),
        );

        expect(written, isEmpty);
        expect(rejections, isEmpty);
        expect(decodeCalls, 0);
        expect(logs, anyElement(contains('own DM echo')));
        await connector.stop();
        connector.dispose();
      },
    );

    test(
      'non-echo own-echo-shaped frame (rewritten sender) acks loudly',
      () async {
        final connector = buildConnector(
          decodeMail: (envelope) =>
              const DecodedMail(payload: '', ownEcho: true),
        );
        final written = <InboundMail>[];
        final rejections = <RejectedMail>[];
        connector.registerLocalSink(
          network: 'personal-x',
          channel: 'chan-1',
          sink: (mail) async => written.add(mail),
        );
        connector.rejections.listen(rejections.add);
        await connector.start();
        await _waitUntil(() => connector.isConnected);

        // msgId 8ff48b96-… shape: an id the connector NEVER minted, with
        // the sender rewritten to the addressed agent. The wire ciphertext
        // stays INTACT (validation requires it); the DECODED payload is
        // empty because the decoder short-circuited on the rewritten
        // sender — exactly how the live frame behaved.
        server.deliverTo(
          deviceId: 'macbook',
          mail: _mailFor('8ff48b96', 'chan-1', ciphertext: 'frame-ciphertext'),
        );
        await _waitUntil(
          () => server.received.any(
            (frame) =>
                frame.kind == NetworkEnvelopeKind.ack &&
                frame.refId == '8ff48b96',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(written, isEmpty);
        expect(rejections, hasLength(1));
        expect(
          rejections.single.reason,
          'non-echo frame with rewritten sender: sender id equals the '
          'addressed agent and the payload is empty',
        );
        expect(
          logs,
          anyElement(
            allOf(
              contains('::warning'),
              contains('non-echo frame with rewritten sender'),
              contains('8ff48b96'),
            ),
          ),
          reason: 'the field-visible regression tripwire',
        );
        await connector.stop();
        connector.dispose();
      },
    );

    test('empty payload WITHOUT the own-echo flag still takes the ACL reject '
        'path (belt never swallows plain empty writes)', () async {
      final connector = buildConnector(
        decodeMail: (envelope) => const DecodedMail(payload: ''),
      );
      final rejections = <RejectedMail>[];
      connector.registerLocalSink(
        network: 'personal-x',
        channel: 'chan-1',
        sink: (_) async {},
      );
      connector.rejections.listen(rejections.add);
      await connector.start();
      await _waitUntil(() => connector.isConnected);
      server.deliverTo(
        deviceId: 'macbook',
        mail: _mailFor('empty-plain', 'chan-1', ciphertext: 'opaque'),
      );
      await _waitUntil(() => rejections.isNotEmpty);
      expect(
        rejections.single.reason,
        'empty remote write carries nothing to deliver',
      );
      await connector.stop();
      connector.dispose();
    });
  });
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
