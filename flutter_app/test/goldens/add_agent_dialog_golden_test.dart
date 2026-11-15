/// Full-frame goldens for the responsive AddAgentDialog (issue #1913).
/// The real modal overlays a deterministic network-chat surface; no network
/// requests, clocks, random channel keys, or live sessions drive the pixels.
library;

import 'dart:convert';

import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/network/add_agent_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../network/fakes.dart';
import 'golden_test_helper.dart';

Future<AddAgentDialog> _dialog() async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Makar');
  await wallet.addNetwork(
    networkId: 'net1',
    name: 'fa-team',
    joinedAt: DateTime.utc(2026, 2, 3, 4, 5, 6),
  );
  await wallet.addChannelKeys(
    networkId: 'net1',
    channel: 'c1',
    pub: base64Encode(List<int>.generate(32, (index) => index)),
    priv: base64Encode(List<int>.generate(32, (index) => index + 32)),
  );
  final manager = NetworkSessionManager(
    baseUrl: testBase,
    wallet: wallet,
    httpClient: FakeHttpClient(),
    wsConnector: FakeWsConnector(),
    jwtToken: 'golden-jwt',
  );
  return AddAgentDialog(
    wallet: wallet,
    manager: manager,
    networkId: 'net1',
    channel: const Channel(
      id: 'c1',
      networkId: 'net1',
      name: 'general',
      isPublic: false,
    ),
  );
}

Future<void> _pumpAddAgent(
  WidgetTester tester, {
  required Size size,
  required ThemeData theme,
}) async {
  await pumpGolden(
    tester,
    _NetworkChatHost(dialog: await _dialog()),
    size: size,
    theme: theme,
    wrap: (child) => child,
  );
  expect(find.byType(AddAgentDialog), findsOneWidget);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    // AddAgentDialog uses the generic monospace family for credentials.
    // Bind it to the bundled real mono font rather than a host/test fallback.
    final mono = FontLoader('monospace')
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Bold.ttf'));
    await mono.load();
  });

  group('AddAgentDialog responsive goldens', () {
    testWidgets('phone light: wrapping options and stacked enrollment', (
      tester,
    ) async {
      await _pumpAddAgent(
        tester,
        size: goldenSizePhone,
        theme: buildFahThemeLight(),
      );
      await expectGolden(tester, 'add_agent_dialog_phone_light');
    });

    testWidgets('phone dark: wrapping options and stacked enrollment', (
      tester,
    ) async {
      await _pumpAddAgent(
        tester,
        size: goldenSizePhone,
        theme: buildFahTheme(),
      );
      await expectGolden(tester, 'add_agent_dialog_phone_dark');
    });

    testWidgets('desktop light: established segmented options and enroll row', (
      tester,
    ) async {
      await _pumpAddAgent(
        tester,
        size: goldenSizeDesktop,
        theme: buildFahThemeLight(),
      );
      await expectGolden(tester, 'add_agent_dialog_desktop_light');
    });

    testWidgets('desktop dark: established segmented options and enroll row', (
      tester,
    ) async {
      await _pumpAddAgent(
        tester,
        size: goldenSizeDesktop,
        theme: buildFahTheme(),
      );
      await expectGolden(tester, 'add_agent_dialog_desktop_dark');
    });
  });
}

class _NetworkChatHost extends StatefulWidget {
  const _NetworkChatHost({required this.dialog});

  final AddAgentDialog dialog;

  @override
  State<_NetworkChatHost> createState() => _NetworkChatHostState();
}

class _NetworkChatHostState extends State<_NetworkChatHost> {
  var _opened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_opened || !mounted) return;
      _opened = true;
      showDialog<void>(context: context, builder: (_) => widget.dialog);
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
            Text('# general', style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.people_outline)),
          IconButton(onPressed: () {}, icon: const Icon(Icons.person_add_alt)),
        ],
      ),
      body: Row(
        children: [
          if (!compact) ...[
            const SizedBox(width: 232, child: _NetworkRail()),
            const VerticalDivider(width: 1),
          ],
          const Expanded(child: _Conversation()),
        ],
      ),
      bottomNavigationBar: const _Composer(),
    );
  }
}

class _NetworkRail extends StatelessWidget {
  const _NetworkRail();

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
          for (final channel in ['general', 'releases', 'support'])
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: channel == 'general'
                    ? theme.colorScheme.primaryContainer
                    : null,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.tag, size: 17),
                  const SizedBox(width: 8),
                  Text(channel),
                ],
              ),
            ),
          const SizedBox(height: 20),
          Text('DIRECT MESSAGES', style: theme.textTheme.labelSmall),
          const SizedBox(height: 12),
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(radius: 14, child: Text('O')),
            title: Text('Olya'),
            subtitle: Text('online'),
          ),
        ],
      ),
    );
  }
}

class _Conversation extends StatelessWidget {
  const _Conversation();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: const [
        _Message(
          author: 'Olya',
          time: '09:41',
          body: 'The staging hub is ready. Could you add the release bot?',
        ),
        SizedBox(height: 14),
        _Message(
          author: 'Makar',
          time: '09:42',
          body:
              'I’ll create a channel-scoped credential so it only reads '
              'and posts here.',
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.author,
    required this.time,
    required this.body,
  });

  final String author;
  final String time;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(author, style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(time, style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(body),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        child: Row(
          children: [
            const Icon(Icons.add_circle_outline),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Message #general',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.send_outlined),
          ],
        ),
      ),
    );
  }
}
