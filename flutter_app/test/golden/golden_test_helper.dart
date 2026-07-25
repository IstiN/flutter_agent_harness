/// Shared scaffolding for the golden (screenshot) tests in `test/golden/`.
///
/// Every golden test pumps through [pumpGolden] so all snapshots share the
/// same theme, real bundled fonts, localization delegates, and surface
/// sizing, then asserts with [expectGolden]. Call [ensureGoldenFonts] from
/// `setUpAll` — without it flutter_test renders text as placeholder boxes.
/// Snapshots are meant to double as marketing material: prefer full app
/// frames filled with realistic content over tiny widgets on a black void.
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Desktop frame for hero/marketing shots.
const goldenSizeDesktop = Size(1280, 800);

/// Default landscape surface for wide panels (file browser, chat).
const goldenSizeWide = Size(900, 600);

/// Default portrait surface (dialogs, forms, sidebars, phone frames).
const goldenSizeTall = Size(500, 800);

/// Phone frame (iPhone-ish) for mobile marketing shots.
const goldenSizePhone = Size(390, 844);

var _fontsLoaded = false;

/// Loads the app's bundled fonts (Inter + JetBrainsMono) plus MaterialIcons
/// so snapshots render real glyphs instead of flutter_test placeholder
/// boxes. Fonts are loaded once per test process; safe to call from every
/// `setUpAll`.
Future<void> ensureGoldenFonts() async {
  if (_fontsLoaded) return;
  final inter = FontLoader('Inter')
    ..addFont(rootBundle.load('assets/fonts/Inter-Regular.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Inter-Medium.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Inter-SemiBold.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Inter-Bold.ttf'));
  final mono = FontLoader('JetBrainsMono')
    ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'))
    ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Bold.ttf'));
  // Icon fonts are not registered from the test asset bundle either, but
  // `uses-material-design: true` places MaterialIcons under fonts/.
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await inter.load();
  await mono.load();
  await icons.load();
  _fontsLoaded = true;
}

/// Pumps [child] inside the app's real theme + localization at [size].
///
/// Use [wrap] to customize the host (e.g. wrap in a `Scaffold` with an
/// `AppBar`); the default centers the child on a scaffold body — for
/// full-screen shots pass `wrap: (child) => child` with a child that is
/// itself a `Scaffold`. Pass [theme] (e.g. `buildFahThemeLight()`) for
/// non-default theme variants.
Future<void> pumpGolden(
  WidgetTester tester,
  Widget child, {
  Size size = goldenSizeTall,
  Locale locale = const Locale('en'),
  ThemeData? theme,
  Widget Function(Widget child)? wrap,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme ?? buildFahTheme(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: wrap != null ? wrap(child) : Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

/// Asserts the current frame matches `test/golden/goldens/<name>.png`.
Future<void> expectGolden(WidgetTester tester, String name) {
  return expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}
