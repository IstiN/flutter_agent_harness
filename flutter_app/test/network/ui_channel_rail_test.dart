// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/add_agent_dialog.dart';
import 'package:fa/ui/network/channel_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// One private + one public channel on net1.
const _twoChannelsBody =
    '[{"id":"c1","networkId":"net1","name":"general","public":false},'
    '{"id":"c2","networkId":"net1","name":"launch","public":true}]';

Future<
  ({
    NetworkModeController controller,
    NetworkSessionManager manager,
    NetworkSession session,
    KeyWallet wallet,
    FakeHttpClient httpClient,
    FakeHttpClient managerHttp,
  })
>
_rig(WidgetTester tester, {String memberClass = 'member'}) async {
  final channelKeys = await EnvelopeCodec.newX25519KeyPair();
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Me');
  await wallet.addNetwork(
    networkId: 'net1',
    name: 'fa-team',
    memberClass: memberClass,
    password: 'secret-pw',
  );
  await wallet.addChannelKeys(
    networkId: 'net1',
    channel: 'c1',
    pub: channelKeys.pub,
    priv: channelKeys.priv,
  );
  final httpClient = FakeHttpClient()
    ..respond(200, body: _twoChannelsBody) // start: channels
    ..respond(200, body: membersBody); // start: members
  final connector = FakeWsConnector();
  final session = buildSession(
    httpClient: httpClient,
    connector: connector,
    wallet: wallet,
  );
  await session.start();
  addTearDown(session.close);
  final controller = NetworkModeController.inMemory(
    mode: AppMode.network,
    networkId: 'net1',
  );
  final managerHttp = FakeHttpClient();
  final manager = NetworkSessionManager(
    baseUrl: testBase,
    wallet: wallet,
    httpClient: managerHttp,
    wsConnector: FakeWsConnector(),
  );
  manager.sessions['net1'] = session;
  manager.notifyListeners();
  addTearDown(manager.disconnectAll);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: ChannelRail(controller: controller, manager: manager),
        ),
      ),
    ),
  );
  await tester.pump();
  return (
    controller: controller,
    manager: manager,
    session: session,
    wallet: wallet,
    httpClient: httpClient,
    managerHttp: managerHttp,
  );
}

