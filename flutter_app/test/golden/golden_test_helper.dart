/// Shared scaffolding for the golden (screenshot) tests in `test/golden/`.
///
/// Every golden test pumps through [pumpGolden] so all snapshots share the
/// same theme, localization delegates, and surface sizing, then asserts
/// with [expectGolden]. Goldens use the deterministic flutter_test font —
/// never load app fonts, or snapshots become host-dependent.
library;

import 'package:fa/ui/app_theme.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Default landscape surface for wide panels (file browser, chat).
const goldenSizeWide = Size(900, 600);

/// Default portrait surface (dialogs, forms, sidebars).
const goldenSizeTall = Size(500, 800);

/// Pumps [child] inside the app's real theme + localization at [size].
///
/// Use [wrap] to customize the host (e.g. wrap in a `Scaffold` with an
/// `AppBar`); the default centers the child on a scaffold body.
Future<void> pumpGolden(
  WidgetTester tester,
  Widget child, {
  Size size = goldenSizeTall,
  Locale locale = const Locale('en'),
  Widget Function(Widget child)? wrap,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildFahTheme(),
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
