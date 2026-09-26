// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Deps land via the orchestrator's pubspec change (issue #955).
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fa/network/fa_network_ws.dart';
import 'package:fa/network/models.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';

/// In-memory [StreamChannel]: [incoming] plays the server side, [outgoing]
/// captures everything the client writes.
class _FakeChannel extends StreamChannelMixin<String> {
  final StreamController<String> incoming = StreamController<String>(
    sync: true,
  );
  final StreamController<String> outgoing = StreamController<String>(
    sync: true,
  );
  final List<String> sent = [];
  bool closed = false;

  _FakeChannel() {
    outgoing.stream.listen(sent.add);
  }

  @override
  Stream<String> get stream => incoming.stream;

  @override
  StreamSink<String> get sink => outgoing.sink;

  List<Map<String, Object?>> get sentFrames =>
      sent.map((f) => (jsonDecode(f) as Map).cast<String, Object?>()).toList();

  /// Server closes the connection.
  Future<void> closeFromServer() => incoming.close();
}

class _FakeConnector implements WsConnector {
  final List<Uri> uris = [];
  final List<Map<String, String>> headerLog = [];
  final List<_FakeChannel> channels = [];
  int failuresBeforeSuccess = 0;

  @override
  Future<StreamChannel<String>> connect(
    Uri wsUri,
    Map<String, String> headers,
  ) async {
    uris.add(wsUri);
    headerLog.add(Map.of(headers));
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw StateError('connection refused');
    }
    final channel = _FakeChannel();
    channels.add(channel);
    return channel;
  }
}

