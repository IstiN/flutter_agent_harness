// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared scaffolding for the trajectory golden (screenshot) tests.
///
/// FONTS: fa_ui bundles no text font assets (it cannot reach flutter_app's
/// Inter/JetBrainsMono — not a dependency), so golden text renders with
/// Flutter's default test font: placeholder glyph shapes, real layout,
/// colors, and metrics. Icons are real: pumpGolden loads the MaterialIcons
/// font bundled via `uses-material-design` (flutter_test does not
/// auto-load FontManifest fonts, so without this every icon draws as a
/// placeholder box). Deterministic and hermetic on every machine; do not
/// add font assets to make the text prettier — the package ships none.
///
/// Every golden pumps through [pumpGolden] (fixed surface size + explicit
/// theme from the fa_ui app_theme builders) and asserts with [expectGolden].
/// Fixtures come from the shared trajectory fixture builders
/// (`../fixture*.dart`) so record ids and indexes match real projection;
/// goldens must stay deterministic — fixed snapshots, no timers or
/// animations beyond route transitions settled by `pumpAndSettle`.
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void>? _fontsFuture;

/// Loads the MaterialIcons font bundled via `uses-material-design: true`
/// once per process. flutter_test does not auto-load FontManifest fonts,
/// and inside a `testWidgets` body the real async I/O never completes
/// (FakeAsync zone) — so this MUST run in the real async zone, from
/// `test/flutter_test_config.dart`. Without it every icon renders as a
/// placeholder box.
Future<void> loadGoldenFonts() => _fontsFuture ??= _loadIconFont();

Future<void> _loadIconFont() async {
  final loader = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await loader.load();
}

/// Desktop canvas for full-frame pages.
const goldenSizeDesktop = Size(1280, 800);

/// Ledger viewport canvas (table goldens); only visible rows matter.
const goldenSizeLedger = Size(800, 600);

/// Phone canvas (narrow layout sheet).
const goldenSizePhone = Size(390, 844);

/// Tall canvas for the details bottom sheet.
const goldenSizeSheet = Size(500, 800);

/// Pumps [child] inside the fa theme at [size]. Pass [theme] (e.g.
/// `buildFahThemeLight()`) for non-default (dark) variants.
Future<void> pumpGolden(
  WidgetTester tester,
  Widget child, {
  Size size = goldenSizeDesktop,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme ?? buildFahTheme(),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

/// Asserts the current frame matches
/// `test/trajectory/golden/goldens/<name>.png`; [name] may omit the
/// `.png` extension.
Future<void> expectGolden(WidgetTester tester, String name) {
  final file = name.endsWith('.png') ? name : '$name.png';
  return expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$file'),
  );
}

Widget goldenCellPage(List<TrajectoryRecord> records) => Builder(
  builder: (context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      for (final record in records)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: buildTrajectoryCell(context, record),
        ),
    ],
  ),
);
