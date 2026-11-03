// The FaIconActionButton contract: ONE circular icon action style for
// every surface — token-driven fill/hairline/ink, a 36pt default diameter
// with a derived 18px glyph, a ≥32pt hit target, and tooltip semantics.
//
// Issue: the header band grew five circle styles (white+border toggle,
// borderless gray header circles, tinted glass avatar, ad-hoc Files
// circles) at five centerlines; this component is the unification.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: Builder(builder: (context) => child)),
  ),
);

void main() {
  testWidgets('default geometry: 36pt circle, 18px glyph, >=32pt hit target', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        FaIconActionButton(
          key: const ValueKey('unitAction'),
          icon: Icons.copy_outlined,
          onPressed: () {},
        ),
      ),
    );
    final chrome = tester.getRect(find.byKey(const ValueKey('unitAction')));
    expect(chrome.width, FaIconActionButton.defaultDiameter);
    expect(chrome.height, FaIconActionButton.defaultDiameter);
    expect(
      FaIconActionButton.defaultDiameter,
      greaterThanOrEqualTo(FaIconActionButton.minHitTarget),
    );
    final icon = tester.widget<Icon>(find.byIcon(Icons.copy_outlined));
    expect(icon.size, FaIconActionButton.glyphSizeFor(36));
    expect(icon.size, 18);
  });

  test('glyph ratio: half the circle nominal, ~0.38 painted ink share', () {
    expect(FaIconActionButton.glyphRatio, 0.5);
    expect(FaIconActionButton.glyphSizeFor(36), 18);
    expect(FaIconActionButton.glyphSizeFor(40), 20);
    expect(FaIconActionButton.glyphSizeFor(32), 16);
  });

  testWidgets('ONE style: token fill surface2 + hairline ring + ink1 glyph', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        FaIconActionButton(
          key: const ValueKey('unitAction'),
          icon: Icons.close,
          onPressed: () {},
        ),
      ),
    );
    final tokens = FaDesignTokens.of(
      tester.element(find.byKey(const ValueKey('unitAction'))),
    );
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const ValueKey('unitAction')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, tokens.surface2);
    final shape = material.shape! as CircleBorder;
    expect(shape.side.color, tokens.hairline);
    expect(shape.side.width, greaterThan(0));
    final theme = IconTheme.of(
      tester.element(find.byIcon(Icons.close)),
    );
    expect(theme.color, tokens.ink1);
  });

  testWidgets('diameter is a parameter; glyph scales with it', (tester) async {
    await tester.pumpWidget(
      _host(
        FaIconActionButton(
          key: const ValueKey('unitAction'),
          icon: Icons.copy_outlined,
          diameter: 40,
          onPressed: () {},
        ),
      ),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('unitAction'))).width,
      40,
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.copy_outlined)).size,
      FaIconActionButton.glyphSizeFor(40),
    );
  });

  testWidgets('tooltip semantics ride the inner button', (tester) async {
    await tester.pumpWidget(
      _host(
        FaIconActionButton(
          key: const ValueKey('unitAction'),
          icon: Icons.copy_outlined,
          tooltip: 'Copy session',
          onPressed: () {},
        ),
      ),
    );
    final button = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const ValueKey('unitAction')),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.tooltip, 'Copy session');
    expect(button.onPressed, isNotNull);
  });

  testWidgets('buttonKey lands on the inner button (single finder match)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        FaIconActionButton(
          icon: Icons.close,
          buttonKey: const ValueKey('filesAppClose'),
          onPressed: () {},
        ),
      ),
    );
    expect(find.byKey(const ValueKey('filesAppClose')), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('filesAppClose')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('child mode: custom glyph rides the same chrome and ink', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        FaIconActionButton(
          key: const ValueKey('unitAction'),
          onPressed: () {},
          child: const Icon(Icons.stop, size: 18),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final theme = IconTheme.of(tester.element(find.byIcon(Icons.stop)));
    expect(theme.color, FaDesignTokens.of(
      tester.element(find.byIcon(Icons.stop)),
    ).ink1);
    expect(
      tester.getRect(find.byKey(const ValueKey('unitAction'))).width,
      36,
    );
  });

  testWidgets('glass flag: floating state rides a glass underlay', (
    tester,
  ) async {
    Widget host({bool? glass}) => _host(
      FaIconActionButton(
        key: const ValueKey('unitAction'),
        icon: Icons.folder_outlined,
        glass: glass ?? false,
        onPressed: () {},
      ),
    );
    // Flat (default): on-surface state — no FaSurface underlay.
    await tester.pumpWidget(host());
    expect(
      find
          .ancestor(
            of: find.byKey(const ValueKey('unitAction')),
            matching: find.byType(FaSurface),
          )
          .evaluate()
          .length,
      0,
    );
    // Floating state: the glass underlay wraps the same chrome.
    await tester.pumpWidget(host(glass: true));
    await tester.pumpAndSettle();
    // The glass FaSurface hosts the chrome (unique in this host).
    final surface = tester.widget<FaSurface>(find.byType(FaSurface));
    expect(surface.glass, isTrue);
    expect(surface.circular, isTrue);
    // Same 36pt chrome box inside the glass disc.
    expect(
      tester.getRect(find.byKey(const ValueKey('unitAction'))).width,
      36,
    );
  });

  test('guard rails: icon XOR child, hit target floor', () {
    expect(
      () => FaIconActionButton(onPressed: () {}),
      throwsAssertionError,
    );
    expect(
      () => FaIconActionButton(
        icon: Icons.close,
        child: const Icon(Icons.close),
        onPressed: () {},
      ),
      throwsAssertionError,
    );
    expect(
      () => FaIconActionButton(icon: Icons.close, diameter: 28, onPressed: () {}),
      throwsAssertionError,
    );
  });

  testWidgets('tap fires onPressed', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(
        FaIconActionButton(
          icon: Icons.close,
          onPressed: () => tapped = true,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.close));
    expect(tapped, isTrue);
  });
}
