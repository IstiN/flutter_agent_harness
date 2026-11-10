@TestOn('vm')
library;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/chats/chat_list_stores.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/chats/network_inbox_adapter.dart';
import 'package:fa/ui/chats/networks_list_panel.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/chat_text_store.dart';
import 'package:fa/services/image_preview_store.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/services/theme_pack_store.dart';
import 'package:fa/ui/activity/activity_surface.dart' show ActivityListPanel;
import 'package:fa/ui/apps/apps_directory_panel.dart';
import 'package:fa/ui/apps/messenger_app_panel.dart';
import 'package:fa/ui/apps/presentation_panel_card.dart';
import 'package:fa/ui/chats/chat_list_controller.dart';
import 'package:fa/ui/chats/chat_list_panel.dart'
    show CollapsedChatAvatarList, ChatListPanel;
import 'package:fa/ui/widgets/fah_wallpaper.dart';
import 'package:fa/ui/widgets/messenger_navigation_controls.dart';
import 'package:fa/ui/widgets/messenger_section_header.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show ProgressiveBlur, ProgressiveBlurDirection;
import 'package:fa_ui/fa_ui.dart'
    show
        FaDuoGeometry,
        FaDuoLayoutScope,
        FaDuoVerticalBarEdge,
        FaHeaderCircularAction,
        FaSurface,
        FaVisualDirection,
        MediaModelsScope,
        MediaModelsStore,
        SessionKeysScope,
        SessionKeysStore,
        TaskModelsScope,
        TaskModelsStore,
        buildFaTheme,
        debugFaGlassAlwaysFake;
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../network/fakes.dart';
import 'golden_test_helper.dart';

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
      timestamp: DateTime.utc(2026, 1, 2, 3, 4),
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

List<ChatListEntry> _goldenConversations({
  bool dense = false,
  bool denseLocal = false,
}) {
  ChatListEntry conversation(
    String id,
    String title,
    DateTime activity, {
    String preview = 'No messages yet',
    String? folder,
    int unread = 0,
    String? parentId,
    bool isSubagent = false,
  }) {
    return ChatListEntry(
      id: ChatEntryId.local(id),
      kind: ChatListEntryKind.localAgent,
      title: title,
      preview: preview,
      folderName: folder,
      folderPath: folder == null ? null : '/work/$folder',
      createdAt: activity,
      lastActivity: activity,
      unreadCount: unread,
      localMessageCount: 2,
      parentId: parentId,
      isSubagent: isSubagent,
    );
  }

  return [
    conversation(
      'design-session',
      'Fa 2.0 redesign',
      DateTime.utc(2020, 1, 2, 15, 4),
      preview: 'It stays in place with search and a calm conversation list.',
    ),
    conversation(
      'release-planning',
      'Release planning',
      DateTime.utc(2020, 1, 5, 9),
      preview: 'The release checklist is ready for review.',
      folder: 'fa',
      unread: 2,
    ),
    // A subagent of the release-planning parent (subagent sessions owner
    // pass): never a flat row — it paints as the parent row's count chip.
    conversation(
      'release-scan',
      'subagent 4a7f12c9',
      DateTime.utc(2020, 1, 5, 10),
      preview: 'The release scan finished without findings.',
      folder: 'fa',
      parentId: 'release-planning',
      isSubagent: true,
    ),
    conversation(
      'research-notes',
      'Research notes',
      DateTime.utc(2020, 1, 4, 14),
      preview: 'Compare the cleanest desktop messenger patterns.',
      folder: 'fa',
    ),
    conversation(
      'website-copy',
      'Website copy review',
      DateTime.utc(2020, 1, 3, 11),
      preview: 'A calmer first-run experience, with fewer utility controls.',
      folder: 'website',
    ),
    conversation(
      'weekly-plan',
      'Weekly planning',
      DateTime.utc(2020, 1, 1, 16),
      preview: 'Plan the next release week.',
      folder: 'website',
    ),
    if (denseLocal)
      ...List.generate(
        12,
        (index) => conversation(
          'local-fixture-$index',
          'Local project ${index + 1}',
          DateTime.utc(2020, 1, index + 10),
          preview: 'A local folder row scrolling under the glass chrome.',
          folder: 'local-$index',
        ),
      ),
    if (dense)
      ...List.generate(
        14,
        (index) => conversation(
          'archive-$index',
          'Archived design ${index + 1}',
          DateTime.utc(2019, 12, 31 - index),
          preview: 'A scrollable conversation beneath the glass chrome.',
        ),
      ),
  ];
}

