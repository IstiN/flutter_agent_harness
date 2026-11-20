// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/device_display.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/chats/messenger_drilldown_panel.dart';
import 'package:fa/ui/network/device_roster_panel.dart';
import 'package:fa/ui/widgets/folder_avatar.dart';
import 'package:fa/ui/network/devices_page.dart'
    show DevicesPage, showDeviceEnrollmentNameDialog;
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'devices_page_test.dart'
    show FakeDevicesService, chatListOf, devicesPage;

ChatListEntry _entry(
  String id, {
  String? title,
  String? preview,
  String? folderPath,
}) => ChatListEntry(
  id: ChatEntryId.local(id),
  kind: ChatListEntryKind.localAgent,
  title: title ?? id,
  preview: preview,
  folderPath: folderPath,
  createdAt: DateTime.utc(2026, 11, 12),
);

Widget _wrap(Widget child) => MaterialApp(
  theme: buildFahTheme(),
  home: Scaffold(body: SizedBox(width: 420, height: 700, child: child)),
);

void main() {
  group('session display titles', () {
    test('preview snippets collapse whitespace and cap at sixty runes', () {
      expect(
        deviceSessionPreviewTitle('  First line\n\tsecond   line  '),
        'First line second line',
      );
      expect(deviceSessionPreviewTitle(' \n\t '), isNull);
      final snippet = deviceSessionPreviewTitle('a' * 80)!;
      expect(snippet.runes.length, 60);
      expect(snippet, '${'a' * 59}…');
    });

    test(
      'display name, project folder, then short id is the complete chain',
      () {
        const id = '123e4567-e89b-12d3-a456-426614174000';
        expect(
          deviceSessionDisplayTitle(
            id: id,
            title: 'Release plan',
            path: '/work/flutter_agent',
          ),
          'Release plan',
        );
        expect(
          deviceSessionDisplayTitle(
            id: id,
            title: id,
            path: '/work/flutter_agent',
          ),
          'flutter_agent',
          reason: 'a first-message snippet is not the session display name',
        );
        expect(
          deviceSessionDisplayTitle(
            id: id,
            title: id,
            path: '/work/flutter_agent/',
          ),
          'flutter_agent',
        );
        expect(
          deviceSessionDisplayTitle(id: id, path: r'C:\work\flutter_agent'),
          'flutter_agent',
        );
        expect(deviceSessionDisplayTitle(id: id, title: id), '123e4567…4000');
        expect(
          deviceSessionDisplayTitle(id: id, title: 'mymac · $id'),
          'mymac · 123e4567…4000',
        );
        expect(
          deviceSessionDisplayTitle(
            id: id,
            title: 'mymac · $id',
            path: '/work/flutter_agent',
          ),
          'mymac · flutter_agent',
        );
        expect(
          deviceSessionDisplayTitle(
            id: id,
            title: '123e4567-e89b-12d3',
            path: '/work/flutter_agent',
          ),
          'flutter_agent',
          reason: 'a legacy peer may truncate a raw id before publishing it',
        );
        expect(
          deviceSessionDisplayTitle(id: id, title: '123e4567-e89b-12d3'),
          '123e4567…4000',
        );
        expect(
          deviceSessionDisplayTitle(
            id: id,
            preview: 'Last DM answer from the peer',
            cliFallback: true,
          ),
          'CLI · Last DM answer from the peer',
        );
        expect(
          deviceSessionDisplayTitle(id: id, cliFallback: true),
          'CLI · 123e4567…4000',
        );
      },
    );
  });

  test('session path subtitles preserve both ends with a middle ellipsis', () {
    expect(
      deviceSessionPathSubtitle(
        '/Users/Uladzimir_Klyshevich/git/flutter_js_widget_runtime',
      ),
      '/Users/Uladz…idget_runtime',
    );
    expect(
      deviceSessionPathSubtitle('/work/flutter_agent'),
      '/work/flutter_agent',
    );
    expect(deviceSessionPathSubtitle(null), '');
  });

  test(
    'metadata loader publishes real title or preview, never an id title',
    () async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      const id = '123e4567-e89b-12d3-a456-426614174000';
      final chatList = ChatListController(
        localAdapter: StaticChatListAdapter([
          _entry('named', title: 'Release plan', preview: 'ignored'),
          _entry(
            id,
            title: id,
            preview: '  First line\n second   line ',
            folderPath: '/work/flutter_agent',
          ),
          _entry('path-only', title: 'path-only'),
        ]),
      );
      await chatList.load();
      final source = createDeviceChatSessionSource(manager, chatList: chatList);
      final rows = await (source as DeviceChatSessionMetadataSource)
          .loadMetadata();

      final byId = {for (final row in rows) row.id: row};
      expect(byId['named']?.title, 'Release plan');
      expect(byId[id]?.title, 'First line second line');
      expect(byId[id]?.path, '/work/flutter_agent');
      expect(byId['path-only']?.title, isNull);
    },
  );

  test(
    'device publisher and Local panel enumerate the same persisted corpus',
    () async {
      final env = MemoryExecutionEnv();
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      for (var i = 0; i < 75; i++) {
        final id = 'session-$i';
        await repo.create(JsonlSessionCreateOptions(id: id, cwd: '/work/$id'));
      }
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
        repo: repo,
        includeSharedSessionRoots: false,
      );
      final localRows = await LocalChatListAdapter(
        manager: manager,
        titleBuilder: (id, _, _) => id,
      ).load();
      final deviceRows = await createDeviceChatSessionSource(manager).load();

      expect(
        deviceRows.map((row) => row.id).toSet(),
        localRows.map((row) => row.id.value).toSet(),
      );
      expect(
        deviceRows,
        hasLength(75),
        reason: 'no recent-50/mobile truncation',
      );
    },
  );

  testWidgets('first-connect name dialog returns a friendly name or hostname', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => TextButton(
            key: const ValueKey('openEnrollmentPrompt'),
            onPressed: () async =>
                result = await showDeviceEnrollmentNameDialog(
                  context,
                  defaultName: 'workstation',
                ),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('openEnrollmentPrompt')));
    await tester.pumpAndSettle();
    final field = tester.widget<FaTextField>(
      find.byKey(const ValueKey('enrollDeviceName')),
    );
    expect(field.controller?.text, 'workstation');

    await tester.enterText(
      find.byKey(const ValueKey('enrollDeviceName')),
      'Studio Mac',
    );
    await tester.tap(find.byKey(const ValueKey('enrollDeviceNameConfirm')));
    await tester.pumpAndSettle();
    expect(result, 'Studio Mac');

    await tester.tap(find.byKey(const ValueKey('openEnrollmentPrompt')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('enrollDeviceName')), '');
    await tester.tap(find.byKey(const ValueKey('enrollDeviceNameConfirm')));
    await tester.pumpAndSettle();
    expect(result, 'workstation');
  });

  testWidgets('own session rows use preview/path instead of a hash', (
    tester,
  ) async {
    const id = '123e4567-e89b-12d3-a456-426614174000';
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-own',
    );
    final sessions = chatListOf([
      _entry(id, title: id, folderPath: '/work/flutter_agent'),
    ]);

    await tester.pumpWidget(_wrap(devicesPage(service, sessions: sessions)));
    await tester.pump();

    final card = tester.widget<DeviceSessionCard>(
      find.byKey(const ValueKey('sessionRow:$id')),
    );
    expect(card.title, 'flutter_agent');
    expect(card.title, isNot('123e4567'));
    expect(
      find.text('/work/flutter_agent'),
      findsOneWidget,
      reason: 'the path remains visible even when its basename is the title',
    );
  });

  testWidgets('sleeping remote session opens DM with address and session id', (
    tester,
  ) async {
    const sessionId = '01a1db81-1111-2222-3333-444444444444';
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-own',
      personalNetworkId: 'net-personal',
    );
    service.seededRoster.add(
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.roster,
        msgId: 'roster-1',
        ts: rfc3339Timestamp(DateTime.utc(2026, 11, 12)),
        network: 'net-personal',
        payload: {
          'devices': [
            {
              'deviceId': 'dev-duo-000',
              'name': 'Duo',
              'agents': [
                {
                  'name': 'fa',
                  'state': 'wake_on_dm',
                  'exposed': true,
                  'dmPub': 'cHVi',
                },
              ],
              'sessions': [
                {
                  'id': sessionId,
                  'state': 'wake_on_dm',
                  'networks': ['net-personal'],
                  'path': '/work/flutter_agent',
                },
              ],
            },
          ],
        },
      ),
    );
    String? openedDevice;
    String? openedAddress;
    String? openedSession;
    String? openedSessionTitle;
    String? openedLabel;

    await tester.pumpWidget(
      _wrap(
        devicesPage(
          service,
          onOpenRemoteConversation:
              ({
                required deviceId,
                required deviceLabel,
                required agentAddress,
                sessionId,
                sessionTitle,
              }) {
                openedDevice = deviceId;
                openedLabel = deviceLabel;
                openedAddress = agentAddress;
                openedSession = sessionId;
                openedSessionTitle = sessionTitle;
              },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-duo-000')));
    await tester.pump();

    final card = tester.widget<DeviceSessionCard>(
      find.byKey(const ValueKey('sessionRow:$sessionId')),
    );
    expect(card.title, 'CLI · flutter_agent');
    expect(card.onTap, isNotNull);
    await tester.tap(find.byKey(const ValueKey('sessionRow:$sessionId')));

    expect(openedDevice, 'dev-duo-000');
    expect(openedLabel, 'Duo');
    expect(openedAddress, 'fa@dev-duo-000');
    expect(openedSession, sessionId);
    expect(openedSessionTitle, 'CLI · flutter_agent');
  });

  testWidgets('named remote catalog rows render snippet/cwd/activity and '
      'live, wake-on-DM, offline states without raw UUID labels', (
    tester,
  ) async {
    const uuid = '123e4567-e89b-12d3-a456-426614174000';
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-own',
      personalNetworkId: 'net-personal',
    );
    service.seededRoster.add(
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.roster,
        msgId: 'roster-named',
        ts: rfc3339Timestamp(DateTime.utc(2026, 11, 12)),
        network: 'net-personal',
        payload: {
          'devices': [
            {
              'deviceId': 'dev-named',
              'name': 'Named workstation',
              'presence': 'online',
              'agents': [
                {'name': 'fa', 'state': 'live', 'dmPub': 'cHVi'},
              ],
              'sessions': [
                {
                  'id': uuid,
                  'state': 'wake_on_dm',
                  'networks': ['net-personal'],
                  'snippet': 'Continue the roster work',
                  'path': '/work/flutter_agent',
                  'lastActivity': '2026-11-12T11:58:00Z',
                },
                {
                  'id': 'live-row',
                  'state': 'live',
                  'networks': ['net-personal'],
                  'displayName': 'Current plan',
                  'path': '/work/flutter_agent',
                  'lastActivity': '2026-11-12T12:00:00Z',
                },
                {
                  'id': 'offline-row',
                  'state': 'offline',
                  'networks': ['net-personal'],
                  'title': 'Old plan',
                  'path': '/work/flutter_agent',
                  'lastActivity': '2026-11-11T12:00:00Z',
                },
              ],
            },
          ],
        },
      ),
    );

    await tester.pumpWidget(_wrap(devicesPage(service)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-named')));
    await tester.pump();

    DeviceSessionCard card(String id) => tester.widget<DeviceSessionCard>(
      find.byKey(ValueKey('sessionRow:$id')),
    );
    expect(card(uuid).title, 'CLI · flutter_agent');
    expect(card(uuid).title, isNot(uuid));
    expect(card(uuid).title, isNot('123e4567…4000'));
    expect(card(uuid).subtitle, contains('/work/flutter_agent'));
    expect(card(uuid).stateLabel, 'Wake on DM');
    expect(card(uuid).timestamp, isNotEmpty);
    expect(card('live-row').title, 'Current plan');
    expect(card('live-row').stateLabel, 'Online');
    expect(card('offline-row').title, 'Old plan');
    expect(card('offline-row').stateLabel, 'Offline');
    expect(card(uuid).showPresenceDot, isTrue);
    expect(card('offline-row').showPresenceDot, isTrue);
  });

  testWidgets(
    'devices reuse Networks rows, mini-strip, header and flat sessions',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const unnamedId = '01a15985-f6c3-7e9e-b16b-203817f2a9c2';
      const folderId = '123e4567-e89b-12d3-a456-426614174000';
      const fallbackId = '89abcdef-e89b-12d3-a456-426614174000';
      final service = FakeDevicesService(
        initialPhase: DeviceConnectorPhase.online,
        deviceId: 'dev-own',
        ownDevice: const DeviceInfo(
          deviceId: 'dev-own',
          name: 'workstation',
          friendlyName: 'Workstation',
        ),
        rosterDevices: const [
          DeviceInfo(deviceId: 'dev-mac', name: 'mymac', presence: 'online'),
          DeviceInfo(deviceId: unnamedId, name: '', presence: 'online'),
        ],
      );
      final sessions = chatListOf([
        _entry('named', title: 'Release assistant'),
        _entry(
          folderId,
          preview: 'This prompt must not replace the project folder',
          folderPath: '/work/flutter_agent',
        ),
        _entry(fallbackId),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(
            body: DevicesPage(
              service: service,
              sessions: sessions,
              compact: true,
              now: () => DateTime.utc(2026, 11, 12),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('deviceRail')), findsNothing);
      expect(find.byType(VerticalDivider), findsNothing);
      expect(find.byKey(const ValueKey('deviceSelectedCapsule')), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('deviceRow'))).height,
        70,
      );
      expect(find.text('This device · Online'), findsOneWidget);
      expect(find.text('Workstation'), findsOneWidget);
      expect(find.text('mymac'), findsOneWidget);
      expect(find.text('01a15985…a9c2'), findsOneWidget);
      expect(find.text('Online'), findsWidgets);
      expect(find.byKey(const ValueKey('devicePane:dev-own')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('deviceRow')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('deviceRail')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('deviceSelectedCapsule')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('devicePane:dev-own')), findsOneWidget);
      expect(find.byKey(const ValueKey('deviceBackButton')), findsOneWidget);
      expect(find.byKey(const ValueKey('deviceOptionsMenu')), findsOneWidget);
      expect(find.byKey(const ValueKey('devicePaneTitle')), findsNothing);
      expect(find.byKey(const ValueKey('devicePaneSubtitle')), findsNothing);
      expect(find.byKey(const ValueKey('currentDeviceBadge')), findsNothing);
      expect(find.byKey(const ValueKey('renameOwnDeviceButton')), findsNothing);
      expect(find.byType(MessengerPanelRow), findsWidgets);
      expect(find.byType(NeutralGlyphAvatar), findsNothing);
      expect(find.text('Workstation'), findsWidgets);
      expect(find.text('Release assistant'), findsOneWidget);
      expect(find.text('flutter_agent'), findsOneWidget);
      expect(find.text('89abcdef…4000'), findsOneWidget);
      expect(find.textContaining('This prompt must not'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('deviceBackButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('deviceRail')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('deviceRow:$unnamedId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('deviceRail')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('devicePane:$unnamedId')),
        findsOneWidget,
      );
      expect(find.text('01a15985…a9c2'), findsWidgets);
    },
  );

  testWidgets('repaired app enrollment unions with same-host CLI enrollment', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-app-000',
      ownDevice: const DeviceInfo(
        deviceId: 'dev-app-000',
        name: '',
        friendlyName: 'EPBYGROW03B0',
      ),
      rosterDevices: const [
        DeviceInfo(deviceId: 'dev-cli-000', name: 'EPBYGROW03B0'),
      ],
    );
    final sessions = chatListOf([
      for (var i = 0; i < 1261; i++) _entry('own-$i', title: 'Session $i'),
    ]);

    await tester.pumpWidget(_wrap(devicesPage(service, sessions: sessions)));
    await tester.pump();
    await tester.pump();

    expect(sessions.localEntries, hasLength(1261));
    expect(find.byKey(const ValueKey('deviceRow')), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceRow:dev-cli-000')), findsNothing);
    expect(
      find.byKey(const ValueKey('devicePane:dev-app-000')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('deviceNoSessionsHint')), findsNothing);
    expect(find.byKey(const ValueKey('sessionRow:own-0')), findsOneWidget);
  });
}
