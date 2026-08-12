/// Renders a terminal screen buffer as a PNG image so integration tests can
/// attach visual artifacts for vision-based verification.
///
/// The palette matches the Fa chrome: dark background (#070A10), light text
/// (#E8EEF7). Colors are read from the xterm cell attributes (ANSI 256-color,
/// RGB true-color, and named colors) — the screenshot shows the same colors
/// the real terminal displays.
library;

import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:xterm/xterm.dart';

/// The Fa palette (from `lib/src/cli/fa_tui.dart`).
const _accentTeal = (94, 234, 212); // #5EEAD4
const _accentIndigo = (129, 140, 248); // #818CF8
const _dim = (147, 161, 181); // #93A1B5
const _text = (232, 238, 247); // #E8EEF7
const _bg = (7, 10, 16); // #070A10

/// The 16 named ANSI colors (standard + bright).
const _namedColors = [
  (0, 0, 0), // black
  (248, 113, 113), // red
  (34, 197, 94), // green
  (250, 204, 21), // yellow
  (59, 130, 246), // blue
  (168, 85, 247), // magenta
  _accentTeal, // cyan (teal accent)
  (255, 255, 255), // white
  (100, 116, 139), // bright black (gray)
  (255, 138, 128), // bright red
  (52, 211, 153), // bright green
  (254, 188, 46), // bright yellow
  _accentIndigo, // bright blue (indigo accent)
  (192, 132, 252), // bright magenta
  (94, 234, 212), // bright cyan (teal)
  (255, 255, 255), // bright white
];

/// Renders terminal screen lines as a PNG screenshot with colors from the
/// xterm cell attributes.
///
/// [terminal] is the xterm Terminal whose buffer contains the rendered
/// screen. [columns]/[rows] fix the canvas geometry (80x24 by default).
Future<File> renderTerminalScreenshot({
  required Terminal terminal,
  required String outputPath,
  int columns = 80,
  int rows = 24,
}) async {
  const cellW = 9;
  const cellH = 18;
  final image = img.Image(width: columns * cellW, height: rows * cellH);
  img.fill(image, color: img.ColorRgb8(_bg.$1, _bg.$2, _bg.$3));

  final font = img.arial14;
  final buf = terminal.buffer;
  final cellData = CellData.empty();

  for (var row = 0; row < rows && row < buf.lines.length; row++) {
    final line = buf.lines[row + buf.scrollBack];
    final y = row * cellH + 2;
    for (var col = 0; col < columns && col < line.length; col++) {
      line.getCellData(col, cellData);
      final content = cellData.content & CellContent.codepointMask;
      if (content == 0) continue; // empty cell
      final char = String.fromCharCode(content);
      final color = _resolveColor(cellData);
      img.drawString(
        image,
        char,
        font: font,
        x: col * cellW + 2,
        y: y,
        color: img.ColorRgb8(color.$1, color.$2, color.$3),
      );
    }
  }

  final png = img.encodePng(image);
  return File(outputPath).writeAsBytes(png);
}

/// Resolves a cell's foreground color to RGB.
/// Falls back to the default text color for unstyled cells.
(int, int, int) _resolveColor(CellData cell) {
  final fg = cell.foreground;
  final type = fg & CellColor.typeMask;
  final value = fg & CellColor.valueMask;

  if (type == CellColor.rgb) {
    final r = (value >> 16) & 0xFF;
    final g = (value >> 8) & 0xFF;
    final b = value & 0xFF;
    return (r, g, b);
  }

  if (type == CellColor.named) {
    if (value < _namedColors.length) return _namedColors[value];
    return _text;
  }

  if (type == CellColor.palette) {
    return _palette256(value);
  }

  // Normal/unstyled: check for bold/dim flags
  if (cell.flags & CellAttr.bold != 0) return _text;
  if (cell.flags & CellAttr.faint != 0) return _dim;

  return _text;
}

/// The 256-color xterm palette (first 16 are named, rest are computed).
(int, int, int) _palette256(int index) {
  if (index < 16) return _namedColors[index];
  if (index < 232) {
    // 216-color cube: index 16-231
    final i = index - 16;
    final r = (i ~/ 36) % 6;
    final g = (i ~/ 6) % 6;
    final b = i % 6;
    return (r * 51, g * 51, b * 51);
  }
  // Grayscale: index 232-255
  final gray = 8 + (index - 232) * 10;
  return (gray, gray, gray);
}
