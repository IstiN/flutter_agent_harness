/// Renders a terminal screen buffer as a PNG image so integration tests can
/// attach visual artifacts for vision-based verification.
///
/// The palette matches the Fa chrome: dark background (#070A10), light text
/// (#E8EEF7). Glyphs are drawn with the bitmap font bundled in
/// package:image — box-drawing characters outside its charset are skipped
/// by the renderer, which is fine for a layout sanity check.
library;

import 'dart:io';

import 'package:image/image.dart' as img;

/// Renders terminal screen lines as a PNG screenshot.
///
/// [lines] should be the full viewport (see `FaCliHarness.viewportLines`) so
/// blank rows keep their place. [columns]/[rows] fix the canvas geometry.
Future<File> renderTerminalScreenshot({
  required List<String> lines,
  required String outputPath,
  int columns = 80,
  int rows = 24,
}) async {
  const cellW = 9;
  const cellH = 18;
  final image = img.Image(width: columns * cellW, height: rows * cellH);
  img.fill(image, color: img.ColorRgb8(7, 10, 16));

  final font = img.arial14;
  for (var r = 0; r < lines.length && r < rows; r++) {
    final line = lines[r];
    if (line.isEmpty) continue;
    img.drawString(
      image,
      line,
      font: font,
      x: 2,
      y: r * cellH + 2,
      color: img.ColorRgb8(232, 238, 247),
    );
  }

  final png = img.encodePng(image);
  return File(outputPath).writeAsBytes(png);
}
