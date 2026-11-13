// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// DevicesPage widget tests (issue #2062 chunk 16): the machine roster
/// tree — the three §5 presence levels nested under machine nodes, the
/// tree expansion, the "This device only" empty state and the phase
/// gates. Driven by a fake service's streams (no connector, no sockets),
/// mirroring the chunk-15 panel test harness.
library;

import 'dart:async';

import 'package:fa/network/device_connector_service.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/devices_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';

/// A scripted service: the tests drive [setPhase], [emitPresence] (the
/// typed own-machine frame) and [emitEnvelope] (raw network-wide frames
/// — remote machines) directly; everything else is inert.
final class FakeDevicesService implements DeviceConnectorService {
  FakeDevicesService({
    DeviceConnectorPhase initialPhase = DeviceConnectorPhase.signedOut,
    this.deviceId,
  }) : _phase = initialPhase;

  DeviceConnectorPhase _phase;

  /// The enrolled device id the page filters its own frames by.
  @override
  final String? deviceId;

  // Synchronous controllers (repo convention): broadcast delivery lands
  // within the same tester.pump().
  final _phaseController = StreamController<DeviceConnectorPhase>.broadcast(
    sync: true,
  );
  final _presence = StreamController<PresenceFrame>.broadcast(sync: true);
  final _presenceFrames = StreamController<NetworkEnvelope>.broadcast(
    sync: true,
  );

  /// Emits a phase transition.
  void setPhase(DeviceConnectorPhase phase) {
    _phase = phase;
    _phaseController.add(phase);
  }

  /// Emits the own machine's parsed presence frame.
  void emitPresence(PresenceFrame frame) => _presence.add(frame);

  /// Emits a raw network-wide presence envelope (remote machines).
  void emitEnvelope(NetworkEnvelope envelope) => _presenceFrames.add(envelope);

  @override
  DeviceConnectorPhase get phase => _phase;

  @override
  Stream<DeviceConnectorPhase> get phaseStream => _phaseController.stream;

  @override
  Stream<PresenceFrame> get presence => _presence.stream;

