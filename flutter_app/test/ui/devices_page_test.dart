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
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/network/devices_page.dart';
import 'package:fa/ui/network/device_roster_panel.dart';
import 'package:fa_ui/fa_ui.dart';
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
    this.lastStartError,
  }) : _phase = initialPhase;

  DeviceConnectorPhase _phase;

  /// The enrolled device id the page filters its own frames by.
  @override
  final String? deviceId;

  /// The simulated start failure the page should surface.
  @override
  final String? lastStartError;

  /// How many times the page asked for a retry start.
  int startCalls = 0;

  @override
  Future<void> start() async {
    startCalls++;
  }

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

/// A chat list controller over the given static entries — the same
/// projection the Local sessions panel rides (the app's canonical local
/// session enumeration).
ChatListController chatListOf(List<ChatListEntry> entries) {
  final controller = ChatListController(
    localAdapter: StaticChatListAdapter(entries),
  );
  unawaited(controller.load());
  return controller;
}

/// One projected LOCAL chat row (the chat screen's row shape).
ChatListEntry localEntry(
  String id, {
  String title = 'Session',
  ChatPresence? presence,
  bool isSubagent = false,
  String? parentId,
  DateTime? createdAt,
}) => ChatListEntry(
  id: ChatEntryId.local(id),
  kind: ChatListEntryKind.localAgent,
  title: title,
  createdAt: createdAt ?? DateTime.utc(2026, 11, 12),
  presence: presence,
  isSubagent: isSubagent,
  parentId: parentId,
);

/// The DevicesPage under test, optionally wired with the local chat list
/// and an open-session callback that records the tapped entries; [selected]
/// pins the shell's open-session id (the accent-fill card).
Widget devicesPage(
  FakeDevicesService service, {
  ChatListController? sessions,
  void Function(ChatListEntry)? onOpen,
  String? selected,
}) => DevicesPage(
  service: service,
  sessions: sessions,
  selectedSessionId: selected,
  onOpenSession: onOpen == null ? null : (entry) => onOpen(entry),
);

/// The palette resolved from the page's own context — tests assert
/// palette roles (teal/pending/dim), never literal hex values.
FahColors paletteOf(WidgetTester tester) =>
    FahColors.of(tester.element(find.byKey(const ValueKey('devicesPage'))));

