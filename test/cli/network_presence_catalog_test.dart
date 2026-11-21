// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/src/cli/network_presence.dart';
import 'package:flutter_agent_harness/src/network/connector/device_api.dart';
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/network_account.dart';
import 'package:flutter_agent_harness/src/session/session_catalog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../network/connector/fake_device_server.dart';

final class _FakeCatalogStore implements SessionCatalogStore {
  _FakeCatalogStore(this.rows);

  List<SessionCatalogEntry> rows;
  var loads = 0;

  @override
  Future<List<SessionCatalogEntry>> loadSessions({
    Set<String> liveSessionIds = const {},
  }) async {
    loads++;
    return [
      for (final row in rows)
        SessionCatalogEntry(
          id: row.id,
          live: liveSessionIds.contains(row.id),
          isSubagent: row.isSubagent,
          title: row.title,
          snippet: row.snippet,
          sessionName: row.sessionName,
          cwd: row.cwd,
          lastActiveAt: row.lastActiveAt,
        ),
    ];
  }
}

SessionCatalogEntry _row(
  String id, {
  String? title,
  String? snippet,
  DateTime? lastActiveAt,
  bool isSubagent = false,
}) => SessionCatalogEntry(
  id: id,
  live: false,
  isSubagent: isSubagent,
  title: title ?? 'Session $id',
  snippet: snippet,
  cwd: '/work/$id',
  lastActiveAt: lastActiveAt ?? DateTime.utc(2026, 11, 12, 12),
);

