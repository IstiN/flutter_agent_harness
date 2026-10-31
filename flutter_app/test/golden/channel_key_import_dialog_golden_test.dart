/// Full-frame goldens for channel-key import over a private-channel surface.
/// Fixed keys and in-memory session fakes keep the filled and validation
/// states deterministic; no session startup, network, or wallet persistence
/// outside memory is involved.
library;

import 'dart:convert';

import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/invite_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/channel_key_import_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../network/fakes.dart';
import 'golden_test_helper.dart';

Future<({KeyWallet wallet, NetworkSession session})> _rig() async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Makar');
  await wallet.addNetwork(
    networkId: 'net1',
    name: 'fa-team',
    joinedAt: DateTime.utc(2026, 2, 3, 4, 5, 6),
  );
  final session = buildSession(
    httpClient: FakeHttpClient(),
    connector: FakeWsConnector(),
    wallet: wallet,
  );
  addTearDown(session.close);
  return (wallet: wallet, session: session);
}

Future<String> _inviteFor(String channelId) async {
  final privateKey = base64UrlEncode(
    List<int>.generate(32, (index) => index + 1),
  );
  const codec = EnvelopeCodec();
  final keyPair = await codec.keyPairFromPriv(privateKey);
  final publicKey = base64UrlEncode((await keyPair.extractPublicKey()).bytes);
  return buildAgentInvite(
    hubUri: Uri.parse('wss://hub.fa1.dev/ws'),
    channel: channelId,
    pub: publicKey,
    priv: privateKey,
  );
}

Future<void> _pumpImport(
  WidgetTester tester, {
  required Size size,
  required ThemeData theme,
  required String inviteChannel,
  bool submit = false,
}) async {
  final rig = await _rig();
  final invite = await _inviteFor(inviteChannel);
  await pumpGolden(
    tester,
    _PrivateChannelHost(wallet: rig.wallet, session: rig.session),
    size: size,
    theme: theme,
    wrap: (child) => child,
  );
  final field = find.byKey(const ValueKey('channelKeyInviteField'));
  expect(field, findsOneWidget);
  expect(tester.widget<TextField>(field).obscureText, isTrue);
  await tester.enterText(field, invite);
  await tester.pumpAndSettle();
  if (submit) {
    await tester.tap(find.byKey(const ValueKey('channelKeyImportSubmit')));
    await tester.pumpAndSettle();
    expect(
      find.text('This invite is for a different channel.'),
      findsOneWidget,
    );
  }
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  expectRealFontText(tester);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(ensureGoldenFonts);

  group('ChannelKeyImportDialog goldens', () {
    testWidgets('phone light: wrong-channel validation state', (tester) async {
      await _pumpImport(
        tester,
        size: goldenSizePhone,
        theme: buildFahThemeLight(),
        inviteChannel: 'another-channel',
        submit: true,
      );
      await expectGolden(tester, 'channel_key_import_dialog_phone_light');
    });

    testWidgets('desktop dark: valid channel invite ready to import', (
      tester,
    ) async {
      await _pumpImport(
        tester,
        size: goldenSizeDesktop,
        theme: buildFahTheme(),
        inviteChannel: 'c1',
      );
      await expectGolden(tester, 'channel_key_import_dialog_desktop_dark');
    });
  });
}

class _PrivateChannelHost extends StatefulWidget {
  const _PrivateChannelHost({required this.wallet, required this.session});

  final KeyWallet wallet;
  final NetworkSession session;

  @override
  State<_PrivateChannelHost> createState() => _PrivateChannelHostState();
}

class _PrivateChannelHostState extends State<_PrivateChannelHost> {
  var _opened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_opened || !mounted) return;
      _opened = true;
      showChannelKeyImportDialog(
        context,
        wallet: widget.wallet,
        session: widget.session,
        networkId: 'net1',
        channelId: 'c1',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    return Scaffold(
      appBar: AppBar(
        leading: compact ? const Icon(Icons.hub) : null,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('fa-team'),
            Text('# private-ops', style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.people_outline)),
          IconButton(onPressed: () {}, icon: const Icon(Icons.lock_outline)),
        ],
      ),
      body: Row(
        children: [
          if (!compact) ...[
            const SizedBox(width: 232, child: _ChannelRail()),
            const VerticalDivider(width: 1),
          ],
          const Expanded(child: _LockedChannelNotice()),
        ],
      ),
      bottomNavigationBar: const _LockedComposer(),
    );
  }
}

class _ChannelRail extends StatelessWidget {
  const _ChannelRail();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('CHANNELS', style: theme.textTheme.labelSmall),
          const SizedBox(height: 12),
          for (final channel in ['general', 'private-ops', 'releases'])
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: channel == 'private-ops'
                    ? theme.colorScheme.primaryContainer
                    : null,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    channel == 'private-ops' ? Icons.lock_outline : Icons.tag,
                    size: 17,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(channel)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _LockedChannelNotice extends StatelessWidget {
  const _LockedChannelNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 36,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'This channel is encrypted',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Import the private-channel key invite from a device '
                    'that already has access to read its history and reply.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LockedComposer extends StatelessWidget {
  const _LockedComposer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        child: Row(
          children: [
            const Icon(Icons.lock_outline, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Channel key required to compose',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
