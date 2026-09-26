// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Debug bisect for the ChannelRail hang — delete after diagnosis.

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/channel_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  testWidgets('debug: rail hang bisect', (tester) async {
    // ignore: avoid_print
    print('STEP 1: keygen');
    final channelKeys = await EnvelopeCodec.newX25519KeyPair();
    // ignore: avoid_print
    print('STEP 2: wallet');
    final wallet = await KeyWallet.load(MemoryWalletBackend());
    await wallet.createIfMissing(displayName: 'Me');
    await wallet.addNetwork(networkId: 'net1', name: 'fa-team', password: 'pw');
    await wallet.addChannelKeys(
      networkId: 'net1',
      channel: 'c1',
      pub: channelKeys.pub,
      priv: channelKeys.priv,
    );
    // ignore: avoid_print
    print('STEP 3: session start');
    final httpClient = FakeHttpClient()
      ..respond(
        200,
        body:
            '[{"id":"c1","networkId":"net1","name":"general","public":false}]',
      )
      ..respond(200, body: membersBody);
    final connector = FakeWsConnector();
    final session = buildSession(
      httpClient: httpClient,
      connector: connector,
      wallet: wallet,
    );
    await session.start();
    addTearDown(session.close);
    // ignore: avoid_print
    print('STEP 4: controller + manager');
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
    // ignore: avoid_print
    print('STEP 5: pumpWidget');
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
    // ignore: avoid_print
    print('STEP 6: pump');
    await tester.pump();
    // ignore: avoid_print
    print('STEP 7: expects');
    expect(find.text('general'), findsOneWidget);
    // ignore: avoid_print
    print('STEP 8: close');
    await session.close();
    // ignore: avoid_print
    print('STEP 9: done');
  });
}
