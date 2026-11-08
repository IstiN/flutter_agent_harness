// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassIconButton;

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme,
  home: Scaffold(body: Center(child: child)),
);

List<FaHeaderAction> _actions(List<VoidCallback> callbacks) => [
  FaHeaderAction(
    key: const ValueKey('expand'),
    icon: Icons.open_in_full,
    label: 'Expand',
    onPressed: callbacks[0],
  ),
  FaHeaderAction(
    key: const ValueKey('pin'),
    icon: Icons.push_pin_outlined,
    label: 'Pin',
    onPressed: callbacks[1],
  ),
  FaHeaderAction(
    key: const ValueKey('close'),
    icon: Icons.close,
    label: 'Close',
    onPressed: callbacks[2],
  ),
];

void main() {
  testWidgets(
    'one capsule, no per-action circles, compact accessible targets',
    (tester) async {
      await tester.pumpWidget(
        _host(
          FaIconActionBand<String>(
            key: const ValueKey('band'),
            actions: _actions([() {}, () {}, () {}]),
            overflowItems: const [
              PopupMenuItem(value: 'reload', child: Text('Reload')),
            ],
            onOverflowSelected: (_) {},
            overflowMenuKey: const ValueKey('overflow'),
            overflowTooltip: 'More actions',
          ),
        ),
      );

      final band = find.byKey(const ValueKey('band'));
      final surfaces = find.descendant(
        of: band,
        matching: find.byType(FaSurface),
      );
      expect(surfaces, findsOneWidget);
      final surface = tester.widget<FaSurface>(surfaces);
      expect(surface.borderRadius!.topLeft.x, 20);
      expect(surface.circular, isFalse);
      expect(
        surface.borderSide?.color,
        FaDesignTokens.of(tester.element(band)).hairline,
        reason: 'the shared capsule keeps a visible frame in every theme',
      );
      expect(
        find.descendant(of: band, matching: find.byType(FaIconActionButton)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: band,
          matching: find.byType(FaHeaderCircularAction),
        ),
        findsNothing,
      );
      final circles = tester
          .widgetList<Material>(
            find.descendant(of: band, matching: find.byType(Material)),
          )
          .where((material) => material.shape is CircleBorder);
      expect(circles, isEmpty);

      // Three actions + overflow in one 40pt-high capsule, with only the
      // surface's 2pt inset beyond the four 36pt hit targets.
      expect(tester.getSize(surfaces), const Size(148, 40));
      for (final key in ['expand', 'pin', 'close', 'overflow']) {
        expect(
          tester.getSize(find.byKey(ValueKey(key))),
          const Size.square(36),
        );
      }
      for (final tooltip in ['Expand', 'Pin', 'Close', 'More actions']) {
        expect(find.byTooltip(tooltip), findsOneWidget);
      }
    },
  );

  testWidgets('action callbacks and overflow selection still work', (
    tester,
  ) async {
    final calls = <String>[];
    String? selected;
    await tester.pumpWidget(
      _host(
        FaIconActionBand<String>(
          actions: _actions([
            () => calls.add('expand'),
            () => calls.add('pin'),
            () => calls.add('close'),
          ]),
          overflowItems: const [
            PopupMenuItem(value: 'reload', child: Text('Reload app')),
          ],
          onOverflowSelected: (value) => selected = value,
          overflowMenuKey: const ValueKey('overflow'),
        ),
      ),
    );

    for (final key in ['expand', 'pin', 'close']) {
      await tester.tap(find.byKey(ValueKey(key)));
    }
    expect(calls, ['expand', 'pin', 'close']);

    await tester.tap(find.byKey(const ValueKey('overflow')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 'reload');
  });

  testWidgets('token surface and ink stay consistent across theme directions', (
    tester,
  ) async {
    for (final direction in FaVisualDirection.values) {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(
            FaIconActionBand<String>(
              key: const ValueKey('band'),
              actions: _actions([() {}, () {}, () {}]),
            ),
            theme: buildFaTheme(direction: direction, brightness: brightness),
          ),
        );
        final band = find.byKey(const ValueKey('band'));
        final tokens = FaDesignTokens.of(tester.element(band));
        final surface = tester.widget<FaSurface>(
          find.descendant(of: band, matching: find.byType(FaSurface)),
        );
        expect(
          surface.color,
          tokens.surface2,
          reason: '$direction $brightness',
        );
        expect(
          IconTheme.of(tester.element(find.byIcon(Icons.close))).color,
          tokens.ink1,
          reason: '$direction $brightness',
        );
        expect(
          find.descendant(of: band, matching: find.byType(FaSurface)),
          findsOneWidget,
          reason: '$direction $brightness',
        );
      }
    }
  });

  testWidgets('glass direction has one glass capsule, not glass action discs', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        FaIconActionBand<String>(
          key: const ValueKey('band'),
          glass: true,
          actions: _actions([() {}, () {}, () {}]),
        ),
        theme: buildFaTheme(
          direction: FaVisualDirection.glass,
          brightness: Brightness.dark,
        ),
      ),
    );
    final band = find.byKey(const ValueKey('band'));
    final surfaces = tester.widgetList<FaSurface>(
      find.descendant(of: band, matching: find.byType(FaSurface)),
    );
    expect(surfaces.length, 1);
    expect(surfaces.single.glass, isTrue);
    expect(
      find.descendant(of: band, matching: find.byType(GlassIconButton)),
      findsNothing,
    );
  });
}
