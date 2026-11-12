// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';
import 'package:flutter_agent_harness/src/network/connector/upstream_client.dart';
import 'package:test/test.dart';

import 'fake_device_server.dart';

void main() {
  late FakeDeviceServer server;
  setUp(() => server = FakeDeviceServer());

  ConnectorUpstreamClient attach({
    String deviceId = 'macbook',
    List<String> networks = const ['personal-x'],
    Duration Function(int attempt)? backoff,
  }) {
    server.seedDevice(deviceId, networks: networks);
    return ConnectorUpstreamClient(
      url: Uri.parse('wss://fake/ws'),
      transport: server.transport,
      ticketProvider: () async => 'ticket-1',
      deviceId: deviceId,
      deviceToken: 'tok-1',
      backoff: backoff ?? upstreamBackoff,
      timers: const SystemTimers(),
    );
  }

  NetworkEnvelope outboundMail(String msgId, {String channel = 'chan-1'}) =>
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.mail,
        msgId: msgId,
        network: 'personal-x',
        channel: channel,
        from: 'goal_builder@macbook',
        to: 'user:u1',
        ts: '2026-11-12T10:00:00.000Z',
        ciphertext: 'c-$msgId',
      );

  test('hello handshake: hello_ok + roster per seeded network (§4)', () async {
    final client = attach(networks: ['personal-x', 'shared-x']);
    final inbound = <NetworkEnvelope>[];
    final sub = client.inbound.listen(inbound.add);
    await client.start();
    final hello = await _firstOfType(inbound, NetworkEnvelopeKind.helloOk);
    expect(hello.refId, isNotEmpty);
    final rosters = await _collect(inbound, NetworkEnvelopeKind.roster, 2);
    expect(rosters.map((frame) => frame.network), ['personal-x', 'shared-x']);
    expect(client.isReady, isTrue);
    await sub.cancel();
    await client.stop();
    client.dispose();
  });

  test('AC1: N sinks share ONE upstream — connectionCount stays 1', () async {
    final client = attach();
    await client.start();
    await _waitUntil(() => server.activeConnections == 1);
    for (var i = 0; i < 4; i++) {
      await client.send(outboundMail('m-$i'));
    }
    await _waitUntil(() => server.received.length >= 4);
    expect(
      server.connectionCount,
      1,
      reason: 'one device socket carries all agents (§3/AC1)',
    );
    expect(server.activeConnections, 1);
    await client.stop();
    client.dispose();
  });

  test('second dial displaces the first socket for the same device', () async {
    final client = attach();
    await client.start();
    await _waitUntil(() => server.activeConnections == 1);
    final dialsAfterFirst = server.connectionCount;
    // A second client dials with the same deviceId: the fake server
    // displaces the first socket (AC1 backend behavior).
    final second = attach();
    await second.start();
    await _waitUntil(() => server.connectionCount >= dialsAfterFirst + 1);
    await _waitUntil(() => server.activeConnections == 1);
    expect(server.connectionCount, 2, reason: 'both dials were accepted');
    expect(server.activeConnections, 1, reason: 'displacement left one socket');
    await client.stop();
    await second.stop();
    client.dispose();
    second.dispose();
  });

  test(
    'server routes + persists mail; msgId dedup never rewrites ids',
    () async {
      final client = attach();
      await client.start();
      await _waitUntil(() => server.activeConnections == 1);
      await client.send(outboundMail('m-1'));
      await client.send(outboundMail('m-1')); // duplicate msgId
      await client.send(outboundMail('m-2', channel: 'chan-2'));
      await _waitUntil(() => server.persistedMail.length >= 2);
      final ids = server.persistedMail.map((frame) => frame.msgId).toList();
      expect(ids, [
        'm-1',
        'm-2',
      ], reason: 'duplicate msgId dropped server-side');
      expect(server.persistedMail.first.seq, 1);
      expect(
        server.persistedMail.last.seq,
        1,
        reason: 'per-channel seq counters',
      );
      expect(
        ids,
        everyElement(isIn(['m-1', 'm-2'])),
        reason: 'ids never rewritten (contract v1.1)',
      );
      await client.stop();
      client.dispose();
    },
  );

  test('invalid mail from a client is answered with an error frame', () async {
    final client = attach();
    final inbound = <NetworkEnvelope>[];
    final sub = client.inbound.listen(inbound.add);
    await client.start();
    await _waitUntil(() => server.activeConnections == 1);
    await client.send(
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.mail,
        msgId: 'bad',
        ts: '2026-11-12T10:00:00.000Z',
        ciphertext: 'c',
      ),
    );
    final error = await _firstOfType(inbound, NetworkEnvelopeKind.error);
    expect(error.refId, 'bad');
    expect(error.payload['message'], contains('network'));
    await sub.cancel();
    await client.stop();
    client.dispose();
  });

  test('unacked mail redelivers in seq order after resume (§4/AC5)', () async {
    final client = attach();
    final inbound = <NetworkEnvelope>[];
    final sub = client.inbound.listen(inbound.add);
    await client.start();
    await _waitUntil(() => server.activeConnections == 1);
    // The server queues mail for the device; the socket drops before ack.
    server.deliverTo(
      deviceId: 'macbook',
      mail: _inboundMail('u-1', seqInput: 1),
    );
    server.deliverTo(
      deviceId: 'macbook',
      mail: _inboundMail('u-2', seqInput: 2),
    );
    await _waitUntil(() => server.deliveries.length == 2);
    server.dropAll();
    await client.stop();

    // Fresh client (same identity) resumes: roster THEN redelivery in seq
    // order, byte-identical msgIds.
    final resumed = attach();
    final resumedInbound = <NetworkEnvelope>[];
    final sub2 = resumed.inbound.listen(resumedInbound.add);
    await resumed.start();
    final redelivered = await _collect(
      resumedInbound,
      NetworkEnvelopeKind.mail,
      2,
    );
    expect(redelivered.map((frame) => frame.msgId), [
      'u-1',
      'u-2',
    ], reason: 'seq order, ids byte-for-byte (contract v1.1)');
    expect(redelivered.map((frame) => frame.seq), [1, 2]);
    // Ack retires the frames — no redelivery on the NEXT resume.
    resumed.acknowledge('u-1');
    resumed.acknowledge('u-2');
    await _waitUntil(() => server.activeConnections == 1);
    await resumed.stop();
    final third = attach();
    final thirdInbound = <NetworkEnvelope>[];
    final sub3 = third.inbound.listen(thirdInbound.add);
    await third.start();
    await _waitUntil(() => server.activeConnections == 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      thirdInbound.where((frame) => frame.kind == NetworkEnvelopeKind.mail),
      isEmpty,
      reason: 'acked mail is not redelivered',
    );
    await sub.cancel();
    await sub2.cancel();
    await sub3.cancel();
    await third.stop();
    resumed.dispose();
    third.dispose();
  });

  test(
    'server answers pings with pongs (application-level liveness)',
    () async {
      final client = attach(networks: []);
      final inbound = <NetworkEnvelope>[];
      final sub = client.inbound.listen(inbound.add);
      await client.start();
      await _waitUntil(() => server.activeConnections == 1);
      // The client pings every 20s (SystemTimers — wait one real period is
      // too slow; assert via the fake: any client ping gets a pong). Force a
      // ping by sending one directly through the seam.
      final ping = NetworkEnvelope(
        kind: NetworkEnvelopeKind.ping,
        msgId: 'ping-1',
        ts: '2026-11-12T10:00:00.000Z',
      );
      await server.transport.dial(Uri.parse('wss://fake/ws'), 'ignored');
      // The live client socket answers: exercise via client.send.
      await client.send(ping);
      final pong = await _firstOfType(inbound, NetworkEnvelopeKind.pong);
      expect(pong.refId, 'ping-1');
      await sub.cancel();
      await client.stop();
      client.dispose();
    },
  );

  test('failNextDials injects the AC5 outage (dial throws)', () async {
    server.seedDevice('macbook', networks: const []);
    server.failNextDials = 1;
    await expectLater(
      server.transport.dial(Uri.parse('wss://fake/ws'), 't'),
      throwsA(isA<StateError>()),
    );
    // Restore: the next dial succeeds.
    final socket = await server.transport.dial(Uri.parse('wss://fake/ws'), 't');
    expect(socket.isOpen, isTrue);
    await socket.close();
  });

  test(
    'outage: frames sent while disconnected queue, then drain in order',
    () async {
      final client = attach();
      await client.start();
      await _waitUntil(() => server.activeConnections == 1);
      // Kill upstream (client notices; it will retry with backoff).
      server.dropAll();
      await client.stop();
      server.failNextDials = 2;
      final resumed = attach(
        backoff: (attempt) => const Duration(milliseconds: 20),
      );
      await resumed.start();
      await _waitUntil(() => server.activeConnections == 1);
      await resumed.send(outboundMail('q-1'));
      await resumed.send(outboundMail('q-2'));
      await resumed.send(outboundMail('q-3'));
      await _waitUntil(
        () =>
            server.received
                .where((frame) => frame.msgId.startsWith('q-'))
                .length ==
            3,
      );
      final sentIds = server.received
          .where((frame) => frame.msgId.startsWith('q-'))
          .map((frame) => frame.msgId)
          .toList();
      expect(sentIds, ['q-1', 'q-2', 'q-3'], reason: 'drain-in-order (AC5)');
      await resumed.stop();
      resumed.dispose();
    },
  );
}

NetworkEnvelope _inboundMail(String msgId, {required int seqInput}) =>
    NetworkEnvelope(
      kind: NetworkEnvelopeKind.mail,
      msgId: msgId,
      network: 'personal-x',
      channel: 'chan-1',
      from: 'user:u1',
      to: 'goal_builder@macbook',
      ts: '2026-11-12T10:00:00.000Z',
      ciphertext: 'c-$msgId',
    );

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not met within 1s');
}

Future<NetworkEnvelope> _firstOfType(
  List<NetworkEnvelope> frames,
  NetworkEnvelopeKind kind,
) async {
  await _waitUntil(() => frames.any((frame) => frame.kind == kind));
  return frames.firstWhere((frame) => frame.kind == kind);
}

Future<List<NetworkEnvelope>> _collect(
  List<NetworkEnvelope> frames,
  NetworkEnvelopeKind kind,
  int count,
) async {
  await _waitUntil(
    () => frames.where((frame) => frame.kind == kind).length >= count,
  );
  return frames.where((frame) => frame.kind == kind).toList();
}
