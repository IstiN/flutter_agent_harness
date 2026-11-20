@TestOn('vm')
/// Golden frames for the Telegram-style vertical rail (the wide shell's
/// left navigation) and the Local section's folder-first navigation:
///
/// - rail rows unselected / selected (accent tint, no fill) / badge
///   variants (accent + muted overlap circles), dark + light;
/// - the Local folder list (deterministic gradient-letter avatars,
///   session counts, running dots, latest-activity times);
/// - an open folder's Telegram-style session list (name, time, preview,
///   unread/running badges, accent-selected row, hairlines);
/// - the chat column's NETWORKS panel (membership rows, letter-gradient
///   avatars, live status meta).
library;

import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/fa_network_client.dart' show DeviceInfo;
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/chats/local_sessions_panel.dart';
import 'package:fa/ui/chats/messenger_drilldown_panel.dart';
import 'package:fa/ui/chats/networks_list_panel.dart';
import 'package:fa/ui/network/device_roster_panel.dart';
import 'package:fa/ui/network/devices_page.dart';
import 'package:fa/ui/widgets/messenger_nav_rail.dart';
import 'package:fa_ui/fa_ui.dart'
    show FahColors, FaVisualDirection, buildFaTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../network/fakes.dart';
import '../ui/devices_page_test.dart' show FakeDevicesService;
import 'golden_test_helper.dart';

/// Long-dead activity stamps (> 7 days old) so [chatListRelativeTime]
/// renders the stable "Dec 1" form instead of a now-relative count.
final _stamp = DateTime.utc(2025, 12, 1, 9, 30);

MessengerRailDestination _dest(
  IconData icon,
  String label, {
  bool selected = false,
  int? badge,
  bool badgeMuted = false,
}) => MessengerRailDestination(
  rowKey: ValueKey('golden-$label'),
  icon: icon,
  label: label,
  selected: selected,
  badge: badge,
  badgeMuted: badgeMuted,
  onTap: (_) {},
);

List<MessengerRailDestination> _railDestinations({
  required bool selected,
  required bool badges,
}) => [
  _dest(Icons.inbox_outlined, 'All', selected: selected),
  _dest(Icons.chat_bubble_outline_rounded, 'Unread', badge: badges ? 4 : null),
  _dest(
    Icons.folder_outlined,
    'Local',
    selected: false,
    badge: badges ? 2 : null,
    badgeMuted: true,
  ),
  _dest(Icons.public_outlined, 'Networks'),
  _dest(Icons.tag_rounded, 'Channels'),
  _dest(Icons.notifications_none_rounded, 'Activity'),
  _dest(Icons.apps_rounded, 'Apps'),
];

ChatListEntry _session(
  String id,
  String? cwd, {
  String? title,
  String? preview,
  int unread = 0,
  bool streaming = false,
}) => ChatListEntry(
  id: ChatEntryId.local(id),
  kind: ChatListEntryKind.localAgent,
  folderPath: cwd,
  title: title ?? id,
  preview: preview ?? 'Preview of $id',
  createdAt: _stamp,
  lastActivity: _stamp,
  unreadCount: unread,
  localMessageCount: 5,
  isStreaming: streaming,
);

Future<ChatListController> _controller(List<ChatListEntry> entries) async {
  final controller = ChatListController(
    localAdapter: StaticChatListAdapter(entries),
  );
  await controller.load();
  return controller;
}

const _unnamedDeviceId = '01a15985-f6c3-7e9e-b16b-203817f2a9c2';
const _folderSessionId = '123e4567-e89b-12d3-a456-426614174000';
const _fallbackSessionId = '89abcdef-e89b-12d3-a456-426614174000';
const _remoteFallbackSessionId = 'abcdef12-e89b-12d3-a456-426614174000';
const _ownerSessionId = '01a15985-f6c3-7345-ae10-e44fc7a9c201';
const _releaseSessionId = '234e4567-e89b-12d3-a456-426614174000';
const _opsSessionId = '345e4567-e89b-12d3-a456-426614174000';
const _cliAgentId = '456e4567-e89b-12d3-a456-426614174000';

