// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/src/cli/network_presence.dart';
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/connector/upstream_client.dart';
import 'package:flutter_agent_harness/src/network/network_account.dart';
import 'package:flutter_agent_harness/src/network/network_roster.dart';
import 'package:test/test.dart';

void main() {
  test(
    'live CLI session publishes mailbox agent + session presence rows',
    () async {
      final socket = _FakeSocket();
      final transport = _FakeTransport(socket);
      final controller = NetworkPresenceController(
        device: const NetworkDeviceCredentials(
          deviceId: 'device-1',
          deviceToken: 'device-secret',
          personalNetworkId: 'personal-1',
        ),
        baseUrl: 'https://relay.test',
        ticketProvider: () async => 'ticket-1',
        transport: transport,
        idFactory: sequentialIds(),
      );

      await controller.startSession(
        const CliNetworkSession(
          sessionId: 'session-1',
          mailboxPrefix: 'mailbox-1',
        ),
      );
      final frame = await _waitForPresence(socket, state: 'live');

      // Presence is device-level; network membership is registry-enforced.
      expect(frame.network, isNull);
      expect(frame.from, isNull);
      final agents = (frame.payload['agents']! as List).cast<Map>();
      expect(agents, hasLength(1));
      expect(agents.single['address'], 'mailbox-1@device-1');
      expect(agents.single['state'], 'live');
      final sessions = (frame.payload['sessions']! as List).cast<Map>();
      expect(sessions, hasLength(1));
      expect(sessions.single['id'], 'session-1');
      expect(sessions.single['state'], 'live');
      expect(transport.dials.single.scheme, 'wss');
      expect(transport.dials.single.host, 'relay.test');
      expect(transport.dials.single.path, '/ws');
      expect(transport.dials.single.queryParameters['ticket'], 'ticket-1');
      expect(
        transport.dials.single.toString(),
        isNot(contains('device-secret')),
      );

      controller.setBusy(true);
      await _waitForPresence(socket, state: 'busy');
      await controller.dispose();
      expect(socket.closed, isTrue);
    },
  );

  test('roster frames become a debug device list', () async {
    final socket = _FakeSocket(
      roster: NetworkEnvelope(
        kind: NetworkEnvelopeKind.roster,
        msgId: 'roster-1',
        ts: '2026-01-01T00:00:00Z',
        network: 'personal-1',
        payload: {
          'devices': [
            {
              'deviceId': 'device-2',
              'name': 'build-box',
              'friendlyName': 'Builder',
              'presence': 'online',
              'agents': [
                {'address': 'agent-1@device-2'},
              ],
              'sessions': [
                {'id': 'session-9'},
              ],
            },
          ],
        },
      ),
    );
    final controller = NetworkPresenceController(
      device: const NetworkDeviceCredentials(
        deviceId: 'device-1',
        deviceToken: 'device-secret',
        personalNetworkId: 'personal-1',
      ),
      baseUrl: 'https://relay.test',
      ticketProvider: () async => 'ticket-1',
      transport: _FakeTransport(socket),
      idFactory: sequentialIds(),
    );

    final rows = await readNetworkDeviceRoster(
      controller,
      timeout: const Duration(seconds: 1),
      settleTime: Duration.zero,
    );
    expect(rows, hasLength(1));
    expect(rows.single.deviceId, 'device-2');
    expect(rows.single.name, 'Builder');
    expect(rows.single.presence, 'online');
    expect(rows.single.networkIds, {'personal-1'});
    expect(rows.single.agentAddresses, {'agent-1@device-2'});
    expect(rows.single.sessionIds, {'session-9'});
    expect(
      rows.single.format(),
      'device-2  Builder  online  networks=personal-1 agents=1 sessions=1',
    );
  });

  test('roster parser tolerates nested, compact, and malformed variants', () {
    final rows = parseNetworkDeviceRoster([
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.presence,
        msgId: 'ignored',
        ts: '2026-01-01T00:00:00Z',
      ),
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.roster,
        msgId: 'roster-variants',
        ts: '2026-01-01T00:00:00Z',
        network: 'inherited',
        payload: {
          'devices': [
            'not-a-device',
            {'name': 'missing-id'},
          ],
          'device': {
            'id': 'single',
            'agents': 'not-a-list',
            'sessions': 'not-a-list',
          },
          'networks': [
            'not-a-network',
            {
              'id': 'nested-a',
              'device': {
                'deviceId': 'nested',
                'networkId': 'row-network',
                'agents': [
                  {'address': 'direct@nested'},
                  {'name': 'worker', 'deviceId': 'nested'},
                  {'name': 'missing-device'},
                  {'deviceId': 'missing-name'},
                  'raw-agent',
                  '',
                  42,
                ],
                'sessions': [
                  {'sessionId': 'fallback'},
                  'raw-session',
                ],
              },
            },
            {
              'networkId': 'nested-b',
              'devices': [
                {'deviceId': 'second'},
              ],
            },
            {
              'id': '',
              'device': {'deviceId': 'inherits-empty'},
            },
            {
              'device': {'deviceId': 'inherits-missing'},
            },
          ],
          'roster': {'deviceId': 'nested-roster', 'name': 'Roster'},
          'deviceId': 'compact',
        },
      ),
    ]);

    expect(rows.map((row) => row.deviceId), [
      'compact',
      'inherits-empty',
      'inherits-missing',
      'nested',
      'nested-roster',
      'second',
      'single',
    ]);
    final nested = rows.singleWhere((row) => row.deviceId == 'nested');
    expect(nested.networkIds, {'nested-a', 'row-network'});
    expect(nested.agentAddresses, {
      'direct@nested',
      'worker@nested',
      'raw-agent',
    });
    expect(nested.sessionIds, {'fallback', 'raw-session'});
    expect(rows.singleWhere((row) => row.deviceId == 'second').networkIds, {
      'nested-b',
    });
    expect(
      rows.singleWhere((row) => row.deviceId == 'inherits-empty').networkIds,
      {'inherited'},
    );
    expect(
      rows.singleWhere((row) => row.deviceId == 'inherits-missing').networkIds,
      {'inherited'},
    );
  });
}

