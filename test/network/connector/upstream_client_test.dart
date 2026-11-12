// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';
import 'package:flutter_agent_harness/src/network/connector/upstream_client.dart';
import 'package:test/test.dart';

/// In-memory socket pair: the fake transport's dial returns a socket whose
/// writes land in the test's hands and whose inbound frames come from the
/// test. No timers, NO read-timeouts anywhere (backend field note: a
/// cancelled read closes the connection).
final class FakeSocket implements ConnectorSocket {
  final controller = StreamController<NetworkEnvelope>.broadcast();
  final sent = <NetworkEnvelope>[];
  var closed = false;

  @override
  Stream<NetworkEnvelope> get frames => controller.stream;

  @override
  bool get isOpen => !closed;

  @override
  Future<void> send(NetworkEnvelope envelope) async {
    if (closed) throw StateError('socket closed');
    sent.add(envelope);
  }

  @override
  Future<void> close() async {
    closed = true;
    await controller.close();
  }

  void receive(NetworkEnvelope envelope) => controller.add(envelope);

  void drop() => controller.close();
}

final class FakeTransport implements ConnectorTransport {
  FakeSocket? next;
  final sockets = <FakeSocket>[];
  final dialTickets = <String>[];
  var failNextDial = false;
  final dials = <Uri>[];

  FakeSocket? get lastSocket => sockets.isEmpty ? null : sockets.last;

  @override
  Future<ConnectorSocket> dial(Uri url, String ticket) async {
    dials.add(url);
    dialTickets.add(ticket);
    if (failNextDial) {
      failNextDial = false;
      throw StateError('server unreachable');
    }
    if (next == null) throw StateError('no socket scripted');
    final socket = next!;
    next = null;
    sockets.add(socket);
    return socket;
  }
}

/// Manually-fired timers mirroring the presence test fakes.
final class FakeTimer implements ConnectorTimer {
  FakeTimer({required this.fire});
  final void Function() fire;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}

final class FakeTimers implements ConnectorTimers {
  final periodicTimers = <FakeTimer>[];
  final delayedTimers = <FakeTimer>[];

  @override
  ConnectorTimer periodic(Duration interval, void Function() onTick) {
    final timer = FakeTimer(fire: onTick);
    periodicTimers.add(timer);
    return timer;
  }

  @override
  ConnectorTimer delayed(Duration duration, void Function() onFire) {
    final timer = FakeTimer(fire: onFire);
    delayedTimers.add(timer);
    return timer;
  }

  void fireDelayed() {
    for (final timer in List.of(delayedTimers)) {
      if (!timer.cancelled) timer.fire();
    }
  }

  void firePings([int count = 1]) {
    for (var i = 0; i < count; i++) {
      for (final timer in List.of(periodicTimers)) {
        if (!timer.cancelled) timer.fire();
      }
    }
  }
}

Future<void> pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

NetworkEnvelope helloOk(String refId) => NetworkEnvelope(
  kind: NetworkEnvelopeKind.helloOk,
  msgId: 'ok-1',
  refId: refId,
  ts: '2026-11-12T10:00:00.000Z',
);

NetworkEnvelope roster({String msgId = 'roster-1'}) => NetworkEnvelope(
  kind: NetworkEnvelopeKind.roster,
  msgId: msgId,
  ts: '2026-11-12T10:00:00.000Z',
  payload: {
    'networks': [
      {'id': 'personal-x', 'agents': []},
    ],
  },
);

