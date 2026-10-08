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
Future<void> ensureGoldenFonts() async {
  // The kaomoji indicator (issue #1374) picks its face randomly in
  // production — goldens pin it (the CLI's FA_KAOMOJI_FACE seam
  // mirrors this) so every frame is deterministic: `>_o`, everywhere.
  //
  // MAC REGEN DONE (PR #1419, issue #1374): the branch swapped the
  // thinking tile (head-with-gear → KaomojiThinkingIcon) and the status
  // row (spinner → KaomojiFaceText); the affected snapshots were
  // regenerated on the host-locked mac (the pin above keeps every
  // frame byte-stable across the regen), with eyes on each diff:
  //   chat/run_status_empty_light, chat/run_status_empty_dark,
  //   chat/run_status_thinking_light, chat/run_status_tool_light,
  //   chat/run_status_tool_dark                       (status row)
  //   launcher/sheet_session_streaming_dark            (status row)
  //   chat_conversation, apps_fa_chat_overlay,
  //   apps_fa_chat_overlay_light, apps_fa_chat_overlay_streaming,
  //   apps_fa_chat_overlay_streaming_light            (thinking tiles)
  // apps_fa_chat_overlay_rich/_rich_ru stayed byte-identical (their
  // thinking bubble renders collapsed — no icon), and unrelated frames
  // carry a pre-existing ~0.5% host drift that also fails on main and
  // waits on a separate host-wide regen pass.
  KaomojiFacePicker.debugPin = 0;
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
