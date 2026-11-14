// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The wide shell's DEVICES nav row (issue #2062 chunk 16): the rail
/// destination exists only for signed-in accounts (a JWT on the network
/// session manager), sits between the Networks and Channels rows, and
/// selects the devices section. Fakes mirror
/// `wide_layout_shell_sidebar_resize_test.dart`. Signed-out shells create
/// no connector; the signed-in boot uses the scripted HTTP fake and never
/// reaches a real socket. The chat-source adapter is covered directly with
/// an in-memory persisted session store.
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/network/device_connector_service.dart'
    show DeviceChatSessionMetadataSource;
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart'
    show FaVisualDirection, buildFaTheme, debugFaGlassAlwaysFake;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../network/fakes.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

AgentService _fakeService(ExecutionEnv env) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

Future<NetworkSessionManager> _networkSessions({required bool jwt}) async =>
    NetworkSessionManager(
      baseUrl: Uri.parse('https://network.fa1.dev'),
      wallet: await KeyWallet.load(MemoryWalletBackend()),
      httpClient: FakeHttpClient(),
      wsConnector: FakeWsConnector(),
      jwtToken: jwt ? 'jwt-1' : null,
    );

Future<void> pumpShell(
  WidgetTester tester, {
  NetworkSessionManager? networkSessions,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  final env = MemoryExecutionEnv();
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('fake-session', _fakeService(env));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WideLayoutShell(manager: manager, networkSessions: networkSessions),
    ),
  );
  // Settle the shell's boot timers/debounces (a pending 50ms timer fails
  // the testWidgets teardown invariant).
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => debugFaGlassAlwaysFake = true);
  tearDown(() => debugFaGlassAlwaysFake = false);

  test(
    'device chat source lists persisted sessions and overlays live state',
    () async {
      final env = MemoryExecutionEnv();
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      await repo.create(
        const JsonlSessionCreateOptions(id: 'persisted-chat', cwd: '/work'),
      );
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
        repo: repo,
        includeSharedSessionRoots: false,
      );
      final source = createDeviceChatSessionSource(manager);
      expect(source.changes, same(manager));

      expect(await source.load(), const [(id: 'persisted-chat', live: false)]);

      manager
        ..addSession('persisted-chat', _fakeService(env))
        ..addSession('new-live-chat', _fakeService(env));
      final opened = await source.load();
      expect(opened, hasLength(2));
      expect(
        opened,
        containsAll(const [
          (id: 'persisted-chat', live: true),
          (id: 'new-live-chat', live: true),
        ]),
      );

      // Closing unloads the agent but does not delete the persisted chat row.
      await manager.closeSession('persisted-chat');
      final closed = await source.load();
      expect(closed, contains(const (id: 'persisted-chat', live: false)));
    },
  );

  test('device chat source keeps the complete persisted corpus', () async {
    final env = MemoryExecutionEnv();
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    for (var i = 0; i < 55; i++) {
      await repo.create(
        JsonlSessionCreateOptions(id: 'persisted-$i', cwd: '/work/$i'),
      );
    }
    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: '/sessions',
      repo: repo,
      includeSharedSessionRoots: false,
    );
    final rows = await createDeviceChatSessionSource(manager).load();
    expect(rows, hasLength(55));
    expect(
      rows.map((row) => row.id),
      containsAll(['persisted-0', 'persisted-54']),
    );
    expect(rows.every((row) => !row.live), isTrue);
  });

  test('device metadata comes from the canonical Local panel rows', () async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    final activity = DateTime.utc(2026, 11, 12, 9);
    final chatList = ChatListController(
      localAdapter: StaticChatListAdapter([
        ChatListEntry(
          id: ChatEntryId.local('rich-chat'),
          kind: ChatListEntryKind.localAgent,
          title: 'Release plan',
          createdAt: DateTime.utc(2026, 11, 11),
          lastActivity: activity,
          folderPath: '/work/flutter_agent',
        ),
        ChatListEntry(
          id: ChatEntryId.local('123e4567-e89b-12d3-a456-426614174000'),
          kind: ChatListEntryKind.localAgent,
          title: '123e4567-e89b-12d3-a456-426614174000',
          createdAt: DateTime.utc(2026, 11, 10),
        ),
      ]),
    );
    await chatList.load();
    final source = createDeviceChatSessionSource(manager, chatList: chatList);
    final metadata = await (source as DeviceChatSessionMetadataSource)
        .loadMetadata();
    expect(metadata, [
      (
        id: 'rich-chat',
        title: 'Release plan',
        path: '/work/flutter_agent',
        lastActivity: activity,
      ),
      (
        id: '123e4567-e89b-12d3-a456-426614174000',
        title: null,
        path: null,
        lastActivity: DateTime.utc(2026, 11, 10),
      ),
    ]);
  });

  /// The vertical order of rail rows (the rail is a column).
  double topOf(WidgetTester tester, Key key) =>
      tester.getTopLeft(find.byKey(key)).dy;

  testWidgets('signed in: the DEVICES rail row exists between Networks and '
      'Channels', (tester) async {
    final sessions = await _networkSessions(jwt: true);
    addTearDown(sessions.disconnectAll);
    await pumpShell(tester, networkSessions: sessions);

    final devices = find.byKey(const ValueKey('messengerPrimaryNav-devices'));
    expect(devices, findsOneWidget);
    // The row carries the l10n label (en fallback path resolves it).
    expect(find.text('Devices'), findsOneWidget);

    // Ordering: Networks → Devices → Channels (the rail is vertical).
    final networksTop = topOf(
      tester,
      const ValueKey('messengerPrimaryNav-network'),
    );
    final devicesTop = topOf(
      tester,
      const ValueKey('messengerPrimaryNav-devices'),
    );
    final channelsTop = topOf(tester, const ValueKey('chatFilter-channels'));
    expect(devicesTop, greaterThan(networksTop));
    expect(devicesTop, lessThan(channelsTop));
  });

  testWidgets('signed out (no JWT): the DEVICES rail row is absent', (
    tester,
  ) async {
    final sessions = await _networkSessions(jwt: false);
    addTearDown(sessions.disconnectAll);
    await pumpShell(tester, networkSessions: sessions);

    expect(
      find.byKey(const ValueKey('messengerPrimaryNav-devices')),
      findsNothing,
    );
    expect(find.text('Devices'), findsNothing);
  });

  testWidgets('no network wiring at all: the DEVICES rail row is absent', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(
      find.byKey(const ValueKey('messengerPrimaryNav-devices')),
      findsNothing,
    );
  });
}
