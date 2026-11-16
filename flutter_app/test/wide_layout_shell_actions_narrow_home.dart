// Copyright (c) 2026, the Flutter Agent Harness authors.
// SPDX-License-Identifier: MIT

part of 'wide_layout_shell_actions_test.dart';

/// Split by concern from the actions suite (PR #2196 review: the
/// staged loc gate caps every Dart file at 2800 lines). Called from
/// the parent main(), so its setUp/tearDown apply.
void wideShellNarrowHomeTests() {
  group('narrow messenger home', () {
    testWidgets('boots to the Chats conversation list, not the launcher', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _listedService(env));

      await pumpShell(
        tester,
        manager: manager,
        sessionNamesStore: SessionNamesStore.inMemory({
          'design-session': 'Fa 2.0 redesign',
        }),
        size: const Size(390, 844),
      );

      expect(find.byType(WideLayoutShell), findsOneWidget);
      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('narrowShellNavigation')),
        findsOneWidget,
      );
      expect(find.text('Fa 2.0 redesign'), findsOneWidget);
      expect(find.text('Chats'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('messengerSearchReveal')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('messengerSearchField')), findsNothing);
      expect(find.byKey(const ValueKey('chatCategoryChips')), findsNothing);
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(AppLauncherScreen), findsNothing);
      expect(find.byKey(const ValueKey('narrowShellNewChat')), findsOneWidget);
    });

    testWidgets(
      'macOS compact chrome clears traffic lights but phones do not',
      (tester) async {
        final env = MemoryExecutionEnv();
        final manager = FlutterSessionManager(
          env: env,
          sessionsRoot: '/sessions',
        )..addSession('design-session', _fakeService(env));
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        for (final platform in const [
          TargetPlatform.macOS,
          TargetPlatform.iOS,
          TargetPlatform.android,
        ]) {
          debugDefaultTargetPlatformOverride = platform;
          await tester.pumpWidget(const SizedBox());
          await pumpShell(tester, manager: manager, size: const Size(390, 844));
          final brand = find.byKey(const ValueKey('wideShellFaBrand'));
          final titlebar = find.byKey(const ValueKey('macosSidebarTitlebar'));
          if (platform == TargetPlatform.macOS) {
            expect(tester.getSize(titlebar).height, 30);
            expect(tester.getTopLeft(brand).dy, greaterThanOrEqualTo(30));
          } else {
            expect(titlebar, findsNothing);
            expect(tester.getTopLeft(brand).dy, lessThan(28));
          }
        }
        debugDefaultTargetPlatformOverride = null;
      },
    );

    test('phone dock moves 15% below its #2196 position', () {
      // #2196 reduced the original 8pt gap to 6.4pt. Issue #2215 asks for
      // another 15% downward move, not 15% of the screen or dock height.
      expect(MessengerBottomNavigation.bottomGap, closeTo(6.4 * .85, .0001));
      expect(
        MessengerFloatingDockInsets.minInflatedBottom,
        MessengerBottomNavigation.height + MessengerBottomNavigation.bottomGap,
      );
    });

    testWidgets('floating dock geometry is invariant across themes', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      const labels = ['All', 'Local', 'Networks', 'Activity', 'Apps', 'More'];
      const ids = [
        'chatFilter-all',
        'messengerPrimaryNav-local',
        'messengerPrimaryNav-network',
        'messengerPrimaryNav-activity',
        'messengerPrimaryNav-apps',
        'messengerPrimaryNav-more',
      ];

      for (final direction in FaVisualDirection.values) {
        for (final brightness in Brightness.values) {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          await pumpShell(
            tester,
            manager: manager,
            direction: direction,
            brightness: brightness,
            size: const Size(390, 844),
          );
          await tester.pumpAndSettle();
          final reason = '$direction/$brightness';
          final navigation = find.byKey(
            const ValueKey('narrowShellNavigation'),
          );
          final dock = tester.getRect(navigation);
          expect(dock.left, 12, reason: reason);
          expect(dock.right, 378, reason: reason);
          expect(
            dock.bottom,
            closeTo(844 - MessengerBottomNavigation.bottomGap, .001),
            reason: reason,
          );
          expect(dock.height, 56, reason: reason);
          final surfaceFinder = find.descendant(
            of: navigation,
            matching: find.byType(FaSurface),
          );
          final surface = tester.widget<FaSurface>(surfaceFinder);
          final surfaceRect = tester.getRect(surfaceFinder);
          expect(surfaceRect.width, 366, reason: reason);
          expect(surfaceRect.height, 56, reason: reason);
          expect(surfaceRect.center.dx, 195, reason: reason);
          expect(
            surface.glass,
            direction == FaVisualDirection.glass,
            reason: reason,
          );
          expect(surface.useBackdropGroup, isTrue, reason: reason);
          final pill = tester.getRect(
            find.byKey(const ValueKey('narrowShellSelectionPill')),
          );
          expect(dock.contains(pill.topLeft), isTrue, reason: reason);
          expect(dock.contains(pill.bottomRight), isTrue, reason: reason);
          expect(pill.top - dock.top, 4, reason: reason);
          expect(dock.bottom - pill.bottom, 4, reason: reason);

          for (var index = 0; index < labels.length; index++) {
            final item = find.byKey(ValueKey(ids[index]));
            final rect = tester.getRect(item);
            expect(rect.width, closeTo(366 / 6, .001), reason: reason);
            expect(rect.height, 56, reason: reason);
            expect(rect.center.dy, dock.center.dy, reason: reason);
            final icon = tester.getRect(
              find.descendant(of: item, matching: find.byType(Icon)),
            );
            final label = tester.getRect(
              find.descendant(of: item, matching: find.text(labels[index])),
            );
            expect(icon.bottom, lessThanOrEqualTo(label.top), reason: reason);
            expect(icon.center.dx, closeTo(rect.center.dx, .001));
            expect(label.center.dx, closeTo(rect.center.dx, .001));
            expect(item.hitTestable(), findsOneWidget, reason: reason);
            final semantics = tester.widget<Semantics>(
              find.descendant(
                of: item,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Semantics &&
                      widget.properties.button == true &&
                      widget.properties.label == labels[index],
                ),
              ),
            );
            expect(semantics.properties.selected, index == 0, reason: reason);
          }
          final selectedIcon = tester.widget<Icon>(
            find.descendant(
              of: find.byKey(const ValueKey('chatFilter-all')),
              matching: find.byType(Icon),
            ),
          );
          final quietIcon = tester.widget<Icon>(
            find.descendant(
              of: find.byKey(const ValueKey('messengerPrimaryNav-activity')),
              matching: find.byType(Icon),
            ),
          );
          expect(selectedIcon.color, isNot(quietIcon.color), reason: reason);
          expect(
            find.descendant(
              of: navigation,
              matching: find.byIcon(Icons.search),
            ),
            findsNothing,
            reason: reason,
          );
          await tester.tap(
            find.byKey(const ValueKey('messengerPrimaryNav-more')),
          );
          await tester.pumpAndSettle();
          final sheet = tester.widget<FaSurface>(
            find.byKey(const ValueKey('narrowShellMoreSheet')),
          );
          expect(
            sheet.glass,
            direction == FaVisualDirection.glass,
            reason: reason,
          );
          expect(sheet.useBackdropGroup, isTrue, reason: reason);
          expect(
            sheet.color!.a,
            direction == FaVisualDirection.glass ? .92 : 1,
          );
          await tester.tap(find.byKey(const ValueKey('narrowShellMoreClose')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: reason);
        }
      }
    });

    testWidgets('dock exposes rail destinations responsively with one More', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      const primary = [
        'chatFilter-all',
        'messengerPrimaryNav-local',
        'messengerPrimaryNav-network',
        'messengerPrimaryNav-activity',
        'messengerPrimaryNav-apps',
      ];
      const all = [
        'chatFilter-all',
        'chatFilter-unread',
        'messengerPrimaryNav-local',
        'messengerPrimaryNav-network',
        'chatFilter-channels',
        'messengerPrimaryNav-activity',
        'messengerPrimaryNav-apps',
        'messengerPrimaryNav-settings',
      ];
      const secondary = [
        'chatFilter-unread',
        'chatFilter-channels',
        'messengerPrimaryNav-settings',
      ];
      final cases = <(Size, List<String>, List<String>)>[
        (const Size(320, 700), primary, secondary),
        (const Size(390, 844), primary, secondary),
        (const Size(430, 844), primary, secondary),
        (
          const Size(500, 844),
          const [
            'chatFilter-all',
            'messengerPrimaryNav-local',
            'messengerPrimaryNav-network',
            'chatFilter-channels',
            'messengerPrimaryNav-activity',
            'messengerPrimaryNav-apps',
          ],
          const ['chatFilter-unread', 'messengerPrimaryNav-settings'],
        ),
      ];
      for (final (size, direct, overflow) in cases) {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await pumpShell(tester, manager: manager, size: size);
        await tester.pumpAndSettle();
        final navigation = find.byKey(const ValueKey('narrowShellNavigation'));
        for (final id in all) {
          expect(
            find.descendant(of: navigation, matching: find.byKey(ValueKey(id))),
            direct.contains(id) ? findsOneWidget : findsNothing,
            reason: '$size/$id',
          );
        }
        final more = find.byKey(const ValueKey('messengerPrimaryNav-more'));
        if (overflow.isEmpty) {
          expect(more, findsNothing, reason: '$size');
        } else {
          expect(more, findsOneWidget, reason: '$size');
          await tester.tap(more);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('narrowShellMoreSheet')),
            findsOneWidget,
          );
          for (final id in overflow) {
            expect(
              find.byKey(ValueKey('narrowShellMore-$id')),
              findsOneWidget,
              reason: '$size/$id',
            );
          }
          if (overflow.contains('chatFilter-channels') &&
              overflow.contains('messengerPrimaryNav-settings')) {
            expect(
              tester
                      .getRect(
                        find.byKey(
                          const ValueKey('narrowShellMore-chatFilter-channels'),
                        ),
                      )
                      .top <
                  tester
                      .getRect(
                        find.byKey(
                          const ValueKey(
                            'narrowShellMore-messengerPrimaryNav-settings',
                          ),
                        ),
                      )
                      .top,
              isTrue,
              reason: '$size must prioritize Channels above Settings',
            );
          }
          await tester.tap(find.byKey(const ValueKey('narrowShellMoreClose')));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull, reason: '$size');
      }
    });

    testWidgets('Networks is direct and More reaches Unread and Channels', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      final more = find.byKey(const ValueKey('messengerPrimaryNav-more'));

      Future<void> openDestination(String id) async {
        await tester.tap(more);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('narrowShellMore-$id')));
        await tester.pumpAndSettle();
        final moreSemantics = tester.widget<Semantics>(
          find.descendant(
            of: more,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics &&
                  widget.properties.button == true &&
                  widget.properties.label == 'More',
            ),
          ),
        );
        expect(moreSemantics.properties.selected, isTrue, reason: id);
      }

      Future<void> openNetworks() async {
        await tester.tap(
          find.byKey(const ValueKey('messengerPrimaryNav-network')),
        );
        await tester.pumpAndSettle();
      }

      final controller = tester
          .widget<ChatListPanel>(find.byType(ChatListPanel))
          .controller;
      Future<void> expectNetworks() async {
        expect(find.byType(ChatNetworksPanel), findsOneWidget);
        expect(find.byKey(const ValueKey('chatNetworksList')), findsOneWidget);
        expect(find.byType(ChatListPanel), findsNothing);
        expect(
          find.byKey(const ValueKey('narrowSettingsButton')),
          findsNothing,
        );
      }

      await openNetworks();
      await expectNetworks();
      await openDestination('chatFilter-unread');
      expect(controller.filter, ChatListFilter.unread);
      expect(find.byType(ChatNetworksPanel), findsNothing);
      expect(find.byType(ChatListPanel), findsOneWidget);

      await openNetworks();
      await expectNetworks();
      await openDestination('chatFilter-channels');
      expect(controller.filter, ChatListFilter.channels);
      expect(find.byType(ChatNetworksPanel), findsNothing);
      expect(find.byType(ChatListPanel), findsOneWidget);

      await openNetworks();
      await expectNetworks();
      expect(find.byKey(const ValueKey('chatNetworksBack')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chatFilter-all')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(controller.filter, ChatListFilter.all);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dock and More badges update from the rail descriptor model', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      final entries = [
        ChatListEntry(
          id: ChatEntryId.local('Busy'),
          kind: ChatListEntryKind.localAgent,
          title: 'Busy',
          preview: 'Preview',
          createdAt: DateTime.utc(2025),
          unreadCount: 3,
          isStreaming: true,
          localMessageCount: 1,
        ),
      ];
      await pumpShell(
        tester,
        manager: manager,
        size: const Size(390, 844),
        localChatAdapterFactory: () => _StaticLocalChatListSource(entries),
      );
      await tester.pumpAndSettle();
      final navigation = find.byKey(const ValueKey('narrowShellNavigation'));
      final more = find.byKey(const ValueKey('messengerPrimaryNav-more'));
      final local = find.byKey(const ValueKey('messengerPrimaryNav-local'));
      expect(
        find.descendant(of: more, matching: find.text('1')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: local, matching: find.text('1')),
        findsOneWidget,
      );
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('narrowShellMore-chatFilter-unread')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('narrowShellMoreClose')));
      await tester.pumpAndSettle();

      final controller = tester
          .widget<ChatListPanel>(find.byType(ChatListPanel))
          .controller;
      await controller.replaceLocalEntries(const []);
      await tester.pumpAndSettle();
      expect(find.descendant(of: more, matching: find.text('1')), findsNothing);
      expect(
        find.descendant(of: local, matching: find.text('1')),
        findsNothing,
      );
      expect(navigation, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow Networks opens a channel in the full chat route', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      final networkSessions = await _narrowNetworkManager();
      final networkMode = NetworkModeController.inMemory();
      addTearDown(networkMode.dispose);
      await pumpShell(
        tester,
        manager: manager,
        size: const Size(390, 844),
        networkMode: networkMode,
        networkSessions: networkSessions,
      );
      await tester.tap(
        find.byKey(const ValueKey('messengerPrimaryNav-network')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('networkRow-net1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chatNetworkChannel-c1')));
      await tester.pumpAndSettle();

      expect(networkMode.networkId, 'net1');
      expect(networkMode.channelId, 'c1');
      expect(find.byType(NetworkChatPage), findsOneWidget);
      expect(find.byKey(const ValueKey('narrowShellNavigation')), findsNothing);
      await tester.tap(find.byType(BackButton).first);
      await tester.pumpAndSettle();
      expect(find.byType(ChatNetworksPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await networkSessions.disconnectAll();
      await tester.pump();
    });

    testWidgets('dock and compact scroll ends stay reachable at 320px', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      final entries = [
        for (var index = 0; index < 20; index++)
          ChatListEntry(
            id: ChatEntryId.local('Agent $index'),
            kind: ChatListEntryKind.localAgent,
            title: 'Agent $index',
            preview: 'Preview',
            createdAt: DateTime.utc(2025),
            lastActivity: DateTime.utc(2026),
            localMessageCount: 1,
          ),
      ];
      await pumpShell(
        tester,
        manager: manager,
        size: const Size(320, 700),
        localChatAdapterFactory: () => _StaticLocalChatListSource(entries),
      );
      await tester.pumpAndSettle();
      final dock = tester.getRect(
        find.byKey(const ValueKey('narrowShellNavigation')),
      );
      expect(dock.left, 12);
      expect(dock.right, 308);
      expect(
        dock.bottom,
        closeTo(700 - MessengerBottomNavigation.bottomGap, .001),
      );
      expect(dock.height, 56);
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('chatListScroll')),
      );
      expect((list.padding as EdgeInsets).bottom, greaterThanOrEqualTo(76));
      final rowRects = [
        for (var index = 0; index < entries.length; index++)
          if (find.text('Agent $index').evaluate().isNotEmpty)
            tester.getRect(find.text('Agent $index')),
      ];
      expect(
        rowRects.any(
          (rect) => rect.bottom > dock.top && rect.top < dock.bottom,
        ),
        isTrue,
        reason: 'visible rows must continue underneath the glass dock',
      );
      final scrollable = tester.widget<Scrollable>(
        find.descendant(
          of: find.byKey(const ValueKey('chatListScroll')),
          matching: find.byType(Scrollable),
        ),
      );
      scrollable.controller!.jumpTo(
        scrollable.controller!.position.maxScrollExtent,
      );
      await tester.pumpAndSettle();
      final last = tester.getRect(find.text('Agent 19'));
      final fab = tester.getRect(
        find.byKey(const ValueKey('narrowShellNewChat')),
      );
      expect(last.bottom, lessThanOrEqualTo(fab.top));
      for (final id in [
        'messengerPrimaryNav-activity',
        'messengerPrimaryNav-apps',
        'chatFilter-all',
      ]) {
        await tester.tap(find.byKey(ValueKey(id)).hitTestable());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: id);
      }
      final returnedScrollable = tester.widget<Scrollable>(
        find.descendant(
          of: find.byKey(const ValueKey('chatListScroll')),
          matching: find.byType(Scrollable),
        ),
      );
      returnedScrollable.controller!.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('Agent 0').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dock clears the FAB while content scrolls underneath', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      tester.view.padding = const FakeViewPadding(bottom: 34);
      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.pumpAndSettle();

      final dock = tester.getRect(
        find.byKey(const ValueKey('narrowShellNavigation')),
      );
      final fab = find.byKey(const ValueKey('narrowShellNewChat'));
      final fabRect = tester.getRect(fab);
      final content = tester.getRect(find.byType(ChatListPanel));
      // 844 - 34 SafeArea - bottomGap separation.
      expect(
        dock.bottom,
        closeTo(810 - MessengerBottomNavigation.bottomGap, .001),
      );
      expect(dock.height, 56);
      expect(
        content.bottom,
        greaterThan(dock.top),
        reason: 'conversation rows must scroll underneath the glass dock',
      );
      expect(fabRect.bottom, lessThanOrEqualTo(dock.top - 8));
      expect(fab.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dock selection animates once and honors reduced motion', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      final pill = find.byKey(const ValueKey('narrowShellSelectionPill'));
      // The first frame is already at Chats; there is no entrance animation.
      final initialPill = tester.getRect(pill);
      expect(initialPill.left, closeTo(16, .001));
      expect(
        initialPill.top,
        closeTo(792 - MessengerBottomNavigation.bottomGap, .001),
      );
      expect(initialPill.width, closeTo(366 / 6 - 8, .001));
      expect(
        initialPill.bottom,
        closeTo(840 - MessengerBottomNavigation.bottomGap, .001),
      );
      var animated = tester.widget<AnimatedPositioned>(pill);
      expect(animated.duration, const Duration(milliseconds: 200));
      expect(animated.curve, Curves.easeInOutCubic);

      Future<void> verify(String id, {required bool forward}) async {
        final previous = tester.getRect(pill);
        await tester.tap(find.byKey(ValueKey(id)));
        await tester.pump();
        expect(tester.getRect(pill), previous);
        var prior = previous;
        for (final elapsed in [50, 100, 200]) {
          await tester.pump(Duration(milliseconds: elapsed == 200 ? 100 : 50));
          final current = tester.getRect(pill);
          expect(current.width, closeTo(previous.width, .001));
          expect(
            forward ? current.left >= prior.left : current.left <= prior.left,
            isTrue,
            reason: '$id at $elapsed ms',
          );
          prior = current;
        }
        final item = tester.getRect(find.byKey(ValueKey(id)));
        expect(prior.center.dx, closeTo(item.center.dx, .001));
        expect(
          find.byType(AppLauncherScreen),
          id == 'messengerPrimaryNav-apps' ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      }

      await verify('messengerPrimaryNav-activity', forward: true);
      await verify('messengerPrimaryNav-apps', forward: true);
      await verify('chatFilter-all', forward: false);

      await pumpShell(
        tester,
        manager: manager,
        size: const Size(390, 844),
        reducedMotion: true,
      );
      animated = tester.widget<AnimatedPositioned>(pill);
      expect(animated.duration, Duration.zero);
      for (final id in [
        'messengerPrimaryNav-activity',
        'messengerPrimaryNav-apps',
        'chatFilter-all',
      ]) {
        await tester.tap(find.byKey(ValueKey(id)));
        await tester.pump();
        final item = tester.getRect(find.byKey(ValueKey(id)));
        expect(tester.getRect(pill).center.dx, closeTo(item.center.dx, .001));
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('bottom navigation opens Apps and the live Activity surface', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));

      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();
      expect(find.byType(AppLauncherScreen), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
      expect(
        find.byKey(const ValueKey('narrowShellNavigation')),
        findsOneWidget,
      );

      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      expect(find.text('Recent'), findsWidgets);
      expect(find.byType(AppLauncherScreen), findsNothing);
      expect(
        find.byKey(const ValueKey('narrowShellNavigation')),
        findsOneWidget,
      );
    });

    testWidgets('narrow Activity opens detail, returns, then opens its chat', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('activitySession-design-session')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ActivityDetailPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('activityBack')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('activityBack')));
      await tester.pumpAndSettle();
      expect(find.byType(ActivityListPanel), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('activitySession-design-session')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('activityOpenChat')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(manager.activeId, 'design-session');
    });

    testWidgets('conversation tap pushes the full chat and back returns', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _listedService(env));

      await pumpShell(
        tester,
        manager: manager,
        sessionNamesStore: SessionNamesStore.inMemory({
          'design-session': 'Fa 2.0 redesign',
        }),
        size: const Size(390, 844),
      );
      await tester.tap(find.text('Fa 2.0 redesign'));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('narrowShellNavigation')), findsNothing);
      expect(manager.activeId, 'design-session');

      await tester.tap(find.byType(BackButton).first);
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(find.text('Fa 2.0 redesign'), findsOneWidget);
    });

    testWidgets('narrow chat route folds into the wide shell on resize', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _listedService(env));

      await pumpShell(
        tester,
        manager: manager,
        sessionNamesStore: SessionNamesStore.inMemory({
          'design-session': 'Fa 2.0 redesign',
        }),
        size: const Size(390, 844),
      );
      await tester.tap(find.text('Fa 2.0 redesign'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(ChatListPanel), findsNothing);

      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(ChatListPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('narrowShellNavigation')), findsNothing);
      expect(
        find.byKey(const ValueKey('wideShellSidebarToggle')),
        findsOneWidget,
      );
    });

    testWidgets('Fa brand tap opens the active chat', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('wideShellFaBrand')));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(manager.activeId, 'design-session');
    });

    testWidgets('model chip long-press opens Models settings', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('wideShellFaBrand')));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const ValueKey('wideModelChip')));
      await tester.pumpAndSettle();

      expect(find.byType(ModelsSettingsPage), findsOneWidget);
    });

    testWidgets('Fa brand long-press mints and activates one session', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.longPress(find.byKey(const ValueKey('wideShellFaBrand')));
      await tester.pumpAndSettle();

      expect(manager.sessions, hasLength(2));
      expect(manager.activeId, isNot('design-session'));
    });

    testWidgets('reveal active chat from Apps pushes one narrow chat route', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();
      FaChatHost.revealActiveChat!();
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(manager.activeId, 'design-session');
    });

    testWidgets('reveal active chat reuses an already visible chat route', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('wideShellFaBrand')));
      await tester.pumpAndSettle();
      await FaChatHost.revealActiveChat!();
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      await tester.tap(find.byType(BackButton).first);
      await tester.pumpAndSettle();
    });

    testWidgets('Duo New chat sits below the camera and gets its own folder', (
      tester,
    ) async {
      final env = MemoryExecutionEnv(cwd: '/sandbox');
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      tester.view.padding = const FakeViewPadding(right: 84);

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      final newButton = find.byKey(const ValueKey('narrowShellNewChat'));
      final rect = tester.getRect(newButton);
      expect(rect.left, greaterThanOrEqualTo(390 - 84));
      expect(rect.top, greaterThanOrEqualTo(88));

      await tester.tap(newButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('newSessionCurrentFolder')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(manager.sessions, hasLength(2));
      expect(find.byType(ChatScreen), findsOneWidget);
      final sessionEnv = manager.active!.service.env;
      expect(sessionEnv.cwd, startsWith('/sandbox/chats/'));
      expect(sessionEnv, isA<CwdOverrideEnv>());
      expect(env.cwd, '/sandbox');
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('faChatHeaderProjectLabel')),
            )
            .data,
        sessionEnv.cwd.split('/').last,
      );
    });

    testWidgets('New chat with a selected mount stays in that project', (
      tester,
    ) async {
      final sandbox = MemoryExecutionEnv(cwd: '/sandbox');
      final env = ProjectMountEnv(sandbox)..mountedRoot = '/host/StudioProject';
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('narrowShellNewChat')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('newSessionCurrentFolder')));
      await tester.pumpAndSettle();

      expect(manager.sessions, hasLength(2));
      expect(manager.active!.service.env, same(env));
      expect(manager.active!.service.env.sessionCwd, '/host/StudioProject');
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('faChatHeaderProjectLabel')),
            )
            .data,
        'StudioProject',
      );
    });

    testWidgets('Duo expanded chat and New chat controls use the safe rail', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      tester.view.padding = const FakeViewPadding(right: 84);
      debugFaGlassAlwaysFake = false;
      await pumpShell(
        tester,
        manager: manager,
        size: const Size(1230, 880),
        brightness: Brightness.light,
      );

      final newButton = find.byKey(const ValueKey('messengerNewButton'));
      final newRect = tester.getRect(newButton);
      expect(newRect.left, greaterThanOrEqualTo(1230 - 84));
      expect(newRect.top, greaterThanOrEqualTo(FaDuoControlRail.top));
      expect(newRect.height, 52);

      final rail = find.byKey(const ValueKey('faChatDuoControlRail'));
      expect(rail, findsOneWidget);
      final railRect = tester.getRect(rail);
      expect(railRect.left, greaterThanOrEqualTo(1230 - 84));
      expect(railRect.top, greaterThanOrEqualTo(newRect.bottom));
      for (final control in [
        find.byKey(const ValueKey('wideModelChip')),
        find.byIcon(Icons.timeline),
      ]) {
        expect(control, findsOneWidget);
        expect(tester.getRect(control).left, greaterThanOrEqualTo(1230 - 84));
      }
      expect(
        tester.getRect(find.byKey(const ValueKey('wideModelChip'))).top,
        greaterThanOrEqualTo(newRect.bottom),
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('iOS New chat can pick a Files folder for the session', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('fah/project_folder');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return switch (call.method) {
              'pickDirectory' => const {
                'path': '/host/StudioProject',
                'bookmark': 'Ym9va21hcms=',
              },
              'startAccessing' => true,
              _ => null,
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final sandbox = MemoryExecutionEnv(cwd: '/sandbox');
      final env = ProjectMountEnv(sandbox);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('narrowShellNewChat')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('newSessionChooseFolder')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('newSessionChooseFolder')));
      await tester.pumpAndSettle();

      expect(manager.sessions, hasLength(2));
      expect(env.mountedRoot, '/host/StudioProject');
      expect(manager.active!.service.env.sessionCwd, '/host/StudioProject');
      expect(find.byType(ChatScreen), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('New chat creates a named folder in the current sandbox', (
      tester,
    ) async {
      final env = MemoryExecutionEnv(cwd: '/sandbox');
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));
      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('narrowShellNewChat')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('newSessionSandboxFolder')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('newSessionSandboxFolder')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('newSessionSandboxName')),
        'research-notes',
      );
      await tester.tap(
        find.byKey(const ValueKey('newSessionCreateSandboxFolder')),
      );
      await tester.pumpAndSettle();

      expect(manager.sessions, hasLength(2));
      expect(manager.active!.service.env.cwd, '/sandbox/chats/research-notes');
      expect(env.cwd, '/sandbox');
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('faChatHeaderProjectLabel')),
            )
            .data,
        'research-notes',
      );
    });

    testWidgets('New chat keeps the session-folder flow', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      final newButton = find.byKey(const ValueKey('narrowShellNewChat'));
      expect(tester.getSize(newButton), const Size.square(52));
      final surface = tester.widget<FaSurface>(
        find.descendant(of: newButton, matching: find.byType(FaSurface)),
      );
      expect(surface.circular, isTrue);
      expect(surface.glass, isTrue);
      expect(surface.useBackdropGroup, isTrue);
      final icon = tester.widget<Icon>(
        find.descendant(of: newButton, matching: find.byType(Icon)),
      );
      expect(icon.color, const Color(0xFF3F8FF7));
      await tester.tap(find.byKey(const ValueKey('narrowShellNewChat')));
      await tester.pumpAndSettle();

      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(find.text('New session — folder'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(manager.sessions.length, 1);
    });

    testWidgets('wide keeps the sidebar and inline chat', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _fakeService(env));

      await pumpShell(tester, manager: manager, size: const Size(1280, 800));

      expect(
        find.byKey(const ValueKey('messengerPrimaryNav-activity')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('messengerPrimaryNav-apps')),
        findsOneWidget,
      );
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('narrowShellNavigation')), findsNothing);
      expect(find.byType(AppLauncherScreen), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
    });
  });
}
