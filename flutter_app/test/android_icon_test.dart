// Issue #289 AC2 — Android launcher icon derivation goldens.
//
// The Android launcher icons must derive from the iOS 1024 master
// (ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png):
//
//   * legacy ic_launcher.png (mdpi–xxxhdpi): the master, full-bleed, scaled;
//   * adaptive foreground ic_launcher_foreground.png (108–432 px): the
//     master scaled into the adaptive safe zone on a transparent canvas;
//   * the adaptive XML layers reference @mipmap/ic_launcher_foreground over
//     the @color/ic_launcher_background brand navy (#0b0f16) — no leftover
//     Flutter-template drawables.
//
// Regenerate with: dart run tool/generate_android_adaptive_icons.dart
// (the tool and this test share the derivation parameters).
//
// The similarity metric is a windowed SSIM over luminance (8×8 windows);
// thresholds are generous enough for resampling differences and strict
// enough to catch wrong-source or full-bleed-foreground regressions.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart';

final brandNavy = ColorRgb8(0x0B, 0x0F, 0x16);

/// The flutter_app root, located by walking up from the cwd (under
/// `flutter test` the cwd is flutter_app) — Platform.script points into
/// .dart_tool and is not stable across flutter_test kernel rebuilds.
String get _appRoot {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/ios').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate the flutter_app root from ${Directory.current}');
    }
    dir = parent;
  }
}

Image _read(String path) {
  final resolved = path.startsWith('/') ? path : '$_appRoot/$path';
  final bytes = File(resolved).readAsBytesSync();
  final image = decodeImage(bytes);
  if (image == null) {
    fail('could not decode $resolved');
  }
  return image;
}

/// Composites [image] over the brand navy background — the adaptive layers
/// have transparent margins and the legacy icons have transparent rounded
/// corners; over the icon background color both are what the eye sees.
Image _overNavy(Image image, {required int size}) {
  final out = Image(width: size, height: size);
  fill(out, color: brandNavy);
  final scaled = copyResize(image, width: size, height: size);
  compositeImage(out, scaled);
  return out;
}

double _luminance(Pixel p) => 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;

/// Windowed SSIM (8×8 windows, C1=(0.01)², C2=(0.03)² on the 0–255 scale).
double _ssim(Image a, Image b) {
  assert(a.width == b.width && a.height == b.height,
      'ssim expects same-size images (${a.width}x${a.height} vs '
      '${b.width}x${b.height})');
  const window = 8;
  const c1 = 6.5025, c2 = 58.5225;
  var total = 0.0;
  var windows = 0;
  for (var wy = 0; wy + window <= a.height; wy += window) {
    for (var wx = 0; wx + window <= a.width; wx += window) {
      var meanA = 0.0, meanB = 0.0;
      for (var y = 0; y < window; y++) {
        for (var x = 0; x < window; x++) {
          meanA += _luminance(a.getPixel(wx + x, wy + y));
          meanB += _luminance(b.getPixel(wx + x, wy + y));
        }
      }
      final n = window * window;
      meanA /= n;
      meanB /= n;
      var varA = 0.0, varB = 0.0, cov = 0.0;
      for (var y = 0; y < window; y++) {
        for (var x = 0; x < window; x++) {
          final da = _luminance(a.getPixel(wx + x, wy + y)) - meanA;
          final db = _luminance(b.getPixel(wx + x, wy + y)) - meanB;
          varA += da * da;
          varB += db * db;
          cov += da * db;
        }
      }
      varA /= n - 1;
      varB /= n - 1;
      cov /= n - 1;
      total += ((2 * meanA * meanB + c1) * (2 * cov + c2)) /
          ((meanA * meanA + meanB * meanB + c1) * (varA + varB + c2));
      windows++;
    }
  }
  return windows == 0 ? 0 : total / windows;
}

/// The expected adaptive foreground: the master scaled into the adaptive
/// safe zone, centered on a transparent canvas. Mirrors
/// tool/generate_android_adaptive_icons.dart.
Image _expectedForeground(Image master, {required int size}) {
  const safeZoneFraction = 0.60; // master width / canvas width
  final inner = (size * safeZoneFraction).round();
  final canvas = Image(width: size, height: size);
  final scaled = copyResize(master, width: inner, height: inner);
  compositeImage(canvas, scaled,
      dstX: (size - inner) ~/ 2, dstY: (size - inner) ~/ 2);
  return canvas;
}

void main() {
  final master = _read(
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png');
  final resDir = '$_appRoot/android/app/src/main/res';

  test('legacy mipmaps derive from the iOS master (all densities)', () {
    const sizes = {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    };
    for (final entry in sizes.entries) {
      final icon = _read('$resDir/mipmap-${entry.key}/ic_launcher.png');
      expect(icon.width, entry.value,
          reason: 'mipmap-${entry.key} ic_launcher.png size');
      final expected = _overNavy(master, size: entry.value);
      final actual = _overNavy(icon, size: entry.value);
      final score = _ssim(expected, actual);
      expect(score, greaterThan(0.95),
          reason: 'mipmap-${entry.key} ic_launcher.png must match the iOS '
              'master (SSIM=$score)');
    }
  });

  test('adaptive foreground = master in the safe zone (all densities)', () {
    const sizes = {
      'mdpi': 108,
      'hdpi': 162,
      'xhdpi': 216,
      'xxhdpi': 324,
      'xxxhdpi': 432,
    };
    for (final entry in sizes.entries) {
      final fg = _read(
          '$resDir/mipmap-${entry.key}/ic_launcher_foreground.png');
      expect(fg.width, entry.value,
          reason: 'mipmap-${entry.key} foreground size');
      final expected = _expectedForeground(master, size: entry.value);
      final actual = _overNavy(fg, size: entry.value);
      final score = _ssim(_overNavy(expected, size: entry.value), actual);
      expect(score, greaterThan(0.95),
          reason: 'mipmap-${entry.key} foreground must be the iOS master '
              'scaled into the safe zone (SSIM=$score)');
    }
  });

  test('adaptive XML layers reference the brand resources, not templates',
      () {
    for (final name in ['ic_launcher.xml', 'ic_launcher_round.xml']) {
      final xml = File('$resDir/mipmap-anydpi-v26/$name').readAsStringSync();
      expect(xml, contains('@mipmap/ic_launcher_foreground'),
          reason: '$name foreground must be the brand mipmap layer');
      expect(xml, contains('@color/ic_launcher_background'),
          reason: '$name background must be the brand color layer');
      expect(xml, isNot(contains('@drawable/')),
          reason: '$name must not reference Flutter-template drawables');
    }

    final colors =
        File('$resDir/values/colors.xml').readAsStringSync();
    expect(colors, contains('#0b0f16'),
        reason: 'ic_launcher_background must stay the brand navy');

    // The Flutter-template density drawables must be gone entirely.
    final templateDirs = Directory('$_appRoot/android/app/src/main/res')
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.contains('drawable'))
        .toList();
    for (final dir in templateDirs) {
      final stale = Directory(dir.path)
          .listSync()
          .where((f) => f.path.endsWith('ic_launcher_foreground.png'));
      expect(stale, isEmpty,
          reason: 'template foreground leaked in ${dir.path}');
    }
  });
}
