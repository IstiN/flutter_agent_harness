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
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

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

  testWidgets('glass flag: glass direction delegates to the kit GlassIconButton', (
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
    // Flat (default): on-surface state — the Material chrome, no kit glass.
    await tester.pumpWidget(host());
    expect(find.byType(GlassIconButton), findsNothing);
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
    // Floating state: the ONE kit delegate carries the glass disc.
    await tester.pumpWidget(host(glass: true));
    await tester.pumpAndSettle();
    final kitButton = tester.widget<GlassIconButton>(
      find.byType(GlassIconButton),
    );
    // OUR control scale passes through (36pt circle, 18px glyph) — the kit
    // default is 44/22 phone sizing.
    expect(kitButton.size, FaIconActionButton.defaultDiameter);
    expect(kitButton.iconSize, FaIconActionButton.glyphSizeFor(36));
    expect(kitButton.interactionScale, 0.95);
    // The jelly press comes from the kit: the squash scale is wired, not
    // re-implemented.
    expect(kitButton.interactionScale, lessThan(1));
    // Token-derived glow.
    final element = tester.element(find.byType(GlassIconButton));
    final tokens = FaDesignTokens.of(element);
    expect(kitButton.glowColor, tokens.ink1.withValues(alpha: .2));
    expect(
      kitButton.glowRadius,
      FaIconActionButton.defaultDiameter * .5,
    );
    // Fa-tuned material: frost ~5, near-clear surface wash, no dispersion.
    expect(kitButton.settings, isNotNull);
    expect(kitButton.settings!.blur, kFaGlassFrost);
    expect(
      kitButton.settings!.glassColor,
      tokens.surface1.withValues(alpha: kFaGlassTintAlpha),
    );
    expect(kitButton.settings!.chromaticAberration, 0);
    // Key + semantics land on the kit button.
    expect(kitButton.onPressed, isNotNull);
    // The glyph rides inside the kit button at the derived size.
    final glyph = tester.widget<Icon>(find.byIcon(Icons.folder_outlined));
    expect(glyph.size, FaIconActionButton.glyphSizeFor(36));
    // Same 36pt box as the flat chrome.
    expect(
      tester.getRect(find.byKey(const ValueKey('unitAction'))).width,
      36,
    );
  });

  testWidgets('glass flag outside the glass direction stays flat chrome', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFaTheme(
          direction: FaVisualDirection.nebula,
          brightness: Brightness.dark,
        ),
        home: Scaffold(
          body: Center(
            child: FaIconActionButton(
              key: const ValueKey('unitAction'),
              icon: Icons.folder_outlined,
              glass: true,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.byType(GlassIconButton), findsNothing);
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
  });

  testWidgets('glass tap fires onPressed', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(
        FaIconActionButton(
          icon: Icons.close,
          glass: true,
          onPressed: () => tapped = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    expect(tapped, isTrue);
  });

  test('faGlassSettings mapping: Fa tokens onto the kit material', () {
    final settings = faGlassSettings(
      tint: const Color(0xFF112233).withValues(alpha: .4),
    );
    expect(settings.blur, kFaGlassFrost);
    expect(settings.blur, greaterThanOrEqualTo(4));
    expect(settings.blur, lessThanOrEqualTo(6));
    expect(settings.glassColor.a, closeTo(.4, .001));
    // The audit measured zero dispersion on the reference chrome.
    expect(settings.chromaticAberration, 0);
    // Frost and tint stay token-remappable per call site.
    final tuned = faGlassSettings(
      tint: const Color(0xFF112233).withValues(alpha: .2),
      frost: 6,
    );
    expect(tuned.blur, 6);
    expect(tuned.glassColor.a, closeTo(.2, .001));
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
