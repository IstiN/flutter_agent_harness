// Regenerates the Android launcher icons from the iOS release master
// (issue #289): the Android launcher must match the iOS app icon.
//
//   dart run tool/generate_android_adaptive_icons.dart
//
// Derivation (shared with test/android_icon_test.dart — the test asserts
// the output matches these parameters):
//
//   * legacy ic_launcher.png (mipmap-mdpi…xxxhdpi, 48–192 px): the iOS
//     1024 master, full-bleed, scaled to each density;
//   * adaptive foreground ic_launcher_foreground.png (108–432 px): the
//     master scaled into the adaptive safe zone (60% of the canvas width)
//     centered on a TRANSPARENT canvas — the adaptive background layer is
//     the brand navy @color/ic_launcher_background (#0b0f16), so the
//     margins composite seamlessly and the glyph survives every launcher
//     mask/parallax.
//
// The adaptive XML layers (mipmap-anydpi-v26) are hand-maintained and
// reference these outputs; icon/generate_icons.sh calls this tool for its
// Android leg (no rsvg/ImageMagick needed here).
//
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:image/image.dart';

const safeZoneFraction = 0.60;

const legacyDensities = {
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

const adaptiveDensities = {
  'mdpi': 108,
  'hdpi': 162,
  'xhdpi': 216,
  'xxhdpi': 324,
  'xxxhdpi': 432,
};

void main() {
  final appRoot = Directory.current.path; // flutter_app under `dart run`
  final masterPath =
      '$appRoot/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png';
  final masterBytes = File(masterPath).readAsBytesSync();
  final master = decodeImage(masterBytes);
  if (master == null) {
    stderr.writeln('could not decode the iOS master: $masterPath');
    exit(1);
  }
  if (master.width != 1024 || master.height != 1024) {
    stderr.writeln('unexpected iOS master size: '
        '${master.width}x${master.height} (want 1024x1024)');
    exit(1);
  }

  final res = '$appRoot/android/app/src/main/res';

  for (final entry in legacyDensities.entries) {
    final icon = copyResize(master, width: entry.value, height: entry.value);
    final out = '$res/mipmap-${entry.key}/ic_launcher.png';
    File(out).writeAsBytesSync(encodePng(icon));
    print('legacy  $out (${entry.value}x${entry.value})');
  }

  for (final entry in adaptiveDensities.entries) {
    final size = entry.value;
    final inner = (size * safeZoneFraction).round();
    final canvas = Image(width: size, height: size);
    final scaled = copyResize(master, width: inner, height: inner);
    compositeImage(canvas, scaled,
        dstX: (size - inner) ~/ 2, dstY: (size - inner) ~/ 2);
    final out = '$res/mipmap-${entry.key}/ic_launcher_foreground.png';
    File(out).writeAsBytesSync(encodePng(canvas));
    print('adaptive $out (${size}x$size, master@${inner}px in safe zone)');
  }

  print('Android launcher icons regenerated from the iOS master.');
}
