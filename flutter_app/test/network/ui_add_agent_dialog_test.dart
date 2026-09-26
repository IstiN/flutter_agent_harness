// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/invite_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/add_agent_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  _registerNetworkScopeGroup();
  group('AddAgentDialog', () {
    late ({String pub, String priv}) channelKeys;

    setUp(() async {
      channelKeys = await EnvelopeCodec.newX25519KeyPair();
    });

    Future<Widget> pumpDialog(WidgetTester tester) async {
      final wallet = await walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      const channel = Channel(
        id: 'c1',
        networkId: 'net1',
        name: 'general',
        isPublic: false,
      );
      final dialog = AddAgentDialog(
        wallet: wallet,
        networkId: 'net1',
        channel: channel,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(body: dialog),
        ),
      );
      await tester.pump();
      return dialog;
    }

    testWidgets('shows the invite: channel + pub, priv only inside the '
        'fragment', (tester) async {
      await pumpDialog(tester);
      final invite = tester
          .widget<Text>(find.byKey(const ValueKey('agentInvite')))
          .data!;

      expect(invite, startsWith('wss://hub.fa1.dev/ws'));
      expect(
        invite,
        contains('channel=c1'),
        reason: 'fa_network relays onto DAP channels named by id',
      );
      final fragmentStart = invite.indexOf('#');
      expect(fragmentStart, greaterThan(0));
      // The private key material appears ONLY after the '#' fragment —
      // never in the wire-visible part of the URI (RFC 3986).
      final parsed = parseAgentInvite(invite);
      expect(parsed.channel, 'c1');
      expect(parsed.pub, isNotEmpty);
      expect(invite.substring(0, fragmentStart), isNot(contains('priv=')));
      expect(
        Uri.splitQueryString(invite.substring(fragmentStart + 1))['priv'],
        parsed.priv,
      );
      // The warning is mandatory.
      expect(
        find.textContaining('anyone with this string can read the channel'),
        findsOneWidget,
      );
    });

    testWidgets('public channel: keyless invite with the channel id', (
      tester,
    ) async {
      const channel = Channel(
        id: 'pc9',
        networkId: 'net1',
        name: 'lobby',
        isPublic: true,
      );
      final wallet = await walletWithChannel(
        channelPub: channelKeys.pub,
        channelPriv: channelKeys.priv,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(
            body: AddAgentDialog(
              wallet: wallet,
              networkId: 'net1',
              channel: channel,
            ),
          ),
        ),
      );
      final invite = tester
          .widget<Text>(find.byKey(const ValueKey('agentInvite')))
          .data!;
      expect(invite, contains('channel=pc9'));
      expect(invite, isNot(contains('#')), reason: 'no key material');
      expect(find.byKey(const ValueKey('copyInvite')), findsOneWidget);
    });

    testWidgets('the invite leaves the device only via the user Copy', (
      tester,
    ) async {
      final clipboard = FakeClipboard()..install(tester);
      await pumpDialog(tester);
      final invite = tester
          .widget<Text>(find.byKey(const ValueKey('agentInvite')))
          .data!;

      await tester.tap(find.byKey(const ValueKey('copyInvite')));
      await tester.pump();

      expect(clipboard.text, invite);
    });
  });
}

void _registerNetworkScopeGroup() {
  group('AddAgentDialog scope × format', () {
    late ({String pub, String priv}) channelKeys;

    setUp(() async {
      channelKeys = await EnvelopeCodec.newX25519KeyPair();
    });

    Future<KeyWallet> buildWallet({String? password}) async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(
        networkId: 'net1',
        name: 'fa-team',
        password: password,
      );
      await wallet.addChannelKeys(
        networkId: 'net1',
        channel: 'c1',
        pub: channelKeys.pub,
        priv: channelKeys.priv,
      );
      return wallet;
    }

    Future<void> pump(
      WidgetTester tester, {
      required KeyWallet wallet,
      bool public = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(
            body: AddAgentDialog(
              wallet: wallet,
              networkId: 'net1',
              channel: Channel(
                id: 'c1',
                networkId: 'net1',
                name: 'general',
                isPublic: public,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('network scope renders the join link with pw in the fragment', (
      tester,
    ) async {
      await pump(tester, wallet: await buildWallet(password: 'sekret42'));
      await tester.tap(find.text('Whole network'));
      await tester.pump();

      final invite = tester
          .widget<Text>(find.byKey(const ValueKey('agentInvite')))
          .data!;
      expect(invite, startsWith('https://network.fa1.dev/join?network=net1'));
      expect(invite, contains('#pw=sekret42'));
      expect(find.byKey(const ValueKey('inviteNoPassword')), findsNothing);
    });

    testWidgets('network scope without password: link asks for it', (
      tester,
    ) async {
      await pump(tester, wallet: await buildWallet());
      await tester.tap(find.text('Whole network'));
      await tester.pump();

      final invite = tester
          .widget<Text>(find.byKey(const ValueKey('agentInvite')))
          .data!;
      expect(invite, startsWith('https://network.fa1.dev/join?network=net1'));
      expect(invite.contains('#'), isFalse);
      expect(find.byKey(const ValueKey('inviteNoPassword')), findsOneWidget);
    });

    testWidgets('CLI format wraps the channel invite into fa dap import', (
      tester,
    ) async {
      await pump(tester, wallet: await buildWallet());
      await tester.tap(find.text('CLI command'));
      await tester.pump();

      final payload = tester
          .widget<Text>(find.byKey(const ValueKey('agentInvite')))
          .data!;
      expect(payload, startsWith("fa dap import 'wss://hub.fa1.dev/ws"));
      expect(payload.endsWith("'"), isTrue);
      expect(find.byKey(const ValueKey('inviteCliHint')), findsOneWidget);
    });

    testWidgets('CLI format on the network scope shares the plain link', (
      tester,
    ) async {
      await pump(tester, wallet: await buildWallet(password: 'sekret42'));
      await tester.tap(find.text('Whole network'));
      await tester.pump();
      await tester.tap(find.text('CLI command'));
      await tester.pump();

      final payload = tester
          .widget<Text>(find.byKey(const ValueKey('agentInvite')))
          .data!;
      expect(payload, startsWith('https://network.fa1.dev/join?network=net1'));
      expect(
        find.byKey(const ValueKey('inviteNetworkCliHint')),
        findsOneWidget,
      );
    });
  });
}
