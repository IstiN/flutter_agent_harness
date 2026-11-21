// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// DevicesPage widget tests (issue #2062 chunk 16, master-rail pass): the
/// NETWORKS-strip avatar rail beside the selected device's pane — the
/// rail renders one avatar cell per machine (own dot ONLINE LOCALLY,
/// remote dots from their frames), a tap switches the pane, local
/// sessions open as channel cards, remote cards stay read-only, and the
/// empty pane shows the muted hint. Driven by a fake service's streams
/// (no connector, no sockets), mirroring the chunk-15 panel test harness.
library;

import 'dart:async';

import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/fa_network_client.dart';
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
    this.personalNetworkId,
    this.lastStartError,
    DeviceInfo? ownDevice,
    this.rosterDevices = const [],
  }) : _phase = initialPhase {
    _ownDevice = ownDevice;
  }

  DeviceConnectorPhase _phase;
  DeviceInfo? _ownDevice;

  /// Scripted REST roster returned on page open and roster invalidations.
  List<DeviceInfo> rosterDevices;

  /// Optional rename failure/transformation seam.
  Future<String?> Function(String name)? renameHandler;

  final renameRequests = <String>[];
  var rosterFetchCalls = 0;
  var ownRefreshCalls = 0;

  /// The enrolled device id the page filters its own frames by. Mutable so
  /// the cached-roster-before-enrollment race can be reproduced directly.
  @override
  String? deviceId;

  @override
  final String? personalNetworkId;

  /// The simulated start failure the page should surface.
  @override
  final String? lastStartError;

  /// How many times the page asked for a retry start.
  int startCalls = 0;

  @override
  Future<void> start() async {
    startCalls++;
  }

  @override
  DeviceInfo? get ownDevice => _ownDevice;

  @override
  String? get ownFriendlyName => _ownDevice?.friendlyName;

  final _ownDeviceController = StreamController<DeviceInfo?>.broadcast(
    sync: true,
  );

  @override
  Stream<DeviceInfo?> get ownDeviceStream => _ownDeviceController.stream;

  void setOwnDevice(DeviceInfo device) {
    _ownDevice = device;
    _ownDeviceController.add(device);
  }

  @override
  Future<DeviceInfo?> refreshOwnDevice() async {
    ownRefreshCalls++;
    return _ownDevice;
  }

  @override
  Future<List<DeviceInfo>> listNetworkDevices() async {
    rosterFetchCalls++;
    return rosterDevices;
  }

  @override
  Future<String?> renameOwnDevice(String name) async {
    renameRequests.add(name);
    final friendly = renameHandler == null
        ? (name.isEmpty ? null : name)
        : await renameHandler!(name);
    final current = _ownDevice;
    setOwnDevice(
      DeviceInfo(
        deviceId: deviceId ?? 'dev-1',
        name: current?.name ?? 'test-host',
        friendlyName: friendly,
      ),
    );
    return friendly;
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
  final _rosterFrames = StreamController<NetworkEnvelope>.broadcast(sync: true);

  /// Emits a phase transition.
  void setPhase(DeviceConnectorPhase phase) {
    _phase = phase;
    _phaseController.add(phase);
  }

  /// Emits the own machine's parsed presence frame.
  void emitPresence(PresenceFrame frame) => _presence.add(frame);

  /// Emits a raw network-wide presence envelope (remote machines).
  void emitEnvelope(NetworkEnvelope envelope) => _presenceFrames.add(envelope);

  /// Emits the connector invalidation that triggers a REST roster refresh.
  void emitRoster(NetworkEnvelope envelope) => _rosterFrames.add(envelope);

  /// Frames that arrived BEFORE the page subscribed (service replay cache).
  final List<NetworkEnvelope> seededRoster = [];

  @override
  List<NetworkEnvelope> get currentRosterFrames => seededRoster;

  @override
  DeviceConnectorPhase get phase => _phase;

  @override
  Stream<DeviceConnectorPhase> get phaseStream => _phaseController.stream;

  @override
  Stream<PresenceFrame> get presence => _presence.stream;

  @override
  Stream<NetworkEnvelope> get presenceFrames => _presenceFrames.stream;

  @override
  Stream<NetworkEnvelope> get rosterFrames => _rosterFrames.stream;

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

/// The production server projection: device rows ride directly in the
/// envelope payload, with one roster frame per shared network and
/// single-device presence flips on the same shape.
NetworkEnvelope _devicesEnvelope({
  NetworkEnvelopeKind kind = NetworkEnvelopeKind.roster,
  String msgId = 'server-devices',
  String? network,
  required List<Map<String, Object?>> devices,
}) => NetworkEnvelope(
  kind: kind,
  msgId: msgId,
  ts: rfc3339Timestamp(DateTime.utc(2026, 11, 12)),
  network: network,
  payload: {'devices': devices},
);

Future<void> openDeviceRename(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('deviceOptionsMenu')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('deviceRenameMenuItem')));
  await tester.pumpAndSettle();
}

Color dotColor(WidgetTester tester, Key key) {
  final container = tester.widget<Container>(find.byKey(key));
  final decoration = container.decoration;
  expect(decoration, isA<BoxDecoration>());
  final color = (decoration as BoxDecoration).color;
  if (color == null) fail('expected a non-null dot color');
  return color;
}

/// The keyed avatar Container's decoration (the rail avatar's gradient
/// box — the shape fields carry the circle↔squircle selection state).
BoxDecoration avatarDecoration(WidgetTester tester, Key key) {
  final container = tester.widget<Container>(
    find
        .descendant(
          of: find.byKey(key),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is BoxDecoration &&
                widget.key == null,
          ),
        )
        .first,
  );
  return container.decoration! as BoxDecoration;
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
  DateTime? lastActivity,
  String? folderPath,
}) => ChatListEntry(
  id: ChatEntryId.local(id),
  kind: ChatListEntryKind.localAgent,
  title: title,
  createdAt: createdAt ?? DateTime.utc(2026, 11, 12),
  lastActivity: lastActivity,
  folderPath: folderPath,
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
  DateTime Function()? now,
  bool startAtRoot = false,
  void Function({
    required String deviceId,
    required String deviceLabel,
    required String agentAddress,
    String? sessionId,
    String? sessionTitle,
  })?
  onOpenRemoteConversation,
}) => DevicesPage(
  service: service,
  sessions: sessions,
  now: now,
  selectedSessionId: selected,
  onOpenSession: onOpen == null ? null : (entry) => onOpen(entry),
  onOpenRemoteConversation: onOpenRemoteConversation,
  // Legacy pane assertions start drilled in; navigation tests opt into the
  // production root explicitly. Goldens construct DevicesPage directly.
  initialDeviceId: startAtRoot ? null : service.deviceId,
);

/// The palette resolved from the page's own context — tests assert
/// palette roles (teal/pending/dim), never literal hex values.
FahColors paletteOf(WidgetTester tester) =>
    FahColors.of(tester.element(find.byKey(const ValueKey('devicesPage'))));

