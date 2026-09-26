// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by an MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/invite_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/add_agent_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// A session manager over the test fakes — the AddAgentDialog enrolls
/// agents through it (the management JWT lives there).
Future<NetworkSessionManager> buildManager({
  required KeyWallet wallet,
  FakeHttpClient? httpClient,
  String? jwt,
}) async => NetworkSessionManager(
  baseUrl: testBase,
  wallet: wallet,
  httpClient: httpClient ?? FakeHttpClient(),
  wsConnector: FakeWsConnector(),
  jwtToken: jwt,
);

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
        manager: await buildManager(wallet: wallet),
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
              manager: await buildManager(wallet: wallet),
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
              manager: await buildManager(wallet: wallet),
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

    testWidgets('env format: channel invite + agent name (no secrets to '
        'fill in)', (tester) async {
      await pump(tester, wallet: await buildWallet());
      await tester.tap(find.text('Env (CI)'));
      await tester.pump();

      final payload = tester
          .widget<Text>(find.byKey(const ValueKey('agentInvite')))
          .data!;
      expect(payload, startsWith("FA_CHANNEL_URL='wss://hub.fa1.dev/ws"));
      // The invite IS the whole credential — no master secret, no
      // provider vars: the runner's provider is its own fa config.
      expect(payload.contains('FA_PROVIDER'), isFalse);
      expect(payload.contains('MASTER_SECRET'), isFalse);
      expect(payload, contains('FA_AGENT_NAME=general-agent fa'));
      expect(find.byKey(const ValueKey('inviteEnvHint')), findsOneWidget);
    });

    testWidgets('env format on the network scope: the join link carries '
        'the network id + password', (tester) async {
      await pump(tester, wallet: await buildWallet(password: 'pw'));
      await tester.tap(find.text('Whole network'));
      await tester.pump();
      await tester.tap(find.text('Env (CI)'));
      await tester.pump();
      final payload = tester
          .widget<Text>(find.byKey(const ValueKey('agentInvite')))
          .data!;
      expect(payload.startsWith('fa dap import'), isFalse);
      expect(
        payload,
        startsWith("FA_NETWORK_URL='https://network.fa1.dev/join?network=net1"),
      );
      // The password is split OUT of the URL into its own variable — CI
      // keeps the link a plain var and masks the password as a secret.
      expect(payload.contains('#pw='), isFalse);
      expect(payload, contains("FA_NETWORK_PASSWORD='pw' "));
      expect(payload.contains('FA_PROVIDER'), isFalse);
      expect(payload.contains('MASTER_SECRET'), isFalse);
      expect(payload, contains('FA_AGENT_NAME=fa-agent fa'));
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

    testWidgets('env format: per-variable rows copy individually', (
      tester,
    ) async {
      await pump(tester, wallet: await buildWallet(password: 'pw'));
      await tester.tap(find.text('Env (CI)'));
      await tester.pump();

      final invite = tester
          .widget<Text>(find.byKey(const ValueKey('envRow:FA_CHANNEL_URL')))
          .data!;
      expect(invite, startsWith('FA_CHANNEL_URL=wss://hub.fa1.dev/ws'));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('envRow:FA_AGENT_NAME')))
            .data,
        'FA_AGENT_NAME=general-agent',
      );
      expect(
        find.byKey(const ValueKey('envRow:DAP_MASTER_SECRET')),
        findsNothing,
      );

      final clipboard = FakeClipboard()..install(tester);
      await tester.tap(find.byKey(const ValueKey('envCopy:FA_CHANNEL_URL')));
      await tester.pump();
      expect(clipboard.text, invite);

      await tester.tap(find.byKey(const ValueKey('envCopy:FA_AGENT_NAME')));
      await tester.pump();
      expect(clipboard.text, 'FA_AGENT_NAME=general-agent');
    });

    testWidgets('env format on the network scope: URL row has no '
        'password, the password is its own row', (tester) async {
      await pump(tester, wallet: await buildWallet(password: 'pw'));
      await tester.tap(find.text('Whole network'));
      await tester.pump();
      await tester.tap(find.text('Env (CI)'));
      await tester.pump();

      final row = tester
          .widget<Text>(find.byKey(const ValueKey('envRow:FA_NETWORK_URL')))
          .data!;
      expect(row, 'FA_NETWORK_URL=https://network.fa1.dev/join?network=net1');
      final passwordRow = tester
          .widget<Text>(
            find.byKey(const ValueKey('envRow:FA_NETWORK_PASSWORD')),
          )
          .data!;
      expect(passwordRow, 'FA_NETWORK_PASSWORD=pw');

      final clipboard = FakeClipboard()..install(tester);
      await tester.tap(find.byKey(const ValueKey('envCopy:FA_NETWORK_URL')));
      await tester.pump();
      expect(clipboard.text, row);
      await tester.ensureVisible(
        find.byKey(const ValueKey('envCopy:FA_NETWORK_PASSWORD')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('envCopy:FA_NETWORK_PASSWORD')),
      );
      await tester.pump();
      expect(clipboard.text, passwordRow);
    });

    testWidgets('a network-scope dialog without a channel hides the scope '
        'switch', (tester) async {
      final wallet = await buildWallet(password: 'pw');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(
            body: AddAgentDialog(
              wallet: wallet,
              manager: await buildManager(wallet: wallet),
              networkId: 'net1',
              channel: null,
              initialScope: AgentInviteScope.network,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('inviteScope')), findsNothing);
      final payload = tester
          .widget<Text>(find.byKey(const ValueKey('agentInvite')))
          .data!;
      expect(payload, startsWith('https://network.fa1.dev/join?network=net1'));
    });
  });

  group('dap format (enroll-based agent credentials)', () {
    late ({String pub, String priv}) channelKeys;

    setUp(() async {
      channelKeys = await EnvelopeCodec.newX25519KeyPair();
    });

    /// A canned `POST /api/networks/net1/agents/enroll` 201 response.
    const enrollBody =
        '{"name":"general-agent","hubUrl":"wss://hub.fa1.dev/ws",'
        '"clientSecret":"sk_enroll_123",'
        '"enrolledAt":"2026-02-03T04:05:06Z",'
        '"note":"store clientSecret now"}';

    Future<KeyWallet> buildWallet() async {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Me');
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      await wallet.addChannelKeys(
        networkId: 'net1',
        channel: 'c1',
        pub: channelKeys.pub,
        priv: channelKeys.priv,
      );
      return wallet;
    }

    Future<void> pumpDap(
      WidgetTester tester, {
      required KeyWallet wallet,
      required NetworkSessionManager manager,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(
            body: AddAgentDialog(
              wallet: wallet,
              manager: manager,
              networkId: 'net1',
              channel: Channel(id: 'c1', networkId: 'net1', name: 'general'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('DAP'));
      await tester.pumpAndSettle();
    }

    FilledButton enrollButton(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byKey(const ValueKey('enrollAgent')));

    testWidgets('an invalid agent name shows the inline error and disables '
        'enroll; the payload area shows the enroll note until then', (
      tester,
    ) async {
      final wallet = await buildWallet();
      final manager = await buildManager(wallet: wallet, jwt: 'jwt-1');
      await pumpDap(tester, wallet: wallet, manager: manager);

      // The prefilled suggestion is valid → enroll is enabled.
      expect(enrollButton(tester).onPressed, isNotNull);
      // No credential yet: the payload area explains enrollment instead.
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('agentInvite')))
            .data!
            .contains('copy it now'),
        isTrue,
      );

      final field = find.byKey(const ValueKey('agentNameField'));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'Bad_Name!');
      await tester.pumpAndSettle();
      expect(find.text('3–64 chars: a-z, 0-9, hyphens'), findsOneWidget);
      expect(enrollButton(tester).onPressed, isNull);

      await tester.enterText(field, 'ops-bot-2');
      await tester.pumpAndSettle();
      expect(find.text('3–64 chars: a-z, 0-9, hyphens'), findsNothing);
      expect(enrollButton(tester).onPressed, isNotNull);
    });

    testWidgets('successful enroll renders the one-time credential rows, '
        'the combined payload, and row copy', (tester) async {
      final clipboard = FakeClipboard()..install(tester);
      final wallet = await buildWallet();
      final http = FakeHttpClient();
      http.respond(201, body: enrollBody);
      final manager = await buildManager(
        wallet: wallet,
        httpClient: http,
        jwt: 'jwt-1',
      );
      await pumpDap(tester, wallet: wallet, manager: manager);

      final enroll = find.byKey(const ValueKey('enrollAgent'));
      await tester.ensureVisible(enroll);
      await tester.pumpAndSettle();
      await tester.tap(enroll);
      await tester.pumpAndSettle();

      // The management call: JWT bearer + the agent name.
      final req = http.requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/api/networks/net1/agents/enroll');
      expect(req.headers['authorization'], 'Bearer jwt-1');
      expect(jsonDecode(req.body), {'name': 'general-agent'});

      // The one-time credential panel.
      expect(find.byKey(const ValueKey('envRow:IMPORT')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('envRow:DAP_HUB_URL')))
            .data,
        'DAP_HUB_URL=wss://hub.fa1.dev/ws',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('envRow:DAP_CLIENT_SECRET')),
            )
            .data,
        'DAP_CLIENT_SECRET=sk_enroll_123',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('envRow:DAP_AGENT_NAME')))
            .data,
        'DAP_AGENT_NAME=general-agent',
      );
      // The hub master secret is gone from this UI entirely.
      expect(
        find.byKey(const ValueKey('envRow:DAP_MASTER_SECRET')),
        findsNothing,
      );

      // The combined payload: channel import first, then the DAP env.
      final payload = tester
          .widget<Text>(find.byKey(const ValueKey('agentInvite')))
          .data!;
      expect(payload, startsWith("fa dap import 'wss://hub.fa1.dev/ws"));
      expect(payload, contains(' && DAP_HUB_URL=wss://hub.fa1.dev/ws'));
      expect(payload, contains("DAP_CLIENT_SECRET='sk_enroll_123'"));
      expect(payload, contains('DAP_AGENT_NAME=general-agent fa'));

      // Row-level copy puts the bare key=value on the clipboard.
      final secretCopy = find.byKey(
        const ValueKey('envCopy:DAP_CLIENT_SECRET'),
      );
      await tester.ensureVisible(secretCopy);
      await tester.pumpAndSettle();
      await tester.tap(secretCopy);
      await tester.pump();
      expect(clipboard.text, 'DAP_CLIENT_SECRET=sk_enroll_123');
    });

    testWidgets('an enrollment failure surfaces the server message inline', (
      tester,
    ) async {
      final wallet = await buildWallet();
      final http = FakeHttpClient();
      http.respond(
        403,
        body:
            '{"error":{"code":"forbidden_by_class",'
            '"message":"owner or admin only"}}',
      );
      final manager = await buildManager(
        wallet: wallet,
        httpClient: http,
        jwt: 'jwt-1',
      );
      await pumpDap(tester, wallet: wallet, manager: manager);

      final enroll = find.byKey(const ValueKey('enrollAgent'));
      await tester.ensureVisible(enroll);
      await tester.pumpAndSettle();
      await tester.tap(enroll);
      await tester.pumpAndSettle();

      final error = tester
          .widget<Text>(find.byKey(const ValueKey('enrollError')))
          .data!;
      expect(error, contains('owner or admin only'));
      expect(
        find.byKey(const ValueKey('envRow:DAP_CLIENT_SECRET')),
        findsNothing,
      );
    });

    testWidgets('without a sign-in the DAP tab shows the sign-in note', (
      tester,
    ) async {
      final wallet = await buildWallet();
      final manager = await buildManager(wallet: wallet); // no JWT
      await pumpDap(tester, wallet: wallet, manager: manager);

      expect(find.byKey(const ValueKey('enrollNeedSignIn')), findsOneWidget);
      expect(find.byKey(const ValueKey('enrollAgent')), findsNothing);
      expect(find.byKey(const ValueKey('agentNameField')), findsNothing);
    });

    testWidgets('network scope: no import row, the enrolled DAP vars stay', (
      tester,
    ) async {
      final wallet = await buildWallet();
      final http = FakeHttpClient();
      http.respond(201, body: enrollBody);
      final manager = await buildManager(
        wallet: wallet,
        httpClient: http,
        jwt: 'jwt-1',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          home: Scaffold(
            body: AddAgentDialog(
              wallet: wallet,
              manager: manager,
              networkId: 'net1',
              channel: null,
              initialScope: AgentInviteScope.network,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('DAP'));
      await tester.pumpAndSettle();

      final enroll = find.byKey(const ValueKey('enrollAgent'));
      await tester.ensureVisible(enroll);
      await tester.pumpAndSettle();
      await tester.tap(enroll);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('envRow:IMPORT')), findsNothing);
      expect(
        find.byKey(const ValueKey('envRow:DAP_CLIENT_SECRET')),
        findsOneWidget,
      );
      final payload = tester
          .widget<Text>(find.byKey(const ValueKey('agentInvite')))
          .data!;
      expect(payload, startsWith('DAP_HUB_URL='));
      expect(payload, isNot(contains('fa dap import')));
    });
  });
}
