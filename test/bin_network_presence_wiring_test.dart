// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// REG guard for the device eviction storm (fa_network: ONE WebSocket per
// deviceId, contract §10): every CLI network-presence construction site
// must route through the shared seam — `resolveCliNetworkPresence` for
// sessions (`fa` boot, which mailbox-woken sessions take too) and
// `readCliNetworkRoster` for the `fa network` roster reads (CLI runner
// AND the hub plugin's runner, which used to build its own direct
// controller and evict the per-machine daemon's socket). With the daemon
// alive for the device a CLI process therefore never dials upstream.
//
// Hermetic source grep (no sockets): the executable library (`bin/fah.dart`
// plus its part files) and the standalone hub plugin library must build NO
// `NetworkPresenceController` and own NO upstream transport except the
// daemon's own host (`bin/fah_connector.dart`). The behaviour itself is
// proven in test/network/connector/cli_presence_routing_test.dart.
import 'dart:io';

import 'package:test/test.dart';

String _executableSource() {
  final primary = File('bin/fah.dart').readAsStringSync();
  final buffer = StringBuffer(primary);
  for (final match in RegExp(
    "^part '(fah_[^']+\\.dart)';",
    multiLine: true,
  ).allMatches(primary)) {
    buffer.write('\n${File('bin/${match[1]}').readAsStringSync()}');
  }
  return buffer.toString();
}

/// Doc comments mention the class by name; only constructions count.
int _constructions(String source, String type) =>
    RegExp('$type\\(').allMatches(source).length;

void main() {
  final exeSource = _executableSource();
  final hubSource = File('bin/fah_hub_plugin.dart').readAsStringSync();
  final daemonSource = File('bin/fah_connector.dart').readAsStringSync();

  test('bin builds no direct NetworkPresenceController anywhere', () {
    expect(_constructions(exeSource, 'NetworkPresenceController'), 0);
    expect(_constructions(hubSource, 'NetworkPresenceController'), 0);
  });

  test('the daemon host is the only upstream transport owner in bin/', () {
    expect(_constructions(exeSource, 'IoConnectorTransport'), 1);
    expect(_constructions(hubSource, 'IoConnectorTransport'), 0);
    expect(_constructions(daemonSource, 'IoConnectorTransport'), 1);
  });

  test('every CLI presence site routes through the shared seam', () {
    // `fa` boot (`_restoreNetworkPresence`): daemon → loopback client,
    // else the direct fallback, with the spawn-on-demand callback a
    // mailbox-woken session relies on.
    expect(exeSource, contains('resolveCliNetworkPresence('));
    expect(exeSource, contains('ensureDaemonRunning:'));
    expect(exeSource, contains('directCliNetworkPresence('));
    // Roster reads: the CLI runner and the hub plugin's runner.
    expect(_constructions(exeSource, 'readCliNetworkRoster'), 1);
    expect(_constructions(hubSource, 'readCliNetworkRoster'), 1);
    expect(hubSource, contains('connectorDaemonStateFile('));
  });
}
