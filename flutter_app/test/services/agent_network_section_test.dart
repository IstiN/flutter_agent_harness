// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The agent-network settings section (issue #402 AC5) behaves: the
/// unsupported platform shows an honest note; the toggle drives the
/// controller; tapping a peer arms the DM composer and sending lands in
/// the controller.
library;

import 'dart:async';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_network_controller.dart';
import 'package:fa/ui/screens/dap_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scripted membership controller: records what the section asks for,
/// serves a fixed joined state.
class _RecordingAgentNetwork extends AgentNetworkController {
  _RecordingAgentNetwork({this.isSupported = true, bool joined = false})
    : super(
        env: MemoryExecutionEnv(cwd: '/test'),
        fileLayer: _fileLayer(),
        fileFabric: SwappableMessagingRepository(_fileLayer()),
        transport: null,
        loadIdentity: (_) async => null,
      ) {
    if (joined) unawaited(store.setEnabled(true));
  }

  final bool isSupported;
  final toggles = <bool>[];
  final saves = <({String? url, String? token, String? name})>[];
  final dms = <({String to, String text})>[];

  @override
  bool get supported => isSupported;

  @override
  HubLinkState? get state => store.enabled ? HubLinkState.connected : null;

  @override
  String? get agentId => store.enabled ? 'a1b2c3d4e5f60718' : null;

  @override
  Future<List<MailboxEntry>> peers() async => store.enabled
      ? const [
          MailboxEntry(id: 'p1', name: 'fa-cli', presence: AgentPresence.live),
        ]
      : const [];

  @override
  Future<void> setEnabled(bool value) async {
    toggles.add(value);
    await store.setEnabled(value);
    notifyListeners();
  }

  @override
  Future<void> saveConnection({
    String? url,
    String? token,
    String? name,
  }) async {
    saves.add((url: url, token: token, name: name));
    await store.setConnection(url: url, token: token, name: name);
    notifyListeners();
  }

  @override
  Future<void> sendDm(String to, String text) async {
    dms.add((to: to, text: text));
  }
}

FileMessagingRepository _fileLayer() => FileMessagingRepository(
  env: MemoryExecutionEnv(cwd: '/test'),
  root: '/test/messages',
  homeDir: null,
  decodeSessionCwd: decodeSessionCwd,
);

Future<void> _pump(WidgetTester tester, _RecordingAgentNetwork controller) =>
    tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en')],
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentNetworkSection(controller: controller),
          ),
        ),
      ),
    );

void main() {
  testWidgets('unsupported controller shows the honest note', (tester) async {
    await _pump(tester, _RecordingAgentNetwork(isSupported: false));
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'toggle drives the controller; joining reveals status, roster and address',
    (tester) async {
      final controller = _RecordingAgentNetwork();
      await _pump(tester, controller);
      await tester.pumpAndSettle();

      expect(controller.toggles, isEmpty);
      expect(find.byType(Switch), findsOneWidget);
      // Opted out: no roster, no hub address.
      expect(find.text('fa-cli'), findsNothing);
      expect(find.text('a1b2c3d4e5f60718'), findsNothing);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(controller.toggles, [true]);
      // Joined: the hub address and the roster appear.
      expect(find.text('a1b2c3d4e5f60718'), findsOneWidget);
      expect(find.text('fa-cli'), findsOneWidget);
    },
  );

  testWidgets('tapping a peer arms the composer; send delivers the DM', (
    tester,
  ) async {
    final controller = _RecordingAgentNetwork(joined: true);
    await _pump(tester, controller);
    await tester.pumpAndSettle();

    // No composer until a peer is picked.
    expect(find.byIcon(Icons.send_outlined), findsNothing);

    await tester.tap(find.text('fa-cli'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.send_outlined), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'ping from app');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pumpAndSettle();

    expect(controller.dms.single, (to: 'p1', text: 'ping from app'));
    // The composer collapses after sending.
    expect(find.byIcon(Icons.send_outlined), findsNothing);
  });

  testWidgets('save persists the connection through the controller', (
    tester,
  ) async {
    final controller = _RecordingAgentNetwork(joined: true);
    await _pump(tester, controller);
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.first, 'ws://hub.example.com/ws');
    await tester.enterText(fields.at(1), 'iPad Fa');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(controller.saves.single, (
      url: 'ws://hub.example.com/ws',
      token: '',
      name: 'iPad Fa',
    ));
    expect(controller.store.url, 'ws://hub.example.com/ws');
    expect(controller.store.name, 'iPad Fa');
  });
}