void main() {
  test('backoff schedule: 1s doubling capped at 30s (contract §4)', () {
    expect(upstreamBackoff(1), const Duration(seconds: 1));
    expect(upstreamBackoff(2), const Duration(seconds: 2));
    expect(upstreamBackoff(3), const Duration(seconds: 4));
    expect(upstreamBackoff(4), const Duration(seconds: 8));
    expect(upstreamBackoff(5), const Duration(seconds: 16));
    expect(upstreamBackoff(6), const Duration(seconds: 30));
    expect(upstreamBackoff(50), const Duration(seconds: 30));
    expect(upstreamBackoff(0), const Duration(seconds: 1));
  });

  test(
    'handshake: dial with fresh ticket, hello, hello_ok → connected',
    () async {
      final transport = FakeTransport();
      final socket = FakeSocket();
      transport.next = socket;
      final tickets = 0;
      final client = ConnectorUpstreamClient(
        url: Uri.parse('wss://network.fa1.dev/ws'),
        transport: transport,
        ticketProvider: () async => 'ticket-$tickets',
        deviceId: 'macbook',
        deviceToken: 'tok-1',
        rosterDigest: () => 'digest-1',
        timers: FakeTimers(),
      );
      final states = <ConnectorLinkState>[];
      final sub = client.stateChanges.listen(states.add);
      await client.start();
      await pump();

      expect(states, [
        ConnectorLinkState.connecting,
        ConnectorLinkState.handshaking,
      ]);
      expect(transport.dialTickets.single, 'ticket-0');
      expect(transport.dials.single.queryParameters['ticket'], 'ticket-0');
      final hello = socket.sent.single;
      expect(hello.kind, NetworkEnvelopeKind.hello);
      expect(hello.payload['deviceId'], 'macbook');
      expect(hello.payload['deviceToken'], 'tok-1');
      expect(hello.payload['rosterDigest'], 'digest-1');
      expect(client.isReady, isFalse);

      socket.receive(helloOk(hello.msgId));
      socket.receive(roster());
      await pump();
      expect(states, [
        ConnectorLinkState.connecting,
        ConnectorLinkState.handshaking,
        ConnectorLinkState.connected,
      ]);
      expect(client.isReady, isTrue);
      expect(client.lastRoster, isNotNull);
      await sub.cancel();
      await client.stop();
      client.dispose();
    },
  );

  test('wrong hello_ok refId fails the handshake and retries', () async {
    final transport = FakeTransport();
    final socket = FakeSocket();
    transport.next = socket;
    final timers = FakeTimers();
    final logs = <String>[];
    final client = ConnectorUpstreamClient(
      url: Uri.parse('wss://network.fa1.dev/ws'),
      transport: transport,
      ticketProvider: () async => 't',
      deviceId: 'macbook',
      backoff: (attempt) => const Duration(milliseconds: 1),
      timers: timers,
      onLog: logs.add,
    );
    await client.start();
    await pump();
    expect(client.attempts, 0);
    socket.receive(helloOk('mismatched-ref'));
    await pump();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(logs.join(' '), contains('unexpected handshake reply'));
    expect(client.state, ConnectorLinkState.disconnected);
    // The retry needs a scripted socket this time.
    transport.next = FakeSocket();
    timers.fireDelayed();
    await pump();
    expect(client.attempts, 1);
    await client.stop();
    client.dispose();
  });

  test(
    'mail + roster frames surface on inbound; ping answers with pong',
    () async {
      final transport = FakeTransport();
      final socket = FakeSocket();
      transport.next = socket;
      final timers = FakeTimers();
      final client = ConnectorUpstreamClient(
        url: Uri.parse('wss://network.fa1.dev/ws'),
        transport: transport,
        ticketProvider: () async => 't',
        deviceId: 'macbook',
        timers: timers,
      );
      final inbound = <NetworkEnvelope>[];
      final sub = client.inbound.listen(inbound.add);
      await client.start();
      await pump();
      socket.receive(helloOk(socket.sent.single.msgId));
      socket.receive(roster());
      await pump();

      // Server ping → automatic application-level pong (no read timeouts).
      socket.receive(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.ping,
          msgId: 'srv-ping',
          ts: '2026-11-12T10:00:00.000Z',
        ),
      );
      await pump();
      final pongs = socket.sent
          .where((frame) => frame.kind == NetworkEnvelopeKind.pong)
          .toList();
      expect(pongs, hasLength(1));
      expect(pongs.single.refId, 'srv-ping');

      // Client ping timer fires every 20s (contract §4).
      timers.firePings(2);
      expect(
        socket.sent.where((frame) => frame.kind == NetworkEnvelopeKind.ping),
        hasLength(2),
      );

      final mail = NetworkEnvelope(
        kind: NetworkEnvelopeKind.mail,
        msgId: 'm-1',
        network: 'personal-x',
        channel: 'chan-1',
        from: 'user:u1',
        to: 'goal_builder@macbook',
        ts: '2026-11-12T10:00:00.000Z',
        seq: 3,
        ciphertext: 'c',
      );
      socket.receive(mail);
      await pump();
      expect(
        inbound.map((frame) => frame.kind),
        containsAll([NetworkEnvelopeKind.mail, NetworkEnvelopeKind.roster]),
      );
      await sub.cancel();
      await client.stop();
      client.dispose();
    },
  );

  test(
    'socket drop → backoff → resume hello carries the same identity',
    () async {
      final transport = FakeTransport();
      final socket = FakeSocket();
      transport.next = socket;
      final timers = FakeTimers();
      final client = ConnectorUpstreamClient(
        url: Uri.parse('wss://network.fa1.dev/ws'),
        transport: transport,
        ticketProvider: () async => 't-2',
        deviceId: 'macbook',
        deviceToken: 'tok-1',
        backoff: (attempt) => const Duration(seconds: 2),
        timers: timers,
      );
      final states = <ConnectorLinkState>[];
      final sub = client.stateChanges.listen(states.add);
      await client.start();
      await pump();
      socket.receive(helloOk(socket.sent.single.msgId));
      await pump();
      expect(client.isReady, isTrue);

      socket.drop();
      await pump();
      expect(client.state, ConnectorLinkState.disconnected);
      expect(client.attempts, 1);
      // Backoff timer armed; firing it redials (resume by same pair).
      final secondSocket = FakeSocket();
      transport.next = secondSocket;
      timers.fireDelayed();
      await pump();
      expect(transport.dials, hasLength(2));
      expect(transport.dialTickets.last, 't-2');
      final resumedHello = transport.lastSocket!.sent.firstWhere(
        (frame) => frame.kind == NetworkEnvelopeKind.hello,
      );
      expect(resumedHello.payload['deviceId'], 'macbook');
      expect(resumedHello.payload['deviceToken'], 'tok-1');
      expect(states.last, ConnectorLinkState.handshaking);
      transport.lastSocket!.receive(helloOk(resumedHello.msgId));
      await pump();
      expect(client.attempts, 0, reason: 'attempt counter resets on welcome');
      expect(client.isReady, isTrue);
      await sub.cancel();
      await client.stop();
      client.dispose();
    },
  );

  test('dial failure retries with backoff (server down)', () async {
    final transport = FakeTransport()..failNextDial = true;
    final timers = FakeTimers();
    final logs = <String>[];
    final client = ConnectorUpstreamClient(
      url: Uri.parse('wss://network.fa1.dev/ws'),
      transport: transport,
      ticketProvider: () async => 't',
      deviceId: 'macbook',
      backoff: (attempt) => const Duration(seconds: 1),
      timers: timers,
      onLog: logs.add,
    );
    await client.start();
    await pump();
    expect(logs.join(' '), contains('dial failed'));
    expect(client.state, ConnectorLinkState.disconnected);
    expect(client.attempts, 1);
    timers.fireDelayed();
    await pump();
    expect(client.attempts, 2);
    await client.stop();
    client.dispose();
  });

  test('ticket provider failure also retries', () async {
    var calls = 0;
    final timers = FakeTimers();
    final client = ConnectorUpstreamClient(
      url: Uri.parse('wss://network.fa1.dev/ws'),
      transport: FakeTransport(),
      ticketProvider: () async {
        calls++;
        throw StateError('401');
      },
      deviceId: 'macbook',
      backoff: (attempt) => const Duration(seconds: 1),
      timers: timers,
    );
    await client.start();
    await pump();
    expect(calls, 1);
    expect(client.attempts, 1);
    timers.fireDelayed();
    await pump();
    expect(calls, 2);
    await client.stop();
    client.dispose();
  });

  test('handshake timeout drops the silent socket and retries', () async {
    final transport = FakeTransport();
    final socket = FakeSocket();
    transport.next = socket;
    final timers = FakeTimers();
    final client = ConnectorUpstreamClient(
      url: Uri.parse('wss://network.fa1.dev/ws'),
      transport: transport,
      ticketProvider: () async => 't',
      deviceId: 'macbook',
      handshakeTimeout: const Duration(seconds: 10),
      backoff: (attempt) => const Duration(seconds: 1),
      timers: timers,
    );
    await client.start();
    await pump();
    expect(client.state, ConnectorLinkState.handshaking);
    timers.fireDelayed();
    await pump();
    expect(socket.closed, isTrue, reason: 'silent server socket dropped');
    expect(client.attempts, 1);
    await client.stop();
    client.dispose();
  });

  test(
    'send works when ready and throws ConnectorOfflineException otherwise',
    () async {
      final transport = FakeTransport();
      final socket = FakeSocket();
      transport.next = socket;
      final client = ConnectorUpstreamClient(
        url: Uri.parse('wss://network.fa1.dev/ws'),
        transport: transport,
        ticketProvider: () async => 't',
        deviceId: 'macbook',
        timers: FakeTimers(),
      );
      final mail = NetworkEnvelope(
        kind: NetworkEnvelopeKind.mail,
        msgId: 'm-1',
        network: 'n',
        channel: 'c',
        from: 'a',
        to: 'b',
        ts: '2026-11-12T10:00:00.000Z',
        ciphertext: 'c',
      );
      await client.start();
      await pump();
      expect(
        () => client.send(mail),
        throwsA(isA<ConnectorOfflineException>()),
      );
      socket.receive(helloOk(socket.sent.single.msgId));
      await pump();
      await client.send(mail);
      expect(socket.sent.last.msgId, 'm-1');
      await client.stop();
      expect(
        () => client.send(mail),
        throwsA(isA<ConnectorOfflineException>()),
      );
      client.dispose();
    },
  );

  test(
    'acknowledge: refId ack written when ready, deferred when offline',
    () async {
      final transport = FakeTransport();
      final socket = FakeSocket();
      transport.next = socket;
      final logs = <String>[];
      final client = ConnectorUpstreamClient(
        url: Uri.parse('wss://network.fa1.dev/ws'),
        transport: transport,
        ticketProvider: () async => 't',
        deviceId: 'macbook',
        timers: FakeTimers(),
        onLog: logs.add,
      );
      client.acknowledge('m-early');
      expect(logs.join(' '), contains('ack deferred'));
      await client.start();
      await pump();
      socket.receive(helloOk(socket.sent.single.msgId));
      await pump();
      client.acknowledge('m-1');
      await pump();
      final ack = socket.sent.lastWhere(
        (frame) => frame.kind == NetworkEnvelopeKind.ack,
      );
      expect(ack.refId, 'm-1');
      expect(ack.isValid, isTrue);
      await client.stop();
      client.dispose();
    },
  );

  test('stop is clean: no reconnect fires afterwards', () async {
    final transport = FakeTransport();
    final socket = FakeSocket();
    transport.next = socket;
    final timers = FakeTimers();
    final client = ConnectorUpstreamClient(
      url: Uri.parse('wss://network.fa1.dev/ws'),
      transport: transport,
      ticketProvider: () async => 't',
      deviceId: 'macbook',
      timers: timers,
    );
    await client.start();
    await pump();
    socket.receive(helloOk(socket.sent.single.msgId));
    await pump();
    await client.stop();
    expect(client.state, ConnectorLinkState.disconnected);
    expect(timers.periodicTimers.every((timer) => timer.cancelled), isTrue);
    expect(timers.delayedTimers.every((timer) => timer.cancelled), isTrue);
    final dialsBefore = transport.dials.length;
    timers.fireDelayed();
    timers.firePings(2);
    await pump();
    expect(
      transport.dials.length,
      dialsBefore,
      reason: 'stopped stays stopped',
    );
  });

  test(
    'second dial displaces the first socket (AC1 server behavior)',
    () async {
      final transport = FakeTransport();
      final first = FakeSocket();
      transport.next = first;
      final client = ConnectorUpstreamClient(
        url: Uri.parse('wss://network.fa1.dev/ws'),
        transport: transport,
        ticketProvider: () async => 't',
        deviceId: 'macbook',
        timers: FakeTimers(),
      );
      await client.start();
      await pump();
      first.receive(helloOk(first.sent.single.msgId));
      await pump();
      // The fake server closes the old socket when a new dial displaces it —
      // the client sees exactly a dropped link and reconnects.
      first.drop();
      await pump();
      expect(client.state, ConnectorLinkState.disconnected);
      await client.stop();
      client.dispose();
    },
  );
}
