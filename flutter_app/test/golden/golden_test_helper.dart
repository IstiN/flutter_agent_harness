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
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show KaomojiFacePicker;
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
///
/// HOST-INDEPENDENCE CONTRACT (issue #1856, from #177 E5): every family a
/// golden can touch is registered HERE, from byte-identical TTFs, so the
/// engine never consults the test host's fonts. flutter_test runs under
/// `--use-test-fonts`: a glyph missing from every registered family
/// resolves to the deterministic test-font box — NOT a host font — and
/// glyphs missing from the PRIMARY family stay trapped the same way
/// (per-glyph fallback cannot escape a resolved family). The production
/// mono fallback stack (FahPalette.monoFallback: SF Mono / Menlo /
/// Consolas / Roboto Mono / Courier — host system fonts) is therefore
/// aliased to the same JetBrainsMono bytes: without the aliases a
/// mono-path glyph JetBrainsMono lacks would resolve to the host's
/// CoreText/fontconfig substitute and drift per host/OS. Emoji and
/// symbols (✦, 🍅, ⏳ …) stay deterministic-by-trap for the same reason;
/// shadows are covered by the test runner's `--skia-deterministic-
/// rendering` flag. The remaining drift axis is the SDK VERSION, so the
/// baselines are only valid for the exact pinned SDK (3.47.4) the
/// nightly golden leg (build-release macOS row) runs — after an SDK
/// bump, regenerate (`flutter test test/golden --update-goldens`) and
/// eyeball every changed PNG.
Future<void> ensureGoldenFonts() async {
  // The kaomoji indicator (issue #1374) picks its face randomly in
  // production — goldens pin it (the CLI's FA_KAOMOJI_FACE seam
  // mirrors this) so every frame is deterministic: `>_o`, everywhere.
  KaomojiFacePicker.debugPin = 0;
  if (_fontsLoaded) return;
  final inter = FontLoader('Inter')
    ..addFont(rootBundle.load('assets/fonts/Inter-Regular.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Inter-Medium.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Inter-SemiBold.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Inter-Bold.ttf'));
  final jbm = [
    rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'),
    rootBundle.load('assets/fonts/JetBrainsMono-Bold.ttf'),
  ];
  // The theme's terminal-ish styles resolve `JetBrainsMono` and fall
  // back through FahPalette.monoFallback — host system fonts (SF Mono
  // only exists on macOS, Menlo/Consolas are platform-bound…). Register
  // the whole stack against the same JetBrainsMono bytes so a mono-path
  // glyph resolves identically on every host (see the contract above).
  final monoLoaders = <FontLoader>[
    for (final family in const [
      'JetBrainsMono',
      'SF Mono',
      'Menlo',
      'Consolas',
      'Roboto Mono',
      'Courier',
    ])
      FontLoader(family)
        ..addFont(jbm[0])
        ..addFont(jbm[1]),
  ];
  // Icon fonts are not registered from the test asset bundle either, but
  // `uses-material-design: true` places MaterialIcons under fonts/.
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await inter.load();
  for (final loader in monoLoaders) {
    await loader.load();
  }
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
///
/// After settling, [expectRealFontText] runs on the pumped frame: any
/// family-less paragraph (test-fallback Ahem bars in goldens) fails the
/// test.
Future<void> pumpGolden(
  WidgetTester tester,
  Widget child, {
  Size size = goldenSizeTall,
  Locale locale = const Locale('en'),
  ThemeData? theme,
  Widget Function(Widget child)? wrap,

  /// False for frames with infinite animations (spinners): settles by
  /// pumping one frame instead of pumpAndSettle, which would time out.
  bool settle = true,
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
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  expectRealFontText(tester);
}

/// Asserts the current frame matches `test/golden/goldens/<name>.png`.
Future<void> expectGolden(WidgetTester tester, String name) {
  return expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

/// Fails when any visible text is painted with the test fallback font.
///
/// A [TextStyle] that REPLACES a themed label style (ButtonStyle.textStyle,
/// `styleFrom(textStyle: …)`, snackbar/tooltip content styles) drops the
/// themed fontFamily, and the engine then paints the glyphs with its default
/// font — solid Ahem placeholder blocks in goldens, a foreign system font on
/// devices (issue #947). Every themed style carries an explicit family (the
/// textTheme is built with `.apply(fontFamily: …)`), so a null family on a
/// rendered paragraph is always this bug.
void expectRealFontText(WidgetTester tester) {
  final offenders = <String>{};
  for (final renderObject
      in tester.allRenderObjects.whereType<RenderParagraph>()) {
    final plain = renderObject.text.toPlainText().trim();
    final family = renderObject.text.style?.fontFamily;
    if (plain.isNotEmpty && (family == null || family.isEmpty)) {
      offenders.add(
        '"${plain.length > 40 ? '${plain.substring(0, 40)}…' : plain}"',
      );
    }
  }
  if (offenders.isNotEmpty) {
    fail(
      'Text painted with the test fallback font (family-less resolved '
      'TextStyle — add fontFamily to the overriding style, mirroring the '
      'button themes in app_theme.dart): ${offenders.take(10).join(', ')}',
    );
  }
}
