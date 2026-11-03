// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'package:fa/ui/widgets/messenger_nav_rail.dart';
import 'package:fa_ui/fa_ui.dart'
    show FaVisualDirection, buildFaTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildFaTheme(direction: FaVisualDirection.nebula, brightness: Brightness.dark),
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
    // The settings glyph is pinned to the rail's bottom slot.
    final settings = tester.getRect(
      find.byKey(const ValueKey('railSettingsRow')),
    );
    final railRect = tester.getRect(find.byType(MessengerNavRail));
    expect(
      railRect.bottom - settings.bottom,
      inInclusiveRange(0, 12),
      reason: 'settings pinned to the bottom slot',
    );
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
        theme: buildFaTheme(direction: FaVisualDirection.nebula, brightness: Brightness.dark),
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
