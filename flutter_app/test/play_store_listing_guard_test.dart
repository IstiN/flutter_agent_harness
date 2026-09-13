// Issue #289 — Google Play store-listing asset guard (pure Dart, no
// rendering).
//
// The Play Console's image rules become OUR tests: every PNG under
// fastlane/metadata/android/<locale>/images/ must match the spec of its
// asset class, so a wrong-size asset can never merge (and never bounce in
// the Console):
//
//   * images/icon.png            — exactly 512×512, ≤1 MB, PNG/JPEG
//   * images/featureGraphic.png  — exactly 1024×500, ≤15 MB, PNG/JPEG
//   * images/phoneScreenshots/   — 2–8 files, 9:16 or 16:9 only,
//                                  each side 320–3840 px, ≤8 MB per file
//   * images/sevenInchScreenshots/ — same shape rule as phone (optional set)
//   * images/tenInchScreenshots/ — 9:16 or 16:9 only, each side
//                                  1080–7680 px, ≤8 MB per file
//
// The screenshots and the feature graphic are COMMITTED GOLDENS generated
// by test/golden/store_screenshots_test.dart (phone + tenInch story
// frames) and test/golden/play_store_assets_test.dart (feature graphic);
// the icon is derived from the iOS 1024 master by
// tool/generate_android_adaptive_icons.dart (SSIM-checked in
// test/android_icon_test.dart).
//
// Conventions this guard also pins (see the lane: `fastlane android
// play_store`):
//   * every locale carries the locale-neutral brand assets (icon) — the
//     ru-RU icon must be byte-identical to en-US;
//   * no stray files where supply/Play would reject them (images/ root
//     accepts only icon.png + featureGraphic.png; screenshot sets are the
//     three Play-named dirs).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart';

/// One KB = 1000 B in Play Console limits (their UI shows "1 MB").
const _oneKb = 1000;

/// The Play screenshot sets this repo ships (sevenInch allowed but unused).
const _screenshotDirs = {
  'phoneScreenshots',
  'sevenInchScreenshots',
  'tenInchScreenshots',
};

(String, String)? _decode(String path) {
  final bytes = File(path).readAsBytesSync();
  final image = decodeImage(bytes);
  if (image == null) return null;
  return ('${image.width}', '${image.height}');
}