void main() {
  testWidgets(
    'signed-out phase → not-running line + This device, tap retries',
    (tester) async {
      final service = FakeDevicesService(
        initialPhase: DeviceConnectorPhase.signedOut,
      );

      await tester.pumpWidget(_wrap(DevicesPage(service: service)));
      await tester.pump();

      // Never blank (issue #2062 field feedback): the header, the
      // not-running line and the own-device node all render.
      expect(find.byKey(const ValueKey('devicesPage')), findsOneWidget);
      expect(find.text('MY DEVICES'), findsOneWidget);
      expect(find.byKey(const ValueKey('devicesNotRunning')), findsOneWidget);
      expect(find.text('Connector not running — tap to retry'), findsOneWidget);
      expect(find.text('This device'), findsOneWidget);

      // Tap → the page asks the service for a retry start.
      await tester.tap(find.byKey(const ValueKey('devicesNotRunning')));
      expect(service.startCalls, 1);
    },
  );

  testWidgets('signed-out phase shows the last start error', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.signedOut,
      lastStartError: 'DeviceEnrollmentException: 401',
    );

    await tester.pumpWidget(_wrap(DevicesPage(service: service)));
    await tester.pump();

    expect(find.byKey(const ValueKey('devicesStartError')), findsOneWidget);
    expect(find.text('DeviceEnrollmentException: 401'), findsOneWidget);
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

  testWidgets('online → This device node: honest offline dot until the '
      'first frame, then frame agents + LOCAL chat sessions', (tester) async {
    final opened = <String>[];
    final controller = chatListOf([
      localEntry('sess-main', title: 'Main chat', presence: ChatPresence.busy),
      localEntry('sess-idle', title: 'Idle chat'),
    ]);
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(
      _wrap(
        devicesPage(
          service,
          sessions: controller,
          onOpen: (entry) => opened.add(entry.id.value),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final palette = paletteOf(tester);

    // No presence frame yet: the machine state is UNKNOWN — the honest
    // offline spec (dim dot, muted label), never the old online default.
    expect(find.text('This device'), findsOneWidget);
    expect(dotColor(tester, const ValueKey('deviceDot')), palette.dim);
    // The node's presence label is the only 'Offline': the session cards'
    // subtitle is the last-activity timestamp now, not the state word.
    expect(find.text('Offline'), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceRow')), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceAvatar')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('deviceAvatar'))),
      const Size(50, 50),
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is FaIcon && widget.icon == FaSemanticIcon.devices,
      ),
      findsOneWidget,
    );

    service.emitPresence(
      _frame(
        machine: MachinePresence.online,
        agents: const {
          'goal_builder@dev-1': AgentRunState.busy,
          'scout@dev-1': AgentRunState.live,
        },
        // The connector's exposed-session view must NOT drive this node:
        // 'sess-exposed' never renders under This device.
        sessions: const {'sess-exposed': ConnectorSessionPresence.wakeOnDm},
      ),
    );
    await tester.pump();

    // The own node's dot follows the frame's machine state; the nested
    // rows carry the agent dots and the LOCAL chat session rows.
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
    // The streaming agent is the only 'Busy' label; the streaming local
    // session's card shows its timestamp subtitle instead.
    expect(find.text('Busy'), findsOneWidget);
    expect(find.byKey(const ValueKey('sessionRow:sess-exposed')), findsNothing);
    expect(find.byKey(const ValueKey('sessionRow:sess-main')), findsOneWidget);
    expect(
      dotColor(tester, const ValueKey('sessionDot:sess-main')),
      palette.pending,
    );
    expect(find.byKey(const ValueKey('sessionRow:sess-idle')), findsOneWidget);
    expect(
      dotColor(tester, const ValueKey('sessionDot:sess-idle')),
      palette.dim,
    );

    // The local session rows route through the shell's open flow.
    await tester.tap(find.byKey(const ValueKey('sessionRow:sess-main')));
    expect(opened, ['sess-main']);
  });

  testWidgets('local subagent sessions follow the messenger visibility '
      'rule: live-parent subagents hidden, orphans shown', (tester) async {
    final controller = chatListOf([
      localEntry('parent-1', title: 'Parent'),
      localEntry('sub-1', title: 'Sub', isSubagent: true, parentId: 'parent-1'),
      localEntry('orphan-1', title: 'Orphan', isSubagent: true),
    ]);
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(_wrap(devicesPage(service, sessions: controller)));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('sessionRow:parent-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('sessionRow:sub-1')), findsNothing);
    expect(find.byKey(const ValueKey('sessionRow:orphan-1')), findsOneWidget);
  });

  testWidgets('every node toggles; an empty expanded node shows the muted '
      'no-sessions hint', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    // The own node starts expanded with no children: the hint renders.
    expect(find.text('No sessions yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceNoSessionsHint')), findsOneWidget);

    // The toggle always works — collapse hides the hint, re-expand shows it.
    await tester.tap(
      find.byKey(const ValueKey('deviceNodeToggle:This device')),
    );
    await tester.pump();
    expect(find.text('No sessions yet'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('deviceNodeToggle:This device')),
    );
    await tester.pump();
    expect(find.text('No sessions yet'), findsOneWidget);

    // A remote node with no children behaves the same once expanded.
    service.emitEnvelope(_envelope(deviceId: 'dev-empty', msgId: 'p-empty'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('deviceNodeToggle:dev-empty')));
    await tester.pump();
    expect(find.text('No sessions yet'), findsNWidgets(2));
  });

  testWidgets('remote device session rows stay read-only; only local rows '
      'carry the open tap', (tester) async {
    final opened = <String>[];
    final controller = chatListOf([localEntry('sess-main')]);
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(
      _wrap(
        devicesPage(
          service,
          sessions: controller,
          onOpen: (entry) => opened.add(entry.id.value),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    service.emitEnvelope(
      _envelope(
        deviceId: 'dev-remote',
        sessions: const {'sess-remote': ConnectorSessionPresence.live},
        msgId: 'p-remote',
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('deviceNodeToggle:dev-remote')));
    await tester.pump();

    final localRow = tester.widget<DeviceSessionCard>(
      find.byKey(const ValueKey('sessionRow:sess-main')),
    );
    expect(localRow.onTap, isNotNull);
    final remoteRow = tester.widget<DeviceSessionCard>(
      find.byKey(const ValueKey('sessionRow:sess-remote')),
    );
    expect(remoteRow.onTap, isNull);

    // Tapping the remote row routes nowhere (no callback attached).
    await tester.tap(find.byKey(const ValueKey('sessionRow:sess-remote')));
    expect(opened, isEmpty);
    await tester.tap(find.byKey(const ValueKey('sessionRow:sess-main')));
    expect(opened, ['sess-main']);

    // The remote card is the same channel-card anatomy but carries NO
    // chevron — it is not navigable.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sessionRow:sess-remote')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is FaIcon && widget.icon == FaSemanticIcon.chevronRight,
        ),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sessionRow:sess-main')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is FaIcon && widget.icon == FaSemanticIcon.chevronRight,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('channel-card anatomy: the open session carries the accent '
      'fill, the white chat-glyph tile and the timestamp subtitle; the '
      'expanded node keys like the selected network', (tester) async {
    final controller = chatListOf([
      localEntry('sess-open', title: 'Open chat', createdAt: DateTime.now()),
      localEntry('sess-idle', title: 'Idle chat', createdAt: DateTime.now()),
    ]);
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(
      _wrap(
        devicesPage(
          service,
          sessions: controller,
          onOpen: (_) {},
          selected: 'sess-open',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final openCard = tester.widget<DeviceSessionCard>(
      find.byKey(const ValueKey('sessionRow:sess-open')),
    );
    expect(openCard.selected, isTrue);
    expect(openCard.onTap, isNotNull);
    // The subtitle is the LAST-ACTIVITY TIMESTAMP (a fresh session reads
    // 'now'), never the presence word.
    expect(openCard.subtitle, 'now');
    final idleCard = tester.widget<DeviceSessionCard>(
      find.byKey(const ValueKey('sessionRow:sess-idle')),
    );
    expect(idleCard.selected, isFalse);

    // Selected = the accent fill (the messenger row's state); unselected
    // stays the quiet panel card.
    final element = tester.element(find.byKey(const ValueKey('devicesPage')));
    final tokens = FaDesignTokens.of(element);
    final colors = FahColors.of(element);
    Material cardMaterial(Key key) => tester.widget<Material>(
      find
          .descendant(of: find.byKey(key), matching: find.byType(Material))
          .first,
    );
    expect(
      cardMaterial(const ValueKey('sessionRow:sess-open')).color,
      tokens.accent,
    );
    expect(
      cardMaterial(const ValueKey('sessionRow:sess-idle')).color,
      colors.panelAlt,
    );

    // The card's white icon tile carries the vector chat glyph and the
    // presence dot badge rides it (sessionDot key above).
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sessionRow:sess-open')),
        matching: find.byWidgetPredicate(
          (widget) => widget is FaIcon && widget.icon == FaSemanticIcon.chat,
        ),
      ),
      findsOneWidget,
    );

    // The expanded This-device row keys like the selected network: the
    // tinted rounded-10 fill and the avatar's accent ring.
    final isLight = Theme.of(element).brightness == Brightness.light;
    final headerMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const ValueKey('deviceRow')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      headerMaterial.color,
      isLight ? const Color(0xFFEEF2FF) : colors.panelAlt,
    );
    final avatarDecoration = tester
        .widget<Container>(
          find
              .descendant(
                of: find.byKey(const ValueKey('deviceAvatar')),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Container &&
                      widget.decoration is BoxDecoration &&
                      widget.key == null,
                ),
              )
              .first,
        )
        .decoration!;
    expect(
      (avatarDecoration as BoxDecoration).border,
      Border.all(color: colors.indigo, width: 2),
    );
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
    // collapsed, same networks-list row shape (round avatar + vector
    // glyph, keyed per device). The own device's frames (no foreign
    // deviceId) are ignored by the remote accumulator.
    expect(find.byKey(const ValueKey('deviceNode:dev-remote')), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceRow:dev-remote')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('deviceAvatar:dev-remote')),
      findsOneWidget,
    );
    final avatarDecoration = tester
        .widget<Container>(
          find
              .descendant(
                of: find.byKey(const ValueKey('deviceAvatar:dev-remote')),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Container &&
                      widget.decoration is BoxDecoration &&
                      widget.key == null,
                ),
              )
              .first,
        )
        .decoration!;
    expect((avatarDecoration as BoxDecoration).shape, BoxShape.circle);
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