void main() {
  group('ChannelRail', () {
    testWidgets('shows channels with lock (private) / globe (public) icons', (
      tester,
    ) async {
      final rig = await _rig(tester);
      expect(find.text('general'), findsOneWidget);
      expect(find.text('launch'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.byIcon(Icons.public), findsOneWidget);
      // Presence header: one live member (Me) from the roster snapshot.
      expect(find.text('1 online'), findsOneWidget);
      await rig.session.close();
    });

    testWidgets('an unnamed 64-char id renders as a friendly short label', (
      tester,
    ) async {
      final rig = await _rig(tester);
      const id =
          '0123456789abcdef0123456789abcdef'
          '0123456789abcdef0123456789abcdef';
      rig.session.channels = [
        const Channel(id: id, networkId: 'net1', isPublic: false),
      ];
      rig.session.notifyListeners();
      await tester.pump();

      expect(find.text(id), findsNothing);
      expect(find.text('01234567…'), findsOneWidget);
      await rig.session.close();
    });

    testWidgets('the online counter opens a live-first roster sheet', (
      tester,
    ) async {
      final rig = await _rig(tester);
      rig.session.roster['agent-kb'] = const Member(
        id: 'agent-kb',
        memberClass: MemberClass.agent,
        displayName: 'kb-agent',
        presence: Presence.live,
      );
      rig.session.notifyListeners();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('networkRosterButton')));
      await tester.pumpAndSettle();

      expect(find.text('Members'), findsOneWidget);
      expect(find.text('kb-agent'), findsOneWidget);
      expect(find.text('Agent'), findsOneWidget);
      expect(find.text('Online'), findsNWidgets(2));
      expect(find.text('Offline'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('kb-agent')).dy,
        lessThan(tester.getTopLeft(find.text('Olya')).dy),
      );
      await rig.session.close();
    });

    testWidgets(
      'roster badges show network/channel scope and hide unknown access',
      (tester) async {
        final rig = await _rig(tester);
        rig.session.roster.addAll({
          'agent-network': const Member(
            id: 'agent-network',
            memberClass: MemberClass.agent,
            displayName: 'Network bot',
            presence: Presence.live,
            access: MemberAccess(scope: MemberAccessScope.network),
          ),
          'agent-scoped': const Member(
            id: 'agent-scoped',
            memberClass: MemberClass.agent,
            displayName: 'Scoped bot',
            presence: Presence.offline,
            access: MemberAccess(
              scope: MemberAccessScope.channels,
              channelIds: ['c1', 'c2'],
            ),
          ),
          'agent-empty-acl': const Member(
            id: 'agent-empty-acl',
            memberClass: MemberClass.agent,
            displayName: 'Empty ACL bot',
            presence: Presence.offline,
            access: MemberAccess(scope: MemberAccessScope.channels),
          ),
          'agent-future': const Member(
            id: 'agent-future',
            memberClass: MemberClass.agent,
            displayName: 'Future bot',
            presence: Presence.offline,
            access: MemberAccess(scope: MemberAccessScope.unknown),
          ),
        });
        rig.session.notifyListeners();
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('networkRosterButton')));
        await tester.pumpAndSettle();

        expect(find.text('Whole network'), findsNWidgets(2));
        expect(find.text('2 channels'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('networkRosterAccess:agent-network')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('networkRosterAccess:agent-scoped')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('networkRosterAccess:agent-future')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('networkRosterAccess:me-1')),
          findsNothing,
        );
        await rig.session.close();
      },
    );

    testWidgets('channel-open roster badges explain this and other channels', (
      tester,
    ) async {
      final rig = await _rig(tester);
      rig.session.roster.addAll({
        'agent-only': const Member(
          id: 'agent-only',
          memberClass: MemberClass.agent,
          displayName: 'Only bot',
          presence: Presence.live,
          access: MemberAccess(
            scope: MemberAccessScope.channels,
            channelIds: ['c1'],
          ),
        ),
        'agent-mixed': const Member(
          id: 'agent-mixed',
          memberClass: MemberClass.agent,
          displayName: 'Mixed bot',
          presence: Presence.live,
          access: MemberAccess(
            scope: MemberAccessScope.channels,
            channelIds: ['c1', 'c2'],
          ),
        ),
        'agent-other': const Member(
          id: 'agent-other',
          memberClass: MemberClass.agent,
          displayName: 'Other bot',
          presence: Presence.live,
          access: MemberAccess(
            scope: MemberAccessScope.channels,
            channelIds: ['c2'],
          ),
        ),
      });
      await rig.controller.selectChannel('c1');
      rig.session.notifyListeners();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('networkRosterButton')));
      await tester.pumpAndSettle();

      expect(find.text('This channel only'), findsOneWidget);
      expect(find.text('This channel + 1 other channel'), findsOneWidget);
      expect(find.text('1 other channel'), findsOneWidget);
      await rig.session.close();
    });

    testWidgets('the roster sheet handles an empty roster politely', (
      tester,
    ) async {
      final rig = await _rig(tester);
      rig.session.roster.clear();
      rig.session.notifyListeners();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('networkRosterButton')));
      await tester.pumpAndSettle();

      expect(find.text('0 online'), findsOneWidget);
      expect(find.text('No members yet.'), findsOneWidget);
      await rig.session.close();
    });

    testWidgets('the list splits into Channels and Showcases sections', (
      tester,
    ) async {
      final rig = await _rig(tester);
      expect(find.text('CHANNELS'), findsOneWidget);
      expect(find.text('SHOWCASES'), findsOneWidget);
      // The private channel sits under Channels, the public one under
      // Showcases.
      expect(
        tester.getTopLeft(find.text('general')).dy,
        greaterThan(tester.getTopLeft(find.text('CHANNELS')).dy),
      );
      expect(
        tester.getTopLeft(find.text('launch')).dy,
        greaterThan(tester.getTopLeft(find.text('SHOWCASES')).dy),
      );
      await rig.session.close();
    });

    testWidgets('tapping a channel selects it and opens its history', (
      tester,
    ) async {
      final rig = await _rig(tester);
      rig.httpClient.respond(200, body: '{"items":[],"nextCursor":""}');

      await tester.tap(find.text('general'));
      await tester.pump();
      await tester.pump();

      expect(rig.controller.channelId, 'c1');
      expect(rig.session.channelStates['c1'], isNotNull);
      await rig.session.close();
    });

    testWidgets('the create-channel button is owner/admin only', (
      tester,
    ) async {
      final rig = await _rig(tester);
      expect(find.byKey(const ValueKey('createChannelButton')), findsNothing);
      await rig.session.close();
    });

    testWidgets('owner sees the create-channel button', (tester) async {
      final rig = await _rig(tester, memberClass: 'owner');
      expect(find.byKey(const ValueKey('createChannelButton')), findsOneWidget);
      await rig.session.close();
    });

    testWidgets(
      'every channel exposes the Add agent invite via the overflow menu',
      (tester) async {
        final rig = await _rig(tester);
        // Public channels invite keyless (the showcase contract) — the
        // menu is there too.
        expect(find.byKey(const ValueKey('channelMenu:c2')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('channelMenu:c1')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Add agent…'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byType(AddAgentDialog), findsOneWidget);
        await rig.session.close();
      },
    );

    testWidgets(
      'network header person-add opens the whole-network agent invite',
      (tester) async {
        final rig = await _rig(tester);
        expect(
          find.byKey(const ValueKey('networkAddAgentButton')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('networkAddAgentButton')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byType(AddAgentDialog), findsOneWidget);
        await tester.tap(find.text('Link (app)'));
        await tester.pump();
        // No channel in context → the scope switch is hidden and the
        // payload is the network join link.
        expect(find.byKey(const ValueKey('inviteScope')), findsNothing);
        final payload = tester
            .widget<Text>(find.byKey(const ValueKey('agentInvite')))
            .data!;
        expect(
          payload,
          startsWith('https://network.fa1.dev/join?network=net1'),
        );
        await rig.session.close();
      },
    );
  });

  group('ChannelRail roster agent management', () {
    testWidgets('owner drops an agent after a named destructive confirmation', (
      tester,
    ) async {
      final rig = await _rig(tester, memberClass: 'owner');
      rig.session.roster['agent-1'] = const Member(
        id: 'agent-1',
        memberClass: MemberClass.agent,
        displayName: 'Helper',
        presence: Presence.live,
      );
      rig.session.notifyListeners();
      rig.httpClient.respond(204);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('networkRosterButton')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('dropAgent:agent-1')));
      await tester.pumpAndSettle();
      expect(find.text('Drop this agent?'), findsOneWidget);
      expect(
        find.text(
          '"Helper" will be removed from this network and lose access. '
          'This cannot be undone.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('confirmDropAgent')));
      await tester.pumpAndSettle();

      final delete = rig.httpClient.requests.singleWhere(
        (request) => request.method == 'DELETE',
      );
      expect(delete.url.path, '/api/networks/net1/agents/agent-1');
      expect(rig.session.roster.containsKey('agent-1'), isFalse);
      expect(
        find.byKey(const ValueKey('networkRosterMember:agent-1')),
        findsNothing,
      );
      expect(find.text('Helper'), findsNothing);

      // Rebuilding from local state cannot resurrect the removed row.
      rig.session.notifyListeners();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('networkRosterMember:agent-1')),
        findsNothing,
      );
      await rig.session.close();
    });

    testWidgets('non-agent and self rows have no drop action', (tester) async {
      final rig = await _rig(tester, memberClass: 'owner');
      rig.session.roster['me-1'] = const Member(
        id: 'me-1',
        memberClass: MemberClass.agent,
        displayName: 'Self agent',
        presence: Presence.live,
      );
      rig.session.roster.addAll({
        'agent-other': const Member(
          id: 'agent-other',
          memberClass: MemberClass.agent,
          displayName: 'Other agent',
          presence: Presence.live,
        ),
        'owner-1': const Member(
          id: 'owner-1',
          memberClass: MemberClass.owner,
          displayName: 'Owner',
          presence: Presence.live,
        ),
        'guest-1': const Member(
          id: 'guest-1',
          memberClass: MemberClass.guest,
          displayName: 'Guest',
          presence: Presence.live,
        ),
      });
      rig.session.notifyListeners();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('networkRosterButton')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('dropAgent:agent-other')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('dropAgent:me-1')), findsNothing);
      expect(find.byKey(const ValueKey('dropAgent:other-1')), findsNothing);
      expect(find.byKey(const ValueKey('dropAgent:owner-1')), findsNothing);
      expect(find.byKey(const ValueKey('dropAgent:guest-1')), findsNothing);
      await rig.session.close();
    });

    testWidgets('members do not see the drop-agent affordance', (tester) async {
      final rig = await _rig(tester);
      rig.session.roster['agent-1'] = const Member(
        id: 'agent-1',
        memberClass: MemberClass.agent,
        displayName: 'Helper',
        presence: Presence.live,
      );
      rig.session.notifyListeners();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('networkRosterButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('dropAgent:agent-1')), findsNothing);
      await rig.session.close();
    });

    testWidgets('a 403 keeps the agent and surfaces the server error', (
      tester,
    ) async {
      final rig = await _rig(tester, memberClass: 'owner');
      rig.session.roster['agent-1'] = const Member(
        id: 'agent-1',
        memberClass: MemberClass.agent,
        displayName: 'Helper',
        presence: Presence.live,
      );
      rig.session.notifyListeners();
      rig.httpClient.respond(
        403,
        body:
            '{"error":{"code":"forbidden_by_class",'
            '"message":"owner or admin required"}}',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('networkRosterButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dropAgent:agent-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirmDropAgent')));
      await tester.pumpAndSettle();

      expect(find.text('owner or admin required'), findsOneWidget);
      expect(rig.session.roster.containsKey('agent-1'), isTrue);
      expect(
        find.byKey(const ValueKey('networkRosterMember:agent-1')),
        findsOneWidget,
      );
      await rig.session.close();
    });
  });

  group('ChannelRail channel management', () {
    testWidgets('rename prefills, validates, PATCHes and updates the rail', (
      tester,
    ) async {
      final rig = await _rig(tester, memberClass: 'owner');
      rig.httpClient.respond(
        200,
        body:
            '{"id":"c1","networkId":"net1","name":"ops",'
            '"public":false}',
      );

      await tester.tap(find.byKey(const ValueKey('channelMenu:c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename channel…'));
      await tester.pumpAndSettle();

      final field = find.byKey(const ValueKey('renameChannelName'));
      expect(tester.widget<TextField>(field).controller!.text, 'general');
      await tester.enterText(field, '   ');
      await tester.tap(find.byKey(const ValueKey('renameChannelConfirm')));
      await tester.pump();
      expect(find.text('Channel name cannot be empty.'), findsOneWidget);
      expect(
        rig.httpClient.requests.where((request) => request.method == 'PATCH'),
        isEmpty,
      );

      await tester.enterText(field, 'ops');
      await tester.tap(find.byKey(const ValueKey('renameChannelConfirm')));
      await tester.pumpAndSettle();

      final patch = rig.httpClient.requests.singleWhere(
        (request) => request.method == 'PATCH',
      );
      expect(patch.url.path, '/api/channels/c1');
      expect(patch.body, '{"name":"ops"}');
      expect(rig.session.channels.first.name, 'ops');
      expect(find.text('ops'), findsOneWidget);
      expect(find.text('general'), findsNothing);
      await rig.session.close();
    });

    testWidgets('deleting the open channel DELETEs and opens a remaining one', (
      tester,
    ) async {
      final rig = await _rig(tester, memberClass: 'owner');
      await rig.controller.selectChannel('c1');
      rig.httpClient.respond(204);
      rig.httpClient.respond(200, body: '{"items":[],"nextCursor":""}');

      await tester.tap(find.byKey(const ValueKey('channelMenu:c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete channel…'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this channel?'), findsOneWidget);
      expect(find.textContaining('general'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('confirmDeleteChannel')));
      await tester.pumpAndSettle();

      final delete = rig.httpClient.requests.singleWhere(
        (request) => request.method == 'DELETE',
      );
      expect(delete.url.path, '/api/channels/c1');
      expect(rig.session.channels.map((channel) => channel.id), ['c2']);
      expect(rig.session.channelStates.containsKey('c1'), isFalse);
      expect(rig.controller.channelId, 'c2');
      expect(rig.session.channelStates['c2'], isNotNull);
      expect(find.text('Channel deleted'), findsOneWidget);
      await rig.session.close();
    });

    testWidgets('deleting the last open channel returns to the empty state', (
      tester,
    ) async {
      final rig = await _rig(tester, memberClass: 'owner');
      rig.session.channels = [rig.session.channels.first];
      rig.session.notifyListeners();
      await rig.controller.selectChannel('c1');
      await tester.pump();
      rig.httpClient.respond(204);

      await tester.tap(find.byKey(const ValueKey('channelMenu:c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete channel…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirmDeleteChannel')));
      await tester.pumpAndSettle();

      expect(rig.controller.channelId, isNull);
      expect(rig.session.channels, isEmpty);
      expect(find.text('No channels'), findsOneWidget);
      await rig.session.close();
    });

    testWidgets('a delete rejection keeps state and surfaces a polite error', (
      tester,
    ) async {
      final rig = await _rig(tester, memberClass: 'owner');
      await rig.controller.selectChannel('c1');
      rig.httpClient.respond(
        403,
        body:
            '{"error":{"code":"forbidden_by_class",'
            '"message":"owner or admin required"}}',
      );

      await tester.tap(find.byKey(const ValueKey('channelMenu:c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete channel…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirmDeleteChannel')));
      await tester.pumpAndSettle();

      expect(find.text('owner or admin required'), findsOneWidget);
      expect(rig.session.channels.map((channel) => channel.id), ['c1', 'c2']);
      expect(rig.controller.channelId, 'c1');
      await rig.session.close();
    });
  });

  group('ChannelRail create channel', () {
    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('createChannelButton')));
      await tester.pumpAndSettle();
    }

    testWidgets('owner creates a channel: POST + local keys + auto-open', (
      tester,
    ) async {
      final rig = await _rig(tester, memberClass: 'owner');
      rig.managerHttp.respond(
        201,
        body:
            '{"id":"c9","networkId":"net1","name":"war-room",'
            '"public":true}',
      );
      // The auto-open's first history page (session http client).
      rig.httpClient.respond(200, body: '{"items":[],"nextCursor":""}');

      await openDialog(tester);
      await tester.enterText(find.byType(TextField), 'war-room');
      await tester.tap(find.byType(SwitchListTile)); // public showcase
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      final post = rig.managerHttp.requests.single;
      expect(post.method, 'POST');
      expect(post.url.path, '/api/networks/net1/channels');
      expect(post.body, contains('"name":"war-room"'));
      expect(post.body, contains('"public":true'));
      // The keypair is generated and stored locally (E2E, invariant I1)…
      expect(rig.wallet.channelKeysFor('net1', 'c9'), isNotNull);
      // …the rail reflects the new channel and it is auto-opened.
      expect(find.text('war-room'), findsOneWidget);
      expect(rig.controller.channelId, 'c9');
      expect(
        rig.httpClient.requests.last.url.path,
        '/api/channels/c9/messages',
      );
      await rig.session.close();
    });

    testWidgets('cancelling the dialog sends nothing', (tester) async {
      final rig = await _rig(tester, memberClass: 'owner');

      await openDialog(tester);
      await tester.enterText(find.byType(TextField), 'war-room');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(rig.managerHttp.requests, isEmpty);
      await rig.session.close();
    });

    testWidgets('an empty name keeps the dialog open and sends nothing', (
      tester,
    ) async {
      final rig = await _rig(tester, memberClass: 'owner');

      await openDialog(tester);
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(rig.managerHttp.requests, isEmpty);
      await rig.session.close();
    });

    testWidgets('a server rejection surfaces as a snackbar', (tester) async {
      final rig = await _rig(tester, memberClass: 'owner');
      rig.managerHttp.respond(
        403,
        body: '{"error":{"code":"forbidden","message":"owner only"}}',
      );

      await openDialog(tester);
      await tester.enterText(find.byType(TextField), 'war-room');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.textContaining('owner only'), findsOneWidget);
      expect(rig.wallet.channelKeysFor('net1', 'c9'), isNull);
      await rig.session.close();
    });

    testWidgets('a malformed response surfaces the generic error', (
      tester,
    ) async {
      final rig = await _rig(tester, memberClass: 'owner');
      rig.managerHttp.respond(201, body: 'not json');

      await openDialog(tester);
      await tester.enterText(find.byType(TextField), 'war-room');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.textContaining('FormatException'), findsOneWidget);
      await rig.session.close();
    });
  });
}
