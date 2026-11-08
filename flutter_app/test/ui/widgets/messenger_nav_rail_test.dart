// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'package:fa/ui/widgets/messenger_nav_rail.dart';
import 'package:fa_ui/fa_ui.dart'
    show FaSurface, FaVisualDirection, buildFaTheme;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildFaTheme(
    direction: FaVisualDirection.nebula,
    brightness: Brightness.dark,
  ),
  home: Scaffold(body: child),
);

void main() {
  Widget rail({bool selected = false, int? badge, bool muted = false}) =>
      MessengerNavRail(
        destinations: [
          MessengerRailDestination(
            rowKey: const ValueKey('railAll'),
            icon: Icons.inbox_outlined,
            label: 'All',
            selected: selected,
            badge: badge,
            badgeMuted: muted,
            onTap: (_) {},
          ),
          MessengerRailDestination(
            rowKey: const ValueKey('railActivity'),
            icon: Icons.notifications_none_rounded,
            label: 'Activity',
            selected: false,
            onTap: (_) {},
          ),
        ],
        settingsLabel: 'Settings',
        onSettingsTap: () {},
      );

  testWidgets('rail geometry: 78pt wide, 64pt row pitch, icon+label stack', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(rail()));
    final row = tester.getRect(find.byKey(const ValueKey('railAll')));
    expect(row.width, MessengerNavRail.width);
    expect(row.height, MessengerNavRail.rowPitch);

    final icon = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('railAll')),
        matching: find.byIcon(Icons.inbox_outlined),
      ),
    );
    expect(icon.width, inInclusiveRange(25, 28), reason: 'pictogram 25–28pt');
    final label = tester.getRect(find.text('All'));
    expect(label.center.dx, closeTo(row.center.dx, .5), reason: 'centered');
    expect(label.center.dy, greaterThan(icon.center.dy), reason: 'below icon');
    // The settings glyph is pinned to the glass card's bottom slot (the
    // card, not the rail's outer footprint, carries the 8pt margins).
    final settings = tester.getRect(
      find.byKey(const ValueKey('railSettingsRow')),
    );
    final card = tester.getRect(
      find.descendant(
        of: find.byType(MessengerNavRail),
        matching: find.byType(FaSurface),
      ),
    );
    expect(
      card.bottom - settings.bottom,
      inInclusiveRange(0, 12),
      reason: 'settings pinned to the bottom slot',
    );
  });

  testWidgets('rail surface is the collapsed sidebar panel floating glass '
      'card (FaSurface, shared backdrop, 18pt radius, 8pt margins)', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(rail()));
    final surface = tester.widget<FaSurface>(
      find.descendant(
        of: find.byType(MessengerNavRail),
        matching: find.byType(FaSurface),
      ),
    );
    expect(surface.glass, isTrue, reason: 'under glass, like the sidebar');
    expect(
      surface.useBackdropGroup,
      isTrue,
      reason: 'one shared backdrop capture for the whole rail',
    );
    expect(
      surface.borderRadius?.topLeft.x,
      MessengerNavRail.glassRadius,
      reason: 'the collapsed chats panel card radius',
    );
    // The floating-card geometry: 8pt margins on every side of the
    // rail's outer footprint; the card itself stays the full rail width.
    final railRect = tester.getRect(find.byType(MessengerNavRail));
    final cardRect = tester.getRect(
      find.descendant(
        of: find.byType(MessengerNavRail),
        matching: find.byType(FaSurface),
      ),
    );
    expect(cardRect.left, MessengerNavRail.seam);
    expect(cardRect.top, MessengerNavRail.seam);
    expect(railRect.right - cardRect.right, MessengerNavRail.seam);
    expect(railRect.bottom - cardRect.bottom, MessengerNavRail.seam);
    expect(cardRect.width, MessengerNavRail.width);
  });

  testWidgets('first row clears the macOS titlebar like the chats sidebar '
      '(mirror of its max(8, MediaQuery top) first-row line)', (tester) async {
    Rect firstRowTop() => tester.getRect(find.byKey(const ValueKey('railAll')));

    // No titlebar, non-macOS (linux override): the card's 8pt margin is
    // the only inset.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(_wrap(rail()));
    expect(firstRowTop().top, MessengerNavRail.seam);
    debugDefaultTargetPlatformOverride = null;

    // macOS desktop is a fullSizeContentView — MediaQuery.top reads 0 while
    // the traffic lights float over the first ~28pt — so a fixed 44pt
    // clearance applies: first row at 8 + 44 = 52.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(_wrap(rail()));
    expect(firstRowTop().top, MessengerNavRail.seam + 44,
        reason: 'clears the macOS traffic lights');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('selected row tints accent without a background fill', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(rail(selected: true)));
    final item = tester.widget<Material>(
      find.descendant(
        of: find.byKey(const ValueKey('railAll')),
        matching: find.byType(Material),
      ),
    );
    expect(item.color, Colors.transparent, reason: 'no background fill');
    final semantics = tester.widget<Semantics>(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.button == true &&
                widget.properties.label == 'All',
          )
          .first,
    );
    expect(semantics.properties.selected, isTrue);
  });

  testWidgets('badge overlaps the icon top-right; muted variant swaps fill', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(rail(badge: 4)));
    final badge = tester.getRect(find.byKey(const ValueKey('railBadgeAccent')));
    expect(badge.width, inInclusiveRange(19, 20));
    expect(badge.height, 19);
    final icon = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('railAll')),
        matching: find.byIcon(Icons.inbox_outlined),
      ),
    );
    expect(badge.left, greaterThan(icon.center.dx));
    expect(badge.top, lessThan(icon.center.dy), reason: 'top-right overlap');
    expect(find.text('4'), findsOneWidget);
    // Hidden when the count is absent or zero.
    await tester.pumpWidget(_wrap(rail()));
    expect(find.byKey(const ValueKey('railBadgeAccent')), findsNothing);

    await tester.pumpWidget(_wrap(rail(badge: 2, muted: true)));
    expect(find.byKey(const ValueKey('railBadgeMuted')), findsOneWidget);
  });

  testWidgets('whole row is one tap target (icon+label together)', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFaTheme(
          direction: FaVisualDirection.nebula,
          brightness: Brightness.dark,
        ),
        home: Scaffold(
          body: MessengerNavRail(
            destinations: [
              MessengerRailDestination(
                rowKey: const ValueKey('railAll'),
                icon: Icons.inbox_outlined,
                label: 'All',
                selected: false,
                onTap: (_) => taps++,
              ),
            ],
            settingsLabel: 'Settings',
            onSettingsTap: () {},
          ),
        ),
      ),
    );
    // Tap near the label (bottom half of the row) — still the row's tap.
    final row = tester.getRect(find.byKey(const ValueKey('railAll')));
    await tester.tapAt(Offset(row.left + 8, row.bottom - 8));
    await tester.pump();
    expect(taps, 1);
  });
}
