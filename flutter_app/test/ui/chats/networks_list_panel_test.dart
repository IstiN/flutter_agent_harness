@TestOn('vm')
/// Widget tests for the chats sidebar's NETWORKS surface (Telegram
/// pattern, owner pass): the networks STRIP (Ø50 circles + name labels,
/// Ø50 letter-gradient circles, accent capsule + rounded-square
/// selection), the in-place channel drill-down beside the strip, the
/// network name in the surface header, and the '<' chevrons walking
/// channels → strip → normal chats.
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/chats/networks_list_panel.dart';
import 'package:fa/ui/widgets/folder_avatar.dart';
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
  VoidCallback? onBack,
  List<(String, String)>? opened,
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
          onBack: onBack ?? () {},
          onManageNetworks: () {},
          onOpenChannel: (networkId, channel) =>
              opened?.add((networkId, channel.id)),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the level-1 networks list renders standard [logo][name] '
      'rows; no strip before a network is drilled', (tester) async {
    final rig = await _manager();
    await pumpPanel(tester, manager: rig.manager);

    expect(find.byKey(const ValueKey('networksList')), findsOneWidget);
    expect(find.byKey(const ValueKey('networksStrip')), findsNothing);
    expect(find.byKey(const ValueKey('networkRow-net1')), findsOneWidget);
    expect(find.byKey(const ValueKey('networkRow-net2')), findsOneWidget);
    // Standard rows: the display name only.
    expect(find.text('fa-team'), findsOneWidget);
    expect(find.text('quiet-net'), findsOneWidget);
    expect(find.text('Connected'), findsNothing);
    expect(find.text('Not connected'), findsNothing);
    expect(find.text('Networks'), findsOneWidget, reason: 'the header title');
    // Geometry: 70pt rows, Ø~50 avatars, circles while unselected.
    expect(
      tester.getSize(find.byKey(const ValueKey('networkRow-net1'))).height,
      ChatNetworksPanel.stripItemPitch,
    );
    final avatars = find.byType(FolderAvatar);
    expect(avatars, findsNWidgets(2));
    expect(tester.getSize(avatars.first).width, 50);
    expect(tester.getSize(avatars.first).height, 50);
    for (final avatar in avatars.evaluate()) {
      expect((avatar.widget as FolderAvatar).circle, isTrue);
    }
    expect(find.byKey(const ValueKey('networkSelectedCapsule')), findsNothing);
    // The networks level's chevron walks back to the normal chats.
    expect(find.byKey(const ValueKey('chatNetworksBack')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatChannelsBack')), findsNothing);
    await rig.session?.close();
  });

  testWidgets('selecting a network drills to its channels beside the strip, '
      'names the header and paints the capsule', (tester) async {
    final rig = await _manager();
    await pumpPanel(tester, manager: rig.manager);

    await tester.tap(find.byKey(const ValueKey('networkRow-net1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // The channel drill-down: same Telegram rows over the session's
    // channels, BESIDE the still-visible strip, with the channels-level
    // chevron and the network's name in the header.
    final strip = tester.getRect(find.byKey(const ValueKey('networksStrip')));
    final general = find.byKey(const ValueKey('chatNetworkChannel-c1'));
    final channels = find.byKey(const ValueKey('chatNetworkChannels'));
    expect(channels, findsOneWidget);
    // Channel rows carry the NEUTRAL tag glyph — no letter avatars.
    expect(
      find.descendant(of: channels, matching: find.byType(FolderAvatar)),
      findsNothing,
    );
    expect(
      find.descendant(of: channels, matching: find.byType(NeutralGlyphAvatar)),
      findsNWidgets(2),
    );
    expect(
      tester
          .widgetList<Icon>(
            find.descendant(
              of: find.byKey(const ValueKey('chatNetworkChannel-c1')),
              matching: find.byType(Icon),
            ),
          )
          .map((icon) => icon.icon),
      contains(Icons.tag_rounded),
    );
    expect(find.byKey(const ValueKey('chatChannelsBack')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNetworksBack')), findsNothing);
    expect(tester.getTopLeft(general).dx, greaterThan(strip.right));
    expect(find.text('general'), findsOneWidget);
    expect(find.text('launch'), findsOneWidget);
    expect(find.text('Private channel'), findsOneWidget);
    expect(find.text('Public channel'), findsOneWidget);
    expect(
      find.text('fa-team'),
      findsOneWidget,
      reason: 'the header name; the strip is avatar-only',
    );
    expect(find.text('quiet-net'), findsNothing);

    // The drilled network wears the accent capsule flush to the strip's
    // LEFT edge and its avatar re-renders as a rounded square (radius
    // ~25%); the other stays a circle.
    final capsule = tester.getRect(
      find.byKey(const ValueKey('networkSelectedCapsule')),
    );
    expect(capsule.width, ChatNetworksPanel.capsuleWidth);
    expect(capsule.height, ChatNetworksPanel.capsuleHeight);
    expect(capsule.left, strip.left);
    final selectedAvatar = tester.widget<FolderAvatar>(
      find.descendant(
        of: find.byKey(const ValueKey('chatNetworkRow-net1')),
        matching: find.byType(FolderAvatar),
      ),
    );
    expect(selectedAvatar.circle, isFalse);
    expect(selectedAvatar.radiusFactor, 0.25);
    final unselectedAvatar = tester.widget<FolderAvatar>(
      find.descendant(
        of: find.byKey(const ValueKey('chatNetworkRow-net2')),
        matching: find.byType(FolderAvatar),
      ),
    );
    expect(unselectedAvatar.circle, isTrue);
    await rig.session?.close();
  });

  testWidgets('the chevrons walk channels → strip → normal chats and the '
      'header titles follow', (tester) async {
    final rig = await _manager(withLiveSession: false);
    var backs = 0;
    await pumpPanel(tester, manager: rig.manager, onBack: () => backs++);
    expect(find.text('Networks'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('networkRow-net1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.text('fa-team'),
      findsOneWidget,
      reason: 'the header name; the strip is avatar-only',
    );
    expect(find.text('Networks'), findsNothing);

    // channels → strip: the header restores the Networks title.
    await tester.tap(find.byKey(const ValueKey('chatChannelsBack')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('chatNetworkChannels')), findsNothing);
    expect(find.byKey(const ValueKey('networksList')), findsOneWidget);
    expect(find.byKey(const ValueKey('networksStrip')), findsNothing);
    expect(find.text('Networks'), findsOneWidget);
    expect(find.text('fa-team'), findsOneWidget, reason: 'the list row name');
    expect(find.byKey(const ValueKey('networkSelectedCapsule')), findsNothing);

    // strip → normal chats: the surface hands back to the shell.
    await tester.tap(find.byKey(const ValueKey('chatNetworksBack')));
    await tester.pump();
    expect(backs, 1);
    expect(find.text('Networks'), findsOneWidget);
  });

  testWidgets('the level swap animates in (200ms easeInOutCubic) and keys '
      'stay stable after settle', (tester) async {
    final rig = await _manager();
    await pumpPanel(tester, manager: rig.manager);

    final switcher = find.byType(AnimatedSwitcher);
    expect(switcher, findsOneWidget);
    final spec = tester.widget<AnimatedSwitcher>(switcher);
    expect(spec.duration, const Duration(milliseconds: 200));
    expect(spec.switchInCurve, Curves.easeInOutCubic);
    expect(spec.switchOutCurve, Curves.easeInOutCubic);

    // Drill: the incoming strip+channels level fades/slides in while the
    // outgoing list fades out (the header never participates).
    await tester.tap(find.byKey(const ValueKey('networkRow-net1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('networksList')), findsOneWidget);
    expect(find.byKey(const ValueKey('networksStrip')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));

    // Settled: exactly the level-2 surface, with the stable keys.
    expect(find.byKey(const ValueKey('networksList')), findsNothing);
    expect(find.byKey(const ValueKey('networksStrip')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNetworkChannels')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNetworkRow-net1')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNetworkChannel-c1')), findsOneWidget);

    // Back runs the SAME transition (no special reverse animation).
    await tester.tap(find.byKey(const ValueKey('chatChannelsBack')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('networksList')), findsOneWidget);
    expect(find.byKey(const ValueKey('networksStrip')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('networksList')), findsOneWidget);
    expect(find.byKey(const ValueKey('networksStrip')), findsNothing);
    expect(find.byKey(const ValueKey('chatNetworkChannels')), findsNothing);
    expect(
      find.byKey(const ValueKey('networkRow-net2')),
      findsOneWidget,
      reason: 'level-1 keys survive the round trip',
    );
    await rig.session?.close();
  });

  testWidgets('a channel tap hands the (network, channel) to the shell', (
    tester,
  ) async {
    final rig = await _manager();
    final opens = <(String, String)>[];
    await pumpPanel(tester, manager: rig.manager, opened: opens);
    await tester.tap(find.byKey(const ValueKey('networkRow-net1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('chatNetworkChannel-c2')));
    await tester.pump();
    expect(opens, [('net1', 'c2')]);
    await rig.session?.close();
  });

  testWidgets('the header gear invokes the manage flow (management stays '
      'reachable from the rail)', (tester) async {
    final rig = await _manager(withLiveSession: false);
    var managed = 0;
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
      'state inside the strip surface (the guest shape)', (tester) async {
    await pumpPanel(tester, manager: null);
    expect(find.byKey(const ValueKey('chatNetworksList')), findsOneWidget);
    expect(find.byKey(const ValueKey('networksList')), findsNothing);
    expect(find.byKey(const ValueKey('networkRow-net1')), findsNothing);
    expect(find.text('No networks yet'), findsOneWidget);

    final rig = await _manager(
      withLiveSession: false,
      withSecondNetwork: false,
    );
    await pumpPanel(tester, manager: rig.manager);
    expect(find.byKey(const ValueKey('networkRow-net1')), findsOneWidget);
    expect(find.text('fa-team'), findsOneWidget, reason: 'the strip label');
    expect(find.text('No networks yet'), findsNothing);
  });

  testWidgets('the channel highlight stays mode-driven inside the open '
      'network; the strip capsule only follows the drilled network', (
    tester,
  ) async {
    final rig = await _manager();
    final mode = NetworkModeController.inMemory(
      mode: AppMode.network,
      networkId: 'net1',
      channelId: 'c2',
    );
    await pumpPanel(tester, manager: rig.manager, mode: mode);
    // Strip selection is the drilled network, not the mode's.
    expect(find.byKey(const ValueKey('networkSelectedCapsule')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('networkRow-net1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final selectedRow = find
        .descendant(
          of: find.byKey(const ValueKey('chatNetworkChannel-c2')),
          matching: find.byType(Material),
        )
        .first;
    expect(
      tester.widget<Material>(selectedRow).color,
      isNot(Colors.transparent),
      reason: 'the selected channel row wears the accent fill',
    );
    final unselectedRow = find
        .descendant(
          of: find.byKey(const ValueKey('chatNetworkChannel-c1')),
          matching: find.byType(Material),
        )
        .first;
    expect(tester.widget<Material>(unselectedRow).color, Colors.transparent);
    await rig.session?.close();
  });
}
