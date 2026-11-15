// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Debug projection of device-roster frames returned by the fa_network
/// device socket. The parser is deliberately additive/tolerant: it accepts
/// a direct `payload.devices` list and the same list nested per network.
library;

import 'connector/envelope.dart';

/// One device row in `fa network devices`.
final class NetworkDeviceRow {
  /// Builds a row.
  const NetworkDeviceRow({
    required this.deviceId,
    required this.name,
    required this.presence,
    required this.networkIds,
    required this.agentAddresses,
    required this.sessionIds,
  });

  /// Server device id.
  final String deviceId;

  /// Friendly name, falling back to the enrollment name/id.
  final String name;

  /// Machine presence (`online`, `degraded`, `offline`, or `unknown`).
  final String presence;

  /// Networks in which this row was observed.
  final Set<String> networkIds;

  /// Exposed agent addresses on the device.
  final Set<String> agentAddresses;

  /// Exposed session ids on the device.
  final Set<String> sessionIds;

  /// One stable, non-secret debug line.
  String format() {
    final networks = networkIds.isEmpty ? '-' : networkIds.join(',');
    return '$deviceId  $name  $presence  '
        'networks=$networks agents=${agentAddresses.length} '
        'sessions=${sessionIds.length}';
  }
}

/// Parses and merges all device rows in [frames], sorted by device id.
/// Unknown/malformed entries are skipped without hiding valid siblings.
List<NetworkDeviceRow> parseNetworkDeviceRoster(
  Iterable<NetworkEnvelope> frames,
) {
  final mutable = <String, _MutableDeviceRow>{};
  for (final frame in frames) {
    if (frame.kind != NetworkEnvelopeKind.roster) continue;
    final network = frame.network;
    _readContainer(frame.payload, network, mutable);
  }
  final rows = mutable.values.map((row) => row.freeze()).toList()
    ..sort((a, b) => a.deviceId.compareTo(b.deviceId));
  return List.unmodifiable(rows);
}

void _readContainer(
  Map<String, Object?> payload,
  String? inheritedNetwork,
  Map<String, _MutableDeviceRow> rows,
) {
  _readDeviceList(payload['devices'], inheritedNetwork, rows);
  final single = payload['device'];
  if (single is Map) _readDevice(single, inheritedNetwork, rows);
  final networks = payload['networks'];
  if (networks is List) {
    for (final value in networks) {
      if (value is! Map) continue;
      final id = value['id'] ?? value['networkId'];
      _readContainer(
        value.cast<String, Object?>(),
        id is String && id.isNotEmpty ? id : inheritedNetwork,
        rows,
      );
    }
  }
  final roster = payload['roster'];
  if (roster is Map) {
    _readContainer(roster.cast<String, Object?>(), inheritedNetwork, rows);
  }
  // A device can itself be the payload in compact roster-patch frames.
  if (payload['deviceId'] is String) {
    _readDevice(payload, inheritedNetwork, rows);
  }
}

void _readDeviceList(
  Object? value,
  String? network,
  Map<String, _MutableDeviceRow> rows,
) {
  if (value is! List) return;
  for (final entry in value) {
    if (entry is Map) _readDevice(entry, network, rows);
  }
}

void _readDevice(
  Map<Object?, Object?> device,
  String? network,
  Map<String, _MutableDeviceRow> rows,
) {
  final id = device['deviceId'] ?? device['id'];
  if (id is! String || id.isEmpty) return;
  final friendly = _nonEmpty(device['friendlyName']);
  final enrolled = _nonEmpty(device['name']);
  final presence = _nonEmpty(device['presence']) ?? 'unknown';
  final row = rows.putIfAbsent(
    id,
    () => _MutableDeviceRow(
      deviceId: id,
      name: friendly ?? enrolled ?? id,
      presence: presence,
    ),
  );
  if (friendly != null) row.name = friendly;
  if (presence != 'unknown' || row.presence == 'unknown') {
    row.presence = presence;
  }
  if (network != null && network.isNotEmpty) row.networkIds.add(network);
  final rowNetwork = _nonEmpty(device['networkId']);
  if (rowNetwork != null) row.networkIds.add(rowNetwork);
  _readAgents(device['agents'], row.agentAddresses);
  _readSessions(device['sessions'], row.sessionIds);
}

void _readAgents(Object? value, Set<String> target) {
  if (value is! List) return;
  for (final agent in value) {
    if (agent is Map) {
      final address = _nonEmpty(agent['address']);
      if (address != null) {
        target.add(address);
        continue;
      }
      final name = _nonEmpty(agent['name']);
      final device = _nonEmpty(agent['deviceId']);
      if (name != null && device != null) target.add('$name@$device');
    } else if (agent is String && agent.isNotEmpty) {
      target.add(agent);
    }
  }
}

void _readSessions(Object? value, Set<String> target) {
  if (value is! List) return;
  for (final session in value) {
    if (session is Map) {
      final id = _nonEmpty(session['id']) ?? _nonEmpty(session['sessionId']);
      if (id != null) target.add(id);
    } else if (session is String && session.isNotEmpty) {
      target.add(session);
    }
  }
}

String? _nonEmpty(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

final class _MutableDeviceRow {
  _MutableDeviceRow({
    required this.deviceId,
    required this.name,
    required this.presence,
  });

  final String deviceId;
  String name;
  String presence;
  final networkIds = <String>{};
  final agentAddresses = <String>{};
  final sessionIds = <String>{};

  NetworkDeviceRow freeze() => NetworkDeviceRow(
    deviceId: deviceId,
    name: name,
    presence: presence,
    networkIds: Set.unmodifiable(networkIds),
    agentAddresses: Set.unmodifiable(agentAddresses),
    sessionIds: Set.unmodifiable(sessionIds),
  );
}