  @override
  Stream<NetworkEnvelope> get presenceFrames => _presenceFrames.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _wrap(Widget child) => MaterialApp(
  theme: buildFahTheme(),
  home: Scaffold(body: SizedBox(width: 360, height: 640, child: child)),
);

PresenceFrame _frame({
  MachinePresence machine = MachinePresence.online,
  Map<String, AgentRunState> agents = const {},
  Map<String, ConnectorSessionPresence> sessions = const {},
}) => PresenceFrame(
  msgId: 'p-1',
  ts: rfc3339Timestamp(DateTime.utc(2026, 11, 12)),
  machine: machine,
  agents: agents,
  sessions: sessions,
);

/// A raw presence envelope, optionally tagged with a foreign deviceId
/// (the network-wide view's remote-machine marker).
NetworkEnvelope _envelope({
  MachinePresence machine = MachinePresence.online,
  String? deviceId,
  Map<String, AgentRunState> agents = const {},
  Map<String, ConnectorSessionPresence> sessions = const {},
  String msgId = 'p-raw',
}) => NetworkEnvelope(
  kind: NetworkEnvelopeKind.presence,
  msgId: msgId,
  ts: rfc3339Timestamp(DateTime.utc(2026, 11, 12)),
  payload: {
    'machine': machine.wireName,
    'deviceId': ?deviceId,
    'agents': [
      for (final entry in agents.entries)
        {'address': entry.key, 'state': entry.value.wireName},
    ],
    'sessions': [
      for (final entry in sessions.entries)
        {'id': entry.key, 'state': entry.value.wireName},
    ],
  },
);

Color dotColor(WidgetTester tester, Key key) {
  final container = tester.widget<Container>(find.byKey(key));
  final decoration = container.decoration;
  expect(decoration, isA<BoxDecoration>());
  final color = (decoration as BoxDecoration).color;
  if (color == null) fail('expected a non-null dot color');
  return color;
}

/// The palette resolved from the page's own context — tests assert
/// palette roles (teal/pending/dim), never literal hex values.
FahColors paletteOf(WidgetTester tester) =>
    FahColors.of(tester.element(find.byKey(const ValueKey('devicesPage'))));

void main() {
  testWidgets('not signed in → nothing renders', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.signedOut,
    );

    await tester.pumpWidget(_wrap(DevicesPage(service: service)));
    await tester.pump();

    expect(find.byKey(const ValueKey('devicesPage')), findsNothing);
    expect(find.text('MY DEVICES'), findsNothing);
  });

  testWidgets('connecting → skeleton line, no tree rows', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.connecting,
    );

    await tester.pumpWidget(_wrap(DevicesPage(service: service)));
    await tester.pump();

    expect(find.byKey(const ValueKey('devicesPage')), findsOneWidget);
    expect(find.text('MY DEVICES'), findsOneWidget);
    expect(find.byKey(const ValueKey('devicesSkeleton')), findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('This device'), findsNothing);
  });

  testWidgets('reconnecting → muted line over the (empty) tree', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.reconnecting,
    );

    await tester.pumpWidget(_wrap(DevicesPage(service: service)));
    await tester.pump();

    expect(find.byKey(const ValueKey('devicesReconnecting')), findsOneWidget);
    expect(find.text('Reconnecting…'), findsOneWidget);
  });

  testWidgets('online → This device node expanded with nested '
      'agent/session rows and their presence dots', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(_wrap(DevicesPage(service: service)));
    await tester.pump();
    final palette = paletteOf(tester);

    // No presence frame yet: the machine node renders (link up ⇒ online).
    expect(find.text('This device'), findsOneWidget);
    expect(dotColor(tester, const ValueKey('deviceDot')), palette.teal);

    service.emitPresence(
      _frame(
        machine: MachinePresence.online,
        agents: const {
          'goal_builder@dev-1': AgentRunState.busy,
          'scout@dev-1': AgentRunState.live,
        },
        sessions: const {
          'sess-main': ConnectorSessionPresence.live,
          'sess-idle': ConnectorSessionPresence.wakeOnDm,
        },
      ),
    );
    await tester.pump();

    // The own node's dot follows the frame's machine state; the nested
    // rows carry the agent/session dots and labels.
    expect(dotColor(tester, const ValueKey('deviceDot')), palette.teal);
    expect(find.text('goal_builder'), findsOneWidget);
    expect(find.text('scout'), findsOneWidget);
    expect(
      dotColor(tester, const ValueKey('agentDot:goal_builder@dev-1')),
      palette.pending,
    );
    expect(
      dotColor(tester, const ValueKey('agentDot:scout@dev-1')),
      palette.teal,
    );
    expect(find.text('Busy'), findsOneWidget);
    expect(
      dotColor(tester, const ValueKey('sessionDot:sess-idle')),
      palette.pending,
    );
    expect(find.text('Wake on DM'), findsOneWidget);
  });

  testWidgets('online with no remote frames → only the This device node', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(_wrap(DevicesPage(service: service)));
    await tester.pump();

    expect(find.text('This device'), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceNode:dev-remote')), findsNothing);
  });

  testWidgets('a foreign deviceId-tagged presence frame adds a remote '
      'machine node, collapsed until tapped', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(_wrap(DevicesPage(service: service)));
    await tester.pump();
    final palette = paletteOf(tester);

    service.emitEnvelope(
      _envelope(
        machine: MachinePresence.degraded,
        deviceId: 'dev-remote',
        agents: const {'agent@dev-remote': AgentRunState.live},
        msgId: 'p-remote',
      ),
    );
    await tester.pump();

    // The remote node renders with its own degraded dot, children
    // collapsed. The own device's frames (no foreign deviceId) are
    // ignored by the remote accumulator.
    expect(find.byKey(const ValueKey('deviceNode:dev-remote')), findsOneWidget);
    expect(
      dotColor(tester, const ValueKey('deviceDot:dev-remote')),
      palette.pending,
    );
    expect(find.text('agent'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('deviceNodeToggle:dev-remote')));
    await tester.pump();

    expect(find.text('agent'), findsOneWidget);
    expect(
      dotColor(tester, const ValueKey('agentDot:agent@dev-remote')),
      palette.teal,
    );
  });

  testWidgets("the own device's envelope (matching deviceId) never becomes "
      'a remote node', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(_wrap(DevicesPage(service: service)));
    await tester.pump();

    service.emitEnvelope(
      _envelope(
        machine: MachinePresence.online,
        deviceId: 'dev-1',
        msgId: 'p-own',
      ),
    );
    await tester.pump();

    expect(find.text('dev-1'), findsNothing);
    expect(find.text('This device'), findsOneWidget);
  });
}