void main() {
  final metadataRoot = '${Directory.current.path}/fastlane/metadata/android';

  test('metadata/android locale tree exists', () {
    expect(
      Directory(metadataRoot).existsSync(),
      isTrue,
      reason: 'fastlane/metadata/android is the supply tree',
    );
  });

  test('every images/ file matches its Play asset-class spec', () {
    final problems = <String>[];
    final locales =
        Directory(metadataRoot).listSync().whereType<Directory>().toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(locales, isNotEmpty, reason: 'at least en-US must exist');

    for (final localeDir in locales) {
      final locale = localeDir.path.split('/').last;
      final imagesDir = Directory('${localeDir.path}/images');
      if (!imagesDir.existsSync()) continue;

      // ── images/ root: only the two single-image assets, fully specced ──
      final rootFiles =
          imagesDir
              .listSync()
              .whereType<File>()
              .map((f) => f.path.split('/').last)
              .toList()
            ..sort();
      for (final name in rootFiles) {
        if (name != 'icon.png' && name != 'featureGraphic.png') {
          problems.add(
            '$locale/images/$name: unexpected file in images/ '
            'root (Play accepts only icon.png + featureGraphic.png here)',
          );
        }
      }

      final icon = File('${imagesDir.path}/icon.png');
      if (icon.existsSync()) {
        final dims = _decode(icon.path);
        final size = icon.lengthSync();
        if (dims == null) {
          problems.add('$locale icon.png: not a decodable PNG/JPEG');
        } else if (dims != ('512', '512')) {
          problems.add(
            '$locale icon.png: ${dims.$1}x${dims.$2} '
            '(Play wants exactly 512x512)',
          );
        }
        if (size > 1024 * _oneKb) {
          problems.add('$locale icon.png: $size bytes > 1 MB');
        }
      } else {
        problems.add('$locale: images/icon.png missing (Play requires it)');
      }

      final feature = File('${imagesDir.path}/featureGraphic.png');
      if (feature.existsSync()) {
        final dims = _decode(feature.path);
        final size = feature.lengthSync();
        if (dims == null) {
          problems.add('$locale featureGraphic.png: not a decodable PNG/JPEG');
        } else if (dims != ('1024', '500')) {
          problems.add(
            '$locale featureGraphic.png: ${dims.$1}x${dims.$2} '
            '(Play wants exactly 1024x500)',
          );
        }
        if (size > 15 * 1024 * _oneKb) {
          problems.add('$locale featureGraphic.png: $size bytes > 15 MB');
        }
      } else {
        problems.add(
          '$locale: images/featureGraphic.png missing (Play requires it)',
        );
      }

      // ── screenshot sets ────────────────────────────────────────────────
      final subdirs = imagesDir
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split('/').last)
          .toSet();
      for (final name in subdirs.difference(_screenshotDirs)) {
        problems.add(
          '$locale/images/$name: unknown screenshot dir '
          '(Play accepts ${_screenshotDirs.join(', ')})',
        );
      }

      for (final setName in _screenshotDirs) {
        final setDir = Directory('${imagesDir.path}/$setName');
        if (!setDir.existsSync()) continue;
        final files =
            setDir
                .listSync()
                .whereType<File>()
                .where(
                  (f) =>
                      f.path.toLowerCase().endsWith('.png') ||
                      f.path.toLowerCase().endsWith('.jpg') ||
                      f.path.toLowerCase().endsWith('.jpeg'),
                )
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        final minSide = setName == 'tenInchScreenshots' ? 1080 : 320;
        final maxSide = setName == 'tenInchScreenshots' ? 7680 : 3840;
        for (final file in files) {
          final rel = '$locale/images/$setName/${file.path.split('/').last}';
          final dims = _decode(file.path);
          final size = file.lengthSync();
          if (dims == null) {
            problems.add('$rel: not a decodable PNG/JPEG');
            continue;
          }
          final w = int.parse(dims.$1), h = int.parse(dims.$2);
          final shortSide = w < h ? w : h, longSide = w < h ? h : w;
          // 9:16 or 16:9 ONLY — integer cross-multiplication, no
          // float tolerance games. (1600x2560 is 10:16 and REJECTED.)
          final isNineSixteen = w * 16 == h * 9 || w * 9 == h * 16;
          if (!isNineSixteen) {
            problems.add('$rel: $w×$h is not 9:16 or 16:9');
          }
          if (shortSide < minSide || longSide > maxSide) {
            problems.add(
              '$rel: $w×$h outside $minSide–$maxSide px '
              'side bounds',
            );
          }
          if (size > 8 * 1024 * _oneKb) {
            problems.add('$rel: $size bytes > 8 MB');
          }
        }
        if (files.isEmpty) {
          problems.add(
            '$locale/images/$setName: empty set — delete the dir '
            'or fill it',
          );
        }
        if (setName == 'phoneScreenshots' &&
            (locale == 'en-US') &&
            (files.length < 2 || files.length > 8)) {
          problems.add(
            '$locale/images/$setName: ${files.length} files '
            '(Play requires 2–8 phone screenshots)',
          );
        }
      }
    }

    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('ru-RU icon mirrors en-US byte-for-byte (locale-neutral brand)', () {
    final en = File('$metadataRoot/en-US/images/icon.png');
    final ru = File('$metadataRoot/ru-RU/images/icon.png');
    expect(en.existsSync(), isTrue, reason: 'en-US icon is the master copy');
    expect(
      ru.existsSync(),
      isTrue,
      reason:
          'ru-RU mirrors the brand icon (repo convention: localized '
          'screenshots, shared brand assets)',
    );
    if (en.existsSync() && ru.existsSync()) {
      expect(
        ru.readAsBytesSync(),
        en.readAsBytesSync(),
        reason:
            'the ru-RU icon must be the exact en-US bytes — regenerate'
            ' with dart run tool/generate_android_adaptive_icons.dart',
      );
    }
  });
}