void main() {
  const device = NetworkDeviceCredentials(
    deviceId: 'device-1',
    deviceToken: 'device-secret',
    personalNetworkId: 'personal-1',
  );

  test('connect publishes the full named catalog in bounded pages; refresh '
      'publishes only changes plus deletion retractions', () async {
    final server = FakeDeviceServer()
      ..seedDevice(device.deviceId, networks: const ['personal-1']);
    final store = _FakeCatalogStore([
      for (var i = 0; i < 45; i++)
        _row(
          'session-$i',
          lastActiveAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
        ),
    ]);
    final requests = <http.Request>[];
    final controller = NetworkPresenceController(
      device: device,
      baseUrl: 'https://relay.test',
      ticketProvider: () async => 'ticket',
      transport: server.transport,
      rosterClient: DeviceEnrollmentClient(
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(jsonEncode({'patched': 'device-1'}), 200);
        }),
      ),
      rosterDebounce: const Duration(milliseconds: 5),
      catalogStore: store,
      catalogPollInterval: Duration.zero,
    );
    addTearDown(controller.dispose);

    await controller.startSession(
      const CliNetworkSession(
        sessionId: 'session-44',
        mailboxPrefix: 'mailbox-1',
      ),
    );
    await _waitUntil(() {
      final count = requests
          .expand((request) => _sessions(request))
          .map((row) => row['id'])
          .toSet()
          .length;
      return count == 45;
    });

    final initialPages = requests.map((request) => _sessions(request).length);
    expect(initialPages, containsAllInOrder([40, 5]));
    final published = {
      for (final row in requests.expand((request) => _sessions(request)))
        row['id']: row,
    };
    expect(published, hasLength(45));
    expect(published['session-44']?['state'], 'live');
    expect(published['session-0']?['state'], 'wake_on_dm');
    expect(published['session-0']?['title'], 'Session session-0');
    expect(published['session-0']?['path'], '/work/session-0');
    expect(published['session-0']?['cwd'], 'session-0');
    expect(published['session-0']?['lastActivity'], isA<String>());

    await _waitUntil(
      () => server.received.any(
        (frame) =>
            frame.kind == NetworkEnvelopeKind.presence &&
            (frame.payload['sessions'] as List).length == 45,
      ),
    );
    final presence = server.received.lastWhere(
      (frame) =>
          frame.kind == NetworkEnvelopeKind.presence &&
          (frame.payload['sessions'] as List).length == 45,
    );
    final socketRows = (presence.payload['sessions'] as List).cast<Map>();
    expect(
      socketRows.singleWhere((row) => row['id'] == 'session-0')['state'],
      'wake_on_dm',
    );
    expect(
      socketRows.singleWhere((row) => row['id'] == 'session-0')['title'],
      'Session session-0',
    );

    final beforeDelta = requests.length;
    store.rows = [
      for (final row in store.rows)
        if (row.id != 'session-1')
          row.id == 'session-2'
              ? _row('session-2', title: 'Renamed session')
              : row,
    ];
    controller.notifySessionCatalogChanged();
    controller.notifySessionCatalogChanged();
    await _waitUntil(() => requests.length > beforeDelta);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(requests.length, beforeDelta + 1);
    final delta = _sessions(requests.last);
    expect(delta, hasLength(2));
    expect(
      delta.singleWhere((row) => row['id'] == 'session-2')['title'],
      'Renamed session',
    );
    final deleted = delta.singleWhere((row) => row['id'] == 'session-1');
    expect(deleted['state'], 'offline');
    expect(deleted['networks'], isEmpty);
    expect(store.loads, greaterThanOrEqualTo(2));
  });

  test(
    'unlisted named live session still publishes its friendly title/cwd',
    () async {
      final server = FakeDeviceServer()
        ..seedDevice(device.deviceId, networks: const ['personal-1']);
      // The persisted catalog has NO row for the live session (fresh start,
      // stale rediscovery) — the old code projected a bare UUID-only row.
      final store = _FakeCatalogStore([_row('session-old')]);
      final requests = <http.Request>[];
      final controller = NetworkPresenceController(
        device: device,
        baseUrl: 'https://relay.test',
        ticketProvider: () async => 'ticket',
        transport: server.transport,
        rosterClient: DeviceEnrollmentClient(
          httpClient: MockClient((request) async {
            requests.add(request);
            return http.Response(jsonEncode({'patched': 'device-1'}), 200);
          }),
        ),
        rosterDebounce: const Duration(milliseconds: 5),
        catalogStore: store,
        catalogPollInterval: Duration.zero,
      );
      addTearDown(controller.dispose);

      await controller.startSession(
        const CliNetworkSession(
          sessionId: 'session-live',
          mailboxPrefix: 'mailbox-1',
          displayName: 'mymac work',
          cwd: '/work/live',
        ),
      );

      await _waitUntil(
        () => requests
            .expand((request) => _sessions(request))
            .any((row) => row['id'] == 'session-live'),
      );
      final published = {
        for (final row in requests.expand((request) => _sessions(request)))
          row['id']: row,
      };
      expect(published['session-live']?['title'], 'mymac work');
      expect(published['session-live']?['path'], '/work/live');
      // Catalog rows keep their own metadata — no overlay clobbering.
      expect(published['session-old']?['title'], 'Session session-old');
    },
  );

  test('full connect retracts active and orphaned subagent sessions', () async {
    final server = FakeDeviceServer()
      ..seedDevice(device.deviceId, networks: const ['personal-1']);
    final store = _FakeCatalogStore([
      _row('parent', title: 'Parent session'),
      _row('child', title: 'Active child', isSubagent: true),
      _row('orphan', title: 'Legacy orphan', isSubagent: true),
    ]);
    final requests = <http.Request>[];
    final controller = NetworkPresenceController(
      device: device,
      baseUrl: 'https://relay.test',
      ticketProvider: () async => 'ticket',
      transport: server.transport,
      rosterClient: DeviceEnrollmentClient(
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(jsonEncode({'patched': 'device-1'}), 200);
        }),
      ),
      rosterDebounce: Duration.zero,
      catalogStore: store,
      catalogPollInterval: Duration.zero,
    );
    addTearDown(controller.dispose);

    await controller.startSession(
      const CliNetworkSession(sessionId: 'parent', mailboxPrefix: 'mailbox-1'),
    );
    await _waitUntil(
      () => requests.expand(_sessions).any((row) => row['id'] == 'orphan'),
    );

    final rows = {
      for (final row in requests.expand(_sessions)) row['id'] as String: row,
    };
    expect(rows['parent']?['state'], 'live');
    expect(rows['parent']?['networks'], ['personal-1']);
    for (final id in const ['child', 'orphan']) {
      expect(rows[id]?['state'], 'offline');
      expect(rows[id]?['networks'], isEmpty);
      expect(rows[id]?['title'], isNull);
    }
  });
}

List<Map<String, Object?>> _sessions(http.Request request) =>
    ((jsonDecode(request.body) as Map<String, Object?>)['sessions'] as List)
        .map((row) => (row as Map).cast<String, Object?>())
        .toList();

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('catalog condition not met within 2s');
}