Future<void> _pumpAdaptiveDevices(
  WidgetTester tester,
  Size size, {
  DeviceConnectorPhase phase = DeviceConnectorPhase.online,
}) async {
  final service = FakeDevicesService(
    initialPhase: phase,
    deviceId: 'self',
    ownDevice: const DeviceInfo(
      deviceId: 'self',
      name: 'workstation',
      friendlyName: 'Workstation',
    ),
    rosterDevices: const [
      DeviceInfo(deviceId: 'dev-mac', name: 'mymac', presence: 'online'),
      DeviceInfo(deviceId: _unnamedDeviceId, name: '', presence: 'online'),
    ],
  );
  // Replay a neighbor's roster before the page opens: both a cwd-named row
  // and a metadata-free row must follow the same flat list as This device.
  service.seededRoster.add(
    NetworkEnvelope(
      kind: NetworkEnvelopeKind.roster,
      msgId: 'golden-remote-sessions',
      ts: '2025-12-01T09:30:00.000Z',
      payload: const {
        'devices': [
          {
            'deviceId': 'dev-mac',
            'name': 'mymac',
            'presence': 'online',
            'agents': [
              {
                'address': 'main@dev-mac',
                'state': 'live',
                'dmPub': 'cHViLW1hYw==',
              },
              {
                'address': _cliAgentId,
                'state': 'live',
                'dmPub': 'cHViLWNsaQ==',
              },
            ],
            'sessions': [
              {
                'id': _ownerSessionId,
                'displayName': 'goal_builder',
                'lastDmPreview': 'Latest peer answer from the named CLI',
                'path':
                    '/Users/Uladzimir_Klyshevich/git/flutter_js_widget_runtime',
                'state': 'live',
                'lastActivity': '2025-12-01T09:30:00.000Z',
              },
              {
                'id': _releaseSessionId,
                'lastDmPreview': 'Release review completed on the peer',
                'path': '/work/flutter_agent',
                'state': 'wake_on_dm',
                'lastActivity': '2025-12-01T09:30:00.000Z',
              },
              {
                'id': _opsSessionId,
                'displayName': 'Ops console',
                'lastDmPreview': 'Latest operations reply',
                'path': '/work/ops',
                'state': 'wake_on_dm',
                'lastActivity': '2025-12-01T09:30:00.000Z',
              },
              {
                'id': _remoteFallbackSessionId,
                'state': 'offline',
                'lastActivity': '2025-12-01T09:30:00.000Z',
              },
            ],
          },
        ],
      },
    ),
  );
  final sessions = await _controller([
    _session(
      'named-local',
      '/work/flutter_agent',
      title: 'Release assistant',
      preview: 'Ship the adaptive device roster',
      streaming: true,
    ),
    _session(
      _folderSessionId,
      '/work/flutter_agent',
      preview: 'This prompt must not replace the project folder',
    ),
    _session(_fallbackSessionId, null),
  ]);
  await pumpGolden(
    tester,
    DevicesPage(
      service: service,
      sessions: sessions,
      compact: size.width < 640,
      now: () => DateTime.utc(2025, 12, 1, 11, 30),
    ),
    size: size,
    theme: buildFaTheme(
      direction: FaVisualDirection.glass,
      brightness: Brightness.dark,
    ),
    wrap: (child) => Scaffold(body: child),
  );
}

