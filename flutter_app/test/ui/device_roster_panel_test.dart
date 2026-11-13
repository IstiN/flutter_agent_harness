// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// DeviceRosterPanel widget tests (issue #2062 chunk 15): the three
/// presence levels (device/agent/session), the connecting skeleton, the
/// reconnecting muted line and the not-signed-in absence — driven by a
/// fake service's phase/presence streams (no connector, no sockets).
library;

import 'dart:async';

import 'package:fa/network/device_connector_service.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/device_roster_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart';

/// A scripted service: the tests drive [phases] and [presenceFrames]
/// directly; every other dependency is inert.
final class FakeRosterService implements DeviceConnectorService {
  FakeRosterService({
    DeviceConnectorPhase initialPhase = DeviceConnectorPhase.signedOut,
  }) : _phase = initialPhase;

  DeviceConnectorPhase _phase;
  // Synchronous controllers (repo convention, fakes.dart): broadcast
  // delivery must land within the same tester.pump() — a non-sync
  // controller's microtask delivery is invisible to widget tests.
  final _phaseController = StreamController<DeviceConnectorPhase>.broadcast(
    sync: true,
  );
  final _presence = StreamController<PresenceFrame>.broadcast(sync: true);

  /// Emits a phase transition.
  void setPhase(DeviceConnectorPhase phase) {
    _phase = phase;
    _phaseController.add(phase);
  }

  /// Emits a parsed server presence frame.
  void emitPresence(PresenceFrame frame) => _presence.add(frame);

  @override
  DeviceConnectorPhase get phase => _phase;

  @override
  Stream<DeviceConnectorPhase> get phaseStream => _phaseController.stream;

  @override
  Stream<PresenceFrame> get presence => _presence.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _wrap(Widget child) => MaterialApp(
  theme: buildFahTheme(),
  home: Scaffold(body: SizedBox(width: 320, child: child)),
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

Color dotColor(WidgetTester tester, Key key) {
  final container = tester.widget<Container>(find.byKey(key));
  final decoration = container.decoration;
  expect(decoration, isA<BoxDecoration>());
  final color = (decoration as BoxDecoration).color;
  if (color == null) fail('expected a non-null dot color');
  return color;
}

/// The theme palette resolved from the panel's own context — the tests
/// assert palette roles (teal/pending/dim), never literal hex values.
FahColors paletteOf(WidgetTester tester) => FahColors.of(
  tester.element(find.byKey(const ValueKey('deviceRosterPanel'))),
);

void main() {
  testWidgets('not signed in → nothing renders', (tester) async {
    final service = FakeRosterService(
      initialPhase: DeviceConnectorPhase.signedOut,
    );

    await tester.pumpWidget(_wrap(DeviceRosterPanel(service: service)));
    await tester.pump();

    expect(find.byKey(const ValueKey('deviceRosterPanel')), findsNothing);
    expect(find.text('MY DEVICES'), findsNothing);
  });

  testWidgets('connecting → skeleton line under the section header', (
    tester,
  ) async {
    final service = FakeRosterService(
      initialPhase: DeviceConnectorPhase.connecting,
    );

    await tester.pumpWidget(_wrap(DeviceRosterPanel(service: service)));
    await tester.pump();

    expect(find.byKey(const ValueKey('deviceRosterPanel')), findsOneWidget);
    expect(find.text('MY DEVICES'), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceRosterSkeleton')), findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceRow')), findsNothing);
  });

  testWidgets('reconnecting → muted line, no roster rows', (tester) async {
    final service = FakeRosterService(
      initialPhase: DeviceConnectorPhase.reconnecting,
    );

    await tester.pumpWidget(_wrap(DeviceRosterPanel(service: service)));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('deviceRosterReconnecting')),
      findsOneWidget,
    );
    expect(find.text('Reconnecting…'), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceRow')), findsNothing);
  });

  testWidgets('online → device row (online dot) + nested agent/session '
      'rows with their presence dots', (tester) async {
    final service = FakeRosterService(
      initialPhase: DeviceConnectorPhase.online,
    );

    await tester.pumpWidget(_wrap(DeviceRosterPanel(service: service)));
    await tester.pump();
    final palette = paletteOf(tester);
    // No presence frame yet: the machine row renders (link up ⇒ online).
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
          'sess-down': ConnectorSessionPresence.offline,
        },
      ),
    );
    await tester.pump();

    // Device row: teal online dot + label.
    expect(dotColor(tester, const ValueKey('deviceDot')), palette.teal);
    expect(find.text('This device'), findsOneWidget);

    // Agents: busy (pending) and live (teal) dots, names without device.
    expect(
      dotColor(tester, const ValueKey('agentDot:goal_builder@dev-1')),
      palette.pending,
    );
    expect(
      dotColor(tester, const ValueKey('agentDot:scout@dev-1')),
      palette.teal,
    );
    expect(find.text('goal_builder'), findsOneWidget);
    expect(find.text('scout'), findsOneWidget);

    // Sessions: live / wake-on-DM / offline.
    expect(
      dotColor(tester, const ValueKey('sessionDot:sess-main')),
      palette.teal,
    );
    expect(
      dotColor(tester, const ValueKey('sessionDot:sess-idle')),
      palette.pending,
    );
    expect(
      dotColor(tester, const ValueKey('sessionDot:sess-down')),
      palette.dim,
    );
    expect(find.text('sess-main'), findsOneWidget);
    expect(find.text('sess-idle'), findsOneWidget);
    expect(find.text('Wake on DM'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('degraded machine renders the pending dot', (tester) async {
    final service = FakeRosterService(
      initialPhase: DeviceConnectorPhase.online,
    );

    await tester.pumpWidget(_wrap(DeviceRosterPanel(service: service)));
    await tester.pump();
    final palette = paletteOf(tester);
    service.emitPresence(_frame(machine: MachinePresence.degraded));
    await tester.pump();

    expect(dotColor(tester, const ValueKey('deviceDot')), palette.pending);
  });

  testWidgets('phase flips online → reconnecting swap the roster for the '
      'muted line', (tester) async {
    final service = FakeRosterService(
      initialPhase: DeviceConnectorPhase.online,
    );

    await tester.pumpWidget(_wrap(DeviceRosterPanel(service: service)));
    await tester.pump();
    service.emitPresence(_frame());
    await tester.pump();
    expect(find.byKey(const ValueKey('deviceRow')), findsOneWidget);

    service.setPhase(DeviceConnectorPhase.reconnecting);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('deviceRosterReconnecting')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('deviceRow')), findsNothing);
  });
}
