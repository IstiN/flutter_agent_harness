@TestOn('vm')
/// Widget tests for the chat column's NETWORKS panel (Telegram pattern,
/// owner pass): membership rows (letter-gradient avatar, name, status
/// meta), the in-place channel drill-down over the live session's
/// channels, and the '<' chevrons walking channels → networks → chats.
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/chats/networks_list_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../network/fakes.dart';

/// One private + one public channel on net1.
const _twoChannelsBody =
    '[{"id":"c1","networkId":"net1","name":"general","public":false},'
    '{"id":"c2","networkId":"net1","name":"launch","public":true}]';

/// A manager whose wallet holds net1 (fa-team) plus an optional net2
/// (quiet-net); with [withLiveSession] the net1 session is live with the
/// two-channel snapshot loaded. The caller closes the session in-body
/// (pending WS timers must flush before the test body ends).
typedef _ManagerRig = ({
  NetworkSessionManager manager,
  NetworkSession? session,
});

Future<_ManagerRig> _manager({
  bool withLiveSession = true,
  bool withSecondNetwork = true,
}) async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Me');
  await wallet.addNetwork(networkId: 'net1', name: 'fa-team', password: 'pw-1');
  if (withSecondNetwork) {
    await wallet.addNetwork(networkId: 'net2', name: 'quiet-net');
  }
  final manager = NetworkSessionManager(
    baseUrl: testBase,
    wallet: wallet,
    httpClient: FakeHttpClient(),
    wsConnector: FakeWsConnector(),
  );
  NetworkSession? session;
  if (withLiveSession) {
    session = buildSession(
      httpClient: FakeHttpClient()
        ..respond(200, body: _twoChannelsBody) // start: channels
        ..respond(200, body: membersBody), // start: members
      connector: FakeWsConnector(),
      wallet: wallet,
    );
    await session.start();
    manager.sessions['net1'] = session;
    manager.notifyListeners();
  }
  addTearDown(manager.disconnectAll);
  return (manager: manager, session: session);
}

Future<void> pumpPanel(
  WidgetTester tester, {
  required NetworkSessionManager? manager,
  NetworkModeController? mode,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(520, 640);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ChatNetworksPanel(
          manager: manager,
          mode: mode,
          onBack: () {},
          onManageNetworks: () {},
          onOpenChannel: (_, _) {},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('membership rows: avatar, name, live status meta', (
    tester,
  ) async {
    final rig = await _manager();
    await pumpPanel(tester, manager: rig.manager);

    expect(find.byKey(const ValueKey('chatNetworksList')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNetworkRow-net1')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNetworkRow-net2')), findsOneWidget);
    expect(find.text('fa-team'), findsOneWidget);
    expect(find.text('quiet-net'), findsOneWidget);
    // The live membership reports Connected; the stored-only one says Not
    // connected.
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    // The networks level's chevron walks back to the chats.
    expect(find.byKey(const ValueKey('chatNetworksBack')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatChannelsBack')), findsNothing);
    await rig.session?.close();
  });

  testWidgets('selecting a network drills to its channels; the chevrons '
      'walk channels → networks → chats', (tester) async {
    final rig = await _manager();
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatNetworksPanel(
            manager: rig.manager,
            onBack: () => backs++,
            onManageNetworks: () {},
            onOpenChannel: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('chatNetworkRow-net1')));
    await tester.pump();

    // The channel drill-down: same row anatomy over the session's
    // channels, with the channels-level chevron.
    expect(find.byKey(const ValueKey('chatNetworkChannels')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatChannelsBack')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNetworksBack')), findsNothing);
    expect(find.text('general'), findsOneWidget);
    expect(find.text('launch'), findsOneWidget);
    expect(find.text('Private channel'), findsOneWidget);
    expect(find.text('Public channel'), findsOneWidget);

    // channels → networks.
    await tester.tap(find.byKey(const ValueKey('chatChannelsBack')));
    await tester.pump();
    expect(find.byKey(const ValueKey('chatNetworksList')), findsOneWidget);
    expect(find.text('fa-team'), findsOneWidget);

    // networks → chats.
    await tester.tap(find.byKey(const ValueKey('chatNetworksBack')));
    await tester.pump();
    expect(backs, 1);
    await rig.session?.close();
  });

  testWidgets('a channel tap hands the (network, channel) to the shell', (
    tester,
  ) async {
    final rig = await _manager();
    final opens = <(String, String)>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatNetworksPanel(
            manager: rig.manager,
            onBack: () {},
            onManageNetworks: () {},
            onOpenChannel: (networkId, channel) =>
                opens.add((networkId, channel.id)),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chatNetworkRow-net1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chatNetworkChannel-c2')));
    await tester.pump();
    expect(opens, [('net1', 'c2')]);
    await rig.session?.close();
  });

  testWidgets('the header gear invokes the manage flow (management stays '
      'reachable from the rail)', (tester) async {
    final rig = await _manager(withLiveSession: false);
    var managed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatNetworksPanel(
            manager: rig.manager,
            onBack: () {},
            onManageNetworks: () => managed++,
            onOpenChannel: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chatNetworksManage')));
    await tester.pump();
    expect(managed, 1);
  });

  testWidgets('no wiring and an empty wallet each render their empty '
      'state (the guest shape)', (tester) async {
    await pumpPanel(tester, manager: null);
    expect(find.byKey(const ValueKey('chatNetworksList')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNetworkRow-net1')), findsNothing);

    final rig = await _manager(
      withLiveSession: false,
      withSecondNetwork: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatNetworksPanel(
            manager: rig.manager,
            onBack: () {},
            onManageNetworks: () {},
            onOpenChannel: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('chatNetworkRow-net1')), findsOneWidget);
    expect(find.text('fa-team'), findsOneWidget);
  });

  testWidgets('the selected network highlights accent (mode-driven)', (
    tester,
  ) async {
    final rig = await _manager(withLiveSession: false);
    final mode = NetworkModeController.inMemory(
      mode: AppMode.network,
      networkId: 'net2',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChatNetworksPanel(
            manager: rig.manager,
            mode: mode,
            onBack: () {},
            onManageNetworks: () {},
            onOpenChannel: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pump();
    final selectedRow = find
        .descendant(
          of: find.byKey(const ValueKey('chatNetworkRow-net2')),
          matching: find.byType(Material),
        )
        .first;
    expect(
      tester.widget<Material>(selectedRow).color,
      isNot(Colors.transparent),
      reason: 'the selected network row wears the accent fill',
    );
    final unselectedRow = find
        .descendant(
          of: find.byKey(const ValueKey('chatNetworkRow-net1')),
          matching: find.byType(Material),
        )
        .first;
    expect(tester.widget<Material>(unselectedRow).color, Colors.transparent);
  });
}