Future<void> _pumpRail(
  WidgetTester tester, {
  required Brightness brightness,
  required bool selected,
  required bool badges,
  required String name,
}) async {
  await pumpGolden(
    tester,
    MessengerNavRail(
      destinations: _railDestinations(selected: selected, badges: badges),
      settingsLabel: 'Settings',
      onSettingsTap: () {},
    ),
    size: const Size(900, 800),
    theme: buildFaTheme(
      direction: FaVisualDirection.glass,
      brightness: brightness,
    ),
    wrap: (child) => Scaffold(
      body: Row(
        children: [
          child,
          Expanded(
            child: Builder(
              builder: (context) => ColoredBox(
                color: FahColors.of(context).panel,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  await expectGolden(tester, name);
}

Future<void> _pumpLocalPanel(
  WidgetTester tester, {
  required ChatListController controller,
  String? folderId,
  required String name,
  Size size = const Size(500, 640),
}) async {
  await pumpGolden(
    tester,
    Scaffold(
      body: LocalSessionsPanel(
        controller: controller,
        selectedFolderId: folderId,
        onSelectFolder: (_) {},
        selectedSessionId: folderId == null ? null : 'design-session',
        onOpenSession: (_) {},
        onNew: () {},
      ),
    ),
    size: size,
    theme: buildFaTheme(
      direction: FaVisualDirection.glass,
      brightness: Brightness.dark,
    ),
    wrap: (child) => child,
  );
  await expectGolden(tester, name);
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    await initializeDateFormatting('en');
    await initializeDateFormatting('ru');
  });

  testWidgets('rail rows unselected: icon over label, no tint, no badges', (
    tester,
  ) async {
    await _pumpRail(
      tester,
      brightness: Brightness.dark,
      selected: false,
      badges: false,
      name: 'rail_nav_unselected',
    );
  });

  testWidgets('rail selection: accent tint on icon+label, no fill', (
    tester,
  ) async {
    await _pumpRail(
      tester,
      brightness: Brightness.dark,
      selected: true,
      badges: true,
      name: 'rail_nav_selected',
    );
  });

  testWidgets('rail badges: accent and muted overlap circles (light)', (
    tester,
  ) async {
    await _pumpRail(
      tester,
      brightness: Brightness.light,
      selected: true,
      badges: true,
      name: 'rail_nav_selected_light',
    );
  });

  testWidgets('local folder list: gradient avatars, counts, running dots', (
    tester,
  ) async {
    await _pumpLocalPanel(
      tester,
      name: 'local_folders',
      controller: await _controller([
        _session('design-session', '/work/flutter_agent', unread: 3),
        _session('docs-session', '/work/flutter_agent'),
        _session('mono-review', '/work/mono', streaming: true),
        _session('sandbox-chat', null),
      ]),
    );
  });

  testWidgets('local folder sessions: Telegram rows with badges and '
      'selection', (tester) async {
    await _pumpLocalPanel(
      tester,
      name: 'local_folder_sessions',
      folderId: '/work/flutter_agent',
      controller: await _controller([
        _session(
          'design-session',
          '/work/flutter_agent',
          preview: 'Rail pitch locked at 64pt',
          unread: 4,
        ),
        _session(
          'docs-session',
          '/work/flutter_agent',
          preview: 'Regenerated the l10n arb keys',
          streaming: true,
        ),
      ]),
    );
  });

  testWidgets('Devices phone reuses the Networks list and drill-down', (
    tester,
  ) async {
    await _pumpAdaptiveDevices(tester, goldenSizePhone);

    expect(find.byKey(const ValueKey('deviceRail')), findsNothing);
    expect(find.byKey(const ValueKey('deviceSelectedCapsule')), findsNothing);
    expect(find.text('mymac'), findsOneWidget);
    expect(find.text('01a15985…a9c2'), findsOneWidget);
    await expectGolden(tester, 'devices_phone_list');

    await tester.tap(find.byKey(const ValueKey('deviceRow')));
    await tester.pumpAndSettle();
    expect(find.text('Release assistant'), findsOneWidget);
    expect(find.text('flutter_agent'), findsOneWidget);
    expect(find.text('/work/flutter_agent'), findsNWidgets(2));
    expect(find.text('89abcdef…4000'), findsOneWidget);
    expect(find.byType(MessengerPanelRow), findsWidgets);
    expect(find.byType(DeviceSessionCard), findsWidgets);
    expect(find.byKey(const ValueKey('devicePaneTitle')), findsNothing);
    expect(find.text('Workstation'), findsOneWidget);
    await expectGolden(tester, 'devices_phone_sessions');

    await tester.tap(find.byKey(const ValueKey('deviceBackButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-mac')));
    await tester.pumpAndSettle();
    expect(find.text('goal_builder'), findsOneWidget);
    expect(find.text('/Users/Uladz…idget_runtime'), findsOneWidget);
    expect(find.text('CLI · flutter_agent'), findsOneWidget);
    expect(find.text('Ops console'), findsOneWidget);
    expect(find.text('CLI · 456e4567…4000'), findsOneWidget);
    expect(find.text('CLI · abcdef12…4000'), findsOneWidget);
    expect(find.text(_remoteFallbackSessionId), findsNothing);
    expect(find.byKey(const ValueKey('devicePaneTitle')), findsNothing);
    expect(find.text('mymac'), findsOneWidget);
    await expectGolden(tester, 'devices_phone_remote_sessions');
  });

  testWidgets('Devices phone connecting keeps the populated list geometry', (
    tester,
  ) async {
    await _pumpAdaptiveDevices(
      tester,
      goldenSizePhone,
      phase: DeviceConnectorPhase.connecting,
    );

    expect(find.byKey(const ValueKey('devicesConnecting')), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceList')), findsOneWidget);
    expect(find.textContaining('This device'), findsWidgets);
    expect(find.byKey(const ValueKey('devicesSkeleton')), findsNothing);
    await expectGolden(tester, 'devices_phone_connecting');
  });

  testWidgets('Devices desktop reuses the Networks list and mini-strip', (
    tester,
  ) async {
    await _pumpAdaptiveDevices(tester, goldenSizeDesktop);

    expect(find.byKey(const ValueKey('deviceList')), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceRail')), findsNothing);
    expect(find.byType(VerticalDivider), findsNothing);
    await expectGolden(tester, 'devices_desktop_list');

    await tester.tap(find.byKey(const ValueKey('deviceRow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('deviceRail')), findsOneWidget);
    expect(find.byType(VerticalDivider), findsNothing);
    expect(find.text('Release assistant'), findsOneWidget);
    expect(find.text('flutter_agent'), findsOneWidget);
    expect(find.text('/work/flutter_agent'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('devicePaneTitle')), findsNothing);
    expect(find.text('Workstation'), findsOneWidget);
    await expectGolden(tester, 'devices_desktop');

    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-mac')));
    await tester.pumpAndSettle();
    expect(find.text('goal_builder'), findsOneWidget);
    expect(find.text('/Users/Uladz…idget_runtime'), findsOneWidget);
    expect(find.text('CLI · flutter_agent'), findsOneWidget);
    expect(find.text('Ops console'), findsOneWidget);
    expect(find.text('CLI · 456e4567…4000'), findsOneWidget);
    expect(find.text('CLI · abcdef12…4000'), findsOneWidget);
    expect(find.byKey(const ValueKey('devicePaneTitle')), findsNothing);
    expect(find.text('mymac'), findsOneWidget);
    await expectGolden(tester, 'devices_desktop_remote_sessions');
  });

  testWidgets('Devices glass keeps its title clear over the scrolled rail', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'self',
      ownDevice: const DeviceInfo(
        deviceId: 'self',
        name: 'workstation',
        friendlyName: 'Workstation',
      ),
      rosterDevices: [
        for (var index = 0; index < 12; index++)
          DeviceInfo(
            deviceId: 'device-$index',
            name: 'device-$index',
            friendlyName: 'Device $index',
          ),
      ],
    );
    final sessions = await _controller([
      _session('design-session', '/work/flutter_agent', unread: 3),
      _session('docs-session', '/work/flutter_agent'),
    ]);
    await pumpGolden(
      tester,
      DevicesPage(
        service: service,
        sessions: sessions,
        initialDeviceId: 'self',
        now: () => DateTime.utc(2025, 12, 1, 11, 30),
      ),
      size: goldenSizeDesktop,
      theme: buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey('deviceRail')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('devicesChromeUnderlay')), findsOneWidget);
    final underHeaderRow = tester.getRect(
      find.byKey(const ValueKey('deviceRow:device-1')),
    );
    expect(underHeaderRow.top, lessThan(52));
    expect(underHeaderRow.bottom, greaterThan(0));
    await expectGolden(tester, 'rail_devices_glass_scrolled');
  });

  for (final size in const [Size(390, 844), Size(1280, 800)]) {
    testWidgets('first-connect device name dialog ${size.width.toInt()}', (
      tester,
    ) async {
      await pumpGolden(
        tester,
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showDeviceEnrollmentNameDialog(
                context,
                defaultName: 'workstation',
              ),
              child: const Text('Connect'),
            ),
          ),
        ),
        size: size,
        theme: buildFaTheme(
          direction: FaVisualDirection.glass,
          brightness: Brightness.dark,
        ),
        wrap: (child) => Scaffold(body: child),
      );
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('enrollDeviceName')), findsOneWidget);
      await expectGolden(tester, 'device_enroll_name_${size.width.toInt()}');
    });
  }

  testWidgets('chats networks panel: membership rows with live status', (
    tester,
  ) async {
    final wallet = await KeyWallet.load(MemoryWalletBackend());
    await wallet.createIfMissing(displayName: 'Me');
    await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
    await wallet.addNetwork(networkId: 'net2', name: 'quiet-net');
    final session = buildSession(
      httpClient: FakeHttpClient()
        ..respond(
          200,
          body:
              '[{"id":"c1","networkId":"net1","name":"general","public":false}]',
        ) // start: channels
        ..respond(200, body: membersBody), // start: members
      connector: FakeWsConnector(),
      wallet: wallet,
    );
    await session.start();
    addTearDown(session.close);
    final manager = NetworkSessionManager(
      baseUrl: testBase,
      wallet: wallet,
      httpClient: FakeHttpClient(),
      wsConnector: FakeWsConnector(),
    );
    manager.sessions['net1'] = session;
    manager.notifyListeners();
    addTearDown(manager.disconnectAll);

    await pumpGolden(
      tester,
      ChatNetworksPanel(
        manager: manager,
        onManageNetworks: () {},
        onOpenChannel: (_, _) {},
      ),
      size: const Size(360, 560),
      theme: buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
      ),
    );
    await expectGolden(tester, 'chats_networks_panel');
    await session.close();
  });

  testWidgets('chats networks panel: the empty wallet offers join + '
      'sign-in instead of a dead-end title (gh-2131)', (tester) async {
    final wallet = await KeyWallet.load(MemoryWalletBackend());
    await wallet.createIfMissing(displayName: 'Me');
    final manager = NetworkSessionManager(
      baseUrl: testBase,
      wallet: wallet,
      httpClient: FakeHttpClient(),
      wsConnector: FakeWsConnector(),
    );
    addTearDown(manager.disconnectAll);

    await pumpGolden(
      tester,
      ChatNetworksPanel(
        manager: manager,
        onManageNetworks: () {},
        onOpenChannel: (_, _) {},
      ),
      size: const Size(360, 560),
      theme: buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
      ),
    );
    await expectGolden(tester, 'chats_networks_empty');
  });
}