void main() {
  testWidgets('drill-down reuses the Networks mini-strip beside the pane', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    // Exact Networks anatomy: fixed 70pt mini-strip, no divider, and the
    // current-device name in the shared section header.
    expect(find.byKey(const ValueKey('devicesPage')), findsOneWidget);
    expect(find.text('This device'), findsWidgets);
    expect(find.byKey(const ValueKey('deviceRail')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('deviceRail'))).width,
      DevicesPage.railWidth,
    );
    expect(find.byType(VerticalDivider), findsNothing);
    expect(find.byKey(const ValueKey('deviceDrilldownBody')), findsOneWidget);
    final railRect = tester.getRect(find.byKey(const ValueKey('deviceRail')));
    final capsuleRect = tester.getRect(
      find.byKey(const ValueKey('deviceSelectedCapsule')),
    );
    // The accent must be fully inside the strip, not a screen-edge sliver.
    expect(capsuleRect.left, greaterThan(railRect.left));
    expect(capsuleRect.right, lessThanOrEqualTo(railRect.right));
    // The mini-strip itself stays avatar-only; names live in the header.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is FaIcon && widget.icon == FaSemanticIcon.expandMore,
      ),
      findsNothing,
    );
    expect(find.text('Online'), findsNothing);
    expect(find.text('Offline'), findsNothing);
  });

  testWidgets('glass header lets the rail scroll underneath its blur', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );
    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    expect(find.byKey(const ValueKey('devicesChromeUnderlay')), findsOneWidget);
    final railFinder = find.byKey(const ValueKey('deviceRail'));
    final rail = tester.widget<ListView>(
      find.descendant(of: railFinder, matching: find.byType(ListView)),
    );
    expect(tester.getRect(railFinder).top, 0);
    expect(rail.padding, const EdgeInsets.only(top: 56, bottom: 4));
    expect(
      tester.getRect(find.byKey(const ValueKey('deviceNoSessionsHint'))).top,
      greaterThanOrEqualTo(52),
    );
    expect(find.byKey(const ValueKey('devicePaneTitle')), findsNothing);
  });

  testWidgets(
    'signed-out phase → not-running line + This device rail cell (own dot '
    'teal locally), tap retries',
    (tester) async {
      final service = FakeDevicesService(
        initialPhase: DeviceConnectorPhase.signedOut,
      );

      await tester.pumpWidget(_wrap(DevicesPage(service: service)));
      await tester.pump();

      // Never blank (issue #2062 field feedback): the header, the
      // not-running line and the own-device rail cell + pane all render.
      expect(find.byKey(const ValueKey('devicesPage')), findsOneWidget);
      expect(find.text('My devices'), findsOneWidget);
      expect(find.byKey(const ValueKey('devicesNotRunning')), findsOneWidget);
      expect(find.text('Connector not running — tap to retry'), findsOneWidget);
      expect(find.text('This device'), findsWidgets);
      // The own rail cell is ONLINE LOCALLY even while the connector is
      // down: the dot says "the app is running on this machine"; the
      // banner above tells the connector's story.
      expect(
        dotColor(tester, const ValueKey('deviceDot')),
        paletteOf(tester).teal,
      );
      expect(find.byKey(const ValueKey('deviceAvatar')), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is FaIcon && widget.icon == FaSemanticIcon.devices,
        ),
        findsOneWidget,
      );

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

  testWidgets('connecting keeps the device list geometry stable', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.connecting,
    );

    await tester.pumpWidget(_wrap(DevicesPage(service: service)));
    await tester.pump();

    expect(find.byKey(const ValueKey('devicesPage')), findsOneWidget);
    expect(find.text('My devices'), findsOneWidget);
    expect(find.byKey(const ValueKey('devicesConnecting')), findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byKey(const ValueKey('devicesSkeleton')), findsNothing);
    expect(find.byKey(const ValueKey('deviceList')), findsOneWidget);
    expect(find.text('This device'), findsWidgets);
    final connectingList = tester.getRect(
      find.byKey(const ValueKey('deviceList')),
    );
    final connectingRow = tester.getRect(
      find.byKey(const ValueKey('deviceRow')),
    );

    service.setPhase(DeviceConnectorPhase.online);
    await tester.pump();

    expect(find.text('Connecting…'), findsNothing);
    expect(
      tester.getRect(find.byKey(const ValueKey('deviceList'))),
      connectingList,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('deviceRow'))),
      connectingRow,
    );
  });

  testWidgets('reconnecting → muted banner over the rail + pane', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.reconnecting,
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    expect(find.byKey(const ValueKey('devicesReconnecting')), findsOneWidget);
    expect(find.text('Reconnecting…'), findsOneWidget);
    // The last-known root list stays mounted under the banner.
    expect(find.byKey(const ValueKey('deviceList')), findsOneWidget);
    expect(find.text('This device'), findsWidgets);
  });

  testWidgets('online → This device rail cell: teal dot WITHOUT a frame, '
      'avatar-only cell; pane shows frame agents + LOCAL chat session '
      'cards', (tester) async {
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

    // No presence frame yet: the dot is already teal — ONLINE LOCALLY,
    // the app is running on this machine (never the old offline default).
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
    expect(dotColor(tester, const ValueKey('deviceDot')), palette.teal);
    // The default selection is named once by the glass appbar, not again by
    // an in-list pane header.
    expect(find.byKey(const ValueKey('devicePaneTitle')), findsNothing);
    expect(find.text('This device'), findsOneWidget);

    // The frame does NOT drive this dot — a frame even claiming the
    // machine OFFLINE leaves it teal (the connector's link state stays
    // the banners' story). Only the nested agents ride the frame; the
    // connector's exposed-session view must NOT drive the own pane
    // ('sess-exposed' never renders under This device).
    service.emitPresence(
      _frame(
        machine: MachinePresence.offline,
        agents: const {
          'goal_builder@dev-1': AgentRunState.busy,
          'scout@dev-1': AgentRunState.live,
        },
        sessions: const {'sess-exposed': ConnectorSessionPresence.wakeOnDm},
      ),
    );
    await tester.pump();

    expect(dotColor(tester, const ValueKey('deviceDot')), palette.teal);
    // The pane carries the agent roster rows and the LOCAL chat session
    // cards.
    expect(find.text('goal_builder'), findsOneWidget);
    expect(find.text('scout'), findsOneWidget);
    expect(
      dotColor(tester, const ValueKey('agentDot:goal_builder')),
      palette.pending,
    );
    expect(dotColor(tester, const ValueKey('agentDot:scout')), palette.teal);
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
    // A merely persisted/idle session has no misleading presence label or
    // activity dot; only the streaming row above is marked active.
    expect(find.byKey(const ValueKey('sessionDot:sess-idle')), findsNothing);
    expect(find.text('Offline'), findsNothing);

    // The local session cards route through the shell's open flow.
    await tester.tap(find.byKey(const ValueKey('sessionRow:sess-main')));
    expect(opened, ['sess-main']);
  });

  testWidgets('a raw agent session id adopts the local registry name and '
      'rich context without changing its DM target', (tester) async {
    const id = '01a15985-f6c3-7345-ae10-e44fc7a9c201';
    final controller = chatListOf([
      localEntry(
        id,
        title: 'goal_builder',
        folderPath: '/work/flutter_agent',
        lastActivity: DateTime.utc(2026, 11, 12, 8),
      ),
    ]);
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
      ownDevice: const DeviceInfo(
        deviceId: 'dev-1',
        name: 'mymac',
        friendlyName: 'mymac',
      ),
    );
    String? openedAddress;
    String? openedSessionId = 'sentinel';
    await tester.pumpWidget(
      _wrap(
        devicesPage(
          service,
          sessions: controller,
          now: () => DateTime.utc(2026, 11, 12, 9),
          onOpenRemoteConversation:
              ({
                required String deviceId,
                required String deviceLabel,
                required String agentAddress,
                String? sessionId,
                String? sessionTitle,
              }) {
                openedAddress = agentAddress;
                openedSessionId = sessionId;
              },
        ),
      ),
    );
    await tester.pump();
    service.emitPresence(_frame(agents: const {id: AgentRunState.busy}));
    await tester.pump();

    final card = tester.widget<DeviceSessionCard>(
      find.byKey(const ValueKey('agentRow:$id')),
    );
    expect(card.title, 'goal_builder');
    expect(card.subtitle, '/work/flutter_agent');
    expect(card.timestamp, isNotEmpty);
    expect(card.stateLabel, 'Busy');
    expect(find.text(id), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('agentRow:$id')),
        matching: find.text('/work/flutter_agent'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('agentRow:$id')),
        matching: find.textContaining('mymac'),
      ),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('agentRow:$id')));
    expect(openedAddress, '$id@dev-1');
    expect(openedSessionId, isNull);
  });

  testWidgets('active and orphaned subagents render exactly one parent row', (
    tester,
  ) async {
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
    expect(find.byKey(const ValueKey('sessionRow:orphan-1')), findsNothing);
    expect(find.byType(DeviceSessionCard), findsOneWidget);
  });

  testWidgets('remote frame adds a rail cell; tapping it switches the '
      'pane; remote dot reads the frame (degraded pending, then offline '
      'dim)', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
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

    // BOTH devices render in the rail (own first, remote second); the
    // remote cell keys per device and carries its own frame-driven dot
    // (degraded ⇒ pending).
    expect(find.byKey(const ValueKey('deviceRow')), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceRow:dev-remote')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('deviceAvatar:dev-remote')),
      findsOneWidget,
    );
    expect(
      dotColor(tester, const ValueKey('deviceDot:dev-remote')),
      palette.pending,
    );

    // The pane still shows the default (first) device — stream updates
    // never hijack the selection.
    expect(find.text('This device'), findsWidgets);
    expect(find.text('agent'), findsNothing);

    // Tap the remote rail cell → the pane switches to its children.
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-remote')));
    await tester.pump();

    expect(find.text('dev-remote'), findsOneWidget);
    expect(find.text('agent'), findsOneWidget);
    expect(dotColor(tester, const ValueKey('agentDot:agent')), palette.teal);

    // Remote presence stays frame-based: the LATEST frame's machine
    // state drives the dot (an offline frame ⇒ the dim dot) while the
    // selection persists across the stream update.
    service.emitEnvelope(
      _envelope(
        machine: MachinePresence.offline,
        deviceId: 'dev-remote',
        msgId: 'p-remote-offline',
      ),
    );
    await tester.pump();
    expect(
      dotColor(tester, const ValueKey('deviceDot:dev-remote')),
      palette.dim,
    );
    expect(find.text('dev-remote'), findsOneWidget);
  });

  testWidgets('selection persists while frames stream updates (a new '
      'remote arrival does not reset the pane)', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    service.emitEnvelope(_envelope(deviceId: 'dev-a', msgId: 'p-a'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-a')));
    await tester.pump();
    expect(find.text('dev-a'), findsWidgets);

    // Another machine arrives: the pane stays on the selected device.
    service.emitEnvelope(
      _envelope(
        deviceId: 'dev-b',
        agents: const {'x@dev-b': AgentRunState.live},
        msgId: 'p-b',
      ),
    );
    await tester.pump();

    // The rail now carries three cells; the pane is untouched.
    expect(find.byKey(const ValueKey('deviceRow:dev-b')), findsOneWidget);
    expect(find.text('dev-a'), findsWidgets);
    expect(find.text('x'), findsNothing);

    // …and tapping back returns to This device's pane.
    await tester.tap(find.byKey(const ValueKey('deviceRow')));
    await tester.pumpAndSettle();
    expect(find.text('This device'), findsWidgets);
    expect(find.text('dev-a'), findsNothing);
  });

  testWidgets('empty devices show the muted no-sessions hint in the pane', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    // The default (This device) pane with no children: the hint renders.
    expect(find.text('No sessions yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceNoSessionsHint')), findsOneWidget);

    // Switching to the empty remote swaps the pane's hint in for its
    // children (exactly one hint at a time — the pane is per device).
    service.emitEnvelope(_envelope(deviceId: 'dev-empty', msgId: 'p-empty'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-empty')));
    await tester.pumpAndSettle();
    expect(find.text('No sessions yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceNoSessionsHint')), findsOneWidget);
  });

  testWidgets('remote session cards stay read-only; only local cards '
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
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-remote')));
    await tester.pumpAndSettle();

    final remoteRow = tester.widget<DeviceSessionCard>(
      find.byKey(const ValueKey('sessionRow:sess-remote')),
    );
    expect(remoteRow.onTap, isNull);

    // Tapping the remote row routes nowhere (no callback attached).
    await tester.tap(find.byKey(const ValueKey('sessionRow:sess-remote')));
    expect(opened, isEmpty);

    // The remote card is the same channel-card anatomy but carries NO
    // chevron — it is not navigable.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sessionRow:sess-remote')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Icon && widget.icon == Icons.chevron_right_rounded,
        ),
      ),
      findsNothing,
    );

    // Back on This device, the local card opens and carries the chevron.
    await tester.tap(find.byKey(const ValueKey('deviceRow')));
    await tester.pumpAndSettle();
    final localRow = tester.widget<DeviceSessionCard>(
      find.byKey(const ValueKey('sessionRow:sess-main')),
    );
    expect(localRow.onTap, isNotNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sessionRow:sess-main')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Icon && widget.icon == Icons.chevron_right_rounded,
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('sessionRow:sess-main')));
    expect(opened, ['sess-main']);
  });

  testWidgets('channel-card anatomy: the open session carries the accent '
      'fill and the timestamp subtitle; the selected rail cell carries '
      'the capsule + squircle avatar', (tester) async {
    final controller = chatListOf([
      localEntry(
        'sess-open',
        title: 'Open chat',
        createdAt: DateTime.now(),
        folderPath: '/work/open',
      ),
      localEntry(
        'sess-idle',
        title: 'Idle chat',
        createdAt: DateTime.now(),
        folderPath: '/work/idle',
      ),
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
    // Activity stays relative (a fresh session reads 'now'); the subtitle is
    // the session path, never preview/presence text.
    expect(openCard.timestamp, 'now');
    expect(openCard.subtitle, '/work/open');
    final idleCard = tester.widget<DeviceSessionCard>(
      find.byKey(const ValueKey('sessionRow:sess-idle')),
    );
    expect(idleCard.selected, isFalse);

    // Selected = the accent fill (the messenger row's state); unselected
    // stays the quiet panel card.
    final element = tester.element(find.byKey(const ValueKey('devicesPage')));
    final tokens = FaDesignTokens.of(element);
    Material cardMaterial(Key key) => tester.widget<Material>(
      find
          .descendant(of: find.byKey(key), matching: find.byType(Material))
          .first,
    );
    expect(
      cardMaterial(const ValueKey('sessionRow:sess-open')).color,
      tokens.accent,
    );

    // Local-panel anatomy: no channel-card glyph tile; clean text rows are
    // hairline-separated and the tappable row keeps its chevron.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sessionRow:sess-open')),
        matching: find.byWidgetPredicate(
          (widget) => widget is FaIcon && widget.icon == FaSemanticIcon.chat,
        ),
      ),
      findsNothing,
    );
    // The controller may recency-sort the two equal-time fixtures; exactly
    // one row is last and therefore hairline-free.
    expect({openCard.hairline, idleCard.hairline}, {true, false});

    // The selected rail cell keys like the networks strip: the accent
    // capsule flush to the rail's left edge, and the avatar squares up
    // (radius ~25%) — the unselected remote cell later stays a circle.
    expect(find.byKey(const ValueKey('deviceSelectedCapsule')), findsOneWidget);
    final capsule = tester.widget<Container>(
      find.byKey(const ValueKey('deviceSelectedCapsule')),
    );
    expect((capsule.decoration! as BoxDecoration).color, tokens.accent);
    expect(capsule.constraints?.maxWidth, DevicesPage.capsuleWidth);
    expect(
      (avatarDecoration(tester, const ValueKey('deviceAvatar')).borderRadius),
      BorderRadius.circular(DevicesPage.railAvatarSize * 0.25),
    );

    service.emitEnvelope(_envelope(deviceId: 'dev-rest', msgId: 'p-rest'));
    await tester.pump();
    expect(
      (avatarDecoration(
        tester,
        const ValueKey('deviceAvatar:dev-rest'),
      ).borderRadius),
      BorderRadius.circular(DevicesPage.railAvatarSize / 2),
    );
  });

  testWidgets('online with no remote frames → only the This device rail '
      'cell', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(_wrap(DevicesPage(service: service)));
    await tester.pump();

    expect(find.byKey(const ValueKey('deviceRow')), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceRow:dev-remote')), findsNothing);
    expect(find.byKey(const ValueKey('deviceSelectedCapsule')), findsNothing);
  });

  testWidgets("the own device's envelope (matching deviceId) never becomes "
      'a remote rail cell', (tester) async {
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
    expect(find.byKey(const ValueKey('deviceRow:dev-1')), findsNothing);
    expect(find.text('This device'), findsWidgets);
  });

  testWidgets('late enrollment retracts an own echo cached before the id was '
      'available and every mini-strip tile keeps its label', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      personalNetworkId: 'net-personal',
    );
    service.seededRoster.add(
      _devicesEnvelope(
        network: 'net-personal',
        devices: const [
          {'deviceId': 'dev-own', 'name': 'mymac', 'presence': 'online'},
        ],
      ),
    );

    await tester.pumpWidget(_wrap(DevicesPage(service: service)));
    await tester.pump();
    expect(find.byKey(const ValueKey('deviceRow:dev-own')), findsOneWidget);

    service.deviceId = 'dev-own';
    service.setOwnDevice(
      const DeviceInfo(
        deviceId: 'dev-own',
        name: 'mymac',
        friendlyName: 'mymac',
      ),
    );
    service.emitRoster(
      _devicesEnvelope(
        network: 'net-personal',
        devices: const [
          {'deviceId': 'dev-own', 'name': 'mymac', 'presence': 'online'},
        ],
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('deviceRow')), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceRow:dev-own')), findsNothing);
    expect(find.text('mymac'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('deviceRow')));
    await tester.pumpAndSettle();
    final tile = find.descendant(
      of: find.byKey(const ValueKey('deviceRail')),
      matching: find.byType(Tooltip),
    );
    expect(tile, findsWidgets);
    expect(
      tester.widgetList<Tooltip>(tile).map((tooltip) => tooltip.message),
      contains('mymac'),
    );
  });

  testWidgets('server roster devices[] populates remote identity, exposed '
      'agents, and only sessions visible on the personal network', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
      personalNetworkId: 'net-personal',
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    service.emitRoster(
      _devicesEnvelope(
        network: 'net-shared',
        devices: const [
          {
            'deviceId': 'dev-remote',
            'name': 'thinkpad',
            'friendlyName': 'Workstation',
            'presence': 'online',
            'userId': 'user-1',
            'agents': [
              {
                'name': 'goal_builder',
                'state': 'live',
                'exposed': true,
                'dmPub': 'cHViLWdvYWw=',
              },
              {
                'name': 'hidden',
                'state': 'live',
                'exposed': false,
                'dmPub': 'cHViLWhpZGRlbg==',
              },
            ],
            'sessions': [
              {
                'id': 'sess-live',
                'state': 'live',
                'networks': ['net-personal', 'net-shared'],
              },
              {
                'id': 'sess-other',
                'state': 'live',
                'networks': ['net-other'],
              },
              // REST's personal-network projection predates `networks`;
              // roster rows without it retain that visible-by-default parity.
              {'id': 'sess-rest', 'state': 'wake_on_dm'},
            ],
          },
        ],
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('deviceRow:dev-remote')), findsOneWidget);
    expect(
      dotColor(tester, const ValueKey('deviceDot:dev-remote')),
      paletteOf(tester).teal,
    );
    final dynamic pageState = tester.state(find.byType(DevicesPage));
    expect(pageState.debugRemoteAgentDmPubs('dev-remote'), {
      'goal_builder@dev-remote': 'cHViLWdvYWw=',
    });

    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-remote')));
    await tester.pump();

    expect(find.text('Workstation'), findsOneWidget);
    expect(find.text('thinkpad'), findsNothing);
    expect(find.byKey(const ValueKey('agentRow:goal_builder')), findsOneWidget);
    expect(find.byKey(const ValueKey('agentRow:hidden')), findsNothing);
    expect(find.byKey(const ValueKey('sessionRow:sess-live')), findsOneWidget);
    expect(find.byKey(const ValueKey('sessionRow:sess-rest')), findsOneWidget);
    expect(find.byKey(const ValueKey('sessionRow:sess-other')), findsNothing);
  });

  testWidgets('roster frames that arrived BEFORE the page opened still '
      'populate remote sessions via the service replay cache', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
      personalNetworkId: 'net-personal',
    );
    // The server pushes roster frames once per connect — long before the
    // user opens the Devices page. Seed the replay cache up front; no live
    // emitRoster happens in this test at all.
    service.seededRoster.add(
      _devicesEnvelope(
        network: 'net-shared',
        devices: const [
          {
            'deviceId': 'dev-remote',
            'name': 'thinkpad',
            'presence': 'online',
            'userId': 'user-1',
            'sessions': [
              {
                'id': 'sess-cached',
                'state': 'live',
                'networks': ['net-personal'],
              },
            ],
          },
        ],
      ),
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-remote')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('sessionRow:sess-cached')),
      findsOneWidget,
    );
  });

  testWidgets('single-device presence flips update the dot without wiping '
      'children; live-only session projections merge into persisted rows', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
      personalNetworkId: 'net-personal',
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();
    service.emitRoster(
      _devicesEnvelope(
        msgId: 'roster-with-children',
        devices: const [
          {
            'deviceId': 'dev-remote',
            'name': 'thinkpad',
            'presence': 'online',
            'userId': 'user-1',
            'agents': [
              {
                'name': 'goal_builder',
                'state': 'live',
                'exposed': true,
                'dmPub': 'cHViLWdvYWw=',
              },
            ],
            'sessions': [
              {
                'id': 'sess-live',
                'state': 'live',
                'networks': ['net-personal'],
              },
            ],
          },
        ],
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-remote')));
    await tester.pump();
    final dynamic pageState = tester.state(find.byType(DevicesPage));

    service.emitEnvelope(
      _devicesEnvelope(
        kind: NetworkEnvelopeKind.presence,
        msgId: 'remote-offline',
        network: 'net-shared',
        devices: const [
          {
            'deviceId': 'dev-remote',
            'name': 'thinkpad',
            'presence': 'offline',
            'userId': 'user-1',
          },
        ],
      ),
    );
    await tester.pump();

    expect(
      dotColor(tester, const ValueKey('deviceDot:dev-remote')),
      paletteOf(tester).dim,
    );
    expect(find.byKey(const ValueKey('agentRow:goal_builder')), findsOneWidget);
    expect(find.byKey(const ValueKey('sessionRow:sess-live')), findsOneWidget);
    expect(pageState.debugRemoteAgentDmPubs('dev-remote'), {
      'goal_builder@dev-remote': 'cHViLWdvYWw=',
    });

    service.emitEnvelope(
      _devicesEnvelope(
        kind: NetworkEnvelopeKind.presence,
        msgId: 'remote-online-empty',
        network: 'net-shared',
        devices: const [
          {
            'deviceId': 'dev-remote',
            'name': 'thinkpad',
            'presence': 'online',
            'userId': 'user-1',
            'agents': [],
            'sessions': [],
          },
        ],
      ),
    );
    await tester.pump();

    expect(
      dotColor(tester, const ValueKey('deviceDot:dev-remote')),
      paletteOf(tester).teal,
    );
    expect(find.byKey(const ValueKey('agentRow:goal_builder')), findsNothing);
    expect(find.byKey(const ValueKey('sessionRow:sess-live')), findsOneWidget);
    expect(pageState.debugRemoteAgentDmPubs('dev-remote'), isEmpty);
  });

  testWidgets('server devices[] skips the own device without dropping later '
      'remote rows in the same frame', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();
    service.emitRoster(
      _devicesEnvelope(
        devices: const [
          {
            'deviceId': 'dev-1',
            'name': 'own-host',
            'presence': 'online',
            'userId': 'user-1',
          },
          {
            'deviceId': 'dev-remote',
            'name': 'remote-host',
            'presence': 'offline',
            'userId': 'user-1',
          },
        ],
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('deviceRow:dev-1')), findsNothing);
    expect(find.byKey(const ValueKey('deviceRow:dev-remote')), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceRow')), findsOneWidget);
  });

  testWidgets('own friendly name drives appbar and root row without an '
      'in-list duplicate', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
      ownDevice: const DeviceInfo(
        deviceId: 'dev-1',
        name: 'MacBook-Pro',
        friendlyName: 'Studio',
      ),
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('MacBook-Pro'), findsNothing);
    expect(find.byKey(const ValueKey('devicePaneTitle')), findsNothing);
    expect(find.byKey(const ValueKey('devicePaneSubtitle')), findsNothing);
    expect(find.byKey(const ValueKey('deviceOptionsMenu')), findsOneWidget);
    expect(find.byKey(const ValueKey('renameOwnDeviceButton')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('deviceBackButton')));
    await tester.pumpAndSettle();
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('This device · Online'), findsOneWidget);
  });

  testWidgets('REST roster adds an offline remote before presence and live '
      'frames update the same friendly-named node', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
      rosterDevices: const [
        DeviceInfo(
          deviceId: 'dev-remote',
          name: 'thinkpad',
          friendlyName: 'Workstation',
          presence: 'offline',
        ),
      ],
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    expect(service.rosterFetchCalls, 1);
    expect(find.byKey(const ValueKey('deviceRow:dev-remote')), findsOneWidget);
    expect(
      dotColor(tester, const ValueKey('deviceDot:dev-remote')),
      paletteOf(tester).dim,
    );
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-remote')));
    await tester.pump();
    expect(find.text('Workstation'), findsOneWidget);
    expect(find.text('thinkpad'), findsNothing);

    service.emitEnvelope(
      _envelope(deviceId: 'dev-remote', msgId: 'remote-online'),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('deviceRow:dev-remote')), findsOneWidget);
    expect(
      dotColor(tester, const ValueKey('deviceDot:dev-remote')),
      paletteOf(tester).teal,
    );
    expect(find.text('Workstation'), findsWidgets);

    service.rosterDevices = const [
      DeviceInfo(
        deviceId: 'dev-remote',
        name: 'thinkpad',
        friendlyName: 'Desk',
        presence: 'online',
      ),
    ];
    service.emitRoster(
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.roster,
        msgId: 'roster-refresh',
        ts: rfc3339Timestamp(DateTime.utc(2026, 11, 12)),
      ),
    );
    await tester.pump();
    expect(service.rosterFetchCalls, 2);
    expect(find.text('Desk'), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceRow:dev-remote')), findsOneWidget);
  });

  testWidgets('rename dialog validates 64 runes and submits a friendly name '
      'from the own-avatar long press', (tester) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    );
    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    await openDeviceRename(tester);
    expect(find.text('Rename device'), findsOneWidget);
    expect(find.byKey(const ValueKey('renameDeviceName')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('renameDeviceName')),
      'a' * 65,
    );
    await tester.tap(find.byKey(const ValueKey('renameDeviceConfirm')));
    await tester.pump();
    expect(
      find.text('Device names can be at most 64 characters.'),
      findsOneWidget,
    );
    expect(find.text('65/64'), findsOneWidget);
    expect(service.renameRequests, isEmpty);

    final sixtyFourEmoji = '😀' * 64;
    await tester.enterText(
      find.byKey(const ValueKey('renameDeviceName')),
      sixtyFourEmoji,
    );
    await tester.tap(find.byKey(const ValueKey('renameDeviceConfirm')));
    await tester.pumpAndSettle();

    expect(service.renameRequests, [sixtyFourEmoji]);
    expect(find.byKey(const ValueKey('renameDeviceName')), findsNothing);
    expect(service.ownFriendlyName, sixtyFourEmoji);
    expect(find.text('64/64'), findsNothing);
  });

  testWidgets('submitting an empty friendly name clears back to This device', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
      ownDevice: const DeviceInfo(
        deviceId: 'dev-1',
        name: 'MacBook-Pro',
        friendlyName: 'Studio',
      ),
    );
    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    await openDeviceRename(tester);
    await tester.enterText(find.byKey(const ValueKey('renameDeviceName')), '');
    await tester.tap(find.byKey(const ValueKey('renameDeviceConfirm')));
    await tester.pumpAndSettle();

    expect(service.renameRequests, ['']);
    expect(service.ownFriendlyName, isNull);
    expect(find.text('This device'), findsWidgets);
    expect(find.byKey(const ValueKey('devicePaneSubtitle')), findsNothing);
  });

  testWidgets('rename server errors stay in the dialog and can be edited', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-1',
    )..renameHandler = (_) async => throw StateError('server offline');
    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();

    await openDeviceRename(tester);
    await tester.enterText(
      find.byKey(const ValueKey('renameDeviceName')),
      'New name',
    );
    await tester.tap(find.byKey(const ValueKey('renameDeviceConfirm')));
    await tester.pump();

    expect(find.byKey(const ValueKey('renameDeviceName')), findsOneWidget);
    expect(find.byKey(const ValueKey('renameDeviceError')), findsOneWidget);
    expect(find.textContaining('server offline'), findsOneWidget);
    expect(service.renameRequests, ['New name']);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('renameDeviceName')))
          .enabled,
      isTrue,
    );
  });

  group('machine grouping + DM conversation', () {
    test('machineGroupKey normalizes and rejects generic names', () {
      expect(machineGroupKey('EPBYGROW03B0'), 'epbygrow03b0');
      expect(machineGroupKey(' epbygrow03b0 '), 'epbygrow03b0');
      expect(machineGroupKey('device'), isNull);
      expect(machineGroupKey(''), isNull);
      expect(machineGroupKey(null), isNull);
    });

    test('devicePlatformIcon heuristics', () {
      expect(devicePlatformIcon(name: 'EPBYGROW03B0'), FaSemanticIcon.laptop);
      expect(devicePlatformIcon(name: 'macbook-pro'), FaSemanticIcon.laptop);
      expect(devicePlatformIcon(name: 'iPhone 15'), FaSemanticIcon.phone);
      expect(
        devicePlatformIcon(name: 'Pixel 8', friendlyName: 'Duo'),
        FaSemanticIcon.phone,
      );
      expect(devicePlatformIcon(name: 'device'), isNull);
    });

    testWidgets('same-hostname devices merge into one card, any-online', (
      tester,
    ) async {
      final service = FakeDevicesService(
        initialPhase: DeviceConnectorPhase.online,
        deviceId: 'dev-1',
        rosterDevices: const [
          DeviceInfo(deviceId: 'dev-cli', name: 'EPBYGROW03B0'),
          DeviceInfo(deviceId: 'dev-mac', name: 'epbygrow03b0'),
        ],
      );
      await tester.pumpWidget(_wrap(devicesPage(service)));
      await tester.pump();
      service
        ..emitEnvelope(
          _envelope(
            deviceId: 'dev-cli',
            agents: const {'fa': AgentRunState.live},
          ),
        )
        ..emitEnvelope(
          _envelope(
            deviceId: 'dev-mac',
            machine: MachinePresence.offline,
            agents: const {'fa': AgentRunState.offline},
          ),
        );
      await tester.pump();

      // One machine card (not two device cells), teal = any member online.
      expect(
        find.byKey(const ValueKey('deviceRow:machine:epbygrow03b0')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('deviceRow:dev-cli')), findsNothing);
      expect(find.byKey(const ValueKey('deviceRow:dev-mac')), findsNothing);
      expect(
        dotColor(tester, const ValueKey('deviceDot:machine:epbygrow03b0')),
        paletteOf(tester).teal,
      );
    });

    testWidgets('generic device names never group', (tester) async {
      final service = FakeDevicesService(
        initialPhase: DeviceConnectorPhase.online,
        deviceId: 'dev-1',
        rosterDevices: const [
          DeviceInfo(deviceId: 'dev-a', name: 'device'),
          DeviceInfo(deviceId: 'dev-b', name: 'device'),
        ],
      );
      await tester.pumpWidget(_wrap(devicesPage(service)));
      await tester.pump();
      service
        ..emitEnvelope(_envelope(deviceId: 'dev-a', msgId: 'online-a'))
        ..emitEnvelope(_envelope(deviceId: 'dev-b', msgId: 'online-b'));
      await tester.pump();
      // Placeholder names alone must not merge two running physical devices.
      expect(find.byKey(const ValueKey('deviceRow:dev-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('deviceRow:dev-b')), findsOneWidget);
    });

    testWidgets('own-hostname remote merges into the own card', (tester) async {
      final service = FakeDevicesService(
        initialPhase: DeviceConnectorPhase.online,
        deviceId: 'dev-1',
        ownDevice: const DeviceInfo(deviceId: 'dev-1', name: 'test-host'),
        rosterDevices: const [
          DeviceInfo(deviceId: 'dev-cli', name: 'test-host'),
        ],
      );
      await tester.pumpWidget(_wrap(devicesPage(service)));
      await tester.pump();
      service.emitEnvelope(
        _envelope(
          deviceId: 'dev-cli',
          agents: const {'fa': AgentRunState.live},
        ),
      );
      await tester.pump();

      // No separate rail cell — the CLI's agent rides the own pane.
      expect(find.byKey(const ValueKey('deviceRow:dev-cli')), findsNothing);
      expect(find.byKey(const ValueKey('agentRow:fa')), findsOneWidget);
    });

    testWidgets(
      'owner mymac aliases merge and every remote UUID gets a CLI title',
      (tester) async {
        const ids = [
          '01a0ca2d-783a-78a0-8217-0533f83f8912',
          '01a1d9c0-3019-7ce5-bf00-a412bce3d1f0',
          '01a1f815-e533-73e7-9757-acaf7e933239',
          '01a1e375-6757-78d7-bdbc-6e47976a6b67',
          '01a15985-f6c3-7345-ae10-e44fc7fbb827',
          '01a1f53f-0f40-733b-9cc4-894a1e1237bf',
          '01a1e9f3-5ab6-726f-9719-a7d43b6487b0',
        ];
        final service = FakeDevicesService(
          initialPhase: DeviceConnectorPhase.online,
          deviceId: 'dev-own',
          personalNetworkId: 'net-personal',
          ownDevice: const DeviceInfo(
            deviceId: 'dev-own',
            name: 'mymac.local',
            friendlyName: 'mymac',
          ),
          rosterDevices: const [
            DeviceInfo(
              deviceId: 'dev-cli',
              name: 'Uladzimirs-MacBook-Pro',
              friendlyName: 'mymac',
            ),
            DeviceInfo(
              deviceId: 'dev-phone',
              name: 'iPhone',
              friendlyName: 'MyMac',
            ),
            DeviceInfo(deviceId: 'dev-vpn', name: 'vpn', friendlyName: 'mymac'),
          ],
        );
        await tester.pumpWidget(_wrap(devicesPage(service)));
        await tester.pump();
        service.emitRoster(
          _devicesEnvelope(
            devices: [
              for (var index = 0; index < ids.length; index++)
                {
                  'deviceId': 'dev-$index',
                  'name': index.isEven ? 'mymac.local' : 'vpn',
                  'friendlyName': 'mymac',
                  'presence': 'online',
                  'sessions': [
                    {
                      'id': ids[index],
                      'state': 'wake_on_dm',
                      'networks': ['net-personal'],
                      if (index == 0) 'path': '/work/flutter_agent',
                      if (index == 1)
                        'lastDmPreview': 'Peer answered from the vpn session',
                      if (index == 2) 'displayName': 'goal_builder',
                    },
                  ],
                },
            ],
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.descendant(
            of: find.byKey(const ValueKey('deviceRail')),
            matching: find.byType(InkWell),
          ),
          findsOneWidget,
          reason: 'one physical mymac, not one avatar per enrollment',
        );
        expect(find.byKey(const ValueKey('deviceRow:dev-cli')), findsNothing);
        expect(find.byKey(const ValueKey('deviceRow:dev-vpn')), findsNothing);
        for (final id in ids) {
          final card = tester.widget<DeviceSessionCard>(
            find.byKey(ValueKey('sessionRow:$id')),
          );
          expect(card.title, isNot(id));
          expect(card.title, isNot(startsWith('01a')));
        }
        expect(find.text('CLI · flutter_agent'), findsOneWidget);
        expect(
          find.text('CLI · Peer answered from the vpn session'),
          findsOneWidget,
        );
        expect(find.text('goal_builder'), findsOneWidget);
        expect(find.text('CLI · 01a1e375…6b67'), findsOneWidget);
        expect(find.text('mymac'), findsOneWidget);
        expect(find.byKey(const ValueKey('devicePaneTitle')), findsNothing);
        for (final id in ids) {
          expect(
            find.descendant(
              of: find.byKey(ValueKey('sessionRow:$id')),
              matching: find.textContaining('mymac'),
            ),
            findsNothing,
          );
        }
      },
    );

    testWidgets('agent tap opens the DM via the shell callback; roster stays', (
      tester,
    ) async {
      final service = FakeDevicesService(
        initialPhase: DeviceConnectorPhase.online,
        deviceId: 'dev-1',
        rosterDevices: const [
          DeviceInfo(deviceId: 'dev-mac', name: 'mac-host'),
        ],
      );
      final opened =
          <({String deviceId, String agentAddress, String? sessionId})>[];
      await tester.pumpWidget(
        _wrap(
          devicesPage(
            service,
            onOpenRemoteConversation:
                ({
                  required String deviceId,
                  required String deviceLabel,
                  required String agentAddress,
                  String? sessionId,
                  String? sessionTitle,
                }) => opened.add((
                  deviceId: deviceId,
                  agentAddress: agentAddress,
                  sessionId: sessionId,
                )),
          ),
        ),
      );
      await tester.pump();
      service.emitEnvelope(
        _envelope(
          deviceId: 'dev-mac',
          agents: const {'fa': AgentRunState.live},
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('deviceRow:dev-mac')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('agentRow:fa')));
      await tester.pump();

      // The callback carries the full DM target; the roster pane stays
      // in place (the conversation lives in the shell's message column).
      expect(opened.single.deviceId, 'dev-mac');
      expect(opened.single.agentAddress, 'fa@dev-mac');
      expect(opened.single.sessionId, isNull);
      expect(find.byKey(const ValueKey('devicePane:dev-mac')), findsOneWidget);
    });
  });

  group('field regressions: physical roster, metadata rows, reconnect', () {
    testWidgets(
      'friendly own device is named only by the appbar in drilldown',
      (tester) async {
        final service = FakeDevicesService(
          initialPhase: DeviceConnectorPhase.online,
          deviceId: 'dev-1',
          ownDevice: const DeviceInfo(
            deviceId: 'dev-1',
            name: 'EPBYGROW03B0',
            friendlyName: 'Mac',
          ),
        );
        await tester.pumpWidget(_wrap(devicesPage(service)));
        await tester.pump();

        expect(find.byKey(const ValueKey('currentDeviceBadge')), findsNothing);
        expect(find.byKey(const ValueKey('devicePaneTitle')), findsNothing);
        expect(find.text('this device'), findsNothing);
        expect(find.text('Mac'), findsOneWidget);
      },
    );

    testWidgets('dead generic enrollments disappear and duplicate generic '
        'enrollments sharing persisted sessions merge by physical machine', (
      tester,
    ) async {
      final service = FakeDevicesService(
        initialPhase: DeviceConnectorPhase.online,
        deviceId: 'dev-own',
        personalNetworkId: 'net-personal',
        ownDevice: const DeviceInfo(
          deviceId: 'dev-own',
          name: 'EPBYGROW03B0',
          friendlyName: 'Mac',
        ),
        rosterDevices: [
          const DeviceInfo(
            deviceId: 'phantom-1',
            name: 'device',
            presence: 'offline',
          ),
          const DeviceInfo(deviceId: 'phantom-2', name: 'device'),
          DeviceInfo(
            deviceId: 'phantom-stale',
            name: 'device',
            createdAt: DateTime.utc(2020),
          ),
          const DeviceInfo(
            deviceId: 'dev-duo-old',
            name: 'device',
            friendlyName: 'Duo',
          ),
          DeviceInfo(deviceId: 'dev-duo', name: 'device', friendlyName: 'Duo'),
        ],
      );
      await tester.pumpWidget(_wrap(devicesPage(service)));
      await tester.pump();
      service.emitRoster(
        _devicesEnvelope(
          devices: const [
            {
              'deviceId': 'phantom-stale',
              'name': 'device',
              'presence': 'offline',
              'createdAt': '2020-01-01T00:00:00.000Z',
              'sessions': [
                {
                  'id': 'unique-dead-test-chat',
                  'state': 'offline',
                  'networks': ['net-personal'],
                },
              ],
            },
            {
              'deviceId': 'dev-duo-old',
              'name': 'device',
              'friendlyName': 'Duo',
              'presence': 'offline',
              'sessions': [
                {
                  'id': 'shared-chat',
                  'state': 'wake_on_dm',
                  'networks': ['net-personal'],
                },
              ],
            },
            {
              'deviceId': 'dev-duo',
              'name': 'device',
              'friendlyName': 'Duo',
              'presence': 'online',
              'sessions': [
                {
                  'id': 'shared-chat',
                  'state': 'live',
                  'networks': ['net-personal'],
                },
              ],
            },
          ],
        ),
      );
      await tester.pump();

      // Own Mac + one Duo = exactly two physical entries. Dead, unnamed test
      // enrollments never become rail cells; the live duplicate wins presence.
      expect(find.byKey(const ValueKey('deviceRow')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('deviceRail')),
          matching: find.byType(InkWell),
        ),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey('deviceRow:machine:duo')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('deviceRow:phantom-1')), findsNothing);
      expect(find.byKey(const ValueKey('deviceRow:phantom-2')), findsNothing);
      expect(
        find.byKey(const ValueKey('deviceRow:phantom-stale')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('deviceRow:dev-duo-old')), findsNothing);
      expect(find.byKey(const ValueKey('deviceRow:dev-duo')), findsNothing);
      expect(
        dotColor(tester, const ValueKey('deviceDot:machine:duo')),
        paletteOf(tester).teal,
      );
    });

    testWidgets('remote rows use title, relative time and path; presence '
        'heartbeats retain the persisted roster and older id-only rows shorten '
        'their fallback title', (tester) async {
      final service = FakeDevicesService(
        initialPhase: DeviceConnectorPhase.online,
        deviceId: 'dev-own',
        personalNetworkId: 'net-personal',
      );
      await tester.pumpWidget(_wrap(devicesPage(service)));
      await tester.pump();
      service.emitRoster(
        _devicesEnvelope(
          devices: const [
            {
              'deviceId': 'dev-mac',
              'name': 'EPBYGROW03B0',
              'presence': 'online',
              'sessions': [
                {
                  'id': '123e4567-e89b-12d3-a456-426614174000',
                  'state': 'wake_on_dm',
                  'networks': ['net-personal'],
                  'title': 'Release plan',
                  'path': '/work/flutter_agent',
                  'lastActivity': '2026-11-12T09:00:00.000Z',
                },
                {
                  'id': 'abcdef12-0000-0000-0000-000000000000',
                  'state': 'wake-on-DM',
                  'networks': ['net-personal'],
                },
              ],
            },
          ],
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('deviceRow:dev-mac')));
      await tester.pumpAndSettle();

      // Networks' adapter is flat for every device: path and unknown-path
      // rows are both immediately visible, with no conditional grouping.
      expect(
        find.byKey(
          const ValueKey('sessionRow:123e4567-e89b-12d3-a456-426614174000'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('sessionRow:abcdef12-0000-0000-0000-000000000000'),
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'remoteFolderHeader:',
              ),
        ),
        findsNothing,
      );

      final titled = tester.widget<DeviceSessionCard>(
        find.byKey(
          const ValueKey('sessionRow:123e4567-e89b-12d3-a456-426614174000'),
        ),
      );
      expect(titled.title, 'Release plan');
      expect(titled.subtitle, '/work/flutter_agent');
      expect(titled.stateLabel, 'Wake on DM');
      expect(titled.timestamp, isNotEmpty);
      expect(find.text('123e4567-e89b-12d3-a456-426614174000'), findsNothing);
      expect(find.text('Offline'), findsNothing);
      expect(find.text('CLI · abcdef12…0000'), findsOneWidget);
      expect(find.text('abcdef12-0000-0000-0000-000000000000'), findsNothing);

      // A live-only/empty presence projection is a patch, not an instruction
      // to erase the REST roster's persisted sessions.
      service.emitEnvelope(
        _devicesEnvelope(
          kind: NetworkEnvelopeKind.presence,
          msgId: 'live-only-heartbeat',
          devices: const [
            {
              'deviceId': 'dev-mac',
              'name': 'EPBYGROW03B0',
              'presence': 'online',
              'agents': [],
              'sessions': [],
            },
          ],
        ),
      );
      await tester.pump();
      expect(find.text('Release plan'), findsOneWidget);
      expect(find.text('No sessions yet'), findsNothing);

      service.emitEnvelope(
        _devicesEnvelope(
          kind: NetworkEnvelopeKind.presence,
          msgId: 'delete-one-session',
          devices: const [
            {
              'deviceId': 'dev-mac',
              'name': 'EPBYGROW03B0',
              'presence': 'online',
              'sessions': [
                {
                  'id': 'abcdef12-0000-0000-0000-000000000000',
                  'state': 'offline',
                  'networks': <Object?>[],
                },
              ],
            },
          ],
        ),
      );
      await tester.pump();
      expect(find.text('abcdef12'), findsNothing);
      expect(find.text('Release plan'), findsOneWidget);
    });

    testWidgets('online → connecting/preparing/reconnecting keeps the same '
        'rail and session pane mounted; only the phase banner changes', (
      tester,
    ) async {
      final controller = chatListOf([
        localEntry('stable-chat', title: 'Stable chat', folderPath: '/work'),
      ]);
      final service = FakeDevicesService(
        initialPhase: DeviceConnectorPhase.online,
        deviceId: 'dev-own',
      );
      await tester.pumpWidget(
        _wrap(devicesPage(service, sessions: controller)),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('sessionRow:stable-chat')),
        findsOneWidget,
      );

      for (final phase in const [
        DeviceConnectorPhase.connecting,
        DeviceConnectorPhase.reconnecting,
        DeviceConnectorPhase.preparing,
      ]) {
        service.setPhase(phase);
        await tester.pump();
        expect(find.byKey(const ValueKey('deviceRail')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('sessionRow:stable-chat')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('devicesSkeleton')), findsNothing);
        expect(find.text('Stable chat'), findsOneWidget);
      }
    });
  });

  testWidgets('marked remote child and orphaned rows never leak into folders', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-own',
      personalNetworkId: 'net-personal',
    );
    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();
    service.emitRoster(
      _devicesEnvelope(
        devices: const [
          {
            'deviceId': 'dev-parent',
            'name': 'Workstation',
            'presence': 'online',
            'sessions': [
              {
                'id': 'parent',
                'state': 'live',
                'networks': ['net-personal'],
                'title': 'Parent session',
                'path': '/work/parent',
              },
              {
                'id': 'child',
                'state': 'live',
                'networks': ['net-personal'],
                'title': 'Child session',
                'path': '/work/child',
                'agent': 'subagent',
                'parent': 'parent',
              },
              {
                'id': 'orphan',
                'state': 'live',
                'networks': ['net-personal'],
                'title': 'Legacy child',
                'path': '/work/legacy',
                'subagent': true,
              },
            ],
          },
        ],
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-parent')));
    await tester.pump();

    expect(find.byKey(const ValueKey('sessionRow:parent')), findsOneWidget);
    expect(find.byKey(const ValueKey('sessionRow:child')), findsNothing);
    expect(find.byKey(const ValueKey('sessionRow:orphan')), findsNothing);
    expect(find.byType(DeviceSessionCard), findsOneWidget);
  });

  testWidgets('offline session rows age out after the documented TTL', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-own',
      personalNetworkId: 'net-personal',
    );
    await tester.pumpWidget(
      _wrap(devicesPage(service, now: () => DateTime.utc(2026, 11, 15))),
    );
    await tester.pump();
    service.emitRoster(
      _devicesEnvelope(
        devices: const [
          {
            'deviceId': 'dev-offline',
            'name': 'Offline workstation',
            'presence': 'offline',
            'sessions': [
              {
                'id': 'stale',
                'state': 'offline',
                'networks': ['net-personal'],
                'title': 'Stale session',
                'lastActivity': '2026-10-01T00:00:00Z',
              },
              {
                'id': 'recent',
                'state': 'offline',
                'networks': ['net-personal'],
                'title': 'Recent session',
                'lastActivity': '2026-11-14T00:00:00Z',
              },
            ],
          },
        ],
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-offline')));
    await tester.pump();

    expect(find.byKey(const ValueKey('sessionRow:stale')), findsNothing);
    expect(find.byKey(const ValueKey('sessionRow:recent')), findsOneWidget);
  });

  testWidgets('own offline rows use the same TTL while live old rows stay', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-own',
    );
    final sessions = chatListOf([
      localEntry('stale', createdAt: DateTime.utc(2026, 10)),
      localEntry('recent', createdAt: DateTime.utc(2026, 11, 14)),
      localEntry(
        'old-live',
        createdAt: DateTime.utc(2026, 10),
        presence: ChatPresence.live,
      ),
    ]);
    await tester.pumpWidget(
      _wrap(
        devicesPage(
          service,
          sessions: sessions,
          now: () => DateTime.utc(2026, 11, 15),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('sessionRow:stale')), findsNothing);
    expect(find.byKey(const ValueKey('sessionRow:recent')), findsOneWidget);
    expect(find.byKey(const ValueKey('sessionRow:old-live')), findsOneWidget);
  });

  testWidgets('roster agents with address and implicit exposure still render', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-own',
    );
    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();
    service.emitRoster(
      _devicesEnvelope(
        devices: const [
          {
            'deviceId': 'dev-agent',
            'name': 'Agent host',
            'agents': [
              {'address': 'fa', 'state': 'live', 'dmPub': 'public-key'},
            ],
          },
        ],
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-agent')));
    await tester.pump();

    expect(find.byKey(const ValueKey('agentRow:fa')), findsOneWidget);
    final dynamic pageState = tester.state(find.byType(DevicesPage));
    expect(pageState.debugRemoteAgentDmPubs('dev-agent'), {
      'fa@dev-agent': 'public-key',
    });
  });

  testWidgets('flat session hairlines stay stable across device switches', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-own',
      personalNetworkId: 'net-personal',
    );
    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();
    service.emitRoster(
      _devicesEnvelope(
        devices: const [
          {
            'deviceId': 'dev-mac',
            'name': 'Mac',
            'presence': 'online',
            'sessions': [
              {
                'id': 'aaa',
                'state': 'live',
                'networks': ['net-personal'],
                'path': '/work/a',
                'title': 'A',
              },
              {
                'id': 'bbb',
                'state': 'live',
                'networks': ['net-personal'],
                'path': '/work/b',
                'title': 'B',
              },
            ],
          },
        ],
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-mac')));
    await tester.pumpAndSettle();

    DeviceSessionCard card(String id) => tester.widget<DeviceSessionCard>(
      find.byKey(ValueKey('sessionRow:$id')),
    );
    expect(card('aaa').hairline, isTrue);
    expect(card('bbb').hairline, isFalse, reason: 'last visible row');

    await tester.tap(find.byKey(const ValueKey('deviceRow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-mac')));
    await tester.pumpAndSettle();
    expect(card('aaa').hairline, isTrue);
    expect(card('bbb').hairline, isFalse);
  });
}
