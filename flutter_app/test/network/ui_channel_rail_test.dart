// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/key_wallet.dart';
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
  final manager = NetworkSessionManager(
    baseUrl: testBase,
    wallet: wallet,
    httpClient: FakeHttpClient(),
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
      'private channels expose the Add agent invite via the overflow menu',
      (tester) async {
        final rig = await _rig(tester);
        // The public channel has no overflow menu.
        expect(find.byKey(const ValueKey('channelMenu:c2')), findsNothing);

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
  });
}
