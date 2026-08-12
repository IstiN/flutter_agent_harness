/// Renders a terminal screen buffer as a PNG image so integration tests can
/// attach visual artifacts for vision-based verification.
///
/// Reads the xterm cell attributes (ANSI colors) so the screenshot shows the
/// same colors the real terminal displays. Box-drawing characters (┌│└─)
/// are rendered as rectangles/lines because the bitmap font lacks them.
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

/// The 16 named ANSI colors.
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

/// Renders terminal screen as a PNG screenshot with colors from the xterm
/// cell attributes. Box-drawing characters are rendered as rectangles/lines.
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
    final y = row * cellH;
    for (var col = 0; col < columns && col < line.length; col++) {
      line.getCellData(col, cellData);
      final content = cellData.content & CellContent.codepointMask;
      if (content == 0) {
        // Empty cell — still render a space to fill the column so the
        // right border lands at the correct column.
        img.fillRect(
          image,
          x1: col * cellW,
          y1: y,
          x2: (col + 1) * cellW,
          y2: y + cellH,
          color: img.ColorRgb8(_bg.$1, _bg.$2, _bg.$3),
        );
        continue;
      }
      final color = _resolveColor(cellData);
      final x = col * cellW;
      _drawCell(image, content, x, y, cellW, cellH, color, font);
    }
  }

  final png = img.encodePng(image);
  return File(outputPath).writeAsBytes(png);
}

/// Draws a single terminal cell. Box-drawing characters are rendered as
/// rectangles/lines; everything else goes through the bitmap font.
void _drawCell(
  img.Image image,
  int content,
  int x,
  int y,
  int w,
  int h,
  (int, int, int) color,
  img.BitmapFont font,
) {
  final c = img.ColorRgb8(color.$1, color.$2, color.$3);
  final midY = y + h ~/ 2;
  final midX = x + w ~/ 2;

  switch (content) {
    case 0x2500: // ─ horizontal line
      img.drawLine(image, x1: x, y1: midY, x2: x + w, y2: midY, color: c);
    case 0x2502: // │ vertical line
      img.drawLine(image, x1: midX, y1: y, x2: midX, y2: y + h, color: c);
    case 0x250C: // ┌ top-left corner
      img.drawLine(image, x1: midX, y1: midY, x2: x + w, y2: midY, color: c);
      img.drawLine(image, x1: midX, y1: midY, x2: midX, y2: y + h, color: c);
    case 0x2510: // ┐ top-right corner
      img.drawLine(image, x1: x, y1: midY, x2: midX, y2: midY, color: c);
      img.drawLine(image, x1: midX, y1: midY, x2: midX, y2: y + h, color: c);
    case 0x2514: // └ bottom-left corner
      img.drawLine(image, x1: midX, y1: y, x2: midX, y2: midY, color: c);
      img.drawLine(image, x1: midX, y1: midY, x2: x + w, y2: midY, color: c);
    case 0x2518: // ┘ bottom-right corner
      img.drawLine(image, x1: x, y1: midY, x2: midX, y2: midY, color: c);
      img.drawLine(image, x1: midX, y1: y, x2: midX, y2: midY, color: c);
    case 0x251C: // ├ left T junction
      img.drawLine(image, x1: midX, y1: y, x2: midX, y2: y + h, color: c);
      img.drawLine(image, x1: midX, y1: midY, x2: x + w, y2: midY, color: c);
    case 0x2524: // ┤ right T junction
      img.drawLine(image, x1: midX, y1: y, x2: midX, y2: y + h, color: c);
      img.drawLine(image, x1: x, y1: midY, x2: midX, y2: midY, color: c);
    case 0x2588: // █ full block (cursor)
      img.fillRect(
        image,
        x1: x + 1,
        y1: y + 1,
        x2: x + w - 1,
        y2: y + h - 1,
        color: c,
      );
    case 0x25B8: // ▸ right-pointing triangle (selection marker)
      img.drawLine(
        image,
        x1: x + 1,
        y1: y + 2,
        x2: x + w - 2,
        y2: midY,
        color: c,
      );
      img.drawLine(
        image,
        x1: x + 1,
        y1: y + h - 2,
        x2: x + w - 2,
        y2: midY,
        color: c,
      );
      img.drawLine(
        image,
        x1: x + 1,
        y1: y + 2,
        x2: x + 1,
        y2: y + h - 2,
        color: c,
      );
    case 0x2022: // • bullet (masked input)
      img.fillCircle(image, x: midX, y: midY, radius: 2, color: c);
    case 0x25CB: // ○ circle (unselected)
      img.drawCircle(image, x: midX, y: midY, radius: w ~/ 3, color: c);
    case 0x25C9: // ◉ filled circle (selected)
      img.fillCircle(image, x: midX, y: midY, radius: w ~/ 3, color: c);
    case 0x2605: // ★ star (recommended)
      _drawStar(image, midX, midY, w ~/ 3, c);
    case 0x00B7: // · middle dot
      img.fillCircle(image, x: midX, y: midY, radius: 1, color: c);
    default:
      // Regular character — use the bitmap font.
      final char = String.fromCharCode(content);
      img.drawString(image, char, font: font, x: x + 2, y: y + 2, color: c);
  }
}

/// Draws a simple star shape (for the ★ recommended marker).
void _drawStar(img.Image image, int cx, int cy, int radius, img.Color c) {
  // Simple 5-pointed star approximation using lines.
  final points = <(int, int)>[];
  for (var i = 0; i < 5; i++) {
    final angle = -90.0 + i * 72.0;
    final rad = angle * 3.14159 / 180.0;
    points.add((
      (cx + radius * _cos(rad)).round(),
      (cy + radius * _sin(rad)).round(),
    ));
  }
  for (var i = 0; i < 5; i++) {
    final next = (i + 2) % 5;
    img.drawLine(
      image,
      x1: points[i].$1,
      y1: points[i].$2,
      x2: points[next].$1,
      y2: points[next].$2,
      color: c,
    );
  }
}

double _cos(double rad) {
  // Taylor series approximation for small angles.
  var x = rad % (2 * 3.14159);
  if (x > 3.14159) x -= 2 * 3.14159;
  final x2 = x * x;
  return 1.0 - x2 / 2.0 + x2 * x2 / 24.0;
}

double _sin(double rad) {
  var x = rad % (2 * 3.14159);
  if (x > 3.14159) x -= 2 * 3.14159;
  final x2 = x * x;
  return x - x * x2 / 6.0 + x * x2 * x2 / 120.0;
}

/// Resolves a cell's foreground color to RGB.
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

  if (cell.flags & CellAttr.bold != 0) return _text;
  if (cell.flags & CellAttr.faint != 0) return _dim;

  return _text;
}

/// The 256-color xterm palette.
(int, int, int) _palette256(int index) {
  if (index < 16) return _namedColors[index];
  if (index < 232) {
    final i = index - 16;
    final r = (i ~/ 36) % 6;
    final g = (i ~/ 6) % 6;
    final b = i % 6;
    return (r * 51, g * 51, b * 51);
  }
  final gray = 8 + (index - 232) * 10;
  return (gray, gray, gray);
}
