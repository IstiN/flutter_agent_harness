// Copyright (c) 2026, the Flutter Agent Harness authors.
// SPDX-License-Identifier: MIT

part of 'wide_layout_shell_actions_test.dart';

/// Split by concern from the actions suite (PR #2196 review: the
/// staged loc gate caps every Dart file at 2800 lines). Called from
/// the parent main(), so its setUp/tearDown apply.
void wideShellRailHeaderTests() {
  testWidgets('the vertical rail owns its surface beside the glass chrome', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager);
    await tester.pump(const Duration(milliseconds: 100));
    // The rail's floating glass card: the outer footprint starts at the
    // window's left edge and carries the 8pt margins on every side; the
    // sidebar column follows immediately (the rail's trailing margin is
    // the seam, the sidebar's own margin completes the gutter).
    final railRect = tester.getRect(
      find.byKey(const ValueKey('messengerNavRail')),
    );
    expect(railRect.left, 0);
    expect(railRect.width, MessengerNavRail.width + MessengerNavRail.seam * 2);
    expect(
      railRect.height,
      tester.view.physicalSize.height / tester.view.devicePixelRatio,
    );
    final sidebar = tester.getRect(
      find.byKey(const ValueKey('desktopSidebarContainer')),
    );
    expect(sidebar.left, railRect.right);
    // The rail's surface is the chats panel's glass 1:1: same FaSurface
    // params (glass mode, one shared backdrop capture, card radius,
    // surface1 tint) and the same 8pt gutter between the two cards — the
    // rail keeps its trailing 8pt margin-as-seam; the sidebar card leads
    // with 0 and keeps its 8pt window margins elsewhere (owner: the gap
    // halves to 8pt total).
    final railSurface = tester.widget<FaSurface>(
      find.descendant(
        of: find.byKey(const ValueKey('messengerNavRail')),
        matching: find.byType(FaSurface),
      ),
    );
    final sidebarSurface = tester.widget<FaSurface>(
      find
          .descendant(
            of: find.byKey(const ValueKey('glassSidebarPanel')),
            matching: find.byType(FaSurface),
          )
          .first,
    );
    expect(railSurface.glass, sidebarSurface.glass);
    expect(railSurface.useBackdropGroup, sidebarSurface.useBackdropGroup);
    expect(
      railSurface.borderRadius?.topLeft.x,
      (sidebarSurface.borderRadius?.topLeft.x ?? 0) + 1,
      reason: 'the inner glass radius sits inside the outer 1pt frame',
    );
    expect(railSurface.color, sidebarSurface.color);
    final railCard = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('messengerNavRail')),
        matching: find.byType(FaSurface),
      ),
    );
    final sidebarCard = tester.getRect(
      find.byKey(const ValueKey('glassSidebarPanel')),
    );
    expect(
      sidebarCard.left - railCard.right,
      MessengerNavRail.seam,
      reason:
          'the rail trailing 8pt seam margin is the shared gutter (one '
          'margin, not two)',
    );
    // The horizontal section pill-bar is gone — its destinations moved
    // into the rail rows.
    expect(find.byKey(const ValueKey('chatCategoryChips')), findsNothing);
    expect(find.byType(MessengerFilterControl), findsNothing);

    // The chat chrome band's glass background stays armed (constant
    // sigma) under the search row.
    final underlay = tester.widget<ProgressiveBlur>(
      find.byKey(const ValueKey('chatListChromeUnderlay')),
    );
    expect(underlay.maxSigma, 8);
    expect(underlay.direction, ProgressiveBlurDirection.topToBottom);
  });

  testWidgets('centered header uses the selected folder and session name', (
    tester,
  ) async {
    final env = MemoryExecutionEnv(cwd: '/work/fa_network');
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(
      tester,
      manager: manager,
      sessionNamesStore: SessionNamesStore.inMemory({
        'design-session': 'Release review',
      }),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('faChatHeaderProjectLabel')))
          .data,
      'fa_network',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('faChatHeaderSessionLabel')))
          .data,
      'Release review',
    );
    expect(find.byKey(const ValueKey('faChatHeaderTitlePill')), findsOneWidget);
  });

  testWidgets('centered header names the live mounted project over Personal', (
    tester,
  ) async {
    final sandbox = MemoryExecutionEnv(cwd: '/sandbox/fah_sandbox');
    final env = ProjectMountEnv(sandbox)..mountedRoot = '/host/StudioProject';
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    await pumpShell(tester, manager: manager);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('faChatHeaderProjectLabel')))
          .data,
      'StudioProject',
    );
  });

  testWidgets('shared section header and primary nav keep geometry and style', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _fakeService(env));
    const labels = ['Chats', 'Activity', 'Apps'];
    final expectedRects = <String, Rect>{};

    for (final direction in FaVisualDirection.values) {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await pumpShell(
          tester,
          manager: manager,
          direction: direction,
          brightness: brightness,
        );
        await tester.pump(const Duration(milliseconds: 100));
        Color? searchFill;
        BoxBorder? searchBorder;
        Color? newBackground;
        for (var section = 0; section < labels.length; section++) {
          if (section > 0) {
            await tester.tap(
              find.byKey(
                ValueKey(
                  'messengerPrimaryNav-${labels[section].toLowerCase()}',
                ),
              ),
            );
            await tester.pumpAndSettle();
          }
          final reason = '$direction $brightness ${labels[section]}';
          final search = find.byKey(const ValueKey('messengerSearchField'));
          final newButton = find.byKey(const ValueKey('messengerNewButton'));
          // Apps has no sidebar search (owner call) — the launcher's
          // header-reveal search is the single apps search surface.
          expect(
            search,
            section == 2 ? findsNothing : findsOneWidget,
            reason: reason,
          );
          expect(newButton, findsOneWidget, reason: reason);
          final current = <String, Rect>{
            if (section != 2) 'search': tester.getRect(search),
            'new': tester.getRect(newButton),
            if (section == 0)
              for (final label in const ['All', 'Unread', 'Channels'])
                'filter-$label': tester.getRect(
                  find.byKey(ValueKey('chatFilter-${label.toLowerCase()}')),
                ),
          };
          for (final entry in current.entries) {
            final expected = expectedRects[entry.key];
            if (expected == null) {
              expectedRects[entry.key] = entry.value;
            } else {
              expect(
                entry.value.left,
                closeTo(expected.left, .001),
                reason: reason,
              );
              expect(
                entry.value.top,
                closeTo(expected.top, .001),
                reason: reason,
              );
              expect(
                entry.value.right,
                closeTo(expected.right, .001),
                reason: reason,
              );
              expect(
                entry.value.bottom,
                closeTo(expected.bottom, .001),
                reason: reason,
              );
            }
          }

          if (section == 0) {
            // The rail: 78pt-wide rows on a fixed 64pt pitch, pictogram
            // 25–28pt with the label centered below. Order: All, Unread,
            // Local, Network, Channels, Activity, Apps.
            final all = current['filter-All']!;
            final unread = current['filter-Unread']!;
            final channels = current['filter-Channels']!;
            for (final rect in [all, unread, channels]) {
              expect(rect.width, MessengerNavRail.width, reason: reason);
              expect(rect.height, MessengerNavRail.rowPitch, reason: reason);
            }
            expect(
              unread.top - all.top,
              MessengerNavRail.rowPitch,
              reason: reason,
            );
            final local = tester.getRect(
              find.byKey(const ValueKey('messengerPrimaryNav-local')),
            );
            final network = tester.getRect(
              find.byKey(const ValueKey('messengerPrimaryNav-network')),
            );
            expect(
              local.top - unread.top,
              MessengerNavRail.rowPitch,
              reason: 'Local moved up, right after Unread',
            );
            expect(
              network.top - local.top,
              MessengerNavRail.rowPitch,
              reason: reason,
            );
            expect(
              channels.top - network.top,
              MessengerNavRail.rowPitch,
              reason: reason,
            );
            final allRow = find.byKey(const ValueKey('chatFilter-all'));
            final icon = tester.getRect(
              find.descendant(of: allRow, matching: find.byType(Icon)),
            );
            final label = tester.getRect(find.text('All'));
            expect(icon.width, inInclusiveRange(25, 28), reason: reason);
            expect(icon.center.dx, closeTo(all.center.dx, .5), reason: reason);
            expect(label.center.dx, closeTo(all.center.dx, .5), reason: reason);
            expect(
              label.center.dy,
              greaterThan(icon.center.dy),
              reason: reason,
            );
            // Activity and Apps close the rail on the same pitch.
            final activity = tester.getRect(
              find.byKey(const ValueKey('messengerPrimaryNav-activity')),
            );
            final apps = tester.getRect(
              find.byKey(const ValueKey('messengerPrimaryNav-apps')),
            );
            expect(
              activity.top - channels.top,
              MessengerNavRail.rowPitch,
              reason: reason,
            );
            expect(
              apps.top - activity.top,
              MessengerNavRail.rowPitch,
              reason: reason,
            );
            expect(local.height, MessengerNavRail.rowPitch, reason: reason);
            expect(network.height, MessengerNavRail.rowPitch, reason: reason);
            expect(activity.height, MessengerNavRail.rowPitch, reason: reason);
            expect(apps.height, MessengerNavRail.rowPitch, reason: reason);
            // Settings is pinned last.
            final settings = tester.getRect(
              find.byKey(const ValueKey('railSettingsRow')),
            );
            expect(settings.top, greaterThan(apps.top), reason: reason);
          }

          if (section == 2) {
            expect(
              find.byKey(const ValueKey('appsDirectorySearch')),
              findsNothing,
              reason: reason,
            );
            // Apps has NO sidebar search at all (owner call) — the
            // launcher's header-reveal search is the single surface.
            expect(search, findsNothing, reason: reason);
            continue;
          }

          // Kit-level reads: the shared field is the kit's GlassTextField —
          // its CupertinoTextField carries a BoxDecoration with the fill
          // and the capsule border in every direction (the kit input is
          // the ONE search field, Material TextField is gone).
          final field = tester.widget<CupertinoTextField>(
            find.descendant(
              of: search,
              matching: find.byType(CupertinoTextField),
            ),
          );
          final newStyle = tester.widget<IconButton>(newButton).style;
          final background = newStyle?.backgroundColor?.resolve(const {});
          if (section == 0) {
            searchFill = field.decoration?.color;
            searchBorder = field.decoration?.border;
            newBackground = background;
          } else {
            expect(field.decoration?.color, searchFill, reason: reason);
            expect(field.decoration?.border, searchBorder, reason: reason);
            expect(background, newBackground, reason: reason);
          }
          expect(field.placeholder, isNotEmpty, reason: reason);
          expect(
            tester
                .widget<Icon>(
                  find.descendant(of: newButton, matching: find.byType(Icon)),
                )
                .icon,
            Icons.edit_outlined,
            reason: reason,
          );
        }
      }
    }
  });

  testWidgets('rail rows keep section selection and callbacks', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('design-session', _listedService(env));
    await pumpShell(tester, manager: manager);
    await tester.pump(const Duration(milliseconds: 100));

    Semantics chip(String label) => tester.widget<Semantics>(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.button == true &&
                widget.properties.label == label,
          )
          .first,
    );
    // Every rail row shows its label; selection is the accent tint.
    expect(find.text('All'), findsOneWidget);
    for (final label in ['Unread', 'Channels']) {
      expect(find.text(label), findsOneWidget);
      expect(chip(label).properties.selected, isFalse);
    }
    expect(chip('All').properties.selected, isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chatFilter-all')),
        matching: find.byIcon(Icons.inbox_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('chatFilter-agents')),
      findsNothing,
      reason: 'agents have no rail row (Local folders own them)',
    );
    expect(
      find.byKey(const ValueKey('wideShellPrimaryNavigation')),
      findsNothing,
    );
    // The rail has no separate Chats destination: the All filter row IS
    // the Chats home.
    expect(
      find.byKey(const ValueKey('messengerPrimaryNav-chats')),
      findsNothing,
    );
    Finder sectionAction(String section) =>
        find.byKey(ValueKey('messengerPrimaryNav-$section'));
    String sectionLabel(String section) => switch (section) {
      'activity' => 'Activity',
      _ => 'Apps',
    };
    final allRect = tester.getRect(
      find.byKey(const ValueKey('chatFilter-all')),
    );
    expect(allRect.width, MessengerNavRail.width);
    final allIcon = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('chatFilter-all')),
        matching: find.byIcon(Icons.inbox_outlined),
      ),
    );
    final allText = tester.getRect(find.text('All'));
    expect(allIcon.center.dx, closeTo(allRect.center.dx, .5));
    expect(allText.center.dx, closeTo(allRect.center.dx, .5));
    for (final section in const ['activity', 'apps']) {
      final action = sectionAction(section);
      expect(tester.getRect(action).height, MessengerNavRail.rowPitch);
      expect(
        find.descendant(
          of: action,
          matching: find.byIcon(switch (section) {
            'activity' => Icons.notifications_none_rounded,
            _ => Icons.grid_view_rounded,
          }),
        ),
        findsOneWidget,
        reason: section,
      );
      // Rail rows always carry their label (Telegram pattern).
      expect(
        find.descendant(of: action, matching: find.text(sectionLabel(section))),
        findsOneWidget,
        reason: section,
      );
      expect(chip(sectionLabel(section)).properties.selected, isFalse);
    }

    await tester.pumpAndSettle();

    for (final selected in const ['activity', 'apps']) {
      await tester.tap(sectionAction(selected));
      await tester.pumpAndSettle();
      expect(
        chip(sectionLabel(selected)).properties.selected,
        isTrue,
        reason: selected,
      );
      // The filter rows quiet down while a section owns the rail.
      for (final label in const ['All', 'Unread', 'Channels']) {
        expect(chip(label).properties.selected, isFalse, reason: label);
      }
      for (final quiet in const ['activity', 'apps']) {
        expect(
          chip(sectionLabel(quiet)).properties.selected,
          quiet == selected,
          reason: quiet,
        );
      }
      expect(tester.takeException(), isNull, reason: selected);
    }

    // Tapping a filter returns to the Chats home from another section.
    await tester.tap(find.byKey(const ValueKey('chatFilter-unread')));
    await tester.pumpAndSettle();
    expect(find.byType(ActivityListPanel), findsNothing);
    expect(find.byKey(const ValueKey('appsDirectory')), findsNothing);
    expect(chip('Unread').properties.selected, isTrue);
    expect(find.text('Unread'), findsOneWidget);
    for (final quiet in const ['activity', 'apps']) {
      expect(
        chip(sectionLabel(quiet)).properties.selected,
        isFalse,
        reason: quiet,
      );
    }

    for (final label in const ['Channels', 'All']) {
      await tester.tap(
        find.byKey(ValueKey('chatFilter-${label.toLowerCase()}')),
      );
      await tester.pumpAndSettle();
      expect(
        chip(label).properties.selected,
        isTrue,
        reason: '$label must be tappable',
      );
    }
    // The Network row (the identity globe, re-keyed) swaps the CHATS
    // SIDEBAR content to the networks surface (the same slot the Local
    // drill-down uses); the chat message column keeps the chat — the old
    // chat-column surface is gone.
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-network')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatNetworksList')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNetworksBack')), findsNothing);
    expect(find.byKey(const ValueKey('wideShellFaBrand')), findsOneWidget);
    expect(chip('Networks').properties.selected, isTrue);
    expect(chip('All').properties.selected, isFalse);
    expect(find.byType(ChatNetworksPanel), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('glassCenterPanel')),
        matching: find.byType(ChatNetworksPanel),
      ),
      findsNothing,
      reason: 'the networks surface no longer renders in the message column',
    );
    // It lives IN the sidebar panel — the same slot the Local drill-down
    // uses.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('glassSidebarPanel')),
        matching: find.byType(ChatNetworksPanel),
      ),
      findsOneWidget,
    );
    // The sidebar swapped: the chat list panel is replaced while the
    // surface is open.
    expect(find.byType(ChatListPanel), findsNothing);

    // Root destinations share the exact same search geometry and glass
    // chrome. Only Local's drilled folder (and Networks' channel list) may
    // introduce a back button.
    final networksSearch = tester.getRect(
      find.byKey(const ValueKey('messengerSearchField')),
    );
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-local')));
    await tester.pumpAndSettle();
    expect(find.byType(LocalSessionsPanel), findsOneWidget);
    expect(find.byKey(const ValueKey('localFolderBack')), findsNothing);
    expect(find.byKey(const ValueKey('localChromeUnderlay')), findsOneWidget);
    final localSearch = tester.getRect(
      find.byKey(const ValueKey('messengerSearchField')),
    );
    expect(localSearch.left, networksSearch.left);
    expect(localSearch.top, networksSearch.top);
    expect(localSearch.width, networksSearch.width);
    expect(chip('Local').properties.selected, isTrue);
    expect(chip('Networks').properties.selected, isFalse);
    await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-network')));
    await tester.pumpAndSettle();

    // All is the chats-home destination; selecting it restores the list and
    // moves rail selection away from Networks.
    await tester.tap(find.byKey(const ValueKey('chatFilter-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatNetworksList')), findsNothing);
    expect(find.byKey(const ValueKey('chatListScroll')), findsOneWidget);
    expect(find.byType(ChatListPanel), findsOneWidget);
    expect(chip('All').properties.selected, isTrue);
    expect(chip('Networks').properties.selected, isFalse);
  });

  testWidgets(
    'wide sections rebuild only the list and keep the shared panel chrome',
    (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('design-session', _listedService(env));
      await pumpShell(tester, manager: manager);
      await tester.pumpAndSettle();

      final panel = find.byType(ChatListPanel);
      expect(find.byKey(const ValueKey('chatListScroll')), findsOneWidget);
      final railRect = tester.getRect(
        find.byKey(const ValueKey('messengerNavRail')),
      );
      final search = tester.getRect(
        find.byKey(const ValueKey('messengerSearchField')),
      );
      final newButton = tester.getRect(
        find.byKey(const ValueKey('messengerNewButton')),
      );
      final panelElement = tester.element(panel);

      await tester.tap(
        find.byKey(const ValueKey('messengerPrimaryNav-activity')),
      );
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(tester.element(panel), same(panelElement));
      expect(find.byType(ActivityListPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('chatListScroll')), findsNothing);
      expect(
        find.byKey(const ValueKey('wideShellPrimaryNavigation')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('messengerPrimaryNav-apps')));
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(tester.element(panel), same(panelElement));
      expect(find.byKey(const ValueKey('appsDirectory')), findsOneWidget);
      expect(find.byType(ActivityListPanel), findsNothing);

      // Filters are the Chats home: tapping one returns from Apps.
      await tester.tap(find.byKey(const ValueKey('chatFilter-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chatListScroll')), findsOneWidget);
      // The rail is steady chrome: section switches never move it.
      expect(
        tester.getRect(find.byKey(const ValueKey('messengerNavRail'))),
        railRect,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('messengerSearchField'))),
        search,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('messengerNewButton'))),
        newButton,
      );

      await pumpShell(tester, manager: manager, size: const Size(390, 844));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('narrowShellNavigation')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('messengerPrimaryTab-Chats')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
