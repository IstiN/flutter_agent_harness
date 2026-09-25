// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/invite_codec.dart';
import 'package:fa/network/models.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/add_agent_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
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
      expect(invite, contains('channel=general'));
      final fragmentStart = invite.indexOf('#');
      expect(fragmentStart, greaterThan(0));
      // The private key material appears ONLY after the '#' fragment —
      // never in the wire-visible part of the URI (RFC 3986).
      final parsed = parseAgentInvite(invite);
      expect(parsed.channel, 'general');
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
