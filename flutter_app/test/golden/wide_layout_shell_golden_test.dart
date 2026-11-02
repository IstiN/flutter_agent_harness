@TestOn('vm')
library;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/chats/chat_list_stores.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:fa/ui/chats/network_inbox_adapter.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/activity/activity_surface.dart' show ActivityListPanel;
import 'package:fa/ui/apps/apps_directory_panel.dart';
import 'package:fa/ui/apps/messenger_app_panel.dart';
import 'package:fa/ui/chats/chat_list_panel.dart';
import 'package:fa/ui/widgets/messenger_navigation_controls.dart';
import 'package:fa/ui/widgets/messenger_section_header.dart';
import 'package:fa_ui/fa_ui.dart'
    show FaVisualDirection, buildFaTheme, debugFaGlassAlwaysFake;
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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

List<ChatListEntry> _goldenConversations({bool dense = false}) {
  ChatListEntry conversation(
    String id,
    String title,
    DateTime activity, {
    String preview = 'No messages yet',
    String? folder,
    int unread = 0,
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

  Future<FlutterSessionManager> pumpShell(
    WidgetTester tester, {
    Size size = goldenSizeDesktop,
    Locale locale = const Locale('en'),
    bool populateChats = false,
    bool denseChats = false,
    bool light = false,
    bool denseTranscript = false,
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
    await pumpGolden(
      tester,
      WideLayoutShell(
        manager: manager,
        sessionNamesStore: names,
        localChatAdapterFactory: populateChats
            ? () =>
                  StaticChatListAdapter(_goldenConversations(dense: denseChats))
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
    );
    return manager;
  }

  Future<void> openDemoApp(
    WidgetTester tester,
    FlutterSessionManager manager, {
    bool narrow = false,
  }) async {
    await manager.env.writeFile('apps/demo/manifest.json', '{}');
    await manager.env.writeFile(
      'apps/demo/widget.js',
      '(function(){jsr.render({type:"text",data:"hi"});})();',
    );
    final app = JsAppInfo.fromManifest(
      const {'id': 'demo', 'name': 'Demo'},
      bundled: false,
      fallbackId: 'demo',
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
    await tester.tap(find.byTooltip('Files'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('faChatFilesPanel')), findsOneWidget);
    await expectGolden(tester, 'wide_layout_shell_chats_files');
    final handle = find.byKey(const ValueKey('faChatFilesPanelResizeHandle'));
    await tester.drag(handle, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('faChatFilesPanel'))).width,
      421,
    );
    await expectGolden(tester, 'wide_layout_shell_chats_files_resized');
  });

  testWidgets('desktop folder drill-down keeps shared chrome pinned', (
    tester,
  ) async {
    await pumpShell(tester, populateChats: true);
    await tester.tap(find.byKey(const ValueKey('chatFolder-folder::/work/fa')));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_chats_folder');
  });

  testWidgets('desktop collapsed Chats rail', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpShell(tester, populateChats: true);
    await tester.tap(find.byKey(const ValueKey('wideShellSidebarToggle')));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_chats_collapsed');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop glass conversation rows scroll beneath sidebar chrome', (
    tester,
  ) async {
    await pumpShell(tester, populateChats: true, denseChats: true);
    expect(find.byKey(const ValueKey('chatListGlassChrome')), findsOneWidget);
    final fade = find.byKey(const ValueKey('chatListScrollUnderFadeOverlay'));
    expect(tester.widget<AnimatedOpacity>(fade).opacity, 0);
    final scrollable = tester.widget<Scrollable>(
      find
          .descendant(
            of: find.byKey(const ValueKey('chatListScroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    scrollable.controller!.jumpTo(180);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(fade).opacity, 1);
    // The shadow is a tight lip that ends at the toolbar's bottom edge.
    expect(
      tester
          .getSize(find.byKey(const ValueKey('chatListScrollUnderFade')))
          .height,
      24,
    );
    await expectGolden(tester, 'wide_layout_shell_sidebar_glass_scroll_under');
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
    await tester.tap(find.byKey(const ValueKey('chatNetworkFilter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local').last);
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

  testWidgets('desktop Apps directory and overview shell', (tester) async {
    final manager = await pumpShell(tester);
    await manager.env.writeFile(
      'apps/demo/manifest.json',
      '{"name":"Demo","description":"A real installed app featured from the existing catalog."}',
    );
    await manager.env.writeFile(
      'apps/demo/widget.js',
      '(function(){jsr.render({type:"text",data:"hi"});})();',
    );
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    expect(find.byType(AppsDirectoryPanel), findsOneWidget);
    await expectGolden(tester, 'wide_layout_shell_apps');
  });

  testWidgets('desktop opened app side panel and Full overlay', (tester) async {
    final manager = await pumpShell(tester);
    await openDemoApp(tester, manager);
    expect(find.byType(MessengerAppPanel), findsOneWidget);
    await expectGolden(tester, 'wide_layout_shell_app_panel');

    await tester.tap(find.byKey(const ValueKey('appFull')));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_app_full');
    await disposeGoldenShell(tester);
  });

  testWidgets('Russian desktop app side panel chrome', (tester) async {
    final manager = await pumpShell(tester, locale: const Locale('ru'));
    await openDemoApp(tester, manager);
    await expectGolden(tester, 'wide_layout_shell_app_panel_ru');
    await disposeGoldenShell(tester);
  });

  testWidgets('mobile opened app surface', (tester) async {
    final manager = await pumpShell(tester, size: goldenSizePhone);
    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'narrow_layout_shell_apps');
    await openDemoApp(tester, manager, narrow: true);
    await expectGolden(tester, 'narrow_layout_shell_app');
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

  testWidgets('mobile folder drill-down keeps shared chrome pinned', (
    tester,
  ) async {
    await pumpShell(tester, size: goldenSizePhone, populateChats: true);
    await tester.tap(find.byKey(const ValueKey('chatFolder-folder::/work/fa')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    await expectGolden(tester, 'narrow_layout_shell_chats_folder');
  });
}
