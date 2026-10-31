/// Programmatic stitch for `inspect_image` (gh-1985 C2): tile N source
/// images into ONE labeled composite so single-image-only models can still
/// answer multi-image (compare / coordinate) questions.
///
/// Layout contract (deterministic, testable):
/// - each tile normalizes into a fixed [stitchCell]×[stitchCell] cell,
///   keeping its aspect, anchored top-left; letterbox area stays black;
/// - ≤3 tiles stack vertically (one column); 4+ tiles lay out in a
///   2-column grid, last row padded with black cells;
/// - every tile carries a LABEL PLATE in its top-left corner: a black plate
///   with the tile letter (A, B, C, …) drawn white from an embedded 5x7
///   bitmap font — no font assets, byte-stable across platforms;
/// - the composite encodes as PNG (lossless labels).
library;

import 'dart:typed_data';

import 'package:image/image.dart';

/// Maximum tiles a composite carries (`inspect_image` caps `paths` at 8).
const stitchMaxTiles = 8;

/// Tile cell edge: every tile normalizes into a cell of this size.
const int stitchCell = 512;

/// Tile labels in ride order — `paths` index i gets [stitchTileLabels[i]].
const stitchTileLabels = 'ABCDEFGH';

/// The label glyph size (pixels).
const stitchGlyphWidth = 5, stitchGlyphHeight = 7;

/// The label plate padding around the glyph (pixels).
const stitchPlatePadding = 4;

/// Layout: one column for ≤3 tiles (vertical stack), a 2-column grid above.
int stitchColumns(int tileCount) => tileCount <= 3 ? 1 : 2;

/// Origin `(x, y)` of tile [index] (0-based) in a [tileCount]-tile
/// composite — the deterministic coordinate contract the compare/coordinate
/// questions rely on.
(int, int) stitchTileOrigin(int index, int tileCount) {
  final columns = stitchColumns(tileCount);
  return (index % columns * stitchCell, index ~/ columns * stitchCell);
}

/// The composite canvas size `(width, height)` for [tileCount] tiles.
(int, int) stitchCanvasSize(int tileCount) {
  final columns = stitchColumns(tileCount);
  final rows = (tileCount + columns - 1) ~/ columns;
  return (columns * stitchCell, rows * stitchCell);
}

/// 5x7 bitmap glyphs for the tile labels A–H, one row per scanline, MSB =
/// leftmost pixel. Embedded (instead of a font asset) so the labels are
/// byte-identical everywhere and trivially testable.
const _glyphs = <String, List<int>>{
  'A': [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
  'B': [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
  'C': [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
  'D': [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
  'E': [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
  'F': [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
  'G': [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E],
  'H': [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
};

/// The on-pixels `(x, y)` of [letter]'s label glyph at origin `(0, 0)` —
/// the assertion surface for "tile labels present in the emitted bytes".
List<(int, int)> stitchGlyphPixels(String letter) {
  final rows = _glyphs[letter.toUpperCase()];
  if (rows == null) {
    throw ArgumentError('no stitch glyph for "$letter"');
  }
  final pixels = <(int, int)>[];
  for (var y = 0; y < rows.length; y++) {
    for (var x = 0; x < stitchGlyphWidth; x++) {
      if ((rows[y] >> (stitchGlyphWidth - 1 - x)) & 0x1 == 0x1) {
        pixels.add((x, y));
      }
    }
  }
  return pixels;
}

/// Draws [letter] white onto [canvas] at `(x, y)` (the glyph's top-left).
void _drawGlyph(Image canvas, String letter, int x, int y) {
  for (final (dx, dy) in stitchGlyphPixels(letter)) {
    canvas.setPixel(x + dx, y + dy, ColorUint8.rgb(255, 255, 255));
  }
}

/// Tiles [tiles] (decoded, EXIF-baked source images in ride order) into the
/// labeled composite. Each tile fits [cell] keeping its aspect, anchored
/// top-left in its cell; every cell carries its letter plate in the
/// top-left corner; odd tile counts pad the last row with black.
Uint8List stitchTiles(List<Image> tiles, {int cell = stitchCell}) {
  if (tiles.isEmpty) {
    throw StateError('stitchTiles needs at least one tile');
  }
  if (tiles.length > stitchMaxTiles) {
    throw StateError(
      'stitchTiles caps at $stitchMaxTiles tiles '
      '(got ${tiles.length})',
    );
  }
  final (canvasWidth, canvasHeight) = stitchCanvasSize(tiles.length);
  final canvas = Image(width: canvasWidth, height: canvasHeight)
    ..clear(ColorUint8.rgb(0, 0, 0));
  for (var i = 0; i < tiles.length; i++) {
    final (originX, originY) = stitchTileOrigin(i, tiles.length);
    final source = tiles[i];
    final scale = (cell / source.width).clamp(0.0, cell / source.height);
    var drawWidth = (source.width * scale).round().clamp(1, cell);
    var drawHeight = (source.height * scale).round().clamp(1, cell);
    if (drawWidth > cell) drawWidth = cell;
    if (drawHeight > cell) drawHeight = cell;
    final tile = source.width == drawWidth && source.height == drawHeight
        ? source
        : copyResize(
            source,
            width: drawWidth,
            height: drawHeight,
            interpolation: Interpolation.cubic,
          );
    // Letterbox fill keeps the tile area black behind transparent pixels,
    // then the tile composes over it at the cell origin (top-left).
    compositeImage(canvas, tile, dstX: originX, dstY: originY);
    // The label plate: black plate + white glyph, deterministic placement.
    final plateWidth = stitchGlyphWidth + stitchPlatePadding * 2;
    final plateHeight = stitchGlyphHeight + stitchPlatePadding * 2;
    fillRect(
      canvas,
      x1: originX,
      y1: originY,
      x2: originX + plateWidth - 1,
      y2: originY + plateHeight - 1,
      color: ColorUint8.rgb(0, 0, 0),
    );
    _drawGlyph(
      canvas,
      stitchTileLabels[i],
      originX + stitchPlatePadding,
      originY + stitchPlatePadding,
    );
  }
  return Uint8List.fromList(encodePng(canvas));
}

/// The result-note line mapping tile letters to source paths (gh-1985 AC4:
/// "text note maps A/B/C → paths").
String stitchTileMapNote(List<String> paths) {
  final buffer = StringBuffer(
    '[Composite of ${paths.length} stitched image tiles '
    '(labels drawn in each tile\'s top-left corner):',
  );
  for (var i = 0; i < paths.length; i++) {
    buffer.write('\n  ${stitchTileLabels[i]} = ${paths[i]}');
  }
  buffer.write(']');
  return buffer.toString();
}
