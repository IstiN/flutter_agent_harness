// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/network_roster.dart';
import 'package:test/test.dart';

void main() {
  test('CLI roster renders named session rows with state, relative activity '
      'and cwd; UUIDs remain only a short disambiguator', () {
    const uuid = '123e4567-e89b-12d3-a456-426614174000';
    final rows = parseNetworkDeviceRoster([
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.roster,
        msgId: 'roster',
        ts: '2026-11-12T12:00:00Z',
        network: 'personal',
        payload: {
          'devices': [
            {
              'deviceId': 'device-1',
              'name': 'Workstation',
              'presence': 'online',
              'sessions': [
                {
                  'id': uuid,
                  'state': 'wake_on_dm',
                  'snippet': 'Fix the roster projection',
                  'path': '/work/flutter_agent',
                  'lastActivity': '2026-11-12T11:56:00Z',
                },
                {
                  'id': 'live-id',
                  'state': 'live',
                  'title': 'Current plan',
                  'cwd': 'flutter_agent',
                  'lastActivity': '2026-11-12T12:00:00Z',
                },
                {
                  'id': 'offline-id',
                  'state': 'offline',
                  'title': 'Old plan',
                  'path': '/work/old',
                  'lastActivity': '2026-11-11T12:00:00Z',
                },
              ],
            },
          ],
        },
      ),
    ]);

    final device = rows.single;
    expect(device.sessionRows.map((row) => row.id), [
      'live-id',
      uuid,
      'offline-id',
    ]);
    expect(device.sessionRows[1].displayName, 'Fix the roster projection');
    final lines = device.formatSessions(now: DateTime.utc(2026, 11, 12, 12));
    expect(lines[0], contains('Current plan'));
    expect(lines[0], contains('live'));
    expect(lines[0], contains('now'));
    expect(lines[1], contains('Fix the roster projection'));
    expect(lines[1], contains('wake_on_dm'));
    expect(lines[1], contains('4m ago'));
    expect(lines[1], contains('cwd=flutter_agent'));
    expect(lines[1], contains('id=123e4567'));
    expect(lines[1], isNot(startsWith(uuid)));
    expect(lines[2], contains('offline'));
    expect(lines[2], contains('1d ago'));
  });
}