Future<NetworkEnvelope> _waitForPresence(
  _FakeSocket socket, {
  required String state,
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    for (final frame in socket.sent) {
      if (frame.kind != NetworkEnvelopeKind.presence) continue;
      final agents = frame.payload['agents'];
      if (agents is List &&
          agents.any((agent) => agent is Map && agent['state'] == state)) {
        return frame;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('no $state presence frame; sent=${socket.sent}');
}

final class _FakeTransport implements ConnectorTransport {
  _FakeTransport(this.socket);

  final _FakeSocket socket;
  final dials = <Uri>[];

  @override
  Future<ConnectorSocket> dial(Uri url, String ticket) async {
    dials.add(url);
    return socket;
  }
}

final class _FakeSocket implements ConnectorSocket {
  _FakeSocket({this.roster});

  final NetworkEnvelope? roster;
  final sent = <NetworkEnvelope>[];
  final _incoming = StreamController<NetworkEnvelope>.broadcast();
  bool closed = false;

  @override
  Stream<NetworkEnvelope> get frames => _incoming.stream;

  @override
  bool get isOpen => !closed;

  @override
  Future<void> send(NetworkEnvelope envelope) async {
    if (closed) throw StateError('closed');
    sent.add(envelope);
    if (envelope.kind == NetworkEnvelopeKind.hello) {
      scheduleMicrotask(() {
        if (closed) return;
        _incoming.add(
          NetworkEnvelope(
            kind: NetworkEnvelopeKind.helloOk,
            msgId: 'hello-ok-1',
            refId: envelope.msgId,
            ts: '2026-01-01T00:00:00Z',
          ),
        );
        final roster = this.roster;
        if (roster != null) _incoming.add(roster);
      });
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _incoming.close();
  }
}

String Function() sequentialIds() {
  var sequence = 0;
  return () => 'id-${++sequence}';
}
