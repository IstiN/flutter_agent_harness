// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared scaffolding for the trajectory golden (screenshot) tests.
///
/// FONTS: golden text renders with the real families the fa theme
/// requests — `Inter` and `JetBrainsMono`, loaded from
/// `test/assets/fonts/` (test-only copies of flutter_app's bundled
/// TTFs; the package itself ships no font assets). Icons are real too:
/// MaterialIcons is loaded from the font bundled via
/// `uses-material-design` (flutter_test does not auto-load FontManifest
/// fonts). All loading happens in the real async zone via
/// [loadGoldenFonts] — inside a `testWidgets` body the I/O never
/// completes (FakeAsync zone). Without the fonts every glyph draws as a
/// placeholder box.
///
/// Every golden pumps through [pumpGolden] (fixed surface size + explicit
/// theme from the fa_ui app_theme builders) and asserts with [expectGolden].
/// Fixtures come from the shared trajectory fixture builders
/// (`../fixture*.dart`) so record ids and indexes match real projection;
/// goldens must stay deterministic — fixed snapshots, no timers or
/// animations beyond route transitions settled by `pumpAndSettle`.

library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void>? _fontsFuture;

/// Loads every font the goldens need, once per process: the text families
/// the fa theme requests (`Inter`, `JetBrainsMono`) from the test-only
/// TTF copies in `test/assets/fonts/`, plus the MaterialIcons font
/// bundled via `uses-material-design: true`. flutter_test does not
/// auto-load FontManifest fonts, and inside a `testWidgets` body the
/// real async I/O never completes (FakeAsync zone) — so this MUST run in
/// the real async zone, from `test/flutter_test_config.dart`. Without it
/// every glyph renders as a placeholder box.
Future<void> loadGoldenFonts() => _fontsFuture ??= _loadFonts();

Future<void> _loadFonts() async {
  Future<ByteData> loadTtf(String name) async {
    final bytes = await File('test/assets/fonts/$name').readAsBytes();
    return ByteData.sublistView(bytes);
  }

  final inter = FontLoader('Inter')
    ..addFont(loadTtf('Inter-Regular.ttf'))
    ..addFont(loadTtf('Inter-Medium.ttf'))
    ..addFont(loadTtf('Inter-SemiBold.ttf'))
    ..addFont(loadTtf('Inter-Bold.ttf'));
  final monoTtfs = [
    loadTtf('JetBrainsMono-Regular.ttf'),
    loadTtf('JetBrainsMono-Bold.ttf'),
  ];
  // The theme's terminal-ish style resolves `JetBrainsMono`, while the
  // trajectory widgets request the generic `monospace` family (real
  // desktops substitute a system mono font; the test env has none).
  // Register the same TTFs under both names so both resolve.
  final mono = FontLoader('JetBrainsMono')
    ..addFont(monoTtfs[0])
    ..addFont(monoTtfs[1]);
  final genericMono = FontLoader('monospace')
    ..addFont(monoTtfs[0])
    ..addFont(monoTtfs[1]);
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await inter.load();
  await mono.load();
  await genericMono.load();
  await icons.load();
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
