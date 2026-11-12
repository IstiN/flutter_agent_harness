// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/src/network/connector/connector_mux.dart';
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:test/test.dart';

void main() {
  NetworkEnvelope mail(
    String msgId, {
    String network = 'net-a',
    String channel = 'chan-1',
    String? to = 'goal_builder@macbook',
  }) => NetworkEnvelope(
    kind: NetworkEnvelopeKind.mail,
    msgId: msgId,
    network: network,
    channel: channel,
    from: 'user:u1',
    to: to,
    ts: '2026-11-12T10:00:00.000Z',
    ciphertext: 'c-$msgId',
  );

  test(
    'routes mail by (network, channel, to) to the registered sink',
    () async {
      final mux = ConnectorMux();
      final delivered = <String>[];
      mux.registerSink(
        const MailRoute(network: 'net-a', channel: 'chan-1', to: 'g@mac'),
        (envelope) async => delivered.add(envelope.msgId),
      );
      expect(mux.demux(mail('m-1', to: 'g@mac')), DemuxOutcome.delivered);
      await mux.settle();
      expect(delivered, ['m-1']);
      mux.dispose();
    },
  );

  test(
    'isolation: mail for another network/channel/to stays unrouted (AC2)',
    () async {
      final mux = ConnectorMux();
      final netADelivered = <String>[];
      final netBDelivered = <String>[];
      Object? unrouted;
      mux
        ..registerSink(
          const MailRoute(
            network: 'net-a',
            channel: 'chan-1',
            to: 'goal_builder@macbook',
          ),
          (envelope) async => netADelivered.add(envelope.msgId),
        )
        ..registerSink(
          const MailRoute(
            network: 'net-b',
            channel: 'chan-1',
            to: 'goal_builder@macbook',
          ),
          (envelope) async => netBDelivered.add(envelope.msgId),
        )
        ..onUnrouted = (envelope) => unrouted = envelope.msgId;
      expect(mux.demux(mail('m-1')), DemuxOutcome.delivered);
      expect(mux.demux(mail('m-2', network: 'net-b')), DemuxOutcome.delivered);
      expect(mux.demux(mail('m-3', network: 'net-c')), DemuxOutcome.unrouted);
      await mux.settle();
      expect(netADelivered, ['m-1']);
      expect(netBDelivered, ['m-2']);
      expect(unrouted, 'm-3');
      mux.dispose();
    },
  );

  test('dedup collapses redelivered msgIds within the window', () async {
    final mux = ConnectorMux(dedupWindow: 2);
    final delivered = <String>[];
    mux.registerSink(
      const MailRoute(network: 'net-a', channel: 'chan-1'),
      (envelope) async => delivered.add(envelope.msgId),
    );
    expect(mux.demux(mail('m-1')), DemuxOutcome.delivered);
    expect(mux.demux(mail('m-1')), DemuxOutcome.duplicate);
    expect(mux.hasSeen('m-1'), isTrue);
    // Window of 2: m-2, m-3 push m-1 out; m-1 again is treated as fresh.
    expect(mux.demux(mail('m-2')), DemuxOutcome.delivered);
    expect(mux.demux(mail('m-3')), DemuxOutcome.delivered);
    expect(mux.hasSeen('m-1'), isFalse, reason: 'windowed out');
    expect(mux.demux(mail('m-1')), DemuxOutcome.delivered);
    await mux.settle();
    expect(delivered, ['m-1', 'm-2', 'm-3', 'm-1']);
    mux.dispose();
  });

  test('dedup window survives a simulated reconnect (AC2)', () async {
    final mux = ConnectorMux();
    final delivered = <String>[];
    mux.registerSink(
      const MailRoute(network: 'net-a', channel: 'chan-1'),
      (envelope) async => delivered.add(envelope.msgId),
    );
    mux.demux(mail('m-1'));
    // Reconnect = attach/detach cycles on outbound; mux keeps its state.
    mux.detachOutbound();
    mux.attachOutbound((envelope) async {});
    expect(
      mux.demux(mail('m-1')),
      DemuxOutcome.duplicate,
      reason: 'at-least-once redelivery after resume collapses',
    );
    await mux.settle();
    expect(delivered, ['m-1']);
    mux.dispose();
  });

  test(
    'per-sender FIFO: handlers chain in demux order across reconnect',
    () async {
      final mux = ConnectorMux();
      final order = <String>[];
      mux.registerSink(const MailRoute(network: 'net-a', channel: 'chan-1'), (
        envelope,
      ) async {
        await Future<void>.delayed(
          Duration(milliseconds: envelope.msgId == 'm-1' ? 20 : 1),
        );
        order.add(envelope.msgId);
      });
      // First handler is slow; demuxing 2 and 3 immediately must NOT reorder.
      mux.demux(mail('m-1'));
      mux.demux(mail('m-2'));
      mux.demux(mail('m-3'));
      await mux.settle();
      expect(order, ['m-1', 'm-2', 'm-3']);
      mux.dispose();
    },
  );

  test('invalid mail is reported and never consumes a dedup id', () async {
    final mux = ConnectorMux();
    final invalid = <String>[];
    mux.onInvalid = (envelope, problems) => invalid.add(envelope.msgId);
    final bad = NetworkEnvelope(
      kind: NetworkEnvelopeKind.mail,
      msgId: 'bad-1',
      ts: '2026-11-12T10:00:00.000Z',
      ciphertext: 'c',
    );
    expect(mux.demux(bad), DemuxOutcome.invalid);
    expect(
      mux.demux(bad),
      DemuxOutcome.invalid,
      reason: 'no dedup id consumed',
    );
    expect(mux.hasSeen('bad-1'), isFalse);
    expect(invalid, ['bad-1', 'bad-1']);
    // Non-mail frames are out of the mux's demux contract.
    expect(
      mux.demux(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.ping,
          msgId: 'p-1',
          ts: '2026-11-12T10:00:00.000Z',
        ),
      ),
      DemuxOutcome.invalid,
    );
    mux.dispose();
  });

  test(
    'channel catch-all receives mail when no exact sink claims it',
    () async {
      final mux = ConnectorMux();
      final catchAll = <String>[];
      mux.registerSink(
        const MailRoute(network: 'net-a', channel: 'chan-1'),
        (envelope) async => catchAll.add(envelope.msgId),
      );
      expect(mux.demux(mail('m-1', to: 'g@mac')), DemuxOutcome.delivered);
      expect(mux.demux(mail('m-2', to: 'other@mac')), DemuxOutcome.delivered);
      await mux.settle();
      expect(catchAll, ['m-1', 'm-2']);
      mux.dispose();
    },
  );

  test('multiple sinks per route fan out in registration order', () async {
    final mux = ConnectorMux();
    final order = <String>[];
    mux.registerSink(
      const MailRoute(network: 'net-a', channel: 'chan-1'),
      (envelope) async => order.add('a:${envelope.msgId}'),
    );
    final second = mux.registerSink(
      const MailRoute(network: 'net-a', channel: 'chan-1'),
      (envelope) async => order.add('b:${envelope.msgId}'),
    );
    mux.demux(mail('m-1'));
    await mux.settle();
    expect(order, ['a:m-1', 'b:m-1']);
    second.close();
    mux.demux(mail('m-2'));
    await mux.settle();
    expect(order, ['a:m-1', 'b:m-1', 'a:m-2']);
    mux.dispose();
  });

  group('outbound send queue', () {
    test('flushes in insertion order through the attached sender', () async {
      final mux = ConnectorMux();
      final sent = <String>[];
      mux.attachOutbound((envelope) async {
        await Future<void>.delayed(
          Duration(milliseconds: envelope.msgId == 'm-1' ? 10 : 1),
        );
        sent.add(envelope.msgId);
      });
      mux.send(mail('m-1'));
      mux.send(mail('m-2'));
      mux.send(mail('m-3'));
      await mux.settle();
      expect(sent, ['m-1', 'm-2', 'm-3']);
      expect(mux.pendingOutbound, 0);
      mux.dispose();
    });

    test('frames queue while detached and flush on attach', () async {
      final mux = ConnectorMux();
      final sent = <String>[];
      mux.send(mail('m-1'));
      mux.send(mail('m-2'));
      expect(mux.pendingOutbound, 2);
      expect(mux.isOutboundAttached, isFalse);
      mux.attachOutbound((envelope) async => sent.add(envelope.msgId));
      await mux.settle();
      expect(sent, ['m-1', 'm-2']);
      mux.dispose();
    });

    test(
      'sender failure keeps the head queued and detaches (order intact)',
      () async {
        final mux = ConnectorMux();
        final sent = <String>[];
        final failures = <String>[];
        mux.onOutboundError = (envelope, error) => failures.add(envelope.msgId);
        var attempts = 0;
        Future<void> sendFrame(NetworkEnvelope envelope) async {
          attempts++;
          if (envelope.msgId == 'm-1' && attempts == 1) {
            throw StateError('link dropped');
          }
          sent.add(envelope.msgId);
        }

        mux.attachOutbound(sendFrame);
        mux.send(mail('m-1'));
        mux.send(mail('m-2'));
        await mux.settle();
        expect(mux.isOutboundAttached, isFalse);
        expect(failures, ['m-1']);
        expect(mux.pendingOutbound, 2, reason: 'm-1 stays at the head');
        // Reconnect: attach again — m-1 retries before m-2.
        mux.attachOutbound(sendFrame);
        await mux.settle();
        expect(sent, ['m-1', 'm-2']);
        mux.dispose();
      },
    );

    test(
      'takePending drains in order (spill into the offline outbox)',
      () async {
        final mux = ConnectorMux();
        mux.send(mail('m-1'));
        mux.send(mail('m-2'));
        final pending = mux.takePending();
        expect(pending.map((envelope) => envelope.msgId), ['m-1', 'm-2']);
        expect(mux.pendingOutbound, 0);
        mux.dispose();
      },
    );

    test('dispose detaches and clears routing state', () {
      final mux = ConnectorMux()
        ..registerSink(
          const MailRoute(network: 'net-a', channel: 'chan-1'),
          (envelope) async {},
        )
        ..send(mail('m-1'));
      mux.dispose();
      expect(mux.isOutboundAttached, isFalse);
      expect(mux.pendingOutbound, 0);
      expect(mux.demux(mail('m-9')), DemuxOutcome.unrouted);
    });
  });
}
