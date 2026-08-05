// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the dark theme uses the landing palette', () {
    final theme = buildFahTheme();
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, FahPalette.bg);
    expect(theme.colorScheme.primary, FahPalette.indigo);
    expect(theme.colorScheme.secondary, FahPalette.teal);
    expect(theme.colorScheme.surface, FahPalette.bgAlt);
    expect(theme.dividerColor, FahPalette.border);
  });

  test('light theme mirrors the dark structure on the light palette', () {
    final theme = buildFahThemeLight();
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, FahLightPalette.bg);
    expect(theme.colorScheme.primary, FahLightPalette.indigo);
    expect(theme.colorScheme.secondary, FahLightPalette.teal);
    expect(theme.colorScheme.surface, FahLightPalette.bgAlt);
    expect(theme.dividerColor, FahLightPalette.border);
  });

  test('a FaUiTheme re-skins accents, typeface, and radii', () {
    final theme = buildFahTheme(
      uiTheme: const FaUiTheme(
        indigo: Colors.deepOrange,
        teal: Colors.lightGreen,
        fontFamily: 'Roboto',
        cardRadius: 4,
        inputRadius: 6,
        buttonRadius: 8,
      ),
    );
    expect(theme.colorScheme.primary, Colors.deepOrange);
    expect(theme.colorScheme.secondary, Colors.lightGreen);
    expect(theme.textTheme.bodyMedium?.fontFamily, 'Roboto');
    final cardShape = theme.cardTheme.shape! as RoundedRectangleBorder;
    expect(cardShape.borderRadius, BorderRadius.circular(4));
    final inputBorder =
        theme.inputDecorationTheme.enabledBorder! as OutlineInputBorder;
    expect(inputBorder.borderRadius, BorderRadius.circular(6));
    // A null field keeps the brand default.
    expect(theme.scaffoldBackgroundColor, FahPalette.bg);
  });

  test('a null FaUiTheme is pixel-identical to no FaUiTheme', () {
    final stock = buildFahTheme();
    final themed = buildFahTheme(uiTheme: const FaUiTheme());
    expect(themed.colorScheme.primary, stock.colorScheme.primary);
    expect(themed.textTheme.bodyMedium?.fontFamily, 'Inter');
    expect(
      (themed.cardTheme.shape! as RoundedRectangleBorder).borderRadius,
      (stock.cardTheme.shape! as RoundedRectangleBorder).borderRadius,
    );
  });

  testWidgets('FahColors.of picks up the provider accent overrides', (
    tester,
  ) async {
    late FahColors colors;
    await tester.pumpWidget(
      FaUiThemeProvider(
        data: const FaUiTheme(indigo: Colors.deepOrange),
        child: MaterialApp(
          theme: buildFahTheme(),
          home: Builder(
            builder: (context) {
              colors = FahColors.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(colors.indigo, Colors.deepOrange);
    // Untouched fields stay on the brand palette; the gradient derives.
    expect(colors.teal, FahPalette.teal);
    expect(colors.panel, FahPalette.panel);
    expect(colors.brandGradient.colors.first, Colors.deepOrange);
  });

  testWidgets('without a provider FahColors.of is the stock palette', (
    tester,
  ) async {
    late FahColors colors;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        home: Builder(
          builder: (context) {
            colors = FahColors.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(identical(colors, FahColors.dark), isTrue);
  });

  test('chat theme honors FaUiTheme background/surface overrides', () {
    const uiTheme = FaUiTheme(
      background: Color(0xFF0B0B0F),
      surface: Color(0xFF13131A),
    );
    final dark = buildFahChatTheme(uiTheme: uiTheme);
    expect(dark.colors.surface, const Color(0xFF0B0B0F));
    expect(dark.colors.surfaceContainer, const Color(0xFF13131A));
    final light = buildFahChatThemeLight(uiTheme: uiTheme);
    expect(light.colors.surface, const Color(0xFF0B0B0F));
    expect(light.colors.surfaceContainer, const Color(0xFF13131A));
    // Null fields keep the stock palette exactly.
    final stock = buildFahChatTheme(uiTheme: const FaUiTheme());
    expect(stock.colors.surface, FahPalette.bg);
    expect(stock.colors.surfaceContainer, FahPalette.panel);
  });

  testWidgets('FahColors.of honors explicit user bubble tokens', (
    tester,
  ) async {
    late FahColors colors;
    await tester.pumpWidget(
      FaUiThemeProvider(
        data: const FaUiTheme(
          userBubble: Color(0xFF1C1C26),
          userBubbleBorder: Color(0x597C3AED),
        ),
        child: MaterialApp(
          theme: buildFahTheme(),
          home: Builder(
            builder: (context) {
              colors = FahColors.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(colors.userBubble, const Color(0xFF1C1C26));
    expect(colors.userBubbleBorder, const Color(0x597C3AED));
    // Accents and the rest of the palette stay stock.
    expect(colors.indigo, FahPalette.indigo);
    expect(colors.panel, FahPalette.panel);
  });

  testWidgets('the provider builds both brightness themes from its data', (
    tester,
  ) async {
    late ThemeData dark;
    late ThemeData light;
    await tester.pumpWidget(
      FaUiThemeProvider(
        data: const FaUiTheme(indigo: Colors.deepOrange),
        child: Builder(
          builder: (context) {
            dark = FaUiThemeProvider.darkThemeOf(context);
            light = FaUiThemeProvider.lightThemeOf(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(dark.brightness, Brightness.dark);
    expect(dark.colorScheme.primary, Colors.deepOrange);
    expect(light.brightness, Brightness.light);
    expect(light.colorScheme.primary, Colors.deepOrange);
  });
}
