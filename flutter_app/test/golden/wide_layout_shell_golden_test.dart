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
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show ProgressiveBlur, ProgressiveBlurDirection;
import 'package:fa_ui/fa_ui.dart'
    show FaSurface, FaVisualDirection, buildFaTheme, debugFaGlassAlwaysFake;
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

  testWidgets('PROBE rows below chrome', (tester) async {
    await pumpShell(tester, populateChats: true, denseChats: true);
    final chips = tester.getRect(
      find.byKey(const ValueKey('chatCategoryChips')),
    );
    final list = tester.getRect(find.byKey(const ValueKey('chatListScroll')));
    // ignore: avoid_print
    print('PROBE chips=$chips list=$list');
    final scrollable = tester.widget<Scrollable>(
      find
          .descendant(
            of: find.byKey(const ValueKey('chatListScroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    // ignore: avoid_print
    print('PROBE maxScroll=${scrollable.controller!.position.maxScrollExtent}');
    scrollable.controller!.jumpTo(180);
    await tester.pumpAndSettle();
    final rows = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('chatRow-'),
    );
    for (final e in rows.evaluate().take(3)) {
      final b = e.findRenderObject()! as dynamic;
      final k = (e.widget.key as ValueKey<String>).value;
      var node = b as dynamic;
      final chain = <String>[];
      while (node != null && chain.length < 8) {
        chain.add(node.runtimeType.toString());
        node = node.parent as dynamic;
      }
      // ignore: avoid_print
      print(
        'PROBE row=$k at=${b.localToGlobal(const Offset(0, 0))} chain=$chain',
      );
    }
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
    expect(blur.maxSigma, 18);
    expect(blur.direction, ProgressiveBlurDirection.topToBottom);
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
        .where((r) => r.top < underlayRect.bottom - 28 && r.bottom > 0)
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
    // The avatar disc next to the title pill is glass too, not an opaque
    // surface2 circle.
    final avatar = tester.widget<FaSurface>(
      find.descendant(
        of: find.byKey(const ValueKey('faChatHeaderAvatar')),
        matching: find.byType(FaSurface),
      ),
    );
    expect(avatar.glass, isTrue);
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
    // The directory header is the sidebar chrome language: a glass
    // capsule toolbar carrying the section eyebrow and the Files entry.
    final toolbar = tester.widget<FaSurface>(
      find.byKey(const ValueKey('appsDirectoryToolbar')),
    );
    expect(toolbar.glass, isTrue);
    expect(toolbar.tintAmount, lessThan(.35));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('appsDirectoryToolbar')),
        matching: find.byKey(const ValueKey('appsDirectoryFiles')),
      ),
      findsOneWidget,
    );
    await expectGolden(tester, 'wide_layout_shell_apps');
  });

  testWidgets('desktop opened app side panel and Full overlay', (tester) async {
    final manager = await pumpShell(tester);
    await openDemoApp(tester, manager);
    expect(find.byType(MessengerAppPanel), findsOneWidget);
    // The presented app is a floating glass card — 8pt margins, rounded
    // corners, the same chrome language as the sidebar panel.
    final card = tester.widget<FaSurface>(
      find.byKey(const ValueKey('messengerAppPanelCard')),
    );
    expect(card.glass, isTrue);
    expect(card.borderRadius, BorderRadius.circular(18));
    final cardRect = tester.getRect(
      find.byKey(const ValueKey('messengerAppPanelCard')),
    );
    final slotRect = tester.getRect(
      find.byKey(const ValueKey('wideShellPresentationSlot')),
    );
    expect(cardRect.right, slotRect.right - 8);
    expect(cardRect.top, slotRect.top + 8);
    await expectGolden(tester, 'wide_layout_shell_app_panel');

    await tester.tap(find.byKey(const ValueKey('appFull')));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'wide_layout_shell_app_full');
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

  // Covers lib/ui/apps/files_presentation_panel.dart (filesAppPanel).
  testWidgets('desktop Files presents through the animated app pane', (
    tester,
  ) async {
    final manager = await pumpShell(tester, populateChats: true);
    await manager.env.createDir('src');
    await manager.env.writeFile('README.md', '# Presented files\n');
    await manager.env.writeFile('pubspec.yaml', 'name: demo\n');
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appsDirectoryFiles')));
    await tester.pump();
    // Native presentation, animated entrance — never an instant pop.
    expect(find.byKey(const ValueKey('filesAppPanel')), findsOneWidget);
    final slot = find.byKey(const ValueKey('wideShellPresentationSlot'));
    expect(tester.getSize(slot).width, lessThan(340));
    await tester.pumpAndSettle();
    expect(tester.getSize(slot).width, 340);
    expect(find.byType(FileBrowser), findsOneWidget);
    // Files presents in the right pane while the Apps overview stays in
    // the center — the same docked surface a JS app occupies.
    expect(find.byType(AppLauncherScreen), findsOneWidget);
    await expectGolden(tester, 'wide_layout_shell_files_panel');
    await tester.tap(find.byKey(const ValueKey('filesAppClose')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('filesAppPanel')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filesAppPanel')), findsNothing);
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
