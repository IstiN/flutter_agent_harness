// Copyright (c) 2026, the Flutter Agent Harness authors.
// SPDX-License-Identifier: MIT

part of 'wide_layout_shell_actions_test.dart';

/// Split by concern from the actions suite (PR #2196 review: the
/// staged loc gate caps every Dart file at 2800 lines). Called from
/// the parent main(), so its setUp/tearDown apply.
void wideShellAppsActivityTests() {
  testWidgets('wide shell opens in Chats without a permanent Apps pane', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));

    await pumpShell(tester, manager: manager);

    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(AppLauncherScreen), findsNothing);
    // Chats is the implicit home and stays a quiet destination; the selected
    // filter owns the toolbar's text.
    expect(find.text('Chats'), findsNothing);
    expect(find.text('Search chats'), findsOneWidget);
    expect(find.byKey(const ValueKey('messengerNewButton')), findsOneWidget);
    expect(find.text('SESSIONS'), findsNothing);
    expect(find.text('Search sessions'), findsNothing);
    // Secondary utilities live in Apps, not as a second navigation stack.
    expect(find.widgetWithText(SidebarNavItem, 'Files'), findsNothing);
    expect(find.widgetWithText(SidebarNavItem, 'Settings'), findsNothing);
    // The vertical rail owns navigation now: All/Unread lead, Local and
    // the Network destination follow, Channels/Activity/Apps close; the
    // horizontal toolbar is gone (agents sessions live in Local folders
    // and the flat All list — no rail row).
    final rail = find.byKey(const ValueKey('messengerNavRail'));
    expect(rail, findsOneWidget);
    expect(find.byKey(const ValueKey('chatCategoryChips')), findsNothing);
    expect(
      find.byKey(const ValueKey('messengerPrimaryNav-chats')),
      findsNothing,
      reason: 'the All filter row is the Chats home',
    );
    for (final destination in const [
      'chatFilter-all',
      'chatFilter-unread',
      'messengerPrimaryNav-local',
      'messengerPrimaryNav-network',
      'chatFilter-channels',
      'messengerPrimaryNav-activity',
      'messengerPrimaryNav-apps',
    ]) {
      expect(
        find.descendant(of: rail, matching: find.byKey(ValueKey(destination))),
        findsOneWidget,
        reason: destination,
      );
    }
    expect(
      find.descendant(
        of: rail,
        matching: find.byKey(const ValueKey('chatFilter-agents')),
      ),
      findsNothing,
      reason: 'agents have no rail row (Local folders own them)',
    );
    expect(
      find.byKey(const ValueKey('chatNetworkFilter')),
      findsNothing,
      reason: 'the rail Network row is re-keyed messengerPrimaryNav-network',
    );
    await tester.pump(const Duration(milliseconds: 100));
  });

  for (final size in const [Size(800, 900), Size(1440, 900)]) {
    testWidgets(
      'Apps keeps its directory beside the overview at ${size.width}',
      (tester) async {
        final env = MemoryExecutionEnv();
        final manager = FlutterSessionManager(
          env: env,
          sessionsRoot: '/sessions',
        )..addSession('fake-session', _fakeService(env));

        await pumpShell(tester, manager: manager, size: size);
        expect(find.byType(AppLauncherScreen), findsNothing);

        await tester.tap(
          find.byKey(const ValueKey('messengerPrimaryNav-apps')),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AppLauncherScreen), findsOneWidget);
        expect(find.byType(ChatScreen), findsNothing);
        expect(find.byType(ChatListPanel), findsOneWidget);
        expect(find.byKey(const ValueKey('appsDirectory')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('appsDirectoryMyApps')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('appsDirectoryStore')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('appsDirectoryRunning')),
          findsOneWidget,
        );
        // Files is a first-class launcher tile again (owner call).
        expect(find.text('Files'), findsOneWidget);
        expect(find.byKey(const ValueKey('appsDirectoryFiles')), findsNothing);
        expect(
          find.byKey(const ValueKey('launcherCell:system:files')),
          findsOneWidget,
        );
        // The directory's Settings tile plus the rail's pinned settings row.
        expect(find.text('Settings'), findsNWidgets(2));
        final appsRect = tester.getRect(find.byType(AppLauncherScreen));
        expect(appsRect.left, greaterThan(250));
        expect(
          appsRect.right,
          size.width,
          reason: 'outer frame reaches the window; content owns its inset',
        );

        await tester.tap(find.byKey(const ValueKey('appsDirectoryStore')));
        await tester.pumpAndSettle();
        expect(find.byType(WidgetsCatalogSheet), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('appsDirectoryMyApps')));
        await tester.pumpAndSettle();
        expect(find.byType(WidgetsCatalogSheet), findsNothing);
        expect(find.byKey(const ValueKey('appsQuickOpen')), findsNothing);
        // No sidebar search on Apps (owner call) — the launcher's
        // header-reveal search is the single surface.
        expect(
          find.byKey(const ValueKey('messengerSearchField')),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('appsNarrowSearchReveal')));
        await tester.pumpAndSettle();
        final search = tester.widget<CupertinoTextField>(
          find.descendant(
            of: find.byKey(const ValueKey('appsSearchField')),
            matching: find.byType(CupertinoTextField),
          ),
        );
        expect(search.focusNode?.hasFocus, isTrue);

        final appsAction = find.byKey(
          const ValueKey('messengerPrimaryNav-apps'),
        );
        expect(
          find.descendant(of: appsAction, matching: find.text('Apps')),
          findsOneWidget,
        );
        final appsSemantics = tester.widget<Semantics>(
          find
              .descendant(
                of: appsAction,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Semantics && widget.properties.button == true,
                ),
              )
              .first,
        );
        expect(appsSemantics.properties.selected, isTrue);
      },
    );
  }

  testWidgets('open_app reveals Apps before resolving its nested Navigator', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));

    await pumpShell(tester, manager: manager);
    expect(FaChatHost.jsAppNavigatorKey?.currentState, isNull);

    final revealed = FaChatHost.revealJsApps!.call();
    await tester.pump();
    await revealed;
    await tester.pumpAndSettle();

    expect(find.byType(AppLauncherScreen), findsOneWidget);
    expect(FaChatHost.jsAppNavigatorKey?.currentState, isNotNull);
    final appsAction = find.byKey(const ValueKey('messengerPrimaryNav-apps'));
    expect(
      find.descendant(of: appsAction, matching: find.text('Apps')),
      findsOneWidget,
    );
    final appsSemantics = tester.widget<Semantics>(
      find
          .descendant(
            of: appsAction,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.button == true,
            ),
          )
          .first,
    );
    expect(appsSemantics.properties.selected, isTrue);
  });

  testWidgets('Apps full-window brand opens the shared profile', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _fakeService(env));

    await pumpShell(tester, manager: manager);
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wideShellFaBrand')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('narrowShellProfileRoute')),
      findsOneWidget,
    );
  });

  testWidgets('desktop app opens beside the current chat and supports Full, '
      'Pin, section navigation, and Close', (tester) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', service);
    const app = JsAppInfo(
      id: 'demo',
      name: 'Demo app',
      description: 'Demo',
      icon: 'D',
      declaredPermissions: AppPermissions(),
    );

    await pumpShell(tester, manager: manager);
    await pushJsApp(
      tester.element(find.byType(ChatScreen)),
      manager: manager,
      app: app,
      source: 'test',
    );
    await tester.pumpAndSettle();

    expect(find.byType(MessengerAppPanel), findsOneWidget);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(AppLauncherScreen), findsNothing);
    expect(tester.getRect(find.byType(MessengerAppPanel)).width, 340);

    await tester.tap(find.byKey(const ValueKey('appFull')));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(MessengerAppPanel)).width, 1280);
    expect(find.byTooltip('Exit full'), findsOneWidget);
    expect(find.byIcon(Icons.close_fullscreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('appFull')));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(MessengerAppPanel)).width, 340);

    await tester.tap(find.byKey(const ValueKey('appPin')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MessengerAppPanel), findsOneWidget);
    expect(find.byType(ActivityDetailPanel), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('appPin')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chatFilter-all')));
    await tester.pumpAndSettle();
    expect(find.byType(MessengerAppPanel), findsNothing);
  });

  testWidgets('Duo docks the app right, collapses the chats list, and '
      'restores it on close', (tester) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', service);
    const app = JsAppInfo(
      id: 'demo',
      name: 'Demo app',
      description: 'Demo',
      icon: 'D',
      declaredPermissions: AppPermissions(),
    );

    await pumpShell(tester, manager: manager, size: const Size(1230, 880));
    tester.view.padding = const FakeViewPadding(right: 84);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    // Expanded chats list before the presentation.
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(find.byType(CollapsedChatAvatarList), findsNothing);
    await pushJsApp(
      tester.element(find.byType(ChatScreen)),
      manager: manager,
      app: app,
      source: 'test',
    );
    await tester.pumpAndSettle();

    // Docked at the window's right edge — no centered dialog, no scrim.
    final slot = find.byKey(const ValueKey('wideShellPresentationSlot'));
    expect(slot, findsOneWidget);
    final slotRect = tester.getRect(slot);
    expect(slotRect.right, closeTo(1230, .5));
    // First Duo presentation sizes the dock to the window, not the
    // 340pt desktop default.
    expect(slotRect.width, greaterThan(340));
    final cardRect = tester.getRect(
      find.byKey(const ValueKey('messengerAppPanelCard')),
    );
    expect(cardRect.right, closeTo(slotRect.right - 8, .5));
    // The app rail actions stay on the window's right edge.
    final backRect = tester.getRect(find.byKey(const ValueKey('duoAppBack')));
    expect(backRect.left, greaterThanOrEqualTo(1230 - 84));
    expect(backRect.right, lessThanOrEqualTo(1230));

    // The chats list auto-collapsed; the chat keeps the left area.
    expect(find.byType(ChatListPanel), findsNothing);
    expect(find.byType(CollapsedChatAvatarList), findsOneWidget);
    expect(find.byType(ChatScreen), findsOneWidget);

    // Closing restores the pre-presentation list.
    await tester.tap(find.byKey(const ValueKey('appClose')));
    await tester.pumpAndSettle();
    expect(slot, findsNothing);
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(find.byType(CollapsedChatAvatarList), findsNothing);

    // Reopening collapses again; a manual re-expand during the
    // presentation wins over the auto-restore.
    await pushJsApp(
      tester.element(find.byType(ChatScreen)),
      manager: manager,
      app: app,
      source: 'test',
    );
    await tester.pumpAndSettle();
    expect(find.byType(CollapsedChatAvatarList), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wideShellSidebarToggle')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatListPanel), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('appClose')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(find.byType(CollapsedChatAvatarList), findsNothing);
  });

  testWidgets('Duo Files docks right, collapses the chats list, and '
      'restores it on close', (tester) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', service);

    await pumpShell(tester, manager: manager, size: const Size(1230, 880));
    tester.view.padding = const FakeViewPadding(right: 84);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    // Expanded chats list before the presentation.
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(find.byType(CollapsedChatAvatarList), findsNothing);
    // Reach the shell's native Files surface: the profile route's Files
    // tile is its one UI entry (the launcher header's icon opens the
    // route); on a wide shell the tile presents the right-dock surface,
    // the same one a JS app uses — NOT the chat's docked Files panel.
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('messengerPageIcon')),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('narrowProfileFiles')));
    await tester.pumpAndSettle();
    // The surface presents beneath the pushed profile route — pop it.
    await tester.tap(find.byType(BackButton).first);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('filesAppPanel')), findsOneWidget);
    // The profile chain lands on the Apps section — whose collapsed body
    // proves the shell-wide auto-collapse: the sidebar column swaps the
    // expanded directory for the collapsed rail while Files docks right.
    expect(find.byKey(const ValueKey('collapsedAppsList')), findsOneWidget);

    // Closing restores the pre-presentation (expanded) state.
    await tester.tap(find.byKey(const ValueKey('filesAppClose')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filesAppPanel')), findsNothing);
    expect(find.byKey(const ValueKey('collapsedAppsList')), findsNothing);
  });

  testWidgets('Duo: the quick apps menu lists running + installed apps '
      'and presents a selection', (tester) async {
    final env = MemoryExecutionEnv();
    await env.writeFile('apps/alpha/manifest.json', '''
{
  "id": "alpha",
  "name": "Alpha Widget",
  "description": "A custom widget",
  "icon": "A"
}
''');
    await env.writeFile(
      'apps/alpha/widget.js',
      '(function(){ jsr.render({type:"text",data:"hi"}); })();',
    );
    final service = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', service);
    const app = JsAppInfo(
      id: 'demo',
      name: 'Demo app',
      description: 'Demo',
      icon: 'D',
      declaredPermissions: AppPermissions(),
    );

    await pumpShell(tester, manager: manager, size: const Size(1230, 880));
    tester.view.padding = const FakeViewPadding(right: 84);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    await pushJsApp(
      tester.element(find.byType(ChatScreen)),
      manager: manager,
      app: app,
      source: 'test',
    );
    await tester.pumpAndSettle();

    // The presented app's chrome quick-apps control opens the menu; the
    // running app comes first, then the installed-not-running ones.
    await tester.tap(find.byKey(const ValueKey('appQuickApps')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quickApp-demo')), findsOneWidget);
    expect(find.byKey(const ValueKey('quickApp-alpha')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('quickApp-alpha')));
    await tester.pumpAndSettle();
    expect(find.text('Alpha Widget'), findsWidgets);
    // The presented engine's _watchUiTree arms a 10s fake-async Timer the
    // settle does not flush; drain it before ending (the pattern at the
    // dock-full test above).
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('Duo: the chat files panel collapses the chats list and '
      'restores it on close', (tester) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', service);

    await pumpShell(tester, manager: manager, size: const Size(1230, 880));
    tester.view.padding = const FakeViewPadding(right: 84);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    // Expanded chats list before the presentation.
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(find.byType(CollapsedChatAvatarList), findsNothing);
    // The CHAT's own docked Files panel — the header's files button —
    // runs the same presentation as a presented app through the
    // FaChatHost.onFilesPanelChanged hook.
    await tester.tap(find.byTooltip('Open files'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('filesAppPanel')), findsOneWidget);
    expect(find.byType(ChatListPanel), findsNothing);
    expect(find.byType(CollapsedChatAvatarList), findsOneWidget);
    expect(find.byType(ChatScreen), findsOneWidget);

    // Closing through the panel band's own X restores the list.
    await tester.tap(find.byKey(const ValueKey('filesAppClose')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filesAppPanel')), findsNothing);
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(find.byType(CollapsedChatAvatarList), findsNothing);
  });

  testWidgets('desktop running apps minimize, keep their JS view, and switch', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', service);
    const first = JsAppInfo(
      id: 'demo',
      name: 'Demo app',
      description: 'Demo',
      icon: 'D',
      declaredPermissions: AppPermissions(),
    );
    const second = JsAppInfo(
      id: 'second',
      name: 'Second app',
      description: 'Second',
      icon: 'S',
      declaredPermissions: AppPermissions(),
    );

    await pumpShell(tester, manager: manager);
    Future<void> open(JsAppInfo app) => pushJsApp(
      tester.element(find.byType(ChatScreen)),
      manager: manager,
      app: app,
      source: 'test',
    );
    Future<void> revealDock() async {
      if (find
          .byKey(const ValueKey('runningAppsDockList'))
          .evaluate()
          .isEmpty) {
        await tester.tap(find.byKey(const ValueKey('runningAppsDockHandle')));
        await tester.pumpAndSettle();
      }
    }

    await open(first);
    await tester.pumpAndSettle();
    final firstViewKey = tester.widget<JsAppView>(find.byType(JsAppView)).key;

    await tester.tap(find.byKey(const ValueKey('presentedAppMinimizeButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('runningAppsDock')), findsOneWidget);
    expect(find.byKey(const ValueKey('runningAppsDockHandle')), findsOneWidget);
    expect(find.byKey(const ValueKey('runningApp-demo')), findsNothing);
    await revealDock();
    expect(find.byKey(const ValueKey('runningApp-demo')), findsOneWidget);
    expect(
      tester
          .widget<JsAppView>(
            find.byWidgetPredicate(
              (widget) => widget is JsAppView && widget.app.id == first.id,
              skipOffstage: false,
            ),
          )
          .key,
      same(firstViewKey),
    );

    await open(second);
    await tester.pumpAndSettle();
    await revealDock();
    expect(find.byKey(const ValueKey('runningApp-demo')), findsOneWidget);
    expect(find.byKey(const ValueKey('runningApp-second')), findsOneWidget);
    expect(
      tester
          .widget<IndexedStack>(find.byKey(const ValueKey('runningAppsStack')))
          .index,
      1,
    );

    await tester.tap(find.byKey(const ValueKey('runningApp-demo')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IndexedStack>(find.byKey(const ValueKey('runningAppsStack')))
          .index,
      0,
    );
    expect(
      tester
          .widget<JsAppView>(
            find.byWidgetPredicate(
              (widget) => widget is JsAppView && widget.app.id == first.id,
              skipOffstage: false,
            ),
          )
          .key,
      same(firstViewKey),
    );

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-local')));
    await tester.pumpAndSettle();
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
    expect(find.text('2 active apps'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('appsDirectoryRunningApp-demo')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('appClose')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('runningApp-demo')), findsNothing);
    await revealDock();
    expect(find.byKey(const ValueKey('runningApp-second')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('runningApp-second')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IndexedStack>(find.byKey(const ValueKey('runningAppsStack')))
          .index,
      0,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('runningAppsDockHandle'))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('runningAppsDockList')), findsOneWidget);
    expect(find.byKey(const ValueKey('runningApp-second')), findsOneWidget);
    await mouse.moveTo(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('runningAppsDockHandle')), findsOneWidget);
    expect(find.byKey(const ValueKey('runningApp-second')), findsNothing);
  });

  testWidgets('narrow Apps opens one full surface and Close returns to the '
      'directory', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    const app = JsAppInfo(
      id: 'demo',
      name: 'Demo app',
      description: 'Demo',
      icon: 'D',
      declaredPermissions: AppPermissions(),
    );

    await pumpShell(tester, manager: manager, size: const Size(390, 844));
    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
    await pushJsApp(
      tester.element(find.byType(AppLauncherScreen)),
      manager: manager,
      app: app,
      source: 'test',
    );
    await tester.pumpAndSettle();

    expect(find.byType(MessengerAppPanel), findsOneWidget);
    expect(tester.getRect(find.byType(MessengerAppPanel)).width, 390);
    expect(find.byKey(const ValueKey('narrowShellNavigation')), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MessengerAppPanel), findsNothing);
    expect(find.byType(AppLauncherScreen), findsOneWidget);

    await pushJsApp(
      tester.element(find.byType(AppLauncherScreen)),
      manager: manager,
      app: app,
      source: 'test',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appClose')));
    await tester.pumpAndSettle();
    expect(find.byType(MessengerAppPanel), findsNothing);
    expect(find.byType(AppLauncherScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('narrowShellNavigation')), findsOneWidget);
  });

  testWidgets('Activity explains its empty state', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');

    await pumpShell(tester, manager: manager);
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();

    expect(find.text('No session activity yet.'), findsOneWidget);
    expect(find.byKey(const ValueKey('activityFilter')), findsOneWidget);
    expect(find.byKey(const ValueKey('activityList')), findsNothing);
    expect(find.text('Choose an activity item'), findsOneWidget);
  });

  testWidgets('Activity follows live streaming state and opens its session '
      'back in Chats', (tester) async {
    final env = MemoryExecutionEnv();
    final runningService = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('running-session', runningService)
      ..addSession('recent-session', _fakeService(env));
    final names = SessionNamesStore.inMemory({
      'running-session': 'Build release',
      'recent-session': 'Write docs',
    });

    await pumpShell(tester, manager: manager, sessionNamesStore: names);
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('activitySession-running-session')),
        matching: find.text('Build release'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('activitySession-recent-session')),
        matching: find.text('Write docs'),
      ),
      findsOneWidget,
    );
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(find.byType(ActivityListPanel), findsOneWidget);
    expect(find.byType(ActivityDetailPanel), findsOneWidget);
    expect(find.text('Recent'), findsWidgets);

    await tester.enterText(
      find.byKey(const ValueKey('messengerSearchField')),
      'Build',
    );
    // The ONE shared search field applies queries after its 150ms
    // debounce (the sidebar/Files capsule behavior) — advance past it.
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const ValueKey('activitySession-running-session')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('activitySession-recent-session')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey('messengerSearchField')),
      '',
    );
    await tester.pump(const Duration(milliseconds: 200));

    runningService.isStreaming = true;
    runningService.notifyListeners();
    await tester.pump();

    expect(find.text('Running'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('activitySession-running-session')),
        matching: find.text('Build release'),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('activitySession-running-session')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.byType(ChatListPanel), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('activityOpenChat')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(manager.activeId, 'running-session');
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(ActivityDetailPanel), findsNothing);
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(
      find.byKey(const ValueKey('wideShellPrimaryNavigation')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
      findsOneWidget,
    );
    runningService.isStreaming = false;
    runningService.notifyListeners();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Liquid Glass desktop separates rounded panels without a divider',
    (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('glass-session', _fakeService(env));
      await pumpShell(tester, manager: manager);
      await tester.pumpAndSettle();

      final sidebarPanel = tester.widget<FaSurface>(
        find
            .descendant(
              of: find.byKey(const ValueKey('glassSidebarPanel')),
              matching: find.byType(FaSurface),
            )
            .first,
      );
      expect(sidebarPanel.glass, isTrue);
      expect(sidebarPanel.color, const Color(0xFF1C1C1E));
      // The chrome band is a graduated blur: rows scroll beneath the
      // search/segment glass (constant sigma — the glass is always armed).
      final underlay = tester.widget<ProgressiveBlur>(
        find.byKey(const ValueKey('chatListChromeUnderlay')),
      );
      expect(underlay.maxSigma, 8);
      final centerPanel = tester.widget<Container>(
        find.byKey(const ValueKey('glassCenterPanel')),
      );
      final centerFrame = centerPanel.decoration as BoxDecoration?;
      expect(centerFrame?.color, const Color(0xFF1E1E1E));
      expect(centerFrame?.border, isNull);
      final sidebar = tester.widget<SizedBox>(
        find.byKey(const ValueKey('desktopSidebarContainer')),
      );
      expect(sidebar.width, 260);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('desktopSidebarContainer')))
            .right,
        tester.getRect(find.byKey(const ValueKey('glassCenterPanel'))).left,
        reason: 'no divider or gap between animated panels',
      );
      final dragHandle = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(kSidebarDragHandleKey),
          matching: find.byKey(const ValueKey('faPaneResizeHandleHitSurface')),
        ),
      );
      expect(
        (dragHandle.decoration as BoxDecoration?)?.color,
        Colors.transparent,
      );
    },
  );

  testWidgets('token notifications do not reload every local session', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('streaming-session', service);
    final source = _CountingLocalChatListSource();
    await pumpShell(
      tester,
      manager: manager,
      localChatAdapterFactory: () => source,
    );
    await tester.pumpAndSettle();
    final initialLoads = source.loadCount;

    service.isStreaming = true;
    service.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(source.loadCount, initialLoads + 1, reason: 'run start refreshes');

    for (var delta = 0; delta < 12; delta++) {
      service.notifyListeners();
      await tester.pump();
    }
    expect(
      source.loadCount,
      initialLoads + 1,
      reason: 'token deltas must not start persisted-session disk loads',
    );

    service.isStreaming = false;
    service.notifyListeners();
    await tester.pumpAndSettle();
    expect(source.loadCount, initialLoads + 2, reason: 'run end refreshes');
  });

  testWidgets('Activity filters running and recent sessions', (tester) async {
    final env = MemoryExecutionEnv();
    final running = _fakeService(env)..isStreaming = true;
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('running-session', running)
      ..addSession('recent-session', _fakeService(env));

    await pumpShell(tester, manager: manager);
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('activityFilter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Running').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('activitySession-running-session')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('activitySession-recent-session')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('activityFilter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recent').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('activitySession-running-session')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('activitySession-recent-session')),
      findsOneWidget,
    );
    running.isStreaming = false;
  });

  testWidgets('Activity and Apps use the Russian messenger labels', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));

    await pumpShell(tester, manager: manager, locale: const Locale('ru'));
    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Вся активность'), findsOneWidget);
    expect(find.text('Статус'), findsOneWidget);
    expect(find.text('Последняя активность'), findsOneWidget);
    expect(find.text('Открыть чат'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    expect(find.text('Мои приложения · Каталог виджетов'), findsOneWidget);
    expect(find.text('Мои приложения'), findsWidgets);
    expect(find.text('Каталог виджетов'), findsWidgets);
    expect(find.text('Магазин виджетов'), findsNothing);
  });

  testWidgets('sidebar section labels share one eyebrow style', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));

    await pumpShell(tester, manager: manager);
    // The flat Chats home renders NO section eyebrows (one flat active
    // list — no Pinned/Recent split); the Activity/Apps bodies still name
    // themselves through FaSectionEyebrow, so typography and case cannot
    // drift where eyebrows do render.
    expect(find.byType(FaSectionEyebrow), findsNothing);

    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FaSectionEyebrow, 'Apps'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('appsOverviewHeader')),
        matching: find.text('Apps'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('appsDirectoryToolbar')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('messengerPrimaryNav-activity')),
    );
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(FaSectionEyebrow, 'All activity'),
      findsOneWidget,
    );
    // The count chip on the Activity toolbar stays a plain dim numeral.
    expect(find.byKey(const ValueKey('activityCount')), findsOneWidget);
  });
}