class _ZeroRandom implements Random {
  const _ZeroRandom();

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => 0;
}

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  FaNetworkWs build(
    _FakeConnector connector, {
    String baseUrl = 'http://localhost:8080',
    Duration heartbeat = const Duration(seconds: 30),
    Duration initialBackoff = const Duration(milliseconds: 100),
  }) => FaNetworkWs(
    baseUrl: Uri.parse(baseUrl),
    connector: connector,
    sessionToken: () => 'sess-tok',
    heartbeat: heartbeat,
    initialBackoff: initialBackoff,
    maxBackoff: const Duration(seconds: 2),
    random: const _ZeroRandom(),
  );

  test('connect builds the ws url and sends the bearer header', () async {
    final connector = _FakeConnector();
    final ws = build(connector);
    await ws.connect();
    expect(connector.uris.single.toString(), 'ws://localhost:8080/ws');
    expect(connector.headerLog.single['Authorization'], 'Bearer sess-tok');
    expect(ws.isConnected, isTrue);
    await ws.dispose();
  });

  test('https base maps to wss', () async {
    final connector = _FakeConnector();
    final ws = build(connector, baseUrl: 'https://network.fa1.dev');
    await ws.connect();
    expect(connector.uris.single.scheme, 'wss');
    await ws.dispose();
  });

  group('frame parsing', () {
    late _FakeConnector connector;
    late FaNetworkWs ws;
    late List<WsEvent> events;

    setUp(() async {
      connector = _FakeConnector();
      ws = build(connector);
      events = [];
      ws.events.listen(events.add);
      await ws.connect();
    });

    tearDown(() => ws.dispose());

    _FakeChannel channel() => connector.channels.single;

    test('roster.snapshot parses members', () async {
      channel().incoming.add(
        jsonEncode({
          'type': 'roster.snapshot',
          'payload': [
            {
              'id': 'm1',
              'class': 'owner',
              'displayName': 'A',
              'presence': 'live',
            },
            {
              'id': 'm2',
              'class': 'agent',
              'displayName': 'B',
              'presence': 'offline',
            },
          ],
        }),
      );
      await pump();
      final e = events.single as RosterSnapshot;
      expect(e.members, hasLength(2));
      expect(e.members.first.memberClass, MemberClass.owner);
      expect(e.members.last.presence, Presence.offline);
    });

    test('envelope parses an Envelope', () async {
      channel().incoming.add(
        jsonEncode({
          'type': 'envelope',
          'payload': {
            'id': 'e1',
            'channelId': 'c1',
            'senderId': 'm1',
            'payload': 'aGk=',
            'mentions': ['a1'],
            'createdAt': '2026-01-02T03:04:05Z',
          },
        }),
      );
      await pump();
      final e = events.single as EnvelopeReceived;
      expect(e.envelope.id, 'e1');
      expect(e.envelope.mentions, ['a1']);
    });

    test('presence.changed parses memberId + presence', () async {
      channel().incoming.add(
        jsonEncode({
          'type': 'presence.changed',
          'payload': {'memberId': 'm1', 'presence': 'busy'},
        }),
      );
      await pump();
      final e = events.single as PresenceChanged;
      expect(e.memberId, 'm1');
      expect(e.presence, Presence.busy);
    });

    test('network.offline / network.drain / wakeup.dispatched', () async {
      channel().incoming
        ..add(
          jsonEncode({
            'type': 'network.offline',
            'payload': {'reason': 'hub unreachable'},
          }),
        )
        ..add(
          jsonEncode({
            'type': 'network.drain',
            'payload': {'count': 3},
          }),
        )
        ..add(
          jsonEncode({
            'type': 'wakeup.dispatched',
            'payload': {'agentId': 'a1', 'at': '2026-01-02T03:04:05Z'},
          }),
        );
      await pump();
      expect(events, hasLength(3));
      expect((events[0] as NetworkOffline).reason, 'hub unreachable');
      expect((events[1] as NetworkDrain).count, 3);
      final dispatched = events[2] as WakeupDispatched;
      expect(dispatched.agentId, 'a1');
      expect(dispatched.at, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('error frame becomes a WsError event', () async {
      channel().incoming.add(
        jsonEncode({
          'type': 'error',
          'payload': {'message': 'bad channel'},
        }),
      );
      await pump();
      expect((events.single as WsError).message, 'bad channel');
    });

    test(
      'malformed frame becomes WsError and the stream keeps working',
      () async {
        channel().incoming
          ..add('{not json')
          ..add(
            jsonEncode({
              'type': 'presence.changed',
              'payload': {'memberId': 'm1', 'presence': 'live'},
            }),
          );
        await pump();
        expect(events, hasLength(2));
        expect(events.first, isA<WsError>());
        expect(events.last, isA<PresenceChanged>());
      },
    );

    test('pong and unknown frame types are ignored', () async {
      channel().incoming
        ..add(jsonEncode({'type': 'pong'}))
        ..add(jsonEncode({'type': 'future.frame', 'payload': {}}));
      await pump();
      expect(events, isEmpty);
    });
  });

  group('outbound frames', () {
    test('sendEnvelope writes an envelope.send frame', () async {
      final connector = _FakeConnector();
      final ws = build(connector);
      await ws.connect();
      ws.sendEnvelope(
        channelId: 'c1',
        id: 'e1',
        payload: 'aGk=',
        mentions: const ['a1'],
      );
      final frame = connector.channels.single.sentFrames.single;
      expect(frame, {
        'type': 'envelope.send',
        'channelId': 'c1',
        'id': 'e1',
        'payload': 'aGk=',
        'mentions': ['a1'],
      });
      await ws.dispose();
    });

    test('frames sent while disconnected flush in order on connect', () async {
      final connector = _FakeConnector();
      final ws = build(connector);
      ws.sendEnvelope(channelId: 'c1', id: 'e1', payload: 'MQ==');
      ws.sendEnvelope(channelId: 'c1', id: 'e2', payload: 'Mg==');
      await ws.connect();
      final ids = connector.channels.single.sentFrames
          .map((f) => f['id'])
          .toList();
      expect(ids, ['e1', 'e2']);
      await ws.dispose();
    });

    test('subscribe/unsubscribe send frames while connected', () async {
      final connector = _FakeConnector();
      final ws = build(connector);
      await ws.connect();
      ws.subscribe('c1');
      ws.unsubscribe('c2');
      expect(connector.channels.single.sentFrames, [
        {'type': 'subscribe', 'channelId': 'c1'},
        {'type': 'unsubscribe', 'channelId': 'c2'},
      ]);
      await ws.dispose();
    });
  });

  group('reconnect', () {
    test('reconnects after the server drops and resubscribes channels', () {
      fakeAsync((async) {
        final connector = _FakeConnector();
        final ws = build(connector);
        ws.connect();
        async.flushMicrotasks();
        expect(connector.channels, hasLength(1));

        ws.subscribe('c1');
        ws.subscribe('c2');
        ws.unsubscribe('c2');
        ws.sendEnvelope(channelId: 'c1', id: 'e1', payload: 'MQ==');

        connector.channels.single.closeFromServer();
        async.flushMicrotasks();
        expect(ws.isConnected, isFalse);

        // While disconnected, sends queue instead of throwing.
        ws.sendEnvelope(channelId: 'c1', id: 'e2', payload: 'Mg==');

        // Backoff: first retry after initialBackoff (zero jitter).
        async.elapse(const Duration(milliseconds: 99));
        expect(connector.channels, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(connector.channels, hasLength(2));
        expect(ws.isConnected, isTrue);

        // Resubscribe happens before the queued envelope flush.
        expect(connector.channels[1].sentFrames, [
          {'type': 'subscribe', 'channelId': 'c1'},
          {
            'type': 'envelope.send',
            'channelId': 'c1',
            'id': 'e2',
            'payload': 'Mg==',
          },
        ]);

        ws.disconnect();
        async.flushMicrotasks();
      });
    });

    test('a failing connector retries with growing backoff', () {
      fakeAsync((async) {
        final connector = _FakeConnector()..failuresBeforeSuccess = 2;
        final ws = build(connector);
        ws.connect();
        async.flushMicrotasks();
        expect(connector.channels, isEmpty);

        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();
        expect(connector.uris, hasLength(2)); // first retry failed too
        expect(connector.channels, isEmpty);

        // Second retry waits 200ms (2^1 * initialBackoff).
        async.elapse(const Duration(milliseconds: 199));
        async.flushMicrotasks();
        expect(connector.uris, hasLength(2));
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(connector.channels, hasLength(1));
        expect(ws.isConnected, isTrue);

        ws.disconnect();
        async.flushMicrotasks();
      });
    });

    test('manual disconnect does not reconnect', () {
      fakeAsync((async) {
        final connector = _FakeConnector();
        final ws = build(connector);
        ws.connect();
        async.flushMicrotasks();
        ws.disconnect();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(connector.uris, hasLength(1));
        expect(ws.isConnected, isFalse);
      });
    });
  });

  group('heartbeat', () {
    test('pings every heartbeat interval while connected', () {
      fakeAsync((async) {
        final connector = _FakeConnector();
        final ws = build(connector, heartbeat: const Duration(seconds: 30));
        ws.connect();
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 30));
        async.elapse(const Duration(seconds: 30));
        final frames = connector.channels.single.sentFrames;
        expect(frames, [
          {'type': 'ping'},
          {'type': 'ping'},
        ]);

        ws.disconnect();
        async.flushMicrotasks();

        // No more pings after disconnect.
        async.elapse(const Duration(minutes: 2));
        expect(connector.channels.single.sentFrames, hasLength(2));
      });
    });
  });
}