void main() {
  setUpAll(ensureGoldenFonts);
  setUp(() => debugFaGlassAlwaysFake = true);
  tearDown(() => debugFaGlassAlwaysFake = false);

  FaDuoGeometry duoGeometry(Size size) => FaDuoGeometry(
    isDuo: true,
    hardwareModel: 'iPhone19,4',
    verticalBarEdge: FaDuoVerticalBarEdge.trailing,
    safeAreaInsets: const EdgeInsets.only(top: 59, right: 84, bottom: 21),
    occlusions: [Rect.fromLTWH(size.width - 84, 12, 84, 114)],
    divisions: const [],
  );

  // Captured from the real iPhone Duo fa simulator through fah/duo_layout:
  // 466×678, a 174pt camera region and no top safe-area inset. Keeping this
  // second profile prevents the 390×844 fixture from hiding compact-height
  // and native-inset regressions.
  FaDuoGeometry compactDuoGeometry() => const FaDuoGeometry(
    isDuo: true,
    hardwareModel: 'iPhone19,4',
    verticalBarEdge: FaDuoVerticalBarEdge.trailing,
    safeAreaInsets: EdgeInsets.only(right: 84, bottom: 34),
    occlusions: [
      Rect.fromLTRB(399.7, 29.3, 436.7, 66.3),
      Rect.fromLTRB(382, 0, 466, 174),
    ],
    divisions: [],
  );

  Future<FlutterSessionManager> pumpShell(
    WidgetTester tester, {
    Size size = goldenSizeDesktop,
    FaDuoGeometry? duo,
    Locale locale = const Locale('en'),
    bool populateChats = false,
    bool denseChats = false,
    bool denseChannels = false,
    bool denseLocal = false,
    bool light = false,
    bool denseTranscript = false,
    bool settingsFixtures = false,
    bool networkFixtures = false,
    FaVisualDirection direction = FaVisualDirection.glass,
  }) async {
    final env = MemoryExecutionEnv(cwd: '/work/fa_network');
    final service = _fakeService(env);
    service.messages
      ..add(
        FahChatMessage(
          role: 'user',
          content: 'Can you make the desktop shell feel like a messenger?',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'assistant',
          content:
              'Done — Chats, Activity, and Apps now share one compact '
              'navigation row, with the conversation front and center.',
        ),
      )
      ..add(
        FahChatMessage(role: 'user', content: 'What can I see in Activity?'),
      )
      ..add(
        FahChatMessage(
          role: 'assistant',
          content:
              'Running work and recent conversations, with live status '
              'updates and a direct path back to each chat.',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'user',
          content: 'Does Apps keep its own directory and overview?',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'assistant',
          content:
              'Exactly. The directory stays beside the overview, and an '
              'opened app can use its own side panel or Full overlay.',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'user',
          content: 'Keep the conversation list familiar, please.',
        ),
      )
      ..add(
        FahChatMessage(
          role: 'assistant',
          content:
              'It stays in place with search, chat names, session '
              'actions, and the active conversation preserved.',
        ),
      );
    if (denseTranscript) {
      for (var index = 0; index < 6; index++) {
        service.messages.add(
          FahChatMessage(
            role: index.isEven ? 'user' : 'assistant',
            content: index.isEven
                ? 'Keep the floating header and composer out of the message '
                      'reading order, even with a long conversation.'
                : 'The transcript scrolls underneath the translucent chrome, '
                      'while every first and last message remains reachable.',
          ),
        );
      }
    }
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession(
        'design-session',
        service,
        createdAt: DateTime.utc(2020, 1, 2, 15, 4),
        lastUpdatedAt: DateTime.utc(2020, 1, 2, 15, 4),
      );
    final titles = <String, String>{'design-session': 'Fa 2.0 redesign'};
    if (populateChats) {
      final conversations = [
        ('release-planning', 'Release planning', DateTime.utc(2020, 1, 5, 9)),
        ('research-notes', 'Research notes', DateTime.utc(2020, 1, 4, 14)),
        ('website-copy', 'Website copy review', DateTime.utc(2020, 1, 3, 11)),
        ('weekly-plan', 'Weekly planning', DateTime.utc(2020, 1, 1, 16)),
      ];
      for (final (id, title, createdAt) in conversations) {
        manager.addSession(
          id,
          _fakeService(env),
          createdAt: createdAt,
          lastUpdatedAt: createdAt,
        );
        titles[id] = title;
      }
      manager.switchTo('design-session');
    }
    final names = SessionNamesStore.inMemory(titles);
    final themeController = settingsFixtures
        ? ThemeController.inMemory()
        : null;
    if (themeController != null) {
      await themeController.setVisualDirection(direction);
    }
    final themePacks = settingsFixtures ? await ThemePackStore.load(env) : null;
    final registry = settingsFixtures ? ProviderRegistry.inMemory() : null;
    if (registry != null) {
      final provider = await registry.add(
        name: 'OpenRouter',
        baseUrl: 'https://openrouter.ai/api/v1',
        modelId: 'moonshotai/Kimi-K2.6',
      );
      registry.rememberKey(provider.id, 'test-provider-secret');
    }
    final sessionKeys = settingsFixtures
        ? SessionKeysStore.inMemory({'OPENROUTER_API_KEY': 'test-session-key'})
        : null;
    final mediaModels = settingsFixtures ? MediaModelsStore.inMemory() : null;
    final taskModels = settingsFixtures ? TaskModelsStore.inMemory() : null;
    final chatText = settingsFixtures ? ChatTextStore(env) : null;
    final imagePreviews = settingsFixtures ? ImagePreviewStore(env) : null;
    NetworkSessionManager? networkSessions;
    if (networkFixtures) {
      final wallet = await KeyWallet.load(MemoryWalletBackend());
      await wallet.createIfMissing(displayName: 'Golden User');
      await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
      await wallet.addNetwork(networkId: 'net2', name: 'quiet-net');
      for (var index = 3; index <= 14; index++) {
        await wallet.addNetwork(networkId: 'net$index', name: 'team-$index');
      }
      final networkManager = NetworkSessionManager(
        baseUrl: testBase,
        wallet: wallet,
        httpClient: FakeHttpClient(),
        wsConnector: FakeWsConnector(),
      );
      addTearDown(networkManager.disconnectAll);
      networkSessions = networkManager;
    }
    if (duo != null) {
      tester.view.padding = FakeViewPadding(
        top: duo.safeAreaInsets.top,
        right: duo.safeAreaInsets.right,
        bottom: duo.safeAreaInsets.bottom,
      );
    }
    await pumpGolden(
      tester,
      WideLayoutShell(
        manager: manager,
        networkSessions: networkSessions,
        registry: registry,
        layoutStore: settingsFixtures
            ? LauncherLayoutStore.inMemory(gridColumns: 4)
            : null,
        sessionNamesStore: names,
        localChatAdapterFactory: populateChats
            ? () => StaticChatListAdapter(
                _goldenConversations(dense: denseChats, denseLocal: denseLocal),
              )
            : null,
        chatPinStore: ChatPinStore.inMemory(
          accountId: 'local',
          pinned: {
            if (populateChats) ChatEntryId.local('design-session').canonical,
          },
        ),
        chatReadCursorStore: ChatReadCursorStore.inMemory(accountId: 'local'),
        networkInboxAdapter: populateChats
            ? FixtureNetworkInboxAdapter(
                items: [
                  NetworkInboxItem(
                    kind: ChatListEntryKind.networkChannel,
                    networkId: 'Fa Network',
                    id: 'general',
                    title: 'General',
                    lastActivity: DateTime.utc(2020, 1, 5, 10),
                    unreadCount: 4,
                  ),
                  NetworkInboxItem(
                    kind: ChatListEntryKind.networkAgent,
                    networkId: 'Fa Network',
                    id: 'release-agent',
                    title: 'Release agent',
                    lastActivity: DateTime.utc(2020, 1, 4, 16),
                    presence: ChatPresence.live,
                  ),
                  if (denseChannels)
                    for (var index = 0; index < 14; index++)
                      NetworkInboxItem(
                        kind: ChatListEntryKind.networkChannel,
                        networkId: 'Fa Network',
                        id: 'channel-$index',
                        title: 'Channel ${index + 1}',
                        lastActivity: DateTime.utc(2020, 1, 3, index),
                      ),
                ],
              )
            : null,
      ),
      size: size,
      locale: locale,
      theme: buildFaTheme(
        direction: direction,
        brightness: light ? Brightness.light : Brightness.dark,
      ),
      wrap: (child) => child,
      builder: (context, navigator) {
        var child = navigator ?? const SizedBox.shrink();
        if (settingsFixtures) {
          child = FahThemeScope(
            controller: themeController!,
            child: ThemePackScope(
              store: themePacks!,
              child: SessionKeysScope(
                store: sessionKeys!,
                child: MediaModelsScope(
                  store: mediaModels!,
                  child: TaskModelsScope(
                    store: taskModels!,
                    child: ChatTextScope(
                      store: chatText!,
                      child: ImagePreviewScope(
                        store: imagePreviews!,
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        return duo == null
            ? child
            : FaDuoLayoutScope(geometry: duo, child: child);
      },
    );
    return manager;
  }

  Future<void> openDemoApp(
    WidgetTester tester,
    FlutterSessionManager manager, {
    bool narrow = false,
    String id = 'demo',
    String name = 'Demo',
    String? icon,
  }) async {
    await manager.env.writeFile('apps/$id/manifest.json', '{}');
    await manager.env.writeFile(
      'apps/$id/widget.js',
      '(function(){jsr.render({type:"text",data:"$name"});})();',
    );
    final app = JsAppInfo.fromManifest(
      {'id': id, 'name': name, 'icon': ?icon},
      bundled: false,
      fallbackId: id,
    );
    await pushJsApp(
      tester.element(find.byType(narrow ? AppLauncherScreen : ChatScreen)),
      manager: manager,
      app: app,
      source: 'golden',
    );
    await tester.pumpAndSettle();
  }

  Future<void> disposeGoldenShell(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // JsAppEngine's null-tree watchdog is a delayed Future rather than a
    // cancellable Timer. Let the armed watchdog observe disposal so the
    // fake-async test zone ends without a pending timer.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  }

  testWidgets('Duo folded New chat and chat controls clear the camera', (
    tester,
  ) async {
    const size = goldenSizePhone;
    await pumpShell(
      tester,
      size: size,
      duo: duoGeometry(size),
      populateChats: true,
    );
    final newChat = find.byKey(const ValueKey('narrowShellNewChat'));
    expect(newChat, findsOneWidget);
    expect(tester.getRect(newChat).left, greaterThanOrEqualTo(390 - 84));
    expect(
      tester.getRect(find.byKey(const ValueKey('narrowDuoContentLane'))).right,
      lessThanOrEqualTo(390 - 84),
    );
    await expectGolden(tester, 'wide_layout_shell_duo_folded_chats');

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-local')));
    await tester.pumpAndSettle();
    expect(newChat, findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('narrowDuoContentLane'))).right,
      lessThanOrEqualTo(390 - 84),
    );
    await expectGolden(tester, 'wide_layout_shell_duo_folded_local');

    await tester.tap(find.text('fa'));
    await tester.pumpAndSettle();
    expect(newChat, findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('narrowDuoContentLane'))).right,
      lessThanOrEqualTo(390 - 84),
    );
    await expectGolden(tester, 'wide_layout_shell_duo_folded_local_detail');

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-network')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatNetworksPanel), findsOneWidget);
    expect(newChat, findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('narrowDuoContentLane'))).right,
      lessThanOrEqualTo(390 - 84),
    );
    await expectGolden(tester, 'wide_layout_shell_duo_folded_networks');

    await tester.tap(find.byKey(const ValueKey('chatFilter-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fa 2.0 redesign'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('wideModelChip')), findsOneWidget);
    expect(find.byIcon(Icons.timeline), findsOneWidget);
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('wideModelChip'))).top,
      lessThan(200),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('faChatDuoContentLane'))).right,
      lessThanOrEqualTo(390 - 84),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('faChatTopMelt'))).height,
      lessThanOrEqualTo(
        115 +
            MediaQuery.paddingOf(
              tester.element(find.byKey(const ValueKey('faChatTopMelt'))),
            ).top,
      ),
    );
    final foldedComposer = tester.getRect(
      find.byKey(const ValueKey('faChatFloatingComposer')),
    );
    expect(foldedComposer.right, lessThanOrEqualTo(390 - 84));
    expect(
      foldedComposer.center.dx,
      closeTo(
        tester
            .getRect(find.byKey(const ValueKey('faChatDuoContentLane')))
            .center
            .dx,
        .5,
      ),
    );
    final foldedRail = tester.getRect(
      find.byKey(const ValueKey('faChatDuoControlRail')),
    );
    expect(foldedRail.bottom, lessThanOrEqualTo(foldedComposer.top));
    await expectGolden(tester, 'wide_layout_shell_duo_folded_chat');
    await disposeGoldenShell(tester);
  });

  testWidgets('Duo folded every shell destination and Settings category', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const size = goldenSizePhone;
    final manager = await pumpShell(
      tester,
      size: size,
      duo: duoGeometry(size),
      populateChats: true,
      denseChats: true,
      denseChannels: true,
      denseLocal: true,
      settingsFixtures: true,
      networkFixtures: true,
    );
    await manager.env.writeFile(
      'apps/demo/manifest.json',
      '{"name":"Demo","description":"A mock installed app for Duo verification."}',
    );
    await manager.env.writeFile(
      'apps/demo/widget.js',
      '(function(){jsr.render({type:"text",data:"Demo"});})();',
    );

    Future<void> capture(String name) async {
      final lane = find.byKey(const ValueKey('narrowDuoContentLane'));
      // Settings owns a full-width rail overlay and a separate body lane;
      // the route root is intentionally full-width, the body is bounded.
      final settingsBody = find.byKey(
        const ValueKey('settingsBodyContentLane'),
      );
      final bounded = lane.evaluate().isNotEmpty
          ? lane
          : settingsBody.evaluate().isNotEmpty
          ? settingsBody
          : find.byKey(const ValueKey('appsOverviewHeader'));
      expect(bounded, findsOneWidget, reason: '$name keeps bounded Duo chrome');
      expect(
        tester.getRect(bounded).right,
        lessThanOrEqualTo(size.width - 84),
        reason: '$name must not paint its destination under the vertical bar',
      );
      await expectGolden(tester, 'wide_layout_shell_duo_folded_$name');
    }

    Future<void> openMore(String id, {bool captureSheet = false}) async {
      await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-more')));
      await tester.pumpAndSettle();
      if (captureSheet) await capture('more');
      await tester.tap(find.byKey(ValueKey('narrowShellMore-$id')));
      await tester.pumpAndSettle();
    }

    await capture('all_chats_dense');
    await openMore('chatFilter-channels', captureSheet: true);
    await capture('channels');

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-local')));
    await tester.pumpAndSettle();
    await capture('local_dense');

    for (var index = 0; index < 12; index++) {
      manager.addSession(
        'activity-$index',
        _fakeService(manager.env),
        createdAt: DateTime.utc(2020, 2, index + 1),
        lastUpdatedAt: DateTime.utc(2020, 2, index + 1),
      );
    }
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    await capture('activity');

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    expect(find.byType(AppLauncherScreen), findsOneWidget);
    expect(find.text('Demo'), findsWidgets);
    await capture('apps');

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-network')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('networkRow-net1')), findsOneWidget);
    await capture('networks_dense');

    await openMore('messengerPrimaryNav-settings');
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const ValueKey('settingsCategoryPanel')), findsOneWidget);
    await capture('settings_root');
    final settingsBack = tester.getRect(
      find.byKey(const ValueKey('settingsBackButton')),
    );
    expect(
      settingsBack.left,
      greaterThanOrEqualTo(size.width - 84),
      reason: 'Duo Settings Back belongs inside the system rail below WiFi',
    );
    expect(settingsBack.right, lessThanOrEqualTo(size.width));
    expect(settingsBack.top, greaterThanOrEqualTo(126));
    const scenes = [
      ('providersModels', 'Default chat model'),
      ('uiTheme', 'Liquid Glass'),
      ('accountsSecrets', 'OPENROUTER_API_KEY'),
      ('skillsTools', 'Built-in skills'),
      ('agentConfig', 'Tool approvals'),
      ('others', 'Reset apps'),
    ];
    for (final scene in scenes) {
      await tester.tap(find.byKey(ValueKey('settingsCategory-${scene.$1}')));
      await tester.pumpAndSettle();
      expect(find.text(scene.$2), findsWidgets, reason: scene.$1);
      expect(find.byKey(const ValueKey('settingsBackButton')), findsOneWidget);
      await capture('settings_${scene.$1}');
      await tester.tap(find.byKey(const ValueKey('settingsBackButton')));
      await tester.pumpAndSettle();
    }
    debugDefaultTargetPlatformOverride = null;
    await disposeGoldenShell(tester);
  });

  testWidgets('Duo folded Activity detail', (tester) async {
    const size = goldenSizePhone;
    await pumpShell(tester, size: size, duo: duoGeometry(size));
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('activitySession-design-session')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('narrowDuoContentLane'))).right,
      lessThanOrEqualTo(size.width - 84),
    );
    await expectGolden(tester, 'wide_layout_shell_duo_folded_activity_detail');
    await disposeGoldenShell(tester);
  });

  testWidgets('Duo folded opened app surface', (tester) async {
    const size = goldenSizePhone;
    final manager = await pumpShell(tester, size: size, duo: duoGeometry(size));
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    // Match the existing phone app golden: warm the lazy glass layer before
    // the first capture instead of freezing its cold initialization frame.
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    await openDemoApp(tester, manager, narrow: true);
    expect(
      find.byKey(const ValueKey('wideShellPresentationResizeHandle')),
      findsNothing,
    );
    final canvasPadding = tester.widget<Padding>(
      find.byKey(const ValueKey('appCanvasHeaderInset')),
    );
    expect(
      canvasPadding.padding.resolve(TextDirection.ltr).top,
      lessThan(180),
      reason: 'the vertical Duo rail must not become a giant app top inset',
    );
    expect(
      canvasPadding.padding.resolve(TextDirection.ltr).top,
      greaterThanOrEqualTo(kToolbarHeight),
      reason: 'the JS canvas still starts below the horizontal title band',
    );
    final appBack = tester.getRect(find.byKey(const ValueKey('duoAppBack')));
    expect(appBack.left, greaterThanOrEqualTo(size.width - 84));
    expect(appBack.top, greaterThanOrEqualTo(126));
    final appBar = find.descendant(
      of: find.byKey(const ValueKey('messengerAppPanel')),
      matching: find.byType(AppBar),
    );
    final toolbarClip = find
        .descendant(of: appBar, matching: find.byType(ClipRect))
        .first;
    expect(tester.getSize(toolbarClip).height, kToolbarHeight);
    await expectGolden(tester, 'wide_layout_shell_duo_folded_app_open');
    await disposeGoldenShell(tester);
  });

  testWidgets('Duo folded chat Files and New chat folder dialog', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const size = goldenSizePhone;
    final manager = await pumpShell(
      tester,
      size: size,
      duo: duoGeometry(size),
      populateChats: true,
      denseTranscript: true,
    );
    await manager.env.createDir('src');
    await manager.env.writeFile('README.md', '# Duo shell files\n');
    await tester.tap(find.text('Fa 2.0 redesign'));
    await tester.pumpAndSettle();
    final chatBack = tester.getRect(
      find.byKey(const ValueKey('faChatHeaderBack')),
    );
    expect(
      chatBack.left,
      greaterThanOrEqualTo(size.width - 84),
      reason:
          'A pushed Duo chat owns Back in the system rail, not the title lane',
    );
    expect(chatBack.top, greaterThanOrEqualTo(126));
    await expectGolden(tester, 'wide_layout_shell_duo_folded_chat_back_rail');
    final inlineFiles = find.byTooltip('Open files');
    if (inlineFiles.evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('faChatHeaderOverflow')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open files'));
    } else {
      await tester.tap(inlineFiles);
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filesAppPanel')), findsOneWidget);
    expect(find.byType(FileBrowser), findsOneWidget);
    expect(find.byKey(const ValueKey('duoFilesContentLane')), findsNothing);
    final foldedFiles = tester.getRect(
      find.byKey(const ValueKey('filesAppPanel')),
    );
    expect(
      foldedFiles.right,
      lessThanOrEqualTo(size.width - 84),
      reason: 'Files controls must not paint under the Duo system rail',
    );
    expect(
      foldedFiles.width,
      greaterThanOrEqualTo(200),
      reason: 'The Drawer SafeArea must not be followed by a second 84pt inset',
    );
    await expectGolden(tester, 'wide_layout_shell_duo_folded_chat_files');
    await tester.tapAt(const Offset(10, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filesAppPanel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('faChatHeaderBack')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('narrowShellNewChat')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('newSessionChooseFolder')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('newSessionName')),
      '  Duo launch plan  ',
    );
    await tester.pumpAndSettle();
    await expectGolden(
      tester,
      'wide_layout_shell_duo_folded_new_chat_folder_dialog',
    );
    final names = tester
        .widget<WideLayoutShell>(find.byType(WideLayoutShell))
        .sessionNamesStore!;
    await tester.tap(find.byKey(const ValueKey('newSessionCurrentFolder')));
    await tester.pumpAndSettle();
    final createdId = manager.active!.id;
    expect(names.titleFor(createdId), 'Duo launch plan');
    expect(find.text('Duo launch plan'), findsWidgets);
    debugDefaultTargetPlatformOverride = null;
    await disposeGoldenShell(tester);
  });

  testWidgets('Duo folded live 466x678 shell geometry', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const size = Size(466, 678);
    await pumpShell(
      tester,
      size: size,
      duo: compactDuoGeometry(),
      populateChats: true,
      denseLocal: true,
      networkFixtures: true,
    );
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-local')));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('narrowDuoContentLane'))).right,
      lessThanOrEqualTo(size.width - 84),
    );
    await expectGolden(tester, 'wide_layout_shell_duo_folded_compact_local');

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-network')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('networkRow-net1')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('narrowDuoContentLane'))).right,
      lessThanOrEqualTo(size.width - 84),
    );

    await tester.tap(find.byKey(const ValueKey('chatFilter-all')));
    await tester.pumpAndSettle();
    final conversationTitle = find.text('Fa 2.0 redesign');
    await tester.scrollUntilVisible(
      conversationTitle,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(conversationTitle);
    await tester.pumpAndSettle();
    final rail = tester.getRect(
      find.byKey(const ValueKey('faChatDuoControlRail')),
    );
    final composer = tester.getRect(
      find.byKey(const ValueKey('faChatFloatingComposer')),
    );
    expect(rail.bottom, lessThanOrEqualTo(composer.top));
    await expectGolden(tester, 'wide_layout_shell_duo_folded_compact_chat');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Duo folded live 466x678 Settings geometry', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const size = Size(466, 678);
    await pumpShell(
      tester,
      size: size,
      duo: compactDuoGeometry(),
      settingsFixtures: true,
    );
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-more')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey('narrowShellMore-messengerPrimaryNav-settings'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settingsCategory-uiTheme')));
    await tester.pumpAndSettle();
    expect(find.text('Liquid Glass'), findsWidgets);
    await expectGolden(
      tester,
      'wide_layout_shell_duo_folded_compact_settings_uiTheme',
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Duo folded live 466x678 opened app geometry', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const size = Size(466, 678);
    final manager = await pumpShell(
      tester,
      size: size,
      duo: compactDuoGeometry(),
      settingsFixtures: true,
    );
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    await openDemoApp(tester, manager, narrow: true);
    expect(find.text('Demo'), findsWidgets);
    final canvasPadding = tester.widget<Padding>(
      find.byKey(const ValueKey('appCanvasHeaderInset')),
    );
    expect(
      canvasPadding.padding.resolve(TextDirection.ltr).top,
      kToolbarHeight,
      reason: 'compact Duo has no top inset; only the 56pt title band remains',
    );
    final appBack = tester.getRect(find.byKey(const ValueKey('duoAppBack')));
    expect(appBack.left, greaterThanOrEqualTo(size.width - 84));
    expect(appBack.top, greaterThanOrEqualTo(174));
    await expectGolden(tester, 'wide_layout_shell_duo_folded_compact_app_open');
    debugDefaultTargetPlatformOverride = null;
    await disposeGoldenShell(tester);
  });

  testWidgets('Duo expanded Files clears the trailing system rail', (
    tester,
  ) async {
    const size = Size(951, 669);
    final manager = await pumpShell(
      tester,
      size: size,
      duo: duoGeometry(size),
      populateChats: true,
    );
    await manager.env.createDir('src');
    await manager.env.writeFile('README.md', '# Duo Files\n');
    await tester.tap(find.byTooltip('Open files'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filesAppPanel')), findsOneWidget);
    expect(find.byKey(const ValueKey('duoFilesContentLane')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('filesAppPanel'))).right,
      lessThanOrEqualTo(size.width - 84),
    );
    await expectGolden(tester, 'wide_layout_shell_duo_expanded_files');
  });

  testWidgets('Duo quick Apps chooser restores a running app', (tester) async {
    const size = Size(951, 669);
    final manager = await pumpShell(
      tester,
      size: size,
      duo: duoGeometry(size),
      populateChats: true,
    );
    await openDemoApp(tester, manager);
    expect(find.byKey(const ValueKey('appQuickApps')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('appQuickApps')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quickApp-demo')), findsOneWidget);
    await expectGolden(tester, 'wide_layout_shell_duo_expanded_quick_apps');
    await tester.tap(find.byKey(const ValueKey('quickApp-demo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('messengerAppPanel')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('duoAppBack')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('messengerAppPanel')), findsNothing);
    expect(find.byKey(const ValueKey('chatQuickApps')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chatQuickApps')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quickApp-demo')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('messengerAppPanel')), findsOneWidget);
    expect(find.byKey(const ValueKey('appQuickApps')), findsOneWidget);
    await disposeGoldenShell(tester);
  });

  testWidgets('Duo expanded every shell destination', (tester) async {
    const size = Size(951, 669);
    final manager = await pumpShell(
      tester,
      size: size,
      duo: duoGeometry(size),
      populateChats: true,
      denseLocal: true,
      settingsFixtures: true,
      networkFixtures: true,
    );
    await manager.env.writeFile(
      'apps/demo/manifest.json',
      '{"name":"Demo","description":"A mock installed app for Duo verification."}',
    );
    await manager.env.writeFile(
      'apps/demo/widget.js',
      '(function(){jsr.render({type:"text",data:"Demo"});})();',
    );
    await expectGolden(tester, 'wide_layout_shell_duo_expanded_all_chats');
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-local')));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_duo_expanded_local');
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-network')));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_duo_expanded_networks');
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_duo_expanded_activity');
    expect(
      tester.getRect(find.byKey(const ValueKey('activityDetailScroll'))).right,
      lessThanOrEqualTo(size.width - 84),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('railSettingsRow')));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_duo_expanded_settings_root');
    final expandedSettingsBack = tester.getRect(
      find.byKey(const ValueKey('settingsBackButton')),
    );
    expect(expandedSettingsBack.left, greaterThanOrEqualTo(size.width - 84));
    expect(expandedSettingsBack.right, lessThanOrEqualTo(size.width));
    expect(expandedSettingsBack.top, greaterThanOrEqualTo(126));
    expect(
      tester
          .getRect(find.byKey(const ValueKey('settingsBodyContentLane')))
          .right,
      lessThanOrEqualTo(size.width - 84),
    );
    expect(tester.takeException(), isNull);

    for (final (key, label, expected) in [
      (
        'settingsCategory-providersModels',
        'providersModels',
        'Default chat model',
      ),
      ('settingsCategory-uiTheme', 'uiTheme', 'Liquid Glass'),
      ('settingsCategory-accountsSecrets', 'accountsSecrets', 'Agent network'),
      ('settingsCategory-skillsTools', 'skillsTools', 'Built-in skills'),
      ('settingsCategory-agentConfig', 'agentConfig', 'Tool approvals'),
      ('settingsCategory-others', 'others', 'Reset apps'),
    ]) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      expect(find.text(expected), findsWidgets, reason: 'expanded $label');
      await expectGolden(
        tester,
        'wide_layout_shell_duo_expanded_settings_$label',
      );
      expect(tester.takeException(), isNull, reason: 'expanded $label');
      if (label == 'providersModels') {
        final modelRow = find.ancestor(
          of: find.byIcon(Icons.chat_bubble_outline),
          matching: find.byType(InkWell),
        );
        expect(modelRow, findsOneWidget);
        Scrollable.ensureVisible(tester.element(modelRow), alignment: .7);
        await tester.pumpAndSettle();
        await tester.tap(modelRow);
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        final editor = tester.getRect(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.byType(Scaffold),
          ),
        );
        expect(editor.width, lessThanOrEqualTo(560));
        expect(editor.right, lessThanOrEqualTo(size.width - 84));
        expect(editor.center.dx, closeTo((size.width - 84) / 2, .5));
        await expectGolden(
          tester,
          'wide_layout_shell_duo_expanded_default_model_dialog',
        );
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
      }
    }

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_duo_expanded_apps');
    expect(tester.takeException(), isNull);

    await openDemoApp(tester, manager, narrow: true);
    await expectGolden(tester, 'wide_layout_shell_duo_expanded_app_open');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('messengerAppPanel')), findsOneWidget);
    expect(find.text('Demo'), findsNWidgets(2));
    // Expanded Duo docks the app at the window's right edge (owner call:
    // no centered dialog) — the chat owns the left area beside it.
    final expandedAppSlot = tester.getRect(
      find.byKey(const ValueKey('wideShellPresentationSlot')),
    );
    final expandedAppCard = tester.getRect(
      find.byKey(const ValueKey('messengerAppPanelCard')),
    );
    expect(expandedAppSlot.right, closeTo(size.width, .5));
    expect(expandedAppSlot.width, greaterThan(340));
    expect(expandedAppCard.right, closeTo(expandedAppSlot.right - 8, .5));
    expect(expandedAppCard.width, lessThanOrEqualTo(expandedAppSlot.width));
    final expandedAppBack = tester.getRect(
      find.byKey(const ValueKey('duoAppBack')),
    );
    expect(expandedAppBack.left, greaterThanOrEqualTo(size.width - 84));
    expect(expandedAppBack.top, greaterThanOrEqualTo(126));
    // The app presented from the rail collapses the chats list; the chat
    // (and its composer) still own the left area.
    expect(find.byType(CollapsedChatAvatarList), findsOneWidget);
    expect(
      find.byKey(const ValueKey('faChatFloatingComposer')),
      findsOneWidget,
    );
    expect(find.text('My Apps'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('appFull')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('messengerAppPanelCard')), findsNothing);
    expect(find.byKey(const ValueKey('duoAppBack')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('appFull')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('messengerAppPanelCard')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('messengerAppPanelCard'))).right,
      closeTo(expandedAppCard.right, .5),
    );
    await disposeGoldenShell(tester);
  });

  testWidgets('Duo expanded shell keeps vertical-bar controls in the rail', (
    tester,
  ) async {
    const size = Size(951, 669);
    await pumpShell(
      tester,
      size: size,
      duo: duoGeometry(size),
      populateChats: true,
    );
    final chip = find.byKey(const ValueKey('wideModelChip'));
    final trajectory = find.byIcon(Icons.timeline);
    expect(chip, findsOneWidget);
    expect(trajectory, findsOneWidget);
    expect(tester.getRect(chip).left, greaterThanOrEqualTo(951 - 84));
    expect(tester.getRect(trajectory).left, greaterThanOrEqualTo(951 - 84));
    expect(
      tester.getRect(chip).top,
      greaterThanOrEqualTo(
        tester.getRect(find.byKey(const ValueKey('messengerNewButton'))).bottom,
      ),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('faChatDuoContentLane'))).right,
      lessThanOrEqualTo(951 - 84),
    );
    expect(find.byKey(const ValueKey('quickModelChipLabel')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('faChatTopMelt'))).height,
      lessThanOrEqualTo(
        115 +
            MediaQuery.paddingOf(
              tester.element(find.byKey(const ValueKey('faChatTopMelt'))),
            ).top,
      ),
    );
    final contentLane = tester.getRect(
      find.byKey(const ValueKey('faChatDuoContentLane')),
    );
    final expandedComposer = tester.getRect(
      find.byKey(const ValueKey('faChatFloatingComposer')),
    );
    expect(expandedComposer.right, lessThanOrEqualTo(951 - 84));
    expect(
      expandedComposer.center.dx,
      closeTo(contentLane.center.dx, .5),
      reason: 'Duo composer is a centered strip inside the usable chat lane',
    );
    expect(expandedComposer.width, lessThanOrEqualTo(560));
    final expandedRail = tester.getRect(
      find.byKey(const ValueKey('faChatDuoControlRail')),
    );
    expect(expandedRail.bottom, lessThanOrEqualTo(expandedComposer.top));
    await expectGolden(tester, 'wide_layout_shell_duo_collapsed');

    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quickModelChipLabel')), findsNothing);
    expect(find.byIcon(Icons.timeline), findsOneWidget);
    await expectGolden(tester, 'wide_layout_shell_duo_expanded');
    await tester.tap(find.byKey(const ValueKey('wideShellSidebarToggle')));
    await tester.pumpAndSettle();
    final collapsedPanel = tester.getRect(
      find.byKey(const ValueKey('glassSidebarPanel')),
    );
    final collapsedToggle = tester.getRect(
      find.byKey(const ValueKey('wideShellSidebarToggle')),
    );
    expect(collapsedToggle.size, const Size.square(36));
    expect(
      collapsedToggle.center.dx,
      closeTo(collapsedPanel.center.dx, .5),
      reason:
          'Duo collapsed chrome is one centered expand control, not a clipped brand+button row',
    );
    expect(find.byKey(const ValueKey('wideShellFaBrand')), findsNothing);
    await expectGolden(
      tester,
      'wide_layout_shell_duo_expanded_sidebar_collapsed',
    );
    await tester.tap(find.byKey(const ValueKey('wideShellSidebarToggle')));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('glassSidebarPanel'))).width,
      greaterThan(collapsedPanel.width),
    );
    await disposeGoldenShell(tester);
  });

  testWidgets('Duo rotated composer is centered with a one-line hint', (
    tester,
  ) async {
    const size = Size(856, 612);
    await pumpShell(
      tester,
      size: size,
      duo: duoGeometry(size),
      populateChats: true,
    );
    // Wide Duo opens the active chat directly; tapping the same list row
    // would only add a second header title to the finder.
    final lane = tester.getRect(
      find.byKey(const ValueKey('faChatDuoContentLane')),
    );
    final composer = tester.getRect(
      find.byKey(const ValueKey('faChatFloatingComposer')),
    );
    expect(composer.center.dx, closeTo(lane.center.dx, .5));
    expect(composer.width, lessThanOrEqualTo(560));
    expect(composer.right, lessThanOrEqualTo(size.width - 84));
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('faChatComposerTextField')),
    );
    expect(field.decoration?.hintMaxLines, 1);
    await expectGolden(tester, 'wide_layout_shell_duo_rotated_composer');
    await disposeGoldenShell(tester);
  });

  testWidgets('desktop Chats shell', (tester) async {
    await pumpShell(tester, populateChats: true);
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(find.byType(MessengerSectionHeader), findsOneWidget);
    await expectGolden(tester, 'wide_layout_shell_chats');
  });

  testWidgets('desktop Chats with Files docked keeps header in center', (
    tester,
  ) async {
    final manager = await pumpShell(tester, populateChats: true);
    await manager.env.createDir('src');
    await manager.env.writeFile('README.md', '# Files panel\n');
    await manager.env.writeFile('pubspec.yaml', 'name: demo\n');
    await tester.tap(find.byTooltip('Open files'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('faChatFilesPanel')), findsOneWidget);
    await expectGolden(tester, 'wide_layout_shell_chats_files');
    final handle = find.byKey(const ValueKey('faChatFilesPanelResizeHandle'));
    await tester.drag(handle, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('faChatFilesPanel'))).width,
      420,
    );
    await expectGolden(tester, 'wide_layout_shell_chats_files_resized');
  });

  testWidgets('desktop collapsed All Local and Networks avatar rails', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpShell(tester, populateChats: true);
    await tester.tap(find.byKey(const ValueKey('wideShellSidebarToggle')));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_chats_collapsed');
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-local')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('collapsedChatAvatarList')),
      findsOneWidget,
    );
    await expectGolden(tester, 'wide_layout_shell_local_collapsed');
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-network')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('collapsedChatAvatarList')),
      findsOneWidget,
    );
    await expectGolden(tester, 'wide_layout_shell_networks_collapsed');
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('collapsedChatAvatarList')),
      findsOneWidget,
    );
    await expectGolden(tester, 'wide_layout_shell_activity_collapsed');
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('collapsedAppsList')), findsOneWidget);
    await expectGolden(tester, 'wide_layout_shell_apps_collapsed');
    debugDefaultTargetPlatformOverride = null;
  });

  // Mid-collapse regression guard: the shrinking sidebar must CLIP its
  // rows — a live capture once caught the selected row painting ~40pt
  // past the panel's right edge during the animation. Pixels are the
  // only honest witness mid-flight, so this stays a golden.
  testWidgets('desktop sidebar collapse never paints rows past the panel', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpShell(tester, populateChats: true, denseChats: true);
    await tester.tap(find.byKey(const ValueKey('wideShellSidebarToggle')));
    await tester.pump(const Duration(milliseconds: 110)); // mid ~220ms flight
    // Structural: mid-flight the rows are laid out at the pre-collapse
    // width, so only a clip between them and the shrinking panel frame
    // keeps them from painting past its edge.
    final panel = find.byKey(const ValueKey('glassSidebarPanel'));
    final clips = find.ancestor(
      of: find.byKey(const ValueKey('chatListScroll')),
      matching: find.byType(ClipRect),
    );
    expect(
      find.descendant(of: panel, matching: clips).evaluate(),
      isNotEmpty,
      reason: 'the chat list must sit under a clip inside the sidebar panel',
    );
    await expectGolden(tester, 'wide_layout_shell_chats_collapse_midflight');
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_chats_collapsed_dense');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop glass rows scroll beneath the sidebar chrome band', (
    tester,
  ) async {
    await pumpShell(tester, populateChats: true, denseChats: true);
    // The chrome band is glass: a constant graduated blur behind the
    // search/segment controls, and the list scrolls beneath the band.
    final blur = tester.widget<ProgressiveBlur>(
      find.byKey(const ValueKey('chatListChromeUnderlay')),
    );
    expect(blur.maxSigma, 8);
    expect(blur.direction, ProgressiveBlurDirection.topToBottom);
    expect(blur.falloff, 3.0);
    final chromeStack = tester.widget<Stack>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('chatListChromeUnderlay')),
            matching: find.byType(Stack),
          )
          .first,
    );
    expect(
      chromeStack.clipBehavior,
      Clip.hardEdge,
      reason: 'the chat-style blur stays inside the sidebar border',
    );
    expect(find.byKey(const ValueKey('chatListChromeFade')), findsNothing);
    final scrollable = tester.widget<Scrollable>(
      find
          .descendant(
            of: find.byKey(const ValueKey('chatListScroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    scrollable.controller!.jumpTo(180);
    await tester.pumpAndSettle();
    // Honesty: the golden must actually exercise scroll-under — at least
    // one row has to sit behind the chrome band's glass.
    final underlayRect = tester.getRect(
      find.byKey(const ValueKey('chatListChromeUnderlay')),
    );
    final rows = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('chatRow-'),
    );
    expect(rows.evaluate(), isNotEmpty, reason: 'fixture rows must exist');
    final behind = rows
        .evaluate()
        .map((e) => e.findRenderObject()! as RenderBox)
        .map((box) => box.localToGlobal(Offset.zero) & box.size)
        .where((r) => r.top < underlayRect.bottom - 6 && r.bottom > 0)
        .toList();
    expect(
      behind,
      isNotEmpty,
      reason: 'a row must scroll behind the chrome band glass',
    );
    await expectGolden(tester, 'wide_layout_shell_sidebar_below_chrome');
  });

  testWidgets('desktop glass transcript scrolls beneath floating chrome', (
    tester,
  ) async {
    await pumpShell(tester, populateChats: true, denseTranscript: true);
    expect(find.byKey(const ValueKey('faChatFloatingHeader')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('faChatFloatingComposer')),
      findsOneWidget,
    );
    final transcript = find.byKey(const ValueKey('faChatTranscriptList'));
    // The melt bands over/under the floating chrome are graduated blurs, not
    // plain shadow gradients.
    final topBlur = tester.widget<ProgressiveBlur>(
      find.byKey(const ValueKey('faChatTopMelt')),
    );
    expect(topBlur.direction, ProgressiveBlurDirection.topToBottom);
    expect(topBlur.maxSigma, greaterThan(0));
    final bottomBlur = tester.widget<ProgressiveBlur>(
      find.byKey(const ValueKey('faChatBottomMelt')),
    );
    expect(bottomBlur.direction, ProgressiveBlurDirection.bottomToTop);
    expect(bottomBlur.maxSigma, greaterThan(0));
    // The avatar disc next to the title pill is the ONE circular chrome
    // now (FaHeaderCircularAction — token surface fill + hairline, the
    // painter behind FaIconActionButton), not a tinted-glass disc.
    // The key rides the FaHeaderCircularAction chrome itself.
    final avatar = tester.widget<FaHeaderCircularAction>(
      find.byKey(const ValueKey('faChatHeaderAvatar')),
    );
    expect(avatar.dimension, 36);
    // The composer surface rides a light tint, not the default dense one.
    final composer = tester.widget<FaSurface>(
      find.byKey(const ValueKey('faChatFloatingComposer')),
    );
    expect(composer.tintOpacity ?? .7, lessThan(.7));
    final scrollable = tester.widget<Scrollable>(
      find.descendant(of: transcript, matching: find.byType(Scrollable)).first,
    );
    scrollable.controller!.jumpTo(140);
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_chats_glass_scroll_under');
  });

  testWidgets('desktop graphite keeps the identical floating shell geometry', (
    tester,
  ) async {
    await pumpShell(
      tester,
      populateChats: true,
      denseTranscript: true,
      direction: FaVisualDirection.graphite,
    );
    expect(find.byKey(const ValueKey('faChatFloatingHeader')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('faChatFloatingComposer')),
      findsOneWidget,
    );
    await expectGolden(tester, 'wide_layout_shell_chats_graphite');
  });

  testWidgets('desktop light Local chats with folder destinations', (
    tester,
  ) async {
    await pumpShell(tester, populateChats: true, light: true);
    // The old globe menu's "Local" entry became the panel — narrow the
    // list through the controller the panel exposes.
    final panel = tester.widget<ChatListPanel>(find.byType(ChatListPanel));
    panel.controller.setNetworkFilter(const ChatNetworkFilter.my());
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_chats_light');
  });

  testWidgets('desktop Activity shell', (tester) async {
    await pumpShell(tester);
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ActivityListPanel), findsOneWidget);
    await expectGolden(tester, 'wide_layout_shell_activity');
  });

  for (final light in [false, true]) {
    testWidgets(
      'desktop categorized Settings replaces the transcript on mock data${light ? ' (light)' : ''}',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await pumpShell(
          tester,
          populateChats: true,
          denseTranscript: true,
          settingsFixtures: true,
          light: light,
        );
        await tester.tap(find.byKey(const ValueKey('railSettingsRow')));
        await tester.pumpAndSettle();

        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(ChatScreen), findsNothing);
        expect(
          find.byKey(const ValueKey('settingsCategoryPanel')),
          findsOneWidget,
        );

        // This categorized route also covers settings_navigation.dart.
        final lightSuffix = light ? '_light' : '';
        const scenes = [
          ('providersModels', 'Providers & Models', 'Default chat model'),
          ('uiTheme', 'UI Theme', 'Liquid Glass'),
          ('accountsSecrets', 'Accounts & Secrets', 'OPENROUTER_API_KEY'),
          ('skillsTools', 'Skills & Tools', 'Built-in skills'),
          ('agentConfig', 'Agent Config', 'Tool approvals'),
          ('others', 'Others', 'Reset apps'),
        ];
        for (final scene in scenes) {
          await tester.tap(
            find.byKey(ValueKey('settingsCategory-${scene.$1}')),
          );
          await tester.pumpAndSettle();
          expect(find.text(scene.$2), findsWidgets);
          expect(
            find.text(scene.$3),
            findsWidgets,
            reason: '${scene.$2} must render real controls, not an empty stub',
          );
          expect(find.byType(ChatScreen), findsNothing);
          final scroll = find.descendant(
            of: find.byKey(const ValueKey('settingsCategoryContent')),
            matching: find.byType(SingleChildScrollView),
          );
          final firstContentColumn = find
              .descendant(of: scroll, matching: find.byType(Column))
              .first;
          expect(tester.getSize(firstContentColumn).height, greaterThan(0));
          expect(
            tester.getRect(firstContentColumn).top,
            greaterThanOrEqualTo(tester.getRect(scroll).top),
            reason:
                '${scene.$2} must start at the top, not stale scroll offset',
          );
          await expectGolden(
            tester,
            'wide_layout_shell_settings_${scene.$1}$lightSuffix',
          );
        }
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  for (final light in [false, true]) {
    testWidgets(
      'desktop Apps directory and overview shell${light ? ' (light)' : ''}',
      (tester) async {
        final manager = await pumpShell(tester, light: light);
        final lightSuffix = light ? '_light' : '';
        await manager.env.writeFile(
          'apps/demo/manifest.json',
          '{"name":"Demo","description":"A real installed app featured from the existing catalog."}',
        );
        await manager.env.writeFile(
          'apps/demo/widget.js',
          '(function(){jsr.render({type:"text",data:"hi"});})();',
        );
        await tester.tap(
          find.byKey(const ValueKey('messengerPrimaryNav-apps')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AppsDirectoryPanel), findsOneWidget);
        // The page header owns the Apps title; the sidebar starts directly with
        // destinations rather than repeating the same label in a glass toolbar.
        expect(
          find.byKey(const ValueKey('appsDirectoryToolbar')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('appsDirectoryMyApps')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('appsOverviewHeader')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('messengerRealGlass')),
          findsNothing,
          reason:
              'the Apps header must melt into the directory, not paint a card',
        );
        expect(find.text('Files'), findsNothing);
        expect(
          find.byKey(const ValueKey('launcherCell:system:files')),
          findsNothing,
        );
        await expectGolden(tester, 'wide_layout_shell_apps$lightSuffix');
      },
    );
  }

  testWidgets('desktop opened app side panel and Full overlay', (tester) async {
    final manager = await pumpShell(tester);
    await openDemoApp(tester, manager);
    expect(find.byType(MessengerAppPanel), findsOneWidget);
    expect(find.byType(FaPresentationPanelCard), findsWidgets);
    expect(
      find.byKey(const ValueKey('presentedAppMinimizeButton')),
      findsOneWidget,
    );
    // The presented app is a floating glass card — 8pt margins, rounded
    // corners, the same chrome language as the sidebar panel.
    final card = tester.widget<Widget>(
      find.byKey(const ValueKey('messengerAppPanelCard')),
    );
    if (card is FaSurface) {
      expect(card.glass, isTrue);
      expect(card.borderRadius, BorderRadius.circular(18));
    } else {
      final decoration = (card as DecoratedBox).decoration as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(18));
    }
    final cardRect = tester.getRect(
      find.byKey(const ValueKey('messengerAppPanelCard')),
    );
    final slotRect = tester.getRect(
      find.byKey(const ValueKey('wideShellPresentationSlot')),
    );
    expect(cardRect.right, slotRect.right - 8);
    expect(cardRect.top, slotRect.top + 8);
    await expectGolden(tester, 'wide_layout_shell_app_panel');

    final resizeHandle = find.byKey(
      const ValueKey('wideShellPresentationResizeHandle'),
    );
    expect(resizeHandle, findsOneWidget);
    await tester.drag(resizeHandle, const Offset(-80, 0));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('wideShellPresentationSlot')))
          .width,
      420,
    );
    await expectGolden(tester, 'wide_layout_shell_app_panel_resized');

    await tester.tap(find.byKey(const ValueKey('appFull')));
    await tester.pumpAndSettle();
    expect(resizeHandle, findsNothing);
    expect(
      find.byKey(const ValueKey('presentedAppMinimizeButton')),
      findsOneWidget,
    );
    await expectGolden(tester, 'wide_layout_shell_app_full');
    await tester.tap(find.byKey(const ValueKey('presentedAppMinimizeButton')));
    await tester.pumpAndSettle();
    expect(find.byType(MessengerAppPanel), findsNothing);
    expect(find.byKey(const ValueKey('faChatHeaderTitlePill')), findsOneWidget);
    await disposeGoldenShell(tester);
  });

  testWidgets('desktop Running dock and directory retain every app', (
    tester,
  ) async {
    final manager = await pumpShell(tester, populateChats: true);
    await openDemoApp(tester, manager, icon: 'D');
    await tester.tap(find.byKey(const ValueKey('presentedAppMinimizeButton')));
    await tester.pumpAndSettle();
    await openDemoApp(tester, manager, id: 'second', name: 'Second', icon: 'S');
    await tester.tap(find.byKey(const ValueKey('presentedAppMinimizeButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('runningAppsDockHandle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('runningApp-demo')), findsOneWidget);
    expect(find.byKey(const ValueKey('runningApp-second')), findsOneWidget);
    await expectGolden(tester, 'wide_layout_shell_running_apps_dock');

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('appsDirectoryRunningApp-demo')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('appsDirectoryRunningApp-second')),
      findsOneWidget,
    );
    await expectGolden(tester, 'wide_layout_shell_running_apps_directory');
    await disposeGoldenShell(tester);
  });

  testWidgets('presented apps and Files animate in and out', (tester) async {
    final manager = await pumpShell(tester);
    await openDemoApp(tester, manager);
    final slot = find.byKey(const ValueKey('wideShellPresentationSlot'));
    expect(tester.getSize(slot).width, 340);
    // Close runs the exit animation: the panel lingers mid-flight, then
    // the pane collapses to nothing.
    await tester.tap(find.byKey(const ValueKey('appClose')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(MessengerAppPanel), findsOneWidget);
    expect(tester.getSize(slot).width, lessThan(340));
    await tester.pumpAndSettle();
    expect(find.byType(MessengerAppPanel), findsNothing);
    expect(slot, findsNothing);

    // Reopening replays the entrance: the slot grows over ~200ms rather
    // than popping in at full width.
    await openDemoApp(tester, manager);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appClose')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getSize(slot).width, lessThan(340));
    await tester.pumpAndSettle();
    await disposeGoldenShell(tester);
  });

  testWidgets('Russian desktop app side panel chrome', (tester) async {
    final manager = await pumpShell(tester, locale: const Locale('ru'));
    await openDemoApp(tester, manager);
    await expectGolden(tester, 'wide_layout_shell_app_panel_ru');
    await disposeGoldenShell(tester);
  });

  for (final light in [false, true]) {
    testWidgets(
      'phone unified glass destinations and categorized Settings${light ? ' (light)' : ''}',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final manager = await pumpShell(
          tester,
          size: goldenSizePhone,
          populateChats: true,
          denseChats: true,
          denseChannels: true,
          denseLocal: true,
          settingsFixtures: true,
          networkFixtures: true,
          light: light,
        );
        final lightSuffix = light ? '_light' : '';
        await manager.env.writeFile(
          'apps/demo/manifest.json',
          '{"name":"Demo","description":"A mock installed app for golden verification."}',
        );
        await manager.env.writeFile(
          'apps/demo/widget.js',
          '(function(){jsr.render({type:"text",data:"Demo"});})();',
        );

        Future<void> openMore(String id) async {
          await tester.tap(
            find.byKey(const ValueKey('messengerPrimaryNav-more')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey('narrowShellMore-$id')));
          await tester.pumpAndSettle();
        }

        Future<void> verifySection(
          String name,
          String underlayKey,
          Finder content,
        ) async {
          expect(
            find.byKey(const ValueKey('narrowSettingsButton')),
            findsNothing,
            reason: '$name keeps Settings out of the compact top bar',
          );
          expect(
            find.byKey(const ValueKey('messengerPrimaryNav-more')),
            findsOneWidget,
            reason: '$name keeps Settings reachable through responsive More',
          );
          final underlay = find.byKey(ValueKey(underlayKey));
          expect(underlay, findsOneWidget, reason: '$name needs real glass');
          expect(tester.getSize(underlay).height, greaterThan(0));
          expect(content, findsWidgets, reason: '$name must not be empty');
          await expectGolden(
            tester,
            'narrow_layout_shell_unified_$name$lightSuffix',
          );
        }

        await verifySection(
          'chats',
          'chatListChromeUnderlay',
          find.text('Local project 12'),
        );

        await tester.tap(
          find.byKey(const ValueKey('messengerPrimaryNav-local')),
        );
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const ValueKey('localFoldersList')),
          const Offset(0, -80),
        );
        await tester.pump();
        await verifySection(
          'local',
          'localChromeUnderlay',
          find.byKey(const ValueKey('localFolderRow-/work/local-11')),
        );

        for (var index = 0; index < 12; index++) {
          manager.addSession(
            'activity-$index',
            _fakeService(manager.env),
            createdAt: DateTime.utc(2020, 2, index + 1),
            lastUpdatedAt: DateTime.utc(2020, 2, index + 1),
          );
        }
        await tester.tap(
          find.byKey(const ValueKey('messengerPrimaryNav-activity')),
        );
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const ValueKey('activityList')),
          const Offset(0, -80),
        );
        await tester.pump();
        expect(
          tester
              .widget<ListView>(find.byKey(const ValueKey('activityList')))
              .childrenDelegate
              .estimatedChildCount,
          greaterThan(0),
        );
        await verifySection(
          'activity',
          'chatListChromeUnderlay',
          find.byKey(const ValueKey('activityCount')),
        );

        await tester.tap(
          find.byKey(const ValueKey('messengerPrimaryNav-apps')),
        );
        await tester.pumpAndSettle();
        await verifySection(
          'apps',
          'messengerPageTitlePill',
          find.text('Demo'),
        );
        expect(
          find.byKey(const ValueKey('appsBackButton')),
          findsNothing,
          reason: 'root phone Apps has no Back-to-Chats chrome',
        );
        expect(
          find.byKey(const ValueKey('messengerPageTopMelt')),
          findsNothing,
        );

        await openMore('chatFilter-channels');
        await tester.drag(
          find.byKey(const ValueKey('chatListScroll')),
          const Offset(0, -80),
        );
        await tester.pump();
        await verifySection(
          'channels',
          'chatListChromeUnderlay',
          find.text('General'),
        );

        await tester.tap(
          find.byKey(const ValueKey('messengerPrimaryNav-network')),
        );
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const ValueKey('networksList')),
          const Offset(0, -80),
        );
        await tester.pump();
        await verifySection(
          'networks',
          'networksChromeUnderlay',
          find.byKey(const ValueKey('networkRow-net1')),
        );

        await openMore('messengerPrimaryNav-settings');
        expect(find.byType(Dialog), findsNothing);
        expect(
          find.byKey(const ValueKey('settingsCategoryPanel')),
          findsOneWidget,
        );
        await expectGolden(
          tester,
          'narrow_layout_shell_settings_root$lightSuffix',
        );

        const scenes = [
          ('providersModels', 'Default chat model'),
          ('uiTheme', 'Liquid Glass'),
          ('accountsSecrets', 'OPENROUTER_API_KEY'),
          ('skillsTools', 'Built-in skills'),
          ('agentConfig', 'Tool approvals'),
          ('others', 'Reset apps'),
        ];
        for (final scene in scenes) {
          await tester.tap(
            find.byKey(ValueKey('settingsCategory-${scene.$1}')),
          );
          await tester.pumpAndSettle();
          expect(
            find.text(scene.$2),
            findsWidgets,
            reason: '${scene.$1} must contain real mock controls',
          );
          expect(
            find.byKey(const ValueKey('settingsBackButton')),
            findsOneWidget,
          );
          final header = find.byKey(const ValueKey('settingsCategoryHeader'));
          final pill = find.descendant(
            of: header,
            matching: find.byKey(const ValueKey('messengerPageTitlePill')),
          );
          final surface = tester.widget<FaSurface>(pill);
          expect(surface.glass, isTrue);
          expect(surface.borderRadius, BorderRadius.circular(14));
          expect(find.byType(FahWallpaper), findsOneWidget);
          await expectGolden(
            tester,
            'narrow_layout_shell_settings_${scene.$1}$lightSuffix',
          );
          await tester.tap(find.byKey(const ValueKey('settingsBackButton')));
          await tester.pumpAndSettle();
        }
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('phone Apps last row clears floating navigation', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final manager = await pumpShell(
      tester,
      size: goldenSizePhone,
      populateChats: true,
    );
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    for (var index = 0; index < 40; index++) {
      final id = 'app-${index.toString().padLeft(2, '0')}';
      final name = 'App ${index.toString().padLeft(2, '0')}';
      await manager.env.writeFile(
        'apps/$id/manifest.json',
        '{"name":"$name","description":"Installed app $index"}',
      );
    }
    manager.active!.service.fsRevision.value++;
    await tester.pumpAndSettle();

    final lastApp = find.text('App 39');
    expect(lastApp, findsOneWidget);
    await tester.ensureVisible(lastApp);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(lastApp).bottom,
      lessThan(
        tester.getRect(find.byKey(const ValueKey('narrowShellNavigation'))).top,
      ),
      reason: 'the final row must scroll above the floating navigation',
    );
    await expectGolden(tester, 'narrow_layout_shell_apps_scrolled');
    debugDefaultTargetPlatformOverride = null;
    await disposeGoldenShell(tester);
  });

  testWidgets('mobile opened app surface', (tester) async {
    final manager = await pumpShell(tester, size: goldenSizePhone);
    await tester.tap(find.text('Apps'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    // Build the same capsule after the kit's lazy glass layer has initialized.
    // A cold first capture otherwise lacks the border painted by every later
    // capture, making this golden depend on its position in the full file.
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'narrow_layout_shell_apps');
    await openDemoApp(tester, manager, narrow: true);
    expect(
      find.byKey(const ValueKey('wideShellPresentationResizeHandle')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('messengerAppPanelCard')), findsNothing);
    await expectGolden(tester, 'narrow_layout_shell_app');
    await disposeGoldenShell(tester);
  });

  // Covers lib/ui/apps/files_presentation_panel.dart (filesAppPanel).
  testWidgets('mobile chat Files opens the shared end drawer', (tester) async {
    final manager = await pumpShell(
      tester,
      size: goldenSizePhone,
      populateChats: true,
    );
    await manager.env.createDir('src');
    await manager.env.writeFile('README.md', '# Narrow shell files\n');
    await tester.tap(find.text('Fa 2.0 redesign'));
    await tester.pumpAndSettle();
    // The chat folder opens the SAME FilesAppPanel card as the desktop
    // docked pane, hosted by the narrow chat's end drawer. On a tight
    // stacked header Files demotes into overflow instead of changing chrome.
    final inlineFiles = find.byTooltip('Open files');
    if (inlineFiles.evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('faChatHeaderOverflow')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open files'));
    } else {
      await tester.tap(inlineFiles);
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filesAppPanel')), findsOneWidget);
    expect(find.byType(FileBrowser), findsOneWidget);
    await expectGolden(tester, 'narrow_layout_shell_chat_files');
    // The narrow chat drawer intentionally closes through its scrim.
    await tester.tapAt(const Offset(10, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filesAppPanel')), findsNothing);
    await disposeGoldenShell(tester);
  });

  testWidgets('mobile Activity detail', (tester) async {
    await pumpShell(tester, size: goldenSizePhone);
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'narrow_layout_shell_activity');
    await tester.tap(
      find.byKey(const ValueKey('activitySession-design-session')),
    );
    await tester.pumpAndSettle();
    await expectGolden(tester, 'narrow_layout_shell_activity_detail');
  });

  testWidgets('mobile Chats shell with populated conversations', (
    tester,
  ) async {
    await pumpShell(tester, size: goldenSizePhone, populateChats: true);
    expect(find.byType(MessengerBottomNavigation), findsOneWidget);
    expect(find.byType(MessengerNewChatButton), findsOneWidget);
    await expectGolden(tester, 'narrow_layout_shell_chats');
  });
}
