/// Google Play store-listing assets, golden-driven (issue #289).
///
/// The Play Console image files committed under
/// `fastlane/metadata/android/` are not hand-made graphics — they are
/// COMMITTED GOLDENS this suite renders and verifies:
///
///   * `images/featureGraphic.png` — the [PlayFeatureGraphic] brand banner
///     rendered at exactly 1024×500 (per locale: en-US + ru-RU taglines);
///   * `images/phoneScreenshots/*.png` + `images/tenInchScreenshots/*.png`
///     — the store story frames at Play-spec sizes, rendered by
///     `store_screenshots_test.dart` (see its Google Play device targets);
///   * `images/icon.png` — derived from the iOS 1024 master by
///     `tool/generate_android_adaptive_icons.dart` (SSIM-checked in
///     `test/android_icon_test.dart`).
///
/// `test/play_store_listing_guard_test.dart` (pure Dart, no rendering)
/// enforces the Play size/aspect/file-cap rules over the same files, so a
/// wrong-size asset can never merge.
///
/// Regenerate with:
/// `flutter test test/golden/play_store_assets_test.dart --update-goldens`
/// (and the same flag on `store_screenshots_test.dart` for the
/// screenshots) — then OPEN every PNG before committing.
library;

import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';
import 'play_feature_graphic.dart';

/// The Play feature-graphic spec: exactly 1024×500.
const playFeatureSize = Size(1024, 500);

/// metadata/android locale dir → feature-graphic language code.
const _locales = {'en-US': 'en', 'ru-RU': 'ru'};

Future<void> _pumpFeatureGraphic(
  WidgetTester tester,
  String lang, {
  required Key key,
}) async {
  tester.view.physicalSize = playFeatureSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      key: key,
      debugShowCheckedModeBanner: false,
      theme: buildFahTheme(),
      home: PlayFeatureGraphic(lang: lang),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(ensureGoldenFonts);

  group('Play feature graphic — 1024×500 brand banner', () {
    for (final entry in _locales.entries) {
      testWidgets('${entry.key} — ${entry.value} tagline', (tester) async {
        await _pumpFeatureGraphic(
          tester,
          entry.value,
          key: ValueKey('play-feature-${entry.key}'),
        );
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            '../../fastlane/metadata/android/${entry.key}/images/'
            'featureGraphic.png',
          ),
        );
      });
    }
  });
}
